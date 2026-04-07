# frozen_string_literal: true

module Funicular
  # Holds runtime configuration for the funicular gem.
  #
  # The most important setting is which PicoRuby.wasm artifact the
  # +picoruby_include_tag+ helper should reference, per Rails environment.
  #
  # Possible source values:
  #
  #   :local_debug - serve the debug build vendored into the gem and
  #                  installed under public/picoruby/debug/
  #   :local_dist  - serve the production (dist) build vendored into the
  #                  gem and installed under public/picoruby/dist/
  #   :cdn         - load from jsDelivr at
  #                  https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@VERSION/dist/init.iife.js
  #
  # Defaults are sensible for most apps:
  #
  #   development -> :local_debug
  #   test        -> :local_debug
  #   production  -> :local_dist
  #
  # Switch production to :cdn if you would rather not host the wasm yourself.
  class Configuration
    SOURCES = %i[local_debug local_dist cdn].freeze

    attr_reader :development_source, :test_source, :production_source
    attr_writer :cdn_version

    def initialize
      @development_source = :local_debug
      @test_source        = :local_debug
      @production_source  = :local_dist
      @cdn_version        = nil
    end

    def development_source=(value)
      @development_source = validate_source!(value)
    end

    def test_source=(value)
      @test_source = validate_source!(value)
    end

    def production_source=(value)
      @production_source = validate_source!(value)
    end

    # Returns the configured source for a given Rails environment name.
    # Unknown environments fall back to development_source.
    def source_for(env_name)
      case env_name.to_s
      when "production" then @production_source
      when "test"       then @test_source
      else                   @development_source
      end
    end

    # The @picoruby/wasm-wasi version to use when source is :cdn.
    # Falls back to the version of the wasm artifacts vendored in this gem.
    def cdn_version
      @cdn_version || Funicular.vendored_wasm_version
    end

    private

    def validate_source!(value)
      sym = value.to_sym
      unless SOURCES.include?(sym)
        raise ArgumentError, "Invalid Funicular source: #{value.inspect}. Expected one of #{SOURCES.inspect}"
      end
      sym
    end
  end
end
