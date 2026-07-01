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
end
