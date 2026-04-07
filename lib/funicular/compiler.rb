# frozen_string_literal: true

require "shellwords"

module Funicular
  class Compiler
    class NodeNotFoundError < StandardError; end
    class PicorbcMissingError < StandardError; end

    # picorbc.js + picorbc.wasm bundled into the gem at build time by `rake copy_wasm`.
    PICORBC_DIR = File.expand_path("vendor/picorbc", __dir__)
    PICORBC_JS  = File.join(PICORBC_DIR, "picorbc.js")

    attr_reader :source_dir, :output_file, :debug_mode, :logger

    def initialize(source_dir:, output_file:, debug_mode: false, logger: nil)
      @source_dir = source_dir
      @output_file = output_file
      @debug_mode = debug_mode
      @logger = logger
    end

    def compile
      check_picorbc_availability!
      gather_source_files
      compile_to_mrb
    end

    private

    def check_picorbc_availability!
      unless File.exist?(PICORBC_JS)
        raise PicorbcMissingError, <<~ERROR
          Vendored picorbc not found at #{PICORBC_JS}.

          The funicular gem ships picorbc.js + picorbc.wasm inside the gem
          package. This file is missing, which likely means the gem was not
          installed correctly. Try reinstalling:

            bundle install --redownload

        ERROR
      end

      unless node_command
        raise NodeNotFoundError, <<~ERROR
          Node.js executable not found.

          Funicular compiles Ruby to .mrb using a WebAssembly build of picorbc
          which is run via Node.js. Please install Node.js and ensure `node`
          is on your PATH (or set the NODE environment variable).
        ERROR
      end
    end

    def node_command
      @node_command ||= ENV["NODE"] || which("node")
    end

    def which(cmd)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, cmd)
        return path if File.executable?(path) && !File.directory?(path)
      end
      nil
    end

    def gather_source_files
      models_files = Dir.glob(File.join(source_dir, "models", "**", "*.rb")).sort
      components_files = Dir.glob(File.join(source_dir, "components", "**", "*.rb")).sort
      initializer_files = Dir.glob(File.join(source_dir, "*_initializer.rb")).sort +
                          Dir.glob(File.join(source_dir, "initializer.rb")).sort

      # Order: models -> components -> initializer
      all_files = models_files + components_files + initializer_files

      if all_files.empty?
        raise "No Ruby files found in #{source_dir}"
      end

      # Create a small temp file for ENV setting
      env_file = "#{output_file}.env.rb"
      File.open(env_file, "w") do |f|
        f.puts "ENV['FUNICULAR_ENV'] = '#{Rails.env}'"
      end

      @source_files = all_files
      @env_file = env_file
    end

    def log(message)
      if logger
        logger.info(message)
        # Also output to stdout so logs are visible in terminal during development
        puts message if debug_mode
      else
        puts message
      end
    end

    def compile_to_mrb
      output_dir = File.dirname(output_file)
      FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

      all_files = @source_files + [@env_file]
      argv = [node_command, PICORBC_JS]
      argv << "-g" if debug_mode
      argv += ["-o", output_file.to_s]
      argv += all_files.map(&:to_s)

      log "Compiling Funicular application..."
      log "  Source: #{source_dir}"
      log "  Input files:"
      all_files.each do |file|
        log "    - #{file}"
      end
      log "  Output: #{output_file}"
      log "  Debug mode: #{debug_mode}"
      log "  Files: #{all_files.size} files"

      result = system(*argv)

      unless result
        raise "Failed to compile with picorbc. Command: #{Shellwords.join(argv)}"
      end

      log "Successfully compiled to #{output_file}"
    ensure
      # Keep temp file for debugging - set FUNICULAR_KEEP_TEMP=1 to inspect temp file
      unless ENV['FUNICULAR_KEEP_TEMP']
        File.delete(@env_file) if @env_file && File.exist?(@env_file)
      end
    end
  end
end
