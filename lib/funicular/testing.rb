# frozen_string_literal: true

require_relative "testing/node_runner"
require_relative "plugin"
require_relative "compiler"

module Funicular
  module Testing
    def self.run!(**options)
      NodeRunner.new(**options).run
    end

    # One-call test-environment setup: syncs plugin assets and compiles
    # the client bundle when it is missing or older than any source or
    # plugin file. Development recompiles through the middleware and
    # production through assets:precompile, but the test environment
    # serves whatever app.mrb is lying around; call this once from
    # test_helper and rely on the mtime check to keep it cheap.
    #
    #   Funicular::Testing.ensure_compiled!            # Rails.root
    #   Funicular::Testing.ensure_compiled!(force: true)
    #
    # Returns the path of the compiled bundle.
    def self.ensure_compiled!(root: nil, force: false, debug_mode: true)
      root = Pathname.new(root || default_root)
      registry = Funicular::Plugin::Registry.new(root)
      registry.validate!
      registry.sync_assets

      source_dir = root.join("app", "funicular").to_s
      output_file = root.join("app", "assets", "builds", "app.mrb").to_s
      sources = registry.local_source_files + Funicular::Compiler.source_files(source_dir)

      if force || stale?(output_file, sources)
        Funicular::Compiler.new(
          source_dir: source_dir,
          output_file: output_file,
          debug_mode: debug_mode,
          prepend_source_files: registry.local_source_files
        ).compile
      end
      output_file
    end

    # A bundle is stale when it does not exist or any source file was
    # modified after it was built.
    def self.stale?(output_file, source_files)
      return true unless File.exist?(output_file)
      build_time = File.mtime(output_file)
      source_files.any? { |f| File.exist?(f) && File.mtime(f) > build_time }
    end

    def self.default_root
      raise ArgumentError, "root is required outside Rails" unless defined?(Rails) && Rails.respond_to?(:root)
      Rails.root
    end

    def self.assert_picotests(test_case, result, print_summary: true)
      puts result.picotest_summary if print_summary
      test_case.assert result.success?, result.output

      # The Minitest wrapper is one CRuby test method, but the actual client
      # checks run inside PicoRuby. Reflect those inner checks in Minitest's
      # assertion count so successful runs do not look like a single assertion.
      extra_assertions = result.picotest_assertion_count - 1
      test_case.assertions += extra_assertions if extra_assertions.positive?
    end
  end
end
