# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "test_helper"

# Covers the freshness decision behind Funicular::Testing.ensure_compiled!.
# The actual compile (Node + vendored mrbc) is integration-only, matching
# the compiler tests' scope.
class TestingEnsureCompiledTest < Minitest::Test
  def test_stale_when_bundle_is_missing
    Dir.mktmpdir do |dir|
      assert Funicular::Testing.stale?(File.join(dir, "app.mrb"), [])
    end
  end

  def test_fresh_when_bundle_is_newer_than_every_source
    Dir.mktmpdir do |dir|
      source = File.join(dir, "component.rb")
      output = File.join(dir, "app.mrb")
      File.write(source, "")
      File.write(output, "")
      File.utime(Time.now - 60, Time.now - 60, source)

      refute Funicular::Testing.stale?(output, [ source ])
    end
  end

  def test_stale_when_any_source_is_newer_than_the_bundle
    Dir.mktmpdir do |dir|
      old_source = File.join(dir, "old.rb")
      new_source = File.join(dir, "new.rb")
      output = File.join(dir, "app.mrb")
      [ old_source, new_source, output ].each { |f| File.write(f, "") }
      File.utime(Time.now - 60, Time.now - 60, old_source)
      File.utime(Time.now - 30, Time.now - 30, output)
      File.utime(Time.now, Time.now, new_source)

      assert Funicular::Testing.stale?(output, [ old_source, new_source ])
    end
  end

  def test_missing_sources_do_not_count
    Dir.mktmpdir do |dir|
      output = File.join(dir, "app.mrb")
      File.write(output, "")

      refute Funicular::Testing.stale?(output, [ File.join(dir, "gone.rb") ])
    end
  end
end
