module Funicular
  module VDOM
    # HTMLSerializer is a string-emitting counterpart of VDOM::Renderer.
    # While Renderer builds a live DOM tree via JS (createElement/appendChild),
    # HTMLSerializer walks the same VNode tree and produces an HTML string.
    #
    # It is pure Ruby with no JS dependency, so it runs under both mruby
    # (in the browser, if ever needed) and CRuby (on the Rails server for SSR).
    #
    # Event handler props (on*) are intentionally skipped: they are Procs that
    # cannot be serialized. They are re-bound on the client during hydration.
    class HTMLSerializer
      # Elements that have no closing tag and no children.
      VOID_ELEMENTS = %w[
        area base br col embed hr img input link meta param source track wbr
      ]

      # Props that must never be emitted as HTML attributes.
      SKIP_PROPS = %i[ref key]

      def self.serialize(vnode, runtime = nil)
        new(runtime).render(vnode)
      end

      def initialize(runtime = nil)
        @runtime = runtime
      end

      def render(vnode)
        case vnode&.type
        when :element
          # @type var vnode: Funicular::VDOM::Element
          render_element(vnode)
        when :text
          # @type var vnode: Funicular::VDOM::Text
          render_text(vnode)
        when :component
          # @type var vnode: Funicular::VDOM::Component
          render_component(vnode)
        when nil
          ""
        else
          raise "Unknown vnode type: #{vnode&.type}"
        end
      end

      private

      def render_element(element)
        tag = element.tag
        attrs = serialize_props(element.props)

        if VOID_ELEMENTS.include?(tag.downcase)
          "<#{tag}#{attrs}>"
        else
          "<#{tag}#{attrs}>#{render_children(element.children)}</#{tag}>"
        end
      end

      def render_children(children)
        parts = [] #: Array[String]
        children.each do |child|
          if child.is_a?(VNode)
            parts << render(child)
          elsif child.is_a?(String)
            parts << escape_html(child)
          elsif child.is_a?(Array)
            parts << render_children(child)
          elsif !child.nil?
            parts << escape_html(child.to_s)
          end
        end
        parts.join
      end

      def render_text(text)
        escape_html(text.content)
      end

      def render_component(component_vnode)
        instance = component_vnode.component_class.new(component_vnode.props)
        instance.runtime = component_vnode.runtime || @runtime || Funicular::Runtime.new
        instance.children = component_vnode.children
        component_vnode.instance = instance
        render(instance.build_vdom)
      end

      def serialize_props(props)
        parts = [] #: Array[String]
        props.each do |key, value|
          key_str = key.to_s
          normalized_key = key_str.downcase
          next if SKIP_PROPS.include?(key) || SKIP_PROPS.include?(normalized_key.to_sym)
          # Event handlers are bound on the client, never serialized.
          next if VDOM.blocked_attribute?(normalized_key, value)

          if BOOLEAN_ATTRIBUTES.include?(normalized_key)
            # Boolean attributes are absent when false/nil, otherwise present.
            next if value.nil? || value.to_s == "false"
            parts << " #{key_str}=\"#{key_str}\""
          else
            parts << " #{key_str}=\"#{escape_attr(value.to_s)}\""
          end
        end
        parts.join
      end

      # Minimal HTML escaping that works the same under mruby and CRuby.
      # Avoids any dependency on CGI/ERB::Util.
      def escape_html(str)
        str.to_s
           .gsub("&", "&amp;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
      end

      def escape_attr(str)
        escape_html(str).gsub('"', "&quot;")
      end
    end
  end
end
