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

  # --- page metadata (docs decisions 12/13) -----------------------------

  def test_disabled_include_tag_omits_all_local_database_metadata
    html = @view.picoruby_include_tag(source: :local_dist, base_styles: false)
    refute_includes html, "data-funicular-local-database"
    refute_includes html, "data-funicular-application-id"
    refute_includes html, "data-funicular-user-key"
    refute_includes html, "data-funicular-anonymous-only"
    refute_includes html, "data-funicular-epoch"
  end

  def test_disabled_include_tag_does_not_call_the_identity_resolver_or_session
    @config.user_key = ->(_controller) { flunk "resolver was called" }
    session = DisabledSession.new
    view = metadata_view(user_key: "u1", session: session)
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    refute_includes html, "data-funicular-local-database"
  end

  def test_include_tag_embeds_anonymous_only
    @config.local_database = true
    @config.anonymous_only = true
    html = @view.picoruby_include_tag(source: :local_dist, base_styles: false)
    assert_includes html, 'data-funicular-local-database="true"'
    assert_includes html, 'data-funicular-application-id="funicular"'
    assert_includes html, 'data-funicular-anonymous-only="true"'
  end

  def test_enabled_include_tag_requires_an_identity_declaration
    @config.local_database = true
    error = assert_raises(ArgumentError) do
      @view.picoruby_include_tag(source: :local_dist, base_styles: false)
    end
    assert_includes error.message, "user_key"
  end

  # A harness with the controller/request surface a real view has. The
  # helper reads the session through request.session (the view's own
  # session helper delegates to the controller, where an action named
  # "session" shadows it).
  class MetadataHarness < Harness
    attr_accessor :controller, :request
  end

  FakeController = Struct.new(:current_user_key)
  FakeViewRequest = Struct.new(:session)

  def metadata_view(user_key: nil, session: {})
    view = MetadataHarness.new
    view.controller = FakeController.new(user_key)
    view.request = FakeViewRequest.new(session)
    view
  end

  # A view rendered by a controller that routes an action named
  # "session": the view's session delegate would invoke that action.
  # The helper must go through request.session and never notice.
  class SessionShadowedHarness < MetadataHarness
    def session
      raise "the session delegate was invoked instead of request.session"
    end
  end

  def test_the_helper_never_calls_the_view_session_delegate
    @config.local_database = true
    @config.user_key = ->(controller) { controller.current_user_key }
    view = SessionShadowedHarness.new
    view.controller = FakeController.new("u1")
    view.request = FakeViewRequest.new({})
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    assert_includes html, "data-funicular-epoch"
  end

  def test_include_tag_embeds_user_key_and_epoch
    @config.local_database = true
    @config.user_key = ->(controller) { controller.current_user_key }
    session = {}
    view = metadata_view(user_key: "u1", session: session)
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    assert_includes html, 'data-funicular-user-key="u1"'
    assert_includes html, 'data-funicular-user-key-configured="true"'
    # The epoch on the page is THE session entry the response header
    # stamps: page and responses cannot disagree at render time.
    epoch = session["funicular_epochs"]["funicular"]["epoch"]
    assert_includes html, %(data-funicular-epoch="#{epoch}")
  end

  # What request.session looks like in a session-less Rails API app.
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

  def test_a_disabled_session_skips_the_epoch_without_breaking
    @config.local_database = true
    @config.user_key = ->(controller) { controller.current_user_key }
    view = metadata_view(user_key: "u1", session: DisabledSession.new)
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    refute_includes html, "data-funicular-epoch"
    assert_includes html, 'data-funicular-user-key="u1"'
  end

  def test_the_resolver_feeds_attribute_and_epoch_from_one_evaluation
    # A racy resolver (current_user changing between two calls) must
    # not embed user A's namespace while stamping user B's identity
    # into the epoch entry: the helper evaluates it exactly once.
    @config.local_database = true
    calls = 0
    @config.user_key = lambda do |_controller|
      calls += 1
      "u#{calls}"
    end
    session = {}
    view = metadata_view(user_key: "ignored", session: session)
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    assert_equal 1, calls
    assert_includes html, 'data-funicular-user-key="u1"'
    assert_equal '["v1","funicular","user","u1"]',
                 session["funicular_epochs"]["funicular"]["identity"]
  end

  def test_signed_out_omits_the_user_key_attribute
    @config.local_database = true
    @config.user_key = ->(controller) { controller.current_user_key }
    view = metadata_view(user_key: nil)
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    refute_includes html, "data-funicular-user-key="
    assert_includes html, 'data-funicular-user-key-configured="true"'
  end

  def test_metadata_values_are_html_escaped
    @config.local_database = true
    @config.application_id = %q{"><script>alert(1)</script>}
    @config.user_key = ->(controller) { controller.current_user_key }
    view = metadata_view(user_key: %q{"><img src=x>})
    html = view.picoruby_include_tag(source: :local_dist, base_styles: false)
    refute_includes html, "<script>alert(1)</script>"
    refute_includes html, "<img src=x>"
    assert_includes html, "&quot;&gt;"
  end

  def test_caller_data_attributes_survive_alongside_the_metadata
    @config.local_database = true
    @config.anonymous_only = true
    html = @view.picoruby_include_tag(source: :local_dist, base_styles: false,
                                      data: { turbo_track: "reload" })
    assert_includes html, 'data-turbo-track="reload"'
    assert_includes html, 'data-funicular-application-id="funicular"'
  end

  def test_caller_data_cannot_override_the_framework_metadata
    # A data: override of the epoch or the user key would make the
    # page disagree with its own responses (instant terminal) or boot
    # the wrong namespace: the framework's values win, in every key
    # spelling that would render as the same HTML attribute.
    @config.local_database = true
    @config.user_key = ->(controller) { controller.current_user_key }
    session = {}
    view = metadata_view(user_key: "u1", session: session)
    html = view.picoruby_include_tag(
      source: :local_dist, base_styles: false,
      data: { funicular_epoch: "evil-symbol",
              "funicular_user_key" => "evil-string",
              "funicular-application-id" => "evil-dashed",
              turbo_track: "reload" })
    refute_includes html, "evil-symbol"
    refute_includes html, "evil-string"
    refute_includes html, "evil-dashed"
    assert_includes html, 'data-funicular-user-key="u1"'
    assert_includes html, 'data-funicular-application-id="funicular"'
    epoch = session["funicular_epochs"]["funicular"]["epoch"]
    assert_includes html, %(data-funicular-epoch="#{epoch}")
    # The caller's unrelated attribute still rides along, and no
    # attribute is emitted twice.
    assert_includes html, 'data-turbo-track="reload"'
    assert_equal 1, html.scan("data-funicular-epoch=").size
    assert_equal 1, html.scan("data-funicular-user-key=").size
    assert_equal 1, html.scan("data-funicular-application-id=").size
  end

  def test_caller_data_cannot_enable_the_disabled_local_database
    html = @view.picoruby_include_tag(
      source: :local_dist, base_styles: false,
      data: { funicular_local_database: "true",
              "funicular-application-id" => "injected",
              funicular_anonymous_only: "true" })
    refute_includes html, "data-funicular-local-database"
    refute_includes html, "data-funicular-application-id"
    refute_includes html, "data-funicular-anonymous-only"
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
