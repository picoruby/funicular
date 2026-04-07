# frozen_string_literal: true

module Funicular
  module Helpers
    # View helpers exposed to ActionView through Funicular::Railtie.
    module PicorubyHelper
      CDN_URL_TEMPLATE = "https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@%<version>s/dist/init.iife.js"

      LOCAL_PATHS = {
        local_debug: "/picoruby/debug/init.iife.js",
        local_dist:  "/picoruby/dist/init.iife.js"
      }.freeze

      # Renders a <script> tag that bootstraps PicoRuby.wasm.
      #
      # The source is determined by Funicular.configuration based on the
      # current Rails environment, but can be overridden per call:
      #
      #   <%= picoruby_include_tag %>
      #   <%= picoruby_include_tag source: :cdn %>
      #   <%= picoruby_include_tag source: :local_dist, defer: true %>
      #
      # Any extra options are passed straight through as HTML attributes.
      def picoruby_include_tag(source: nil, **options)
        resolved_source = source ? source.to_sym : Funicular.configuration.source_for(Rails.env)
        src = picoruby_src_for(resolved_source)
        tag.script("", src: src, **options)
      end

      private

      def picoruby_src_for(source)
        if source == :cdn
          version = Funicular.configuration.cdn_version
          if version.nil? || version.empty?
            raise ArgumentError,
                  "picoruby_include_tag source :cdn requires a version. " \
                  "Set Funicular.configuration.cdn_version or vendor the wasm artifacts via `rake funicular:vendor`."
          end
          format(CDN_URL_TEMPLATE, version: version)
        elsif (path = LOCAL_PATHS[source])
          path
        else
          raise ArgumentError,
                "Unknown picoruby source: #{source.inspect}. Expected one of #{Funicular::Configuration::SOURCES.inspect}"
        end
      end
    end
  end
end
