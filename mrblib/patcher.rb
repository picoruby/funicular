module Funicular
  module VDOM
    class Patcher
      def initialize(doc = nil)
        @doc = doc || JS.document
      end

      def apply(element, patches)
        return element if patches.empty?
        result = element
        patches.each do |patch|
          case patch[0]
          when :replace
            new_vnode = patch[1]
            old_vnode = patch[2]
            unmount_component(old_vnode)
            new_element = create_element(new_vnode)
            if parent = element.parentElement
              parent.replaceChild(new_element, element)
              result = new_element
            end
          when :props
            # Props patches only make sense for Element nodes (text nodes have
            # no attributes); narrow before delegating.
            update_props(element, patch[1]) if element.is_a?(JS::Element)
          when :update_and_rebind
            instance, internal_patches, new_vdom = patch[1], patch[2], patch[3]
            old_dom_element = instance.dom_element

            # Apply internal patches and get the potentially new root element
            new_dom_element = Patcher.new(@doc).apply(old_dom_element, internal_patches)

            # Update the instance's reference to its root DOM element if it changed
            if new_dom_element != old_dom_element && new_dom_element.is_a?(JS::Element)
              instance.dom_element = new_dom_element
            end

            # Update the instance's VDOM to the new one AFTER applying patches
            instance.vdom = new_vdom

            # Re-collect refs using the new DOM element
            if new_dom_element.is_a?(JS::Element)
              instance.collect_refs(new_dom_element, new_vdom)

              # Re-bind events using the new DOM element
              instance.cleanup_events
              instance.bind_events(new_dom_element, new_vdom)
            end

            # Call component_updated on the child instance
            instance.component_updated if instance.respond_to?(:component_updated)
          when :update_props
            # Update component props - element is the component's DOM element
            # The component instance needs to be retrieved and updated
            # This is handled at a higher level (in Component#re_render)
            # For now, we just return the element as-is
          when :remove
            old_vnode = patch[1]
            unmount_component(old_vnode)
            element.parentElement&.removeChild(element)
          when :keyed_children
            # Composite patch produced by Differ.diff_children_with_keys.
            # Applied in three phases against `element`:
            #   1. snapshot DOM children, then remove unmatched keyed old
            #      children (descending old_index so the snapshot indices
            #      remain valid as removes happen).
            #   2. apply content updates to kept children in place. The
            #      lookup is by snapshot[old_index], so updates are stable
            #      regardless of subsequent insertions.
            #   3. insert new children at their new_index using
            #      insertBefore on the live DOM. Processed in ascending
            #      new_index order so each insertion fixes its own
            #      position before later inserts run.
            ops = patch[1]
            removes = patch[2]

            child_nodes = element[:childNodes]
            snapshot = child_nodes.is_a?(JS::Object) ? child_nodes.to_a : [] #: Array[untyped]

            # Phase 1: removes (descending old_index)
            sorted_removes = removes.sort { |a, b| b[0] <=> a[0] }
            sorted_removes.each do |entry|
              old_index = entry[0]
              old_vnode = entry[1]
              target = snapshot[old_index]
              next if target.nil?
              unmount_component(old_vnode)
              parent_el = target.parentElement
              parent_el.removeChild(target) if parent_el
            end

            # Phase 2: updates against the snapshot (no movement)
            ops.each do |op|
              next unless op[0] == :keep
              old_index = op[1]
              child_patches = op[3]
              next if child_patches.empty?
              target = snapshot[old_index]
              next if target.nil?
              apply(target, child_patches)
            end

            # Phase 3: inserts in ascending new_index order
            ops.each do |op|
              next unless op[0] == :insert
              new_index = op[1]
              new_vnode = op[2]
              new_node = create_element(new_vnode)
              next if new_node.nil?
              live_nodes = element[:childNodes]
              live_arr = live_nodes.is_a?(JS::Object) ? live_nodes.to_a : [] #: Array[untyped]
              ref = live_arr[new_index]
              if ref.nil?
                element.appendChild(new_node) if element.is_a?(JS::Element)
              else
                element.insertBefore(new_node, ref) if element.is_a?(JS::Element)
              end
            end
          when Integer
            child_index = patch[0]
            child_patches = patch[1]
            # Use childNodes instead of children to include text nodes
            child_nodes = element[:childNodes]
            children = child_nodes.is_a?(JS::Object) ? child_nodes.to_a : [] #: Array[JS::Object]
            child_element = children[child_index]
            if child_element.nil?
              # No existing child at this index - we need to create new elements
              child_patches.each do |child_patch|
                case child_patch[0]
                when :replace
                  new_child_element = create_element(child_patch[1])
                  element.appendChild(new_child_element) if element.is_a?(JS::Element)
                when :remove
                  # Nothing to remove if child doesn't exist
                when Integer
                  # This shouldn't happen at the top level of child_patches
                  # But if it does, recursively process it
                end
              end
            elsif child_element.is_a?(JS::Object)
              # Recurse into the child node. apply handles both Element and
              # text Node cases (the latter only meaningfully via :replace).
              apply(child_element, child_patches)
            end
          end
        end
        result
      end

      private

      def unmount_component(vnode)
        return unless vnode.is_a?(VDOM::Component) && vnode.instance
        vnode.instance.unmount
      end

      def update_props(element, props_patch)
        return unless element.is_a?(JS::Element)

        props_patch.each do |key, value|
          key_str = key.to_s

          # Skip event handlers (handled by bind_events)
          next if key_str.start_with?('on')

          # Skip updating value for focused input/textarea elements
          if key_str == "value"
            tag_name = element[:tagName].to_s.downcase
            if (tag_name == "input" || tag_name == "textarea")
              active_element = @doc[:activeElement]
              if active_element && element == active_element
                next
              end
              # Use property instead of attribute for value
              element[:value] = value.to_s
              next
            end
          end

          # Block javascript: URIs in URL attributes
          if URL_ATTRIBUTES.include?(key_str) && value.to_s.strip.downcase.start_with?('javascript:')
            puts "[WARN] Funicular: Blocked potentially malicious value for attribute '#{key_str}'."
            next
          end

          # Handle boolean attributes
          if BOOLEAN_ATTRIBUTES.include?(key_str)
            if value.nil? || value.to_s == "false"
              element.removeAttribute(key_str)
              element[key_str] = false
            else
              element.setAttribute(key_str, key_str)
              element[key_str] = true
            end
          elsif value.nil?
            element.removeAttribute(key_str)
          else
            element.setAttribute(key_str, value.to_s)
          end
        end
      end

      def create_element(vnode)
        return @doc.createTextNode(vnode) if vnode.is_a?(String)
        if vnode.is_a?(Array)
          # Arrays should have been flattened in VDOM::Element.normalize_children
          # Create a wrapper div as fallback
          wrapper = @doc.createElement("div")
          vnode.each do |child|
            if child.is_a?(VNode)
              wrapper.appendChild(create_element(child))
            elsif child.is_a?(String)
              wrapper.appendChild(@doc.createTextNode(child))
            end
          end
          return wrapper
        end
        raise "Invalid vnode: #{vnode.class}" unless vnode.is_a?(VNode)
        case vnode.type
        when :text
          raise "Expected Text vnode" unless vnode.is_a?(Text)
          @doc.createTextNode(vnode.content)
        when :element
          raise "Expected Element vnode" unless vnode.is_a?(Element)
          element = @doc.createElement(vnode.tag)
          vnode.props.each do |key, value|
            key_str = key.to_s
            next if key_str.start_with?('on')
            if URL_ATTRIBUTES.include?(key_str) && value.to_s.strip.downcase.start_with?('javascript:')
              puts "[WARN] Funicular: Blocked potentially malicious value for attribute '#{key_str}'."
              next
            end
            if key_str == "value" && (vnode.tag == "input" || vnode.tag == "textarea")
              element[:value] = value.to_s
            elsif BOOLEAN_ATTRIBUTES.include?(key_str)
              if value.nil? || value.to_s == "false"
                element[key_str] = false
              else
                element.setAttribute(key_str, key_str)
                element[key_str] = true
              end
            else
              element.setAttribute(key_str, value.to_s)
            end
          end
          vnode.children.each do |child|
            if child.is_a?(VNode)
              element.appendChild(create_element(child))
            elsif child.is_a?(String)
              text_node = @doc.createTextNode(child)
              element.appendChild(text_node)
            elsif child.is_a?(Array)
              child.each do |c|
                if c.is_a?(VNode)
                  element.appendChild(create_element(c))
                elsif c.is_a?(String)
                  text_node = @doc.createTextNode(c)
                  element.appendChild(text_node)
                end
              end
            end
          end
          element
        when :component
          raise "Expected Component vnode" unless vnode.is_a?(Component)
          Renderer.new(@doc).render(vnode, nil)
        else
          raise "Unknown vnode type: #{vnode.type}"
        end
      end
    end
  end
end
