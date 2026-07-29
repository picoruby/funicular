# frozen_string_literal: true

require "test_helper"
require "funicular/epoch_stamping"
require "funicular/epoch_header"

# Exercises Funicular::EpochStamping (the controller mixin the Railtie
# installs) and its interplay with the EpochHeader middleware. The
# around_action stamps the epoch before the action AND re-stamps in
# its ensure with the post-action identity: a login/logout inside the
# action rotates on its own response, and a raising action still gets
# a truthful header on the exception page.
class EpochStampingTest < Minitest::Test
  class FakeRequest
    attr_reader :env

    def initialize(env = {})
      @env = env
    end
  end

  class FakeControllerBase
    def self.around_action(name)
      (@around_actions ||= []) << name
    end

    def self.around_actions
      @around_actions || []
    end

    attr_reader :request, :session

    def initialize(session, env = {})
      @request = FakeRequest.new(env)
      @session = session
    end

    # A minimal filter chain: the action block runs inside every
    # registered around_action, exceptions propagating like Rails'.
    def process(&action)
      chain = self.class.around_actions.reverse.inject(action) do |inner, name|
        -> { send(name) { inner.call } }
      end
      chain.call
    end
  end

  class StampedController < FakeControllerBase
    include Funicular::EpochStamping

    attr_accessor :current_user_key
  end

  # What request.session looks like in a session-less Rails API app:
  # enabled? says no, every read and write raises.
  class DisabledSession
    def enabled?
      false
    end

    def [](_key)
      raise "sessions are disabled in this application"
    end

    def []=(_key, _value)
      raise "sessions are disabled in this application"
    end
  end

  def setup
    @config = Funicular::Configuration.new
    @config.local_database = true
    @config.user_key = ->(controller) { controller.current_user_key }
    Funicular.instance_variable_set(:@configuration, @config)
    @session = {}
  end

  def teardown
    Funicular.instance_variable_set(:@configuration, nil)
  end

  def session_epoch
    entry = @session["funicular_epochs"]
    entry ? entry["funicular"]["epoch"] : nil
  end

  # Runs one fake request: the controller starts as initial_key, the
  # action block may mutate it (login/logout), the env epoch is what
  # the middleware would write.
  def run_request(initial_key, env = {}, &action)
    controller = StampedController.new(@session, env)
    controller.current_user_key = initial_key
    controller.process { action ? action.call(controller) : nil }
    env["funicular.epoch"]
  end

  def test_including_registers_the_around_action
    assert_includes StampedController.around_actions, :stamp_funicular_epoch
  end

  def test_disabled_local_database_does_not_touch_the_session_or_resolver
    @config.local_database = false
    @config.user_key = ->(_controller) { flunk "resolver was called" }
    ran = false
    session = {}
    controller = StampedController.new(session)
    controller.current_user_key = "u1"
    controller.process { ran = true }
    assert ran
    assert_empty session
    assert_nil controller.request.env["funicular.epoch"]
  end

  def test_the_epoch_lands_in_the_request_env
    epoch = run_request("u1")
    refute_nil epoch
    refute_empty epoch
    # Same user, same session: stable across requests.
    assert_equal epoch, run_request("u1")
  end

  def test_the_env_value_matches_the_session_entry
    epoch = run_request("u1")
    assert_equal epoch, session_epoch
  end

  def test_a_login_inside_the_action_rotates_on_its_own_response
    # The page was rendered signed-out; the LOGIN action itself flips
    # the identity mid-request. Its own response must already carry
    # the rotated epoch -- with only a pre-action stamp, an old page
    # would apply the login response as an epoch match and the
    # rotation would be a request late.
    anonymous = run_request(nil)
    login_epoch = run_request(nil) do |controller|
      controller.current_user_key = "u1"
    end
    refute_equal anonymous, login_epoch
    assert_equal session_epoch, login_epoch
    # And it holds on the user's next request.
    assert_equal login_epoch, run_request("u1")
  end

  def test_a_logout_inside_the_action_rotates_on_its_own_response
    signed_in = run_request("u1")
    logout_epoch = run_request("u1") do |controller|
      controller.current_user_key = nil
    end
    refute_equal signed_in, logout_epoch
    assert_equal session_epoch, logout_epoch
  end

  def test_a_disabled_session_skips_stamping_but_runs_the_action
    # Session-less Rails API apps (no session middleware) must keep
    # working with Funicular merely loaded: the epoch feature stays
    # off instead of raising on every action.
    ran = false
    controller = StampedController.new(DisabledSession.new)
    controller.current_user_key = "u1"
    controller.process { ran = true }
    assert ran
    assert_nil controller.request.env["funicular.epoch"]
  end

  def test_an_enabled_session_object_still_stamps
    enabled = Hash.new
    def enabled.enabled?
      true
    end
    controller = StampedController.new(enabled)
    controller.current_user_key = "u1"
    controller.process { nil }
    refute_nil controller.request.env["funicular.epoch"]
  end

  def test_a_raising_action_still_produces_a_stamped_response
    # The exception renderer builds a FRESH response none of the
    # controller's headers survive into; the ensure re-stamp plus the
    # middleware cover it -- with the POST-transition identity even
    # when the action logged the user in before dying.
    inner = lambda do |env|
      controller = StampedController.new(@session, env)
      controller.current_user_key = nil
      begin
        controller.process do
          controller.current_user_key = "u1"
          raise "boom in the action"
        end
      rescue RuntimeError
        [500, {}, ["error page"]]
      end
    end
    status, headers, = Funicular::EpochHeader.new(inner).call({})
    assert_equal 500, status
    assert_equal session_epoch, headers["x-funicular-epoch"]
    assert_equal '["v1","funicular","user","u1"]',
                 @session["funicular_epochs"]["funicular"]["identity"]
  end
end
