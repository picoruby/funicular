# frozen_string_literal: true

require "tmpdir"

require "test_helper"
require_relative "support/rails_stub"
require "action_view"
require "funicular/helpers/picoruby_helper"

# Exercises the ActionView helpers (Funicular::Helpers::PicorubyHelper): the
# <script> bootstrap tag across the local/cdn sources, the SSR container, and
# the security-critical state-tag escaping. A minimal ActionView harness plus
# the Rails stub stand in for a booted app.
class PicorubyHelperTest < Minitest::Test
  # Just enough ActionView plumbing for the helper's tag/raw/safe_join calls.
  class Harness
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::OutputSafetyHelper
    include Funicular::Helpers::PicorubyHelper
  end

  def setup
    Rails.reset_stub!
    @view = Harness.new
    @config = Funicular::Configuration.new
    Funicular.instance_variable_set(:@configuration, @config)
  end

  def teardown
    Rails.reset_stub!
    Funicular.instance_variable_set(:@configuration, nil)
  end

  # --- picoruby_include_tag --------------------------------------------

  def test_local_dist_source_emits_script_and_base_style
    html = @view.picoruby_include_tag(source: :local_dist)
    assert_includes html, '<script src="/picoruby/dist/init.iife.js?v='
    assert_includes html, "<style"
    assert_includes html, "data-funicular-base"
  end

  def test_local_debug_source_path
    html = @view.picoruby_include_tag(source: :local_debug)
    assert_includes html, '<script src="/picoruby/debug/init.iife.js?v='
  end

  def test_base_styles_can_be_skipped
    html = @view.picoruby_include_tag(source: :local_dist, base_styles: false)
    assert_includes html, "<script"
    refute_includes html, "<style"
  end

  def test_source_defaults_to_configuration_for_current_env
    Rails.env_name = "production"
    @config.production_source = :local_dist
    html = @view.picoruby_include_tag
    assert_includes html, "/picoruby/dist/init.iife.js"
  end

  def test_extra_options_become_script_attributes
    html = @view.picoruby_include_tag(source: :local_dist, base_styles: false, defer: true)
    assert_includes html, "defer"
  end

  def test_cdn_source_uses_versioned_jsdelivr_url
    @config.cdn_version = "1.2.3"
    html = @view.picoruby_include_tag(source: :cdn, base_styles: false)
    assert_includes html,
                    "https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@1.2.3/dist/init.iife.js"
  end

  def test_cdn_source_without_version_raises
    @config.define_singleton_method(:cdn_version) { nil }
    error = assert_raises(ArgumentError) do
      @view.picoruby_include_tag(source: :cdn)
    end
    assert_includes error.message, ":cdn requires a version"
  end

  def test_unknown_source_raises
    error = assert_raises(ArgumentError) do
      @view.picoruby_include_tag(source: :bogus)
    end
    assert_includes error.message, "Unknown picoruby source"
  end

  # --- funicular_app_container -----------------------------------------

  def test_app_container_wraps_html_with_default_id
    html = @view.funicular_app_container("<h1>Hi</h1>")
    assert_includes html, '<div id="app">'
    assert_includes html, "<h1>Hi</h1>" # raw, not escaped
  end

  def test_app_container_accepts_custom_id_and_attributes
    html = @view.funicular_app_container("", id: "root", class: "shell")
    assert_includes html, 'id="root"'
    assert_includes html, 'class="shell"'
  end

  # --- funicular_state_tag (XSS-sensitive) -----------------------------

  def test_state_tag_serializes_state_as_json
    html = @view.funicular_state_tag({ "title" => "Channels" })
    assert_includes html, "window.__FUNICULAR_STATE__ = "
    assert_includes html, '"title":"Channels"'
  end

  def test_state_tag_escapes_script_breaking_characters
    html = @view.funicular_state_tag({ "x" => "</script><b>&" })
    refute_includes html, "</script><b>"
    assert_includes html, "\\u003c"
    assert_includes html, "\\u003e"
    assert_includes html, "\\u0026"
  end

  def test_state_tag_defaults_to_empty_object
    assert_includes @view.funicular_state_tag, "window.__FUNICULAR_STATE__ = {};"
    assert_includes @view.funicular_state_tag(nil), "{};"
  end

  # --- funicular_plugin_include_tags -----------------------------------

  def test_plugin_include_tags_empty_when_no_plugins
    Dir.mktmpdir do |dir|
      Rails.root = Pathname(dir)
      assert_equal "", @view.funicular_plugin_include_tags
    end
  end

  # --- base_css --------------------------------------------------------

  def test_base_css_is_read_once
    css = Funicular::Helpers::PicorubyHelper.base_css
    assert_kind_of String, css
    assert_same css, Funicular::Helpers::PicorubyHelper.base_css
  end
end
