# frozen_string_literal: true

require "test_helper"

# Exercises Funicular::Configuration: the per-environment source selection, the
# source allowlist validation, and the cdn_version fallback to the vendored
# wasm version.
class ConfigurationTest < Minitest::Test
  def setup
    @config = Funicular::Configuration.new
  end

  def test_defaults
    assert_equal :local_debug, @config.development_source
    assert_equal :local_debug, @config.test_source
    assert_equal :local_dist,  @config.production_source
  end

  def test_source_for_known_environments
    assert_equal :local_debug, @config.source_for("development")
    assert_equal :local_debug, @config.source_for("test")
    assert_equal :local_dist,  @config.source_for("production")
  end

  def test_source_for_accepts_symbols
    assert_equal :local_dist, @config.source_for(:production)
  end

  def test_source_for_unknown_environment_falls_back_to_development
    assert_equal :local_debug, @config.source_for("staging")
  end

  def test_setters_accept_valid_sources
    @config.development_source = :cdn
    @config.test_source = "local_dist"
    @config.production_source = :cdn

    assert_equal :cdn, @config.development_source
    assert_equal :local_dist, @config.test_source
    assert_equal :cdn, @config.source_for("production")
  end

  def test_setters_reject_invalid_sources
    error = assert_raises(ArgumentError) { @config.production_source = :nonsense }
    assert_includes error.message, "Invalid Funicular source"
    assert_includes error.message, "nonsense"
  end

  def test_cdn_version_prefers_explicit_value
    @config.cdn_version = "9.9.9"
    assert_equal "9.9.9", @config.cdn_version
  end

  def test_cdn_version_falls_back_to_vendored_wasm_version
    # No explicit version set -> delegates to Funicular.vendored_wasm_version
    # (nil in a source checkout without vendored artifacts).
    vendored = Funicular.vendored_wasm_version
    if vendored.nil?
      assert_nil @config.cdn_version
    else
      assert_equal vendored, @config.cdn_version
    end
  end

  # --- local-database namespace settings (docs decisions 12/13) ---------

  def test_namespace_defaults
    assert_equal false, @config.local_database
    assert_equal "funicular", @config.application_id
    assert_nil @config.user_key
    assert_equal false, @config.anonymous_only
  end

  def test_local_database_setter_normalizes_truthiness
    @config.local_database = Object.new
    assert_equal true, @config.local_database
    @config.local_database = nil
    assert_equal false, @config.local_database
  end

  def test_disabled_local_database_needs_no_identity
    assert_equal true, @config.validate_local_database!
  end

  def test_enabled_local_database_requires_an_identity_declaration
    @config.local_database = true
    error = assert_raises(ArgumentError) do
      @config.validate_local_database!
    end
    assert_includes error.message, "user_key"
    assert_includes error.message, "anonymous_only"
  end

  def test_either_identity_declaration_satisfies_local_database
    @config.local_database = true
    @config.anonymous_only = true
    assert_equal true, @config.validate_local_database!

    fresh = Funicular::Configuration.new
    fresh.local_database = true
    fresh.user_key = ->(_controller) { nil }
    assert_equal true, fresh.validate_local_database!
  end

  def test_application_id_rejects_empty_values
    error = assert_raises(ArgumentError) { @config.application_id = "" }
    assert_includes error.message, "application_id"
    error = assert_raises(ArgumentError) { @config.application_id = nil }
    assert_includes error.message, "application_id"
  end

  def test_application_id_is_canonicalized_with_to_s
    @config.application_id = :chat_app
    assert_equal "chat_app", @config.application_id
  end

  def test_user_key_must_be_callable
    error = assert_raises(ArgumentError) { @config.user_key = "not callable" }
    assert_includes error.message, "callable"
  end

  def test_user_key_and_anonymous_only_are_mutually_exclusive
    # The reliably-detectable server-side config error: whichever
    # setter comes second raises, in both orders.
    @config.user_key = ->(controller) { nil }
    error = assert_raises(ArgumentError) { @config.anonymous_only = true }
    assert_includes error.message, "mutually exclusive"

    fresh = Funicular::Configuration.new
    fresh.anonymous_only = true
    error = assert_raises(ArgumentError) do
      fresh.user_key = ->(controller) { nil }
    end
    assert_includes error.message, "mutually exclusive"
  end

  def test_anonymous_only_false_never_conflicts
    @config.user_key = ->(controller) { nil }
    @config.anonymous_only = false
    assert_equal false, @config.anonymous_only
  end
end
