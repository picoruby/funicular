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
      instance.runtime = Funicular::Runtime.new(router)
      instance.seed_state(state)
      html = Funicular::VDOM::HTMLSerializer.serialize(instance.build_vdom, instance.runtime)

      { html: html, state: state, component: component_class }
    end

    # Render one component to an HTML string with no route lookup: for
    # embedding a Funicular component into an otherwise server-rendered
    # (ERB) page -- a shared site header, say -- so the markup has a
    # single source of truth. The component is named by string and
    # resolved after boot!, because host apps keep app/funicular out of
    # Rails autoloading and the constant does not exist before loading.
    # Handlers are not bound and no hydration happens: the output is
    # static HTML (links still work; onclick and friends do not).
    def self.render_component(component_name, props: {}, state: {}, source_dir: nil)
      Runtime.boot!(source_dir || default_source_dir)

      router = Funicular.router
      raise "Funicular router is not configured; check app/funicular/initializer.rb" unless router

      component_class = Object.const_get(component_name.to_s)
      instance = component_class.new(symbolize_keys(props))
      instance.runtime = Funicular::Runtime.new(router)
      instance.seed_state(state)
      Funicular::VDOM::HTMLSerializer.serialize(instance.build_vdom, instance.runtime)
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
