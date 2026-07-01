# frozen_string_literal: true

require "logger"
require "pathname"

# A tiny stand-in for the slice of Rails the funicular gem touches, so the
# Rails-integration units (middleware, view helpers, the CLI command) can be
# exercised under plain minitest without booting a real application.
#
# Only what the gem actually reads is implemented: Rails.env (with the
# `env.development?` style predicates), Rails.root, Rails.logger, and
# Rails.application. Everything is resettable so tests stay isolated.
module Rails
  # String subclass answering `development?` / `production?` / `test?` etc.,
  # mirroring ActiveSupport::StringInquirer closely enough for the gem's needs.
  class EnvInquirer < String
    def method_missing(name, *args)
      str = name.to_s
      return super unless str.end_with?("?")

      self == str.chomp("?")
    end

    def respond_to_missing?(name, _include_private = false)
      name.to_s.end_with?("?") || super
    end
  end

  class << self
    attr_writer :root, :logger, :application
    attr_accessor :env_name

    def env
      EnvInquirer.new(env_name || "test")
    end

    def root
      @root
    end

    def logger
      @logger ||= Logger.new(IO::NULL)
    end

    def application
      @application
    end

    # Restore defaults between tests.
    def reset_stub!
      @root = nil
      @logger = Logger.new(IO::NULL)
      @application = nil
      @env_name = "test"
    end
  end

  reset_stub!
end
