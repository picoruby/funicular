# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "test_helper"

# Development-mode SSR reload: with auto_reload enabled (the railtie
# turns it on in development), editing an app source makes the next
# boot! re-load the sources, so server-rendered markup matches what the
# recompiled client bundle will hydrate.
class SSRReloadTest < Minitest::Test
  def setup
    Funicular::SSR::Runtime.load_framework!
  end

  def teardown
    Funicular::SSR::Runtime.auto_reload = false
    Funicular::SSR::Runtime.reset_app!
  end

  def write_component(dir, title)
    File.write(File.join(dir, "components", "reload_probe_component.rb"), <<~RUBY)
      class ReloadProbeComponent < Funicular::Component
        def render
          div { "#{title}" }
        end
      end
    RUBY
  end

  def build_app(dir)
    FileUtils.mkdir_p(File.join(dir, "components"))
    write_component(dir, "before reload")
    File.write(File.join(dir, "initializer.rb"), <<~RUBY)
      Funicular.start(container: "app") do |router|
        router.get("/probe", to: ReloadProbeComponent, as: "probe")
      end
    RUBY
  end

  def render_probe(dir)
    Funicular::SSR.render(path: "/probe", source_dir: dir)[:html]
  end

  def quietly
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end

  def test_edited_sources_are_reloaded_when_auto_reload_is_on
    Dir.mktmpdir do |dir|
      build_app(dir)
      Funicular::SSR::Runtime.reset_app!
      assert_includes render_probe(dir), "before reload"

      write_component(dir, "after reload")
      bump_mtime(dir)

      # Off (the default): still the stale markup.
      assert_includes render_probe(dir), "before reload"

      Funicular::SSR::Runtime.auto_reload = true
      quietly do
        assert_includes render_probe(dir), "after reload"
      end
    end
  end

  def test_reset_app_discards_the_snapshot
    Dir.mktmpdir do |dir|
      build_app(dir)
      Funicular::SSR::Runtime.reset_app!
      quietly { render_probe(dir) }
      refute Funicular::SSR::Runtime.sources_changed?(dir)

      Funicular::SSR::Runtime.reset_app!
      assert Funicular::SSR::Runtime.sources_changed?(dir)
    end
  end

  def test_unchanged_sources_are_not_reloaded
    Dir.mktmpdir do |dir|
      build_app(dir)
      Funicular::SSR::Runtime.reset_app!
      Funicular::SSR::Runtime.auto_reload = true
      quietly { render_probe(dir) }

      refute Funicular::SSR::Runtime.sources_changed?(dir)
    end
  end

  private

  # mtime comparison, not equality of content: make the edit observable
  # even on filesystems with coarse timestamps.
  def bump_mtime(dir)
    future = Time.now + 2
    Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
      File.utime(future, future, file)
    end
  end
end
