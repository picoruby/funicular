module Funicular
  module VDOM
    BOOLEAN_ATTRIBUTES = %w[
      disabled checked selected readonly required autofocus multiple
    ]

    URL_ATTRIBUTES = %w[href src action formaction data poster xlink:href]

    # VDOM input is normally authored by application code, but props and tags
    # can also be assembled from hashes. Validate names before either the DOM
    # renderer or the SSR serializer sees them so an attacker-controlled key
    # cannot become HTML syntax.
    SCRIPTING_ELEMENTS = %w[script]

    def self.valid_tag_name?(name)
      str = name.to_s
      return false if str.empty?

      index = 0
      str.each_byte do |byte|
        alpha = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        digit = byte >= 48 && byte <= 57
        return false unless alpha || (index > 0 && (digit || byte == 45))
        index += 1
      end
      true
    end

    def self.valid_attribute_name?(name)
      str = name.to_s
      return false if str.empty?

      str.each_byte do |byte|
        alpha = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        digit = byte >= 48 && byte <= 57
        punctuation = byte == 45 || byte == 46 || byte == 58 || byte == 95
        return false unless alpha || digit || punctuation
      end
      true
    end

    def self.event_attribute?(name)
      name.to_s.downcase.start_with?('on')
    end

    def self.unsafe_url?(name, value)
      return false unless URL_ATTRIBUTES.include?(name.to_s.downcase)

      # Browsers discard ASCII tabs and newlines while parsing URLs, so test
      # the same canonical form rather than only a literal "javascript:".
      raw = value.to_s
      start = 0
      start += 1 while (byte = raw.getbyte(start)) && byte <= 32

      normalized = (raw[start..-1] || "")
                        .gsub("\t", "")
                        .gsub("\n", "")
                        .gsub("\r", "")
                        .gsub("\f", "")
                        .strip
                        .downcase
      normalized.start_with?('javascript:') || normalized.start_with?('vbscript:')
    end

    def self.blocked_attribute?(name, value)
      normalized_name = name.to_s.downcase
      event_attribute?(normalized_name) ||
        normalized_name == 'srcdoc' ||
        unsafe_url?(normalized_name, value)
    end

    class VNode
      attr_reader :type, :key

      def initialize(type)
        @type = type
      end
    end

    class Element < VNode
      attr_reader :tag, :props, :children

      def initialize(tag, props = {}, children = [])
        super(:element)
        @tag = tag.to_s
        unless VDOM.valid_tag_name?(@tag)
          raise ArgumentError, "Invalid VDOM tag name: #{@tag.inspect}"
        end
        if SCRIPTING_ELEMENTS.include?(@tag.downcase)
          raise ArgumentError, "Unsafe VDOM tag: #{@tag.inspect}"
        end

        @key = props.delete(:key)
        @props = props || {}
        @props.each_key do |name|
          unless VDOM.valid_attribute_name?(name)
            raise ArgumentError, "Invalid VDOM attribute name: #{name.inspect}"
          end
        end
        @children = normalize_children(children || [])
      end

      private

      def normalize_children(children)
        result = [] #: Array[child_t]
        children.each do |child|
          case child
          when VNode
            result << child
          when String
            result << child
          when Array
            # Flatten arrays (typically from .each or .map return values)
            # Recursively normalize nested arrays
            # @type var child: Array[Funicular::VDOM::child_t]
            result.concat(normalize_children(child))
          when nil
            # Skip nil values
          else
            # Convert other types to strings
            result << child.to_s
          end
        end
        result
      end

      def ==(other)
        return false unless other.is_a?(Element)
        @tag == other.tag && @props == other.props && @children == other.children
      end
    end

    class Text < VNode
      attr_reader :content

      def initialize(content)
        super(:text)
        @content = content.to_s
      end

      def ==(other)
        return false unless other.is_a?(Text)
        @content == other.content
      end
    end

    class Component < VNode
      attr_reader :component_class, :props, :children
      attr_accessor :instance, :runtime

      def initialize(component_class, props = {}, children = [])
        super(:component)
        @component_class = component_class
        @key = props.delete(:key)
        @props = props
        @children = children || []
        @instance = nil
        @runtime = nil
      end

      def ==(other)
        return false unless other.is_a?(Component)
        @component_class == other.component_class && @props == other.props && @children == other.children
      end
    end

    class Renderer
      def initialize(doc = nil, runtime = nil)
        @doc = doc || JS.document
        @runtime = runtime
        @error_boundary_stack = []
      end

      def render(vnode, parent = nil)
        case vnode&.type
        when :element
          # @type var vnode: Funicular::VDOM::Element
          render_element(vnode, parent)
        when :text
          # @type var vnode: Funicular::VDOM::Text
          render_text(vnode, parent)
        when :component
          # @type var vnode: Funicular::VDOM::Component
          render_component(vnode, parent)
        else
          raise "Unknown vnode type: #{vnode&.type}"
        end
      end

      private

      # Find the nearest error boundary instance on the stack
      def current_error_boundary
        @error_boundary_stack.last
      end

      def render_element(element, parent)
        dom_node = @doc.createElement(element.tag)

        element.props.each do |key, value|
          key_str = key.to_s
          normalized_key = key_str.downcase
          if VDOM.event_attribute?(normalized_key)
            # Event handlers are handled by Funicular::Component and should not be set as attributes.
            # warn "Funicular: Attempted to set event handler '#{key_str}' as an attribute. This will be ignored."
          elsif VDOM.blocked_attribute?(normalized_key, value)
            # Prevent active HTML content and unsafe URL schemes.
            puts "[WARN] Funicular: Blocked potentially malicious value for attribute '#{key_str}'."
          elsif BOOLEAN_ATTRIBUTES.include?(normalized_key)
            # Handle boolean attributes
            if value.nil? || value.to_s == "false"
              # Do not set attribute (leave it absent)
              dom_node[key_str] = false
            else
              dom_node.setAttribute(key_str, key_str)
              dom_node[key_str] = true
            end
          else
            # Attribute
            dom_node.setAttribute(key_str, value.to_s)
          end
        end

        element.children.each do |child|
          if child.is_a?(VNode)
            child_dom = render(child)
            dom_node.appendChild(child_dom)
          elsif child.is_a?(String)
            text_node = @doc.createTextNode(child)
            dom_node.appendChild(text_node)
          elsif child.is_a?(Array)
            child.each do |c|
              if c.is_a?(VNode)
                child_dom = render(c)
                dom_node.appendChild(child_dom)
              elsif c.is_a?(String)
                text_node = @doc.createTextNode(c)
                dom_node.appendChild(text_node)
              end
            end
          end
        end

        parent.appendChild(dom_node) if parent

        dom_node
      end

      def render_text(text, parent)
        dom_node = @doc.createTextNode(text.content)
        parent.appendChild(dom_node) if parent
        dom_node
      end

      def render_component(component_vnode, parent)
        instance = component_vnode.component_class.new(component_vnode.props)
        instance.runtime = component_vnode.runtime || @runtime || Funicular::Runtime.new
        instance.children = component_vnode.children
        component_vnode.instance = instance

        is_error_boundary = instance.is_a?(Funicular::ErrorBoundary)

        # Push error boundary to stack if this component is one
        @error_boundary_stack.push(instance) if is_error_boundary

        begin
          component_vdom = instance.build_vdom
          dom_node = render(component_vdom, parent)

          # Check if this ErrorBoundary caught an error during child rendering
          # If so, its @vdom was already set to fallback in the rescue block
          error_was_caught = is_error_boundary && instance.error_caught_during_render

          if error_was_caught
            # ErrorBoundary caught an error - use the fallback vdom/dom that were set in rescue
            # Note: The div.error-boundary-content created during initial render
            # will be orphaned, but that's acceptable as it's not attached to the DOM
            fallback_vdom = instance.vdom
            fallback_dom = instance.dom_element

            # Bind events on the fallback DOM
            instance.bind_events(fallback_dom, fallback_vdom)
            instance.collect_refs(fallback_dom, fallback_vdom)

            # Return the fallback DOM
            fallback_dom
          else
            # Normal case - store VDOM and DOM element
            instance.vdom = component_vdom
            instance.dom_element = dom_node
            instance.bind_events(dom_node, component_vdom)
            instance.collect_refs(dom_node, component_vdom)
            dom_node
          end
        rescue => e
          # Pop error boundary from stack before handling
          @error_boundary_stack.pop if is_error_boundary

          # Try to find an error boundary to handle this error
          boundary = current_error_boundary
          if boundary && !is_error_boundary
            error_info = {
              component_class: component_vnode.component_class.to_s,
              props: component_vnode.props
            }

            # Let the error boundary handle the error
            boundary.catch_error(e, error_info)

            # Re-render the error boundary with fallback UI
            boundary_vdom = boundary.build_vdom
            fallback_dom = render(boundary_vdom, nil)

            # Update boundary's internal state
            boundary.vdom = boundary_vdom
            boundary.dom_element = fallback_dom
            boundary.mounted = true
            boundary.bind_events(fallback_dom, boundary_vdom)

            fallback_dom
          else
            # No error boundary to catch this error, let it propagate
            raise e
          end
        ensure
          # Pop error boundary from stack after successful render
          @error_boundary_stack.pop if is_error_boundary && @error_boundary_stack.last == instance
        end
      end
    end

    def self.create_element(tag, props = {}, *children)
      Element.new(tag, props, children.flatten)
    end

    def self.create_text(content)
      Text.new(content)
    end

    def self.render(vnode, container)
      renderer = Renderer.new
      container.innerHTML = ''
      renderer.render(vnode, container)
    end

    def self.diff(old_vnode, new_vnode)
      Differ.diff(old_vnode, new_vnode)
    end

    def self.patch(element, patches)
      patcher = Patcher.new
      patcher.apply(element, patches)
    end
  end
end
