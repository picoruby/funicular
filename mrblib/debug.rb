module Funicular
  module Debug
    class << self
      attr_accessor :enabled

      def enabled?
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
              }
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
        result = {}
        state.each do |key, value|
          begin
            result[key.to_s] = value.inspect
          rescue
            result[key.to_s] = "<error inspecting value>"
          end
        end
        JSON.generate(result)
      end

      def get_component_instance_variables(id)
        return "{}" unless enabled?
        component = get_component(id)
        return "{}" unless component

        result = {}
        component.instance_variables.each do |var|
          next if var == :@state
          next if var.to_s.start_with?('@__debug')
          if var == :@vdom || var == :@child_components
            result[var.to_s] = "<omitted>"
            next
          end
          begin
            result[var.to_s] = component.instance_variable_get(var).inspect
          rescue
            result[var.to_s] = "<error inspecting value>"
          end
        end
        JSON.generate(result)
      end

      def expose_to_global
        return unless enabled?
        # Export to global variable for DevTools access
        $__funicular_debug__ = self
      end

      private

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
