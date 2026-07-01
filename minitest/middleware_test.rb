# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "test_helper"
require_relative "support/rails_stub"
require "funicular/middleware"

# Exercises the development-only recompile middleware: when it decides to
# recompile (env + source dir presence + mtime), the compiling/last_mtime
# guard state machine, and that a compiler failure is swallowed so the request
# still passes through. The real mrbc spawn is stubbed out.
class MiddlewareTest < Minitest::Test
  def setup
    Rails.reset_stub!
    Rails.env_name = "development"
    Funicular::Middleware.reset!
    @downstream_calls = 0
    @app = ->(env) { @downstream_calls += 1; [200, {}, ["ok"]] }
  end

  def teardown
    Rails.reset_stub!
    Funicular::Middleware.reset!
  end

  # Builds an app dir with one source file and points Rails.root at it.
  def with_app
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "funicular"))
      File.write(File.join(dir, "app", "funicular", "home_component.rb"), "# c\n")
      Rails.root = Pathname(dir)
      yield dir
    end
  end

  # A compiler double whose #compile just records that it ran.
  def recording_compiler
    compiler = Object.new
    compiler.define_singleton_method(:compiled?) { @compiled ||= false }
    compiler.define_singleton_method(:compile) { @compiled = true }
    compiler
  end

  # Minitest 6 dropped Object#stub, so swap Compiler.new by hand. `replacement`
  # is returned as the compiler, unless it's callable, in which case it's
  # invoked with the constructor args (used to assert "never compiled").
  def stub_compiler_new(replacement)
    original = Funicular::Compiler.method(:new)
    Funicular::Compiler.define_singleton_method(:new) do |*args, **kwargs|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs) : replacement
    end
    yield
  ensure
    Funicular::Compiler.singleton_class.send(:remove_method, :new)
    Funicular::Compiler.define_singleton_method(:new, original)
  end

  def test_passes_request_through_downstream
    with_app do
      stub_compiler_new(recording_compiler) do
        status, _headers, body = Funicular::Middleware.new(@app).call({})
        assert_equal 200, status
        assert_equal ["ok"], body
      end
    end
    assert_equal 1, @downstream_calls
  end

  def test_skips_recompile_outside_development
    Rails.env_name = "production"
    with_app do
      stub_compiler_new(->(*) { flunk "should not compile in production" }) do
        Funicular::Middleware.new(@app).call({})
      end
    end
    assert_nil Funicular::Middleware.last_mtime
  end

  def test_skips_recompile_when_source_dir_absent
    Dir.mktmpdir do |dir|
      Rails.root = Pathname(dir) # no app/funicular
      stub_compiler_new(->(*) { flunk "should not compile without sources" }) do
        Funicular::Middleware.new(@app).call({})
      end
      assert_nil Funicular::Middleware.last_mtime
    end
  end

  def test_compiles_and_records_last_mtime_on_first_request
    with_app do
      compiler = recording_compiler
      stub_compiler_new(compiler) do
        Funicular::Middleware.new(@app).call({})
      end
      assert compiler.compiled?, "expected the compiler to run"
      refute_nil Funicular::Middleware.last_mtime
      refute Funicular::Middleware.compiling, "compiling flag must be cleared"
    end
  end

  def test_skips_recompile_when_sources_unchanged
    with_app do
      # Pretend a compile already happened in the future so nothing is stale.
      Funicular::Middleware.last_mtime = Time.now + 3600
      stub_compiler_new(->(*) { flunk "should not recompile unchanged sources" }) do
        Funicular::Middleware.new(@app).call({})
      end
    end
  end

  def test_compiler_failure_is_swallowed_and_request_continues
    with_app do
      exploding = Object.new
      exploding.define_singleton_method(:compile) { raise "mrbc boom" }
      stub_compiler_new(exploding) do
        status, = Funicular::Middleware.new(@app).call({})
        assert_equal 200, status
      end
      # Failure path must still clear the compiling guard.
      refute Funicular::Middleware.compiling
    end
    assert_equal 1, @downstream_calls
  end

  def test_successful_compile_sweeps_the_asset_pipeline_cache
    swept = []
    sweeper = Object.new
    sweeper.define_singleton_method(:execute) { swept << true }
    # Struct doubles mirror the Propshaft chain the middleware walks; their
    # respond_to? answers true for each member, matching the real objects.
    load_path = Struct.new(:cache_sweeper).new(sweeper)
    assets = Struct.new(:load_path).new(load_path)
    Rails.application = Struct.new(:assets).new(assets)

    with_app do
      stub_compiler_new(recording_compiler) do
        Funicular::Middleware.new(@app).call({})
      end
    end

    assert_equal [true], swept, "expected the Propshaft cache sweeper to run"
  end

  def test_reset_clears_class_state
    Funicular::Middleware.last_mtime = Time.now
    Funicular::Middleware.compiling = true
    Funicular::Middleware.reset!
    assert_nil Funicular::Middleware.last_mtime
    refute Funicular::Middleware.compiling
    assert_instance_of Mutex, Funicular::Middleware.mutex
  end
end
