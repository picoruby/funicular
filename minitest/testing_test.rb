# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "test_helper"
require_relative "support/rails_stub"
require "funicular/testing"

# Exercises the CRuby-side glue around the PicoRuby ("picotest") client test
# runner: the Result value object's tally math, the assertion bridging in
# Funicular::Testing.assert_picotests, and NodeRunner's pure output helpers.
# The actual Node/WASM subprocess launch (NodeRunner#run, Testing.run!) is
# integration-only and not exercised here.
class TestingTest < Minitest::Test
  Runner = Funicular::Testing::NodeRunner
  Result = Runner::Result

  # Stand-in for Process::Status: success? is all Result reads from it.
  Status = Struct.new(:ok) do
    def success? = ok
  end

  # Minimal Minitest::Test stand-in so assert_picotests can drive `assert`
  # and mutate `assertions` without touching this test's own counters.
  class FakeTestCase
    attr_accessor :assertions

    def initialize
      @assertions = 0
    end

    def assert(cond, msg = nil)
      @assertions += 1
      raise Minitest::Assertion, msg.to_s unless cond

      true
    end
  end

  def result(picotest_results, ok: true, stdout: "out", stderr: "")
    Result.new(status: Status.new(ok), stdout: stdout, stderr: stderr,
               picotest_results: picotest_results)
  end

  def sample_results
    {
      "AlphaTest" => { "success_count" => 3, "failures" => [{}], "skipped_count" => 1 },
      "BetaTest"  => { "success_count" => 2, "exceptions" => [{}], "crashes" => [{}] }
    }
  end

  # --- Result tallies ---------------------------------------------------

  def test_assertion_count_sums_successes_failures_exceptions_crashes
    # 3 + 1 (fail) + 2 + 1 (exc) + 1 (crash) = 8
    assert_equal 8, result(sample_results).picotest_assertion_count
  end

  def test_skip_and_test_counts
    r = result(sample_results)
    assert_equal 1, r.picotest_skip_count
    assert_equal 9, r.picotest_test_count # 8 assertions + 1 skip
  end

  def test_failure_exception_crash_counts
    r = result(sample_results)
    assert_equal 1, r.picotest_failure_count
    assert_equal 1, r.picotest_exception_count
    assert_equal 1, r.picotest_crash_count
  end

  def test_counts_tolerate_missing_keys_and_nil_results
    empty = result(nil)
    assert_equal 0, empty.picotest_assertion_count
    assert_equal 0, empty.picotest_skip_count

    sparse = result({ "T" => {} })
    assert_equal 0, sparse.picotest_assertion_count
  end

  def test_success_and_output
    assert_predicate result({}, ok: true), :success?
    refute_predicate result({}, ok: false), :success?

    # output joins non-empty stdout/stderr with a newline.
    assert_equal "out\nboom", result({}, stdout: "out", stderr: "boom").output
    assert_equal "out", result({}, stdout: "out", stderr: "").output
  end

  def test_summary_reports_every_dimension
    summary = result(sample_results).picotest_summary
    assert_includes summary, "9 tests"
    assert_includes summary, "8 assertions"
    assert_includes summary, "1 failures"
    assert_includes summary, "1 exceptions"
    assert_includes summary, "1 crashes"
    assert_includes summary, "1 skips"
  end

  # --- Testing.assert_picotests ----------------------------------------

  def test_assert_picotests_passes_and_bridges_assertion_count
    tc = FakeTestCase.new
    out, = capture_io do
      Funicular::Testing.assert_picotests(tc, result(sample_results))
    end

    assert_includes out, "Funicular picotest:"
    # 1 for the pass/fail `assert`, plus (assertion_count - 1) bridged.
    assert_equal 8, tc.assertions
  end

  def test_assert_picotests_can_suppress_summary
    tc = FakeTestCase.new
    out, = capture_io do
      Funicular::Testing.assert_picotests(tc, result(sample_results), print_summary: false)
    end
    assert_equal "", out
  end

  def test_assert_picotests_fails_with_output_when_run_failed
    tc = FakeTestCase.new
    r = result({}, ok: false, stdout: "boom detail")
    error = nil
    capture_io do
      error = assert_raises(Minitest::Assertion) do
        Funicular::Testing.assert_picotests(tc, r)
      end
    end
    assert_includes error.message, "boom detail"
  end

  # --- NodeRunner pure helpers -----------------------------------------

  def test_strip_ansi_removes_color_codes
    runner = Runner.new(app_root: Dir.pwd)
    assert_equal "hello", runner.send(:strip_ansi, "\e[32mhello\e[0m")
  end

  def test_extract_picotest_results_pulls_marker_line_out_of_stdout
    runner = Runner.new(app_root: Dir.pwd)
    marker = Runner::RESULT_MARKER
    stdout = "before\n#{marker}{\"AlphaTest\":{\"success_count\":1}}\nafter\n"

    results, remaining = runner.send(:extract_picotest_results, stdout)

    assert_equal({ "AlphaTest" => { "success_count" => 1 } }, results)
    assert_equal "before\nafter\n", remaining
  end

  def test_extract_picotest_results_ignores_malformed_marker
    runner = Runner.new(app_root: Dir.pwd)
    stdout = "#{Runner::RESULT_MARKER}not-json\n"

    results, remaining = runner.send(:extract_picotest_results, stdout)

    assert_equal({}, results)
    assert_equal stdout, remaining
  end

  def test_initialize_defaults_derive_source_dir_from_app_root
    Dir.mktmpdir do |dir|
      runner = Runner.new(app_root: dir)
      assert_equal File.join(dir, "app", "funicular"), runner.source_dir
      assert_equal Runner::DEFAULT_TEST_GLOB, runner.test_glob
    end
  end

  # --- NodeRunner file gathering / manifest ----------------------------

  def test_source_files_skips_initializers_for_a_generic_source_dir
    Dir.mktmpdir do |dir|
      source = File.join(dir, "src")
      FileUtils.mkdir_p(File.join(source, "components"))
      File.write(File.join(source, "components", "a_component.rb"), "")
      File.write(File.join(source, "top.rb"), "")
      File.write(File.join(source, "initializer.rb"), "")
      File.write(File.join(source, "app_initializer.rb"), "")

      runner = Runner.new(app_root: dir, source_dir: source)
      basenames = runner.send(:source_files).map { |f| File.basename(f) }

      assert_includes basenames, "a_component.rb"
      assert_includes basenames, "top.rb"
      refute_includes basenames, "initializer.rb"
      refute_includes basenames, "app_initializer.rb"
    end
  end

  def test_source_files_empty_when_dir_absent
    Dir.mktmpdir do |dir|
      runner = Runner.new(app_root: dir, source_dir: File.join(dir, "missing"))
      assert_equal [], runner.send(:source_files)
    end
  end

  def test_test_files_are_globbed_from_app_root
    Dir.mktmpdir do |dir|
      target = File.join(dir, "test", "funicular", "client")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "x_picotest.rb"), "")
      File.write(File.join(target, "not_a_test.rb"), "")

      runner = Runner.new(app_root: dir)
      found = runner.send(:test_files).map { |f| File.basename(f) }

      assert_equal ["x_picotest.rb"], found
    end
  end

  def test_build_manifest_shape
    Dir.mktmpdir do |dir|
      runner = Runner.new(app_root: dir, timeout_ms: 1234)
      manifest = runner.send(:build_manifest)

      assert_equal dir, manifest[:appRoot]
      assert_equal 1234, manifest[:timeoutMs]
      assert_includes manifest[:html], "<div id=\"app\">"
      assert_kind_of Array, manifest[:sourceFiles]
      assert_kind_of Array, manifest[:testFiles]
    end
  end

  def test_with_manifest_file_writes_json_and_cleans_up
    runner = Runner.new(app_root: Dir.pwd)
    captured = nil
    runner.send(:with_manifest_file, { appRoot: "/x", n: 1 }) do |path|
      captured = path
      assert File.exist?(path)
      assert_equal({ "appRoot" => "/x", "n" => 1 }, JSON.parse(File.read(path)))
    end
    refute File.exist?(captured), "manifest tempfile should be unlinked"
  end

  def test_app_root_defaults_to_rails_root
    Dir.mktmpdir do |dir|
      Rails.reset_stub!
      Rails.root = Pathname(dir)
      assert_equal File.expand_path(dir), Runner.new.app_root
    ensure
      Rails.reset_stub!
    end
  end

  def test_source_files_uses_compiler_order_for_a_rails_app_dir
    Dir.mktmpdir do |dir|
      app_funicular = File.join(dir, "app", "funicular")
      FileUtils.mkdir_p(File.join(app_funicular, "models"))
      FileUtils.mkdir_p(File.join(app_funicular, "components"))
      File.write(File.join(app_funicular, "models", "m_model.rb"), "")
      File.write(File.join(app_funicular, "components", "c_component.rb"), "")
      File.write(File.join(app_funicular, "initializer.rb"), "")

      runner = Runner.new(app_root: dir)
      basenames = runner.send(:source_files).map { |f| File.basename(f) }

      # Compiler order (models before components) and initializer excluded.
      assert_equal ["m_model.rb", "c_component.rb"], basenames
    end
  end

  def test_runner_js_points_at_the_bundled_mjs
    runner = Runner.new(app_root: Dir.pwd)
    assert_match %r{node_runner\.mjs\z}, runner.send(:runner_js)
  end
end
