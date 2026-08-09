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
    attr_reader :application_id, :user_key, :anonymous_only, :local_database
    attr_writer :cdn_version

    def initialize
      @development_source = :local_debug
      @test_source        = :local_debug
      @production_source  = :local_dist
      @cdn_version        = nil
      @application_id     = "funicular"
      @user_key           = nil
      @anonymous_only     = false
      @local_database     = false
    end

    # The SQLite/IndexedDB subsystem is deliberately opt-in. A plain
    # Funicular application remains REST-only and pays none of its boot,
    # storage, locking, or session-epoch costs.
    def local_database=(value)
      @local_database = value ? true : false
    end

    # Called after Rails initializers and again when the include tag is
    # rendered. The client boot separately validates the emitted contract.
    # Validation cannot run from local_database= because initializer
    # assignment order is free.
    def validate_local_database!
      return true unless @local_database
      return true if @user_key || @anonymous_only

      raise ArgumentError,
            "Funicular local_database requires config.user_key or " \
            "config.anonymous_only = true"
    end

    # The application's namespace id (docs: local_database.md, data
    # isolation). Give each Funicular app sharing an origin a distinct
    # one; it keys the client's snapshot/lock namespace AND the epoch
    # entry in the Rails session.
    def application_id=(value)
      id = value.to_s
      if id.empty?
        raise ArgumentError, "Funicular application_id cannot be empty"
      end
      @application_id = id
    end

    # A callable receiving the controller and returning a stable,
    # non-reusable identifier for the signed-in user (nil when signed
    # out). Mandatory whenever the local database is enabled, unless
    # anonymous_only says the app genuinely has no users.
    def user_key=(value)
      unless value.respond_to?(:call)
        raise ArgumentError,
              "Funicular user_key must be callable (a lambda receiving the controller)"
      end
      if @anonymous_only
        raise ArgumentError,
              "Funicular user_key and anonymous_only are mutually exclusive; declare one or the other"
      end
      @user_key = value
    end

    # The explicit opt-out for apps without authentication: every
    # visitor shares the anonymous namespace ON PURPOSE. Mutually
    # exclusive with user_key -- the framework never picks silently.
    def anonymous_only=(value)
      flag = value ? true : false
      if flag && @user_key
        raise ArgumentError,
              "Funicular user_key and anonymous_only are mutually exclusive; declare one or the other"
      end
      @anonymous_only = flag
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
