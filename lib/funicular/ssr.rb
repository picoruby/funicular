# frozen_string_literal: true

require_relative "ssr/runtime"

module Funicular
  # Server-side rendering entry point.
  #
  # Usage (typically from a Rails controller / view helper):
  #
  #   result = Funicular::SSR.render(
  #     path: request.path,
  #     state: { channels: Channel.all.as_json }
  #   )
  #   # result[:html]  -> HTML string for the #app container
  #   # result[:state] -> data to embed as window.__FUNICULAR_STATE__
  #
  module SSR
    # Render the component mapped to `path` to an HTML string, seeding it with
    # server-provided `state`. Returns a hash:
    #   { html:, state:, component: }
    # When no route matches, html is "" so the caller can fall back to plain
    # client-side rendering (empty #app container).
    def self.render(path:, state: {}, props: {}, source_dir: nil)
      Runtime.boot!(source_dir || default_source_dir)

      router = Funicular.router
      raise "Funicular router is not configured; check app/funicular/initializer.rb" unless router

      component_class, params = router.match(path)
      return { html: "", state: {}, component: nil } unless component_class

      instance = component_class.new(symbolize_keys(params).merge(props))
      instance.seed_state(state)
      html = Funicular::VDOM::HTMLSerializer.serialize(instance.build_vdom)

      { html: html, state: state, component: component_class }
    end

    def self.default_source_dir
      raise "source_dir is required outside Rails" unless defined?(Rails) && Rails.respond_to?(:root)
      Rails.root.join("app", "funicular")
    end

    def self.symbolize_keys(hash)
      return {} unless hash
      out = {}
      hash.each { |k, v| out[k.to_sym] = v }
      out
    end
  end
end
