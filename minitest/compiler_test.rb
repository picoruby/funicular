# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "test_helper"
require_relative "support/rails_stub"

# Exercises the environment-independent parts of Funicular::Compiler: the
# source-file discovery/ordering (shared with the SSR runtime), the `node`
# executable lookup, and the vendored-mrbc availability guard. The actual
# spawn of mrbc via Node is integration-only and not covered here.
class CompilerTest < Minitest::Test
  def make_compiler(source_dir: "/tmp/app", output_file: "/tmp/out.mrb", **opts)
    Funicular::Compiler.new(source_dir: source_dir, output_file: output_file, **opts)
  end

  # --- source_files ordering -------------------------------------------

  def test_source_files_orders_models_stores_components_then_initializers
    Dir.mktmpdir do |dir|
      %w[models stores components].each { |d| FileUtils.mkdir_p(File.join(dir, d)) }
      File.write(File.join(dir, "models", "b_model.rb"), "")
      File.write(File.join(dir, "models", "a_model.rb"), "")
      File.write(File.join(dir, "stores", "s_store.rb"), "")
      File.write(File.join(dir, "components", "c_component.rb"), "")
      File.write(File.join(dir, "app_initializer.rb"), "")
      File.write(File.join(dir, "initializer.rb"), "")

      files = Funicular::Compiler.source_files(dir).map { |f| f.sub("#{dir}/", "") }

      assert_equal(
        [
          "models/a_model.rb",
          "models/b_model.rb",
          "stores/s_store.rb",
          "components/c_component.rb",
          "app_initializer.rb",
          "initializer.rb"
        ],
        files
      )
    end
  end

  def test_source_files_recurses_into_subdirectories
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "components", "nested"))
      File.write(File.join(dir, "components", "nested", "deep_component.rb"), "")

      files = Funicular::Compiler.source_files(dir)

      assert_equal 1, files.size
      assert_match %r{components/nested/deep_component\.rb\z}, files.first
    end
  end

  def test_source_files_empty_for_missing_directory
    assert_equal [], Funicular::Compiler.source_files("/no/such/dir")
  end

  # --- node executable lookup ------------------------------------------

  def test_node_command_prefers_node_env_var
    original = ENV["NODE"]
    ENV["NODE"] = "/custom/bin/node"
    assert_equal "/custom/bin/node", make_compiler.send(:node_command)
  ensure
    ENV["NODE"] = original
  end

  def test_which_finds_executable_on_path
    Dir.mktmpdir do |dir|
      exe = File.join(dir, "faketool")
      File.write(exe, "#!/bin/sh\n")
      File.chmod(0o755, exe)

      original = ENV["PATH"]
      ENV["PATH"] = dir
      assert_equal exe, make_compiler.send(:which, "faketool")
      assert_nil make_compiler.send(:which, "does_not_exist_tool")
    ensure
      ENV["PATH"] = original
    end
  end

  # --- availability guard ----------------------------------------------

  def test_compile_raises_when_vendored_mrbc_missing
    skip "vendored mrbc present in this checkout" if File.exist?(Funicular::Compiler::MRBC_JS)

    error = assert_raises(Funicular::Compiler::MrbcMissingError) { make_compiler.compile }
    assert_includes error.message, "Vendored mrbc not found"
  end

  def test_prepend_source_files_are_coerced_to_strings
    compiler = make_compiler(prepend_source_files: [Pathname.new("/a.rb"), :b])
    assert_equal ["/a.rb", "b"], compiler.prepend_source_files
  end

  # --- source gathering (writes the FUNICULAR_ENV temp file) -----------

  def test_gather_source_files_prepends_extras_and_writes_env_file
    Rails.reset_stub!
    Rails.env_name = "test"
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "components"))
      File.write(File.join(dir, "components", "a_component.rb"), "")
      output = File.join(dir, "build", "app.mrb")

      compiler = make_compiler(source_dir: dir, output_file: output,
                               prepend_source_files: ["/plugin/x.rb"])
      compiler.send(:gather_source_files)

      gathered = compiler.instance_variable_get(:@source_files)
      assert_equal "/plugin/x.rb", gathered.first
      assert(gathered.any? { |f| f.end_with?("a_component.rb") })

      env_file = compiler.instance_variable_get(:@env_file)
      assert_match(/FUNICULAR_ENV.*test/, File.read(env_file))
    ensure
      Rails.reset_stub!
    end
  end

  def test_gather_source_files_raises_without_ruby_files
    Dir.mktmpdir do |dir|
      compiler = make_compiler(source_dir: dir, output_file: File.join(dir, "out.mrb"))
      error = assert_raises(RuntimeError) { compiler.send(:gather_source_files) }
      assert_includes error.message, "No Ruby files found"
    end
  end

  # --- compile_to_mrb (spawns the mrbc command) ------------------------
  #
  # `true`/`false` stand in for `node mrbc.js ...`: both ignore their argv, so
  # the exit status alone drives the success/failure branches without needing a
  # real Node/WASM toolchain.

  def prepared_compiler(dir, node:, debug_mode: false)
    src = File.join(dir, "a.rb")
    File.write(src, "")
    compiler = make_compiler(source_dir: dir, output_file: File.join(dir, "out.mrb"),
                             debug_mode: debug_mode)
    compiler.instance_variable_set(:@node_command, node)
    compiler.instance_variable_set(:@source_files, [src])
    compiler.instance_variable_set(:@env_file, nil)
    compiler
  end

  def test_compile_to_mrb_succeeds_when_command_exits_zero
    Dir.mktmpdir do |dir|
      compiler = prepared_compiler(dir, node: "/bin/true", debug_mode: true)
      out, = capture_io { compiler.send(:compile_to_mrb) }
      assert_includes out, "Successfully compiled"
      assert_includes out, "Debug mode: true"
    end
  end

  def test_compile_to_mrb_raises_when_command_fails
    Dir.mktmpdir do |dir|
      compiler = prepared_compiler(dir, node: "/bin/false")
      error = nil
      capture_io do
        error = assert_raises(RuntimeError) { compiler.send(:compile_to_mrb) }
      end
      assert_includes error.message, "Failed to compile with mrbc"
    end
  end

  def test_compile_to_mrb_deletes_env_file_unless_kept
    Dir.mktmpdir do |dir|
      compiler = prepared_compiler(dir, node: "/bin/true")
      env_file = File.join(dir, "out.mrb.env.rb")
      File.write(env_file, "ENV['FUNICULAR_ENV'] = 'test'\n")
      compiler.instance_variable_set(:@env_file, env_file)

      capture_io { compiler.send(:compile_to_mrb) }
      refute File.exist?(env_file), "temp env file should be removed"
    end
  end

  def test_logger_is_used_when_provided
    Dir.mktmpdir do |dir|
      messages = []
      fake_logger = Object.new
      fake_logger.define_singleton_method(:info) { |m| messages << m }
      compiler = prepared_compiler(dir, node: "/bin/true")
      compiler.instance_variable_set(:@logger, fake_logger)

      compiler.send(:compile_to_mrb)
      assert(messages.any? { |m| m.include?("Successfully compiled") })
    end
  end
end
