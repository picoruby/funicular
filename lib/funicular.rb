# frozen_string_literal: true

require_relative "funicular/version"
require_relative "funicular/configuration"
require_relative "funicular/compiler"

module Funicular
  class Error < StandardError; end

  # Path to the directory containing vendored PicoRuby.wasm builds.
  VENDOR_PICORUBY_DIR = File.expand_path("funicular/vendor/picoruby", __dir__)

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Version of the @picoruby/wasm-wasi npm package whose builds are
    # vendored under lib/funicular/vendor/picoruby/. Written by the
    # funicular:vendor rake task at gem build time.
    def vendored_wasm_version
      @vendored_wasm_version ||= File.read(File.join(VENDOR_PICORUBY_DIR, "VERSION")).strip
    rescue Errno::ENOENT
      nil
    end
  end
end

if defined?(Rails)
  require_relative "funicular/middleware"
  require_relative "funicular/railtie"
end
