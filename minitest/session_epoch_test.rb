# frozen_string_literal: true

require "test_helper"

# Exercises Funicular::SessionEpoch, the server half of the session
# epoch (docs decision 13): identity encoding, rotation on every
# authentication transition, stability while the identity holds, and
# per-application_id isolation inside one shared Rails session.
class SessionEpochTest < Minitest::Test
  FakeController = Struct.new(:current_user_key)

  def setup
    @config = Funicular::Configuration.new
    Funicular.instance_variable_set(:@configuration, @config)
    @session = {}
  end

  def teardown
    Funicular.instance_variable_set(:@configuration, nil)
  end

  def controller_for(key)
    FakeController.new(key)
  end

  def configure_user_key
    @config.user_key = ->(controller) { controller&.current_user_key }
  end

  def stamp(key)
    Funicular::SessionEpoch.stamp!(@session, controller_for(key))
  end

  # --- identity ---------------------------------------------------------

  def test_identity_is_the_typed_versioned_tuple
    configure_user_key
    assert_equal '["v1","funicular","anonymous"]',
                 Funicular::SessionEpoch.identity(controller_for(nil))
    assert_equal '["v1","funicular","user","u1"]',
                 Funicular::SessionEpoch.identity(controller_for("u1"))
  end

  def test_user_key_is_canonicalized_with_to_s
    configure_user_key
    assert_equal '["v1","funicular","user","42"]',
                 Funicular::SessionEpoch.identity(controller_for(42))
  end

  def test_a_user_key_of_anonymous_cannot_collide_with_signed_out
    configure_user_key
    refute_equal Funicular::SessionEpoch.identity(controller_for(nil)),
                 Funicular::SessionEpoch.identity(controller_for("anonymous"))
  end

  def test_without_a_user_key_lambda_everyone_is_anonymous
    assert_equal '["v1","funicular","anonymous"]',
                 Funicular::SessionEpoch.identity(controller_for("u1"))
  end

  def test_empty_resolved_user_key_fails_loud
    configure_user_key
    error = assert_raises(Funicular::Error) { stamp("") }
    assert_includes error.message, "empty"
  end

  # --- rotation ---------------------------------------------------------

  def test_stamp_creates_and_then_holds_an_epoch
    configure_user_key
    epoch = stamp("u1")
    refute_empty epoch
    assert_equal epoch, stamp("u1")
    assert_equal epoch, stamp("u1")
  end

  def test_login_logout_and_switch_all_rotate
    configure_user_key
    anonymous = stamp(nil)
    login = stamp("u1")
    refute_equal anonymous, login
    switch = stamp("u2")
    refute_equal login, switch
    logout = stamp(nil)
    refute_equal switch, logout
    # A fresh anonymous epoch, not the first one resurrected.
    refute_equal anonymous, logout
  end

  # --- per-application isolation ----------------------------------------

  def test_epochs_are_tracked_per_application_id
    configure_user_key
    epoch_a = stamp("u1")
    @config.application_id = "second_app"
    epoch_b = stamp("u1")
    refute_equal epoch_a, epoch_b
    # Rotating the second app's epoch leaves the first app's alone.
    stamp("u2")
    @config.application_id = "funicular"
    assert_equal epoch_a, stamp("u1")
  end

  # --- session shape ------------------------------------------------------

  def test_session_entry_uses_string_keys_for_json_round_trips
    configure_user_key
    epoch = stamp("u1")
    entry = @session["funicular_epochs"]["funicular"]
    assert_equal '["v1","funicular","user","u1"]', entry["identity"]
    assert_equal epoch, entry["epoch"]
  end

  def test_a_corrupt_session_value_is_replaced_not_crashed_on
    configure_user_key
    @session["funicular_epochs"] = "garbage"
    epoch = stamp("u1")
    refute_empty epoch
    assert_equal epoch,
                 @session["funicular_epochs"]["funicular"]["epoch"]
  end
end
