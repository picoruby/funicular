# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module Funicular
  module Testing
    class NodeRunner
      RESULT_MARKER = "__FUNICULAR_TEST_RESULTS_JSON__="

      Result = Struct.new(:status, :stdout, :stderr, :picotest_results, keyword_init: true) do
        def success?
          status.success?
        end

        def output
          [stdout, stderr].reject(&:empty?).join("\n")
        end

        def picotest_assertion_count
          each_picotest_result.sum do |_name, result|
            result.fetch("success_count", 0) +
              Array(result["failures"]).size +
              Array(result["exceptions"]).size +
              Array(result["crashes"]).size
          end
        end

        def picotest_test_count
          picotest_assertion_count + picotest_skip_count
        end

        def picotest_failure_count
          each_picotest_result.sum { |_name, result| Array(result["failures"]).size }
        end

        def picotest_exception_count
          each_picotest_result.sum { |_name, result| Array(result["exceptions"]).size }
        end

        def picotest_crash_count
          each_picotest_result.sum { |_name, result| Array(result["crashes"]).size }
        end

        def picotest_skip_count
          each_picotest_result.sum { |_name, result| result.fetch("skipped_count", 0) }
        end

        def picotest_summary
          "Funicular picotest: #{picotest_test_count} tests, " \
            "#{picotest_assertion_count} assertions, " \
            "#{picotest_failure_count} failures, " \
            "#{picotest_exception_count} exceptions, " \
            "#{picotest_crash_count} crashes, " \
            "#{picotest_skip_count} skips"
        end

        private

        def each_picotest_result
          (picotest_results || {}).each
        end
      end

      DEFAULT_TEST_GLOB = "test/funicular/client/**/*_picotest.rb"

      attr_reader :app_root, :source_dir, :test_glob, :runtime_dir, :node, :timeout_ms

      def initialize(app_root: nil, source_dir: nil, test_glob: DEFAULT_TEST_GLOB,
                     runtime_dir: nil, node: nil, timeout_ms: 5000)
        @app_root = File.expand_path(app_root || rails_root || Dir.pwd)
        @source_dir = File.expand_path(source_dir || File.join(@app_root, "app", "funicular"))
        @test_glob = test_glob
        @runtime_dir = File.expand_path(runtime_dir || default_runtime_dir)
        @node = node || ENV["NODE"] || "node"
        @timeout_ms = timeout_ms
      end

      def run
        manifest = build_manifest
        with_manifest_file(manifest) do |path|
          stdout, stderr, status = Open3.capture3(node, runner_js, path, chdir: app_root)
          stdout = strip_ansi(stdout)
          stderr = strip_ansi(stderr)
          results, stdout = extract_picotest_results(stdout)
          Result.new(status: status, stdout: stdout, stderr: stderr, picotest_results: results)
        end
      end

      private

      def strip_ansi(output)
        output.gsub(/\e\[[0-9;]*m/, "")
      end

      def extract_picotest_results(output)
        results = {}
        lines = output.lines.reject do |line|
          next false unless line.start_with?(RESULT_MARKER)

          results = JSON.parse(line.delete_prefix(RESULT_MARKER))
          true
        rescue JSON::ParserError
          false
        end
        [results, lines.join]
      end

      def rails_root
        Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
      end

      def gem_root
        File.expand_path("../../..", __dir__)
      end

      def default_runtime_dir
        ENV["FUNICULAR_TEST_PICORUBY_DIR"] ||
          existing_path(File.join(gem_root, "lib", "funicular", "vendor", "picoruby-test-node")) ||
          existing_path(File.expand_path("../picoruby/build/picoruby-wasm-test/bin", gem_root)) ||
          existing_path(File.expand_path("../../build/picoruby-wasm-test/bin", gem_root)) ||
          File.join(gem_root, "lib", "funicular", "vendor", "picoruby-test-node")
      end

      def existing_path(path)
        path if Dir.exist?(path)
      end

      def runner_js
        File.expand_path("node_runner.mjs", __dir__)
      end

      def build_manifest
        {
          appRoot: app_root,
          runtimeDir: runtime_dir,
          timeoutMs: timeout_ms,
          html: "<!doctype html><html><body><div id=\"app\"></div></body></html>",
          url: "http://localhost/",
          sourceFiles: source_files,
          testFiles: test_files
        }
      end

      def source_files
        return [] unless Dir.exist?(source_dir)

        files = if rails_app_source_dir? && defined?(Funicular::Compiler)
                  Funicular::Compiler.source_files(source_dir)
                else
                  generic_source_files
                end
        app_files = files.reject { |path| File.basename(path) == "initializer.rb" || path.end_with?("_initializer.rb") }
        plugin_source_files + app_files
      end

      def rails_app_source_dir?
        source_dir == File.expand_path(File.join(app_root, "app", "funicular"))
      end

      def generic_source_files
        nested = Dir.glob(File.join(source_dir, "*", "**", "*.rb")).sort
        top_level = Dir.glob(File.join(source_dir, "*.rb")).sort
        nested + top_level
      end

      def plugin_source_files
        return [] unless defined?(Funicular::Plugin::Registry)

        Funicular::Plugin::Registry.new(app_root).local_source_files
      rescue Funicular::Plugin::Error
        []
      end

      def test_files
        Dir.glob(File.join(app_root, test_glob)).sort
      end

      def with_manifest_file(manifest)
        file = Tempfile.new(["funicular-test-manifest", ".json"])
        file.write(JSON.pretty_generate(manifest))
        file.close
        yield file.path
      ensure
        file&.unlink
      end
    end
  end
end
