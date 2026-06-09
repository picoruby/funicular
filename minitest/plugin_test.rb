# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "test_helper"

class PluginTest < Minitest::Test
  def test_registry_resolves_funicular_group_gems_and_syncs_assets
    Dir.mktmpdir do |dir|
      rails_root = File.join(dir, "app")
      gem_root = File.join(dir, "funicular-datepicker")
      FileUtils.mkdir_p(File.join(gem_root, "lib", "components"))
      FileUtils.mkdir_p(File.join(gem_root, "assets"))
      File.write(File.join(gem_root, "lib", "date_picker.rb"), "# plugin entry\n")
      File.write(File.join(gem_root, "lib", "components", "date_picker_component.rb"), "# component\n")
      File.write(File.join(gem_root, "assets", "date_picker.css"), "/* css */\n")

      spec = Gem::Specification.new do |s|
        s.name = "funicular-datepicker"
        s.version = "0.1.0"
        s.full_gem_path = gem_root
      end

      registry = Funicular::Plugin::Registry.new(rails_root)
      registry.define_singleton_method(:funicular_specs) { [spec] }
      registry.sync_assets

      synced_css = File.join(
        rails_root,
        "app",
        "assets",
        "builds",
        "funicular",
        "plugins",
        "funicular_datepicker",
        "date_picker.css"
      )
      assert File.exist?(synced_css)

      entries = registry.asset_entries
      assert_equal 1, entries.size
      assert_equal "css", entries.first["type"]
      assert_equal "funicular/plugins/funicular_datepicker/date_picker.css", entries.first["logical_path"]
      assert_equal [
        File.join(gem_root, "lib", "components", "date_picker_component.rb"),
        File.join(gem_root, "lib", "date_picker.rb")
      ], registry.local_source_files
    end
  end
end
