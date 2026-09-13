module Funicular
  module Debug
    class << self
      attr_accessor :enabled

      def enabled?
        # Disabled on the server: SSR instantiates components per request and
        # must not accumulate them in the debug registry.
        return false if Funicular.server?
        @enabled ||= Funicular.env.development?
      end

      def component_registry
        @component_registry ||= {}
      end

      def error_registry
        @error_registry ||= []
      end

      def register_component(component)
        return nil unless enabled?
        @component_counter ||= 0
        id = (@component_counter += 1)
        component_registry[id] = component
        id
      end

      # Report an error caught by an ErrorBoundary
      def report_error(boundary, error, error_info = nil)
        return unless enabled?

        error_entry = {
          id: (error_registry.length + 1),
          timestamp: Time.now.to_s,
          boundary_id: boundary.instance_variable_get(:@__debug_id__),
          boundary_class: boundary.class.to_s,
          error_class: error.class.to_s,
          error_message: error.message,
          component_class: error_info&.dig(:component_class),
          backtrace: error.backtrace&.first(10)
        }

        error_registry << error_entry

        # Log to console
        puts "[ErrorBoundary] Caught error in #{error_info&.dig(:component_class) || 'unknown'}: #{error.message}"

        # Keep only last 50 errors
        @error_registry = error_registry.last(50) if error_registry.length > 50

        error_entry
      end

      # Clear all recorded errors
      def clear_errors
        @error_registry = []
      end

      # Get all recorded errors as JSON
      def error_list
        return "[]" unless enabled?
        begin
          JSON.generate(error_registry)
        rescue => e
          JSON.generate([{ "error" => e.message }])
        end
      end

      # Get the most recent error
      def last_error
        return nil unless enabled?
        error_registry.last
      end

      def unregister_component(id)
        return unless enabled?
        component_registry.delete(id)
      end

      def get_component(id)
        return nil unless enabled?
        component_registry[id]
      end

      def all_components
        return [] unless enabled?
        component_registry.values
      end

      def component_tree
        return "[]" unless enabled?

        begin
          components = component_registry.map do |id, component|
            begin
              mounted = component.instance_variable_get(:@mounted)
              state_keys = get_state_keys(component)
              class_name = component.class.to_s
              child_ids = get_child_ids(component)
              is_error_boundary = component.is_a?(Funicular::ErrorBoundary)
              has_error = is_error_boundary && component.instance_variable_get(:@state)&.dig(:has_error)
              entry = {
                "id" => id,
                "class" => class_name,
                "state_keys" => state_keys,
                "mounted" => mounted,
                "children" => child_ids
              } #: Hash[String, untyped]
              if is_error_boundary
                entry["is_error_boundary"] = true
                entry["has_error"] = has_error
              end
              entry
            rescue => e
              { "id" => id, "error" => e.message }
            end
          end
          JSON.generate(components)
        rescue => e
          JSON.generate({ "error" => e.message })
        end
      end

      # Get error count
      def error_count
        return 0 unless enabled?
        error_registry.length
      end

      def get_component_state(id)
        return "{}" unless enabled?
        component = get_component(id)
        return "{}" unless component

        state = component.instance_variable_get(:@state) || {}
        result = {} #: Hash[String, String]
        state.each do |key, value|
          result[key.to_s] = safe_inspect(value)
        end
        JSON.generate(result)
      end

      def get_component_instance_variables(id)
        return "{}" unless enabled?
        component = get_component(id)
        return "{}" unless component

        result = {} #: Hash[String, String]
        component.instance_variables.each do |var|
          name = var.to_s
          next if name == '@state'
          next if name.start_with?('@__debug')
          if name == '@vdom' || name == '@child_components'
            result[name] = "<omitted>"
            next
          end
          result[name] = safe_inspect(component.instance_variable_get(var))
        end
        JSON.generate(result)
      end

      def expose_to_global
        return unless enabled?
        # Export to global variable for DevTools access
        $__funicular_debug__ = self
      end

      private

      # Bounded inspect for the DevTools inspector. A plain Object#inspect
      # walks the whole object graph: a component's @runtime reaches the
      # router, the mounted component and its entire VDOM tree, and that
      # recursion overflows the wasm C stack in a -O0 build. Without a
      # guard page the overflow silently overwrites the heap below the
      # stack, which surfaces later as garbage registers and GC crashes.
      # Only leaves are inspected in full; containers and objects are
      # summarized past INSPECT_MAX_DEPTH.
      INSPECT_MAX_DEPTH = 3
      INSPECT_MAX_ITEMS = 25

      def safe_inspect(value, depth = 0)
        case value
        when nil, true, false, Integer, Float, Symbol, String
          value.inspect
        when Array
          return "[...#{value.size} items]" if depth >= INSPECT_MAX_DEPTH
          items = value.first(INSPECT_MAX_ITEMS).map { |v| safe_inspect(v, depth + 1) }
          items << "...#{value.size - INSPECT_MAX_ITEMS} more" if value.size > INSPECT_MAX_ITEMS
          "[#{items.join(', ')}]"
        when Hash
          return "{...#{value.size} pairs}" if depth >= INSPECT_MAX_DEPTH
          pairs = [] #: Array[String]
          value.each do |k, v|
            break if pairs.size >= INSPECT_MAX_ITEMS
            pairs << "#{safe_inspect(k, depth + 1)} => #{safe_inspect(v, depth + 1)}"
          end
          pairs << "...#{value.size - INSPECT_MAX_ITEMS} more" if value.size > INSPECT_MAX_ITEMS
          "{#{pairs.join(', ')}}"
        else
          safe_inspect_object(value, depth)
        end
      rescue => e
        "<#{e.class}: #{e.message}>"
      end

      def safe_inspect_object(value, depth)
        # JS::Object#inspect is a shallow C implementation; other BasicObject
        # proxies (style accessors) raise from method_missing on any name.
        return value.inspect if defined?(::JS::Object) && ::JS::Object === value
        return "#<BasicObject>" unless ::Object === value
        klass = value.class.to_s
        return "#<#{klass}>" if depth >= INSPECT_MAX_DEPTH
        ivars = value.instance_variables
        return value.inspect if ivars.empty?
        parts = ivars.first(INSPECT_MAX_ITEMS).map do |iv|
          "#{iv}=#{safe_inspect(value.instance_variable_get(iv), depth + 1)}"
        end
        parts << "...#{ivars.size - INSPECT_MAX_ITEMS} more" if ivars.size > INSPECT_MAX_ITEMS
        "#<#{klass} #{parts.join(', ')}>"
      end

      def get_state_keys(component)
        state = component.instance_variable_get(:@state)
        return [] unless state.is_a?(Hash)
        state.keys.map(&:to_s)
      end

      def get_child_ids(component)
        # Get only direct children by scanning component's vdom
        vdom = component.instance_variable_get(:@vdom)
        return [] unless vdom

        direct_children = [] #: Array[Funicular::Component]
        collect_direct_children(vdom, direct_children)
        direct_children.map { |child| child.instance_variable_get(:@__debug_id__) }.compact
      end

      def collect_direct_children(vnode, children)
        if vnode.is_a?(VDOM::Component)
          # Found a direct child component, don't recurse further
          children << vnode.instance if vnode.instance
        elsif vnode.is_a?(VDOM::Element)
          # Keep looking through elements
          vnode.children&.each do |child|
            # @type var child: VDOM::VNode
            collect_direct_children(child, children)
          end
        end
      end
    end
  end
end
