# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module Funicular
  module Testing
    class NodeRunner
      Result = Struct.new(:status, :stdout, :stderr, keyword_init: true) do
        def success?
          status.success?
        end

        def output
          [stdout, stderr].reject(&:empty?).join("\n")
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
          Result.new(status: status, stdout: strip_ansi(stdout), stderr: strip_ansi(stderr))
        end
      end

      private

      def strip_ansi(output)
        output.gsub(/\e\[[0-9;]*m/, "")
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
