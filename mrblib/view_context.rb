module Funicular
  class ViewContext
    HTML_TAGS = %w[
      div span p a data
      h1 h2 h3 h4 h5 h6
      ul ol li
      table thead tbody tr th td
      form input textarea button select option label
      header footer nav section article aside
      img video audio canvas
      br hr
    ]

    def initialize(component)
      @component = component
    end

    def state
      @component.state
    end

    def props
      @component.props
    end

    def resources
      @component.resources
    end

    def styles
      @component.styles
    end

    def routes
      @component.runtime.routes
    end

    def tag(name, props = {}, &block)
      build_element(name, props, &block)
    end

    HTML_TAGS.each do |tag_name|
      define_method(tag_name) do |props = {}, &block|
        tag(tag_name, props, &block) # steep:ignore
      end
    end

    def component(component_class, props = {}, &block)
      unless component_class.is_a?(Class) && component_class.ancestors.include?(Funicular::Component)
        raise "h.component expects a Funicular::Component class"
      end

      children = if block
        capture(&block)
      else
        [] #: Array[Funicular::VDOM::child_t]
      end
      vnode = VDOM::Component.new(component_class, props, children)
      vnode.runtime = @component.runtime
      add_child(vnode)
      vnode
    end

    def form_for(model_key, options = {}, &block)
      @component.build_form_for(self, model_key, options, &block)
    end

    def suspense(name, fallback:, error: nil, &block)
      @component.render_suspense(self, name, fallback: fallback, error: error, &block)
    end

    def link_to(path, **options, &block)
      @component.build_link_to(self, path, **options, &block)
    end

    def button_to(path, method: :post, **options, &block)
      @component.build_button_to(self, path, method: method, **options, &block)
    end

    def capture(&block)
      children = [] #: Array[Funicular::VDOM::child_t]
      previous = @component.current_children
      @component.current_children = children
      result = block.call(self)
      @component.current_children = previous

      if result && !result.equal?(children) && children.empty?
        if result.is_a?(Array)
          result.each do |item|
            if item.is_a?(String)
              children << item
            else
              normalized = @component.normalize_vnode_for_view(item)
              children << normalized if normalized
            end
          end
        elsif result.is_a?(String)
          children << result
        else
          normalized = @component.normalize_vnode_for_view(result)
          children << normalized if normalized
        end
      end
      children
    ensure
      @component.current_children = previous
    end

    def add_child(child)
      @component.add_child_from_view(child)
    end

    private

    def build_element(tag_name, props = {}, &block)
      children = if block
        capture(&block)
      else
        [] #: Array[Funicular::VDOM::child_t]
      end
      normalized_props = normalize_props(props || {})
      element = VDOM::Element.new(tag_name.to_s, normalized_props, children)
      add_child(element)
      element
    end

    def normalize_props(props)
      normalized = {} #: Hash[Symbol, untyped]
      props.each do |key, value|
        normalized[key] = key == :class && value.is_a?(StyleValue) ? value.to_s : value
      end
      normalized
    end
  end
end
