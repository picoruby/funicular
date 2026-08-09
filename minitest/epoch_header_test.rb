# frozen_string_literal: true

require "test_helper"
require "funicular/epoch_header"

# Exercises Funicular::EpochHeader, the middleware that writes
# X-Funicular-Epoch on every outgoing response: from the env value the
# controller concern pinned, from the stored session entry when the
# request died before the concern ran, or not at all when neither
# exists.
class EpochHeaderTest < Minitest::Test
  # Lowercase: the Rack 3 spec requires lowercase response header
  # names, and HTTP header lookups are case-insensitive client-side.
  HEADER = "x-funicular-epoch"

  def setup
    @config = Funicular::Configuration.new
    @config.local_database = true
    Funicular.instance_variable_set(:@configuration, @config)
  end

  def teardown
    Funicular.instance_variable_set(:@configuration, nil)
  end

  def app_returning(status, headers = {})
    ->(_env) { [status, headers, ["body"]] }
  end

  def test_writes_the_env_pinned_epoch
    middleware = Funicular::EpochHeader.new(app_returning(200))
    _, headers, = middleware.call({ "funicular.epoch" => "e-ctrl" })
    assert_equal "e-ctrl", headers[HEADER]
  end

  def test_disabled_local_database_leaves_the_response_untouched
    @config.local_database = false
    headers = { HEADER => "inner", "X-Funicular-Epoch" => "legacy" }
    middleware = Funicular::EpochHeader.new(app_returning(200, headers))
    _, result, = middleware.call({ "funicular.epoch" => "outer" })
    assert_same headers, result
    assert_equal "inner", result[HEADER]
    assert_equal "legacy", result["X-Funicular-Epoch"]
  end

  def test_falls_back_to_the_stored_session_epoch
    # The concern never ran (an earlier before_action raised, say),
    # but the session already carries this app's epoch: stamped
    # without rotation.
    session = {
      "funicular_epochs" => {
        "funicular" => { "identity" => "i", "epoch" => "e-stored" },
      },
    }
    middleware = Funicular::EpochHeader.new(app_returning(500))
    _, headers, = middleware.call({ "rack.session" => session })
    assert_equal "e-stored", headers[HEADER]
  end

  def test_the_env_value_wins_over_the_stored_one
    session = {
      "funicular_epochs" => {
        "funicular" => { "identity" => "i", "epoch" => "e-stored" },
      },
    }
    middleware = Funicular::EpochHeader.new(app_returning(200))
    _, headers, = middleware.call(
      { "funicular.epoch" => "e-ctrl", "rack.session" => session })
    assert_equal "e-ctrl", headers[HEADER]
  end

  def test_without_any_epoch_the_header_stays_absent
    middleware = Funicular::EpochHeader.new(app_returning(200))
    _, headers, = middleware.call({})
    refute headers.key?(HEADER)
  end

  def test_an_inner_header_is_dropped_when_no_epoch_is_available
    # No env value and no session: the contract is "no authoritative
    # epoch, no header". An inner layer's leftover would otherwise
    # survive as the page's only epoch signal -- and one stamped
    # before the session rotated would read as a MATCH, keeping a page
    # alive that decision 13 wants terminal.
    middleware = Funicular::EpochHeader.new(
      app_returning(200, { HEADER => "stale-pre-login" }))
    _, headers, = middleware.call({})
    refute headers.key?(HEADER)
  end

  def test_a_legacy_cased_inner_header_is_dropped_without_an_epoch_too
    middleware = Funicular::EpochHeader.new(
      app_returning(200, { "X-Funicular-Epoch" => "stale-pre-login" }))
    _, headers, = middleware.call({})
    refute headers.key?("X-Funicular-Epoch")
    refute headers.key?(HEADER)
  end

  def test_respects_the_configured_application_id
    @config.application_id = "second_app"
    session = {
      "funicular_epochs" => {
        "funicular"  => { "identity" => "i", "epoch" => "e-other" },
        "second_app" => { "identity" => "i", "epoch" => "e-mine" },
      },
    }
    middleware = Funicular::EpochHeader.new(app_returning(200))
    _, headers, = middleware.call({ "rack.session" => session })
    assert_equal "e-mine", headers[HEADER]
  end

  def test_overwrites_a_stale_inner_header
    # An inner layer's header may have been stamped BEFORE a login/
    # logout rotated the epoch; keeping it would let an old page apply
    # the post-transition response as a match. The framework's value
    # is authoritative.
    middleware = Funicular::EpochHeader.new(
      app_returning(200, { HEADER => "stale-pre-login" }))
    _, headers, = middleware.call({ "funicular.epoch" => "e-ctrl" })
    assert_equal "e-ctrl", headers[HEADER]
  end

  def test_a_legacy_cased_inner_header_cannot_ride_out_as_a_duplicate
    # Plain header hashes are case-sensitive: a stale capitalized
    # spelling must be removed, not merely shadowed by our lowercase
    # (Rack 3) name.
    middleware = Funicular::EpochHeader.new(
      app_returning(200, { "X-Funicular-Epoch" => "stale-pre-login" }))
    _, headers, = middleware.call({ "funicular.epoch" => "e-ctrl" })
    assert_equal "e-ctrl", headers[HEADER]
    refute headers.key?("X-Funicular-Epoch")
  end

  def test_the_header_name_is_lowercase_for_rack_3
    middleware = Funicular::EpochHeader.new(app_returning(200))
    _, headers, = middleware.call({ "funicular.epoch" => "e-ctrl" })
    assert_equal ["x-funicular-epoch"], headers.keys
  end

  def test_a_broken_session_read_never_masks_the_response
    broken = Object.new
    def broken.[](_key)
      raise "session store exploded"
    end
    middleware = Funicular::EpochHeader.new(app_returning(500))
    status, headers, = middleware.call({ "rack.session" => broken })
    assert_equal 500, status
    refute headers.key?(HEADER)
  end
end
