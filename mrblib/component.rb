module Funicular
  class Component
    class StateAccessor
      def initialize(state_hash)
        @state = state_hash
      end

      def [](key)
        @state[key]
      end

      def fetch(key, default = nil)
        return @state.fetch(key) if default.nil? && @state.key?(key)
        @state.fetch(key, default)
      end

      def key?(key)
        @state.key?(key)
      end

      def to_h
        @state
      end
    end

    class ResourceAccessor
      def initialize(data, states, errors)
        @data = data
        @states = states
        @errors = errors
      end

      def [](key)
        @data[key]
      end

      def fetch(key, default = nil)
        return @data.fetch(key) if default.nil? && @data.key?(key)
        @data.fetch(key, default)
      end

      def loading?(key)
        @states[key] == :pending || @states[key] == :loading
      end

      def error?(key)
        @states[key] == :rejected
      end

      def error(key)
        @errors[key]
      end
    end

    include Tags

    attr_accessor :props, :vdom, :dom_element, :mounted, :runtime, :children, :current_children
    attr_reader :refs

    # Opt out of DSL collision detection for the given method names. The
    # shadowed tag remains reachable through tag(:name, ...).
    def self.allow_dsl_override(*names)
      @dsl_overrides ||= [] #: Array[Symbol]
      @dsl_overrides.concat(names)
    end

    def self.dsl_overrides
      @dsl_overrides ||= [] #: Array[Symbol]
    end

    # Layer 1: catches `def`, `define_method`, and `alias` in subclasses at
    # class-definition time. attr_* does not fire this hook on mruby, and
    # included modules never do; validate_dsl_conflicts! covers those.
    def self.method_added(name)
      if self != Funicular::Component && Funicular::Tags::RESERVED_DSL[name] && !dsl_overrides.include?(name)
        kind = Funicular::Tags::RESERVED_DSL[name] == :tag ? "<#{name}> tag helper" : "##{name} helper"
        raise Funicular::DSLCollisionError,
          "#{self}##{name} collides with the Funicular DSL (#{kind}). " \
          "Rename it (e.g. `#{name}_value`), or declare `allow_dsl_override :#{name}` " \
          "and use `tag(:#{name}, ...)` to emit the element."
      end
      super
    end

    # Layer 2: once per class, sweep methods the method_added hook cannot
    # see (attr_* on mruby, user-included modules).
    def self.validate_dsl_conflicts!
      return if @dsl_validated
      if instance_method(:render).arity != 0
        raise Funicular::DSLCollisionError,
          "#{self}#render must not take parameters as of Funicular 0.4.0: " \
          "delete the parameter (`def render`) and drop the `h.` receivers " \
          "inside; tags are bareword methods on the component now."
      end
      ancestors.each do |mod|
        break if mod == Funicular::Component || mod == Funicular::Tags
        next unless mod.is_a?(Module)
        methods = mod.instance_methods(false) + mod.private_instance_methods(false)
        offenders = methods.select { |m| Funicular::Tags::RESERVED_DSL[m] } - dsl_overrides
        next if offenders.empty?
        raise Funicular::DSLCollisionError,
          "#{mod} defines methods that collide with the Funicular DSL: " \
          "#{offenders.map { |m| m.to_s }.join(', ')}. Rename them, or declare " \
          "`allow_dsl_override` and use `tag(...)` to emit the element."
      end
      @dsl_validated = true
    end

    def initialize(props = {})
      @props = props
      @state = initialize_state || {}
      @state_accessor = nil
      @resource_accessor = nil
      @style_accessor = nil
      @runtime = Funicular::Runtime.new
      @children = [] #: Array[Funicular::VDOM::child_t]
      @vdom = nil
      @dom_element = nil
      @refs = {} #: Hash[Symbol, JS::Element]
      @event_listeners = [] #: Array[untyped]
      @mounted = false
      @updating = false
      @child_components = [] #: Array[Funicular::Component]

      # Initialize suspense state
      @suspense_data = {} #: Hash[Symbol, untyped]
      @suspense_states = {} #: Hash[Symbol, Symbol]
      @suspense_errors = {} #: Hash[Symbol, untyped]
      @suspense_pending_timers = [] #: Array[untyped]
      self.class.suspense_definitions.each_key do |name|
        @suspense_states[name] = :pending
      end

      # Register component for debugging in development mode
      @__debug_id__ = Funicular::Debug.register_component(self) if Funicular::Debug.enabled?
    end

    def state
      @state_accessor ||= StateAccessor.new(@state)
    end

    def resources
      @resource_accessor ||= ResourceAccessor.new(@suspense_data, @suspense_states, @suspense_errors)
    end

    def styles
      @style_accessor ||= self.class.style_accessor_class.new(self.class.styles_definitions)
    end

    # Override this method in subclasses to define initial state
    def initialize_state
      {}
    end

    # Merge externally provided state into the component before rendering.
    # Used by SSR to inject server data, and by client hydration to restore
    # the same state from window.__FUNICULAR_STATE__ so the first client
    # render matches the server HTML. Top-level keys are symbolized so they
    # are reachable via state[:foo] (StateAccessor uses symbol keys); nested
    # values are left untouched (components read them with string keys).
    def seed_state(state_hash)
      return self if state_hash.nil?
      return self if state_hash.respond_to?(:empty?) && state_hash.empty?

      symbolized = {} #: Hash[Symbol, untyped]
      state_hash.each do |key, value|
        symbolized[key.to_sym] = value
      end
      @state = @state.merge(symbolized)
      @state_accessor = nil
      self
    end

    # Load all registered suspense data
    # Called automatically in component_mounted if suspense definitions exist
    def load_suspense_data
      self.class.suspense_definitions.each do |name, loader|
        load_single_suspense(name, loader)
      end
    end

    # Load a single suspense data by name
    def load_single_suspense(name, definition = nil)
      definition ||= self.class.suspense_definitions[name]
      return unless definition
      return if @suspense_states[name] == :loading

      # Support both old format (just loader) and new format (hash with loader and on_resolve)
      if definition.is_a?(Hash)
        loader = definition[:loader]
        on_resolve = definition[:on_resolve]
        min_delay = definition[:min_delay]
      else
        loader = definition
        on_resolve = nil
        min_delay = nil
      end

      @suspense_states[name] = :loading
      start_time = Time.now.to_f * 1000  # Convert to milliseconds

      # Helper to finalize resolve
      do_resolve = ->(data) {
        @suspense_data[name] = data
        @suspense_states[name] = :resolved
        @suspense_errors[name] = nil
        if on_resolve
          # on_resolve callback is expected to call patch() which triggers re-render
          instance_exec(data, &on_resolve)
        else
          re_render if @mounted
        end
      }

      resolve = ->(data) {
        if min_delay
          elapsed = (Time.now.to_f * 1000) - start_time
          remaining = min_delay - elapsed
          if remaining > 0
            # Delay resolve to ensure minimum loading time
            timer_id = JS.global.setTimeout(remaining.to_i) do
              do_resolve.call(data) if @mounted
            end
            @suspense_pending_timers << timer_id
          else
            do_resolve.call(data)
          end
        else
          do_resolve.call(data)
        end
      }

      reject = ->(error) {
        @suspense_data[name] = nil
        @suspense_states[name] = :rejected
        @suspense_errors[name] = error
        re_render if @mounted
      }

      # Execute loader with resolve/reject callbacks
      instance_exec(resolve, reject, &loader)
    end

    # Reload suspense data (useful for retry or refresh)
    def reload_suspense(name)
      @suspense_states[name] = :pending
      load_single_suspense(name)
    end

    # Check if suspense data is loading
    def suspense_loading?(*names)
      names = self.class.suspense_definitions.keys if names.empty?
      names.any? { |name| @suspense_states[name] == :pending || @suspense_states[name] == :loading }
    end

    # Check if suspense data has error
    def suspense_error?(name)
      @suspense_states[name] == :rejected
    end

    # Get suspense error
    def suspense_error(name)
      @suspense_errors[name]
    end

    # Suspense helper for render method
    #
    # @param fallback [Proc] Content to show while loading
    # @param error [Proc] Optional content to show on error (receives error as argument)
    # @yield Block to render when data is loaded
    #
    # @example
    #   suspense(fallback: -> { div { "Loading..." } }) do
    #     div { user.name }
    #   end
    #
    # @example with error handling
    #   suspense(
    #     fallback: -> { div { "Loading..." } },
    #     error: ->(e) { div { "Error: #{e}" } }
    #   ) do
    #     div { user.name }
    #   end
    def render_suspense(name, fallback:, error: nil, &block)
      current_children = @current_children
      child_count_before = current_children&.size
      result = nil

      if @suspense_states[name] == :rejected
        result = if error
          error.call(@suspense_errors[name])
        else
          fallback.call
        end
      elsif suspense_loading?(name)
        result = fallback.call
      else
        result = block.call(resources)
      end

      if current_children && current_children.size == child_count_before
        add_child_from_view(result)
      end

      result
    end

    # Class methods for styles DSL. The block is instance_exec'd on a
    # StyleBuilder cleanroom so barewords define styles; it also receives
    # the builder for the explicit `styles { |css| css.define(...) }` form.
    def self.styles(&block)
      builder = StyleBuilder.new
      builder.instance_exec(builder, &block) # steep:ignore
      @styles_definitions = builder.to_definitions
      @style_accessor_class = nil
    end

    def self.styles_definitions
      @styles_definitions ||= {}
    end

    # Per-class accessor with one real method per declared style name.
    def self.style_accessor_class
      @style_accessor_class ||= StyleAccessor.accessor_for(styles_definitions)
    end

    # Suspense DSL - register async data loaders
    #
    # @param name [Symbol] Name of the suspense data (becomes accessible as method)
    # @param loader [Proc] Lambda that receives resolve and reject callbacks
    # @param on_resolve [Proc] Optional callback called with data after resolve, before re-render
    # @param min_delay [Integer] Minimum time in ms to show loading state (prevents flickering)
    #
    # @example
    #   use_suspense :user, ->(resolve, reject) {
    #     User.find(props[:id]) do |user, error|
    #       error ? reject.call(error) : resolve.call(user)
    #     end
    #   }
    #
    # @example with on_resolve callback and min_delay
    #   use_suspense :current_user,
    #     ->(resolve, reject) { Session.current_user { |u, e| ... } },
    #     on_resolve: ->(user) { patch(user: { username: user.username }) },
    #     min_delay: 300  # Show loading spinner for at least 300ms
    def self.use_suspense(name, loader, on_resolve: nil, min_delay: nil)
      @suspense_definitions ||= {} # steep:ignore UnannotatedEmptyCollection
      @suspense_definitions[name] = { loader: loader, on_resolve: on_resolve, min_delay: min_delay }
    end

    def self.suspense_definitions
      @suspense_definitions ||= {}
    end

    # Update state and trigger re-render
    def patch(new_state)
      return unless @mounted
      return if @updating

      begin
        @updating = true
        component_will_update if respond_to?(:component_will_update)

        # Convert JS::Object values to Ruby native types automatically
        normalized_state = {} #: Hash[Symbol, untyped]
        new_state.each do |key, value|
          normalized_state[key] = normalize_state_value(value)
        end

        @state = @state.merge(normalized_state)
        @state_accessor = nil  # Invalidate accessor to reflect new state
        re_render

        component_updated if respond_to?(:component_updated)
      rescue => e
        component_raised(e) if respond_to?(:component_raised)
        raise e
      ensure
        @updating = false
      end
    end

    # Mount component to a DOM container
    def mount(container)
      return if @mounted

      begin
        component_will_mount if respond_to?(:component_will_mount)

        @container = container
        new_vdom = build_vdom
        @dom_element = VDOM::Renderer.new(nil, @runtime).render(new_vdom)
        bind_events(@dom_element, new_vdom)
        collect_refs(@dom_element, new_vdom)
        collect_child_components(new_vdom)
        container.appendChild(@dom_element)
        @vdom = new_vdom
        @mounted = true

        # Start loading suspense data after mounted
        load_suspense_data if self.class.suspense_definitions.any?

        # Mark child components as mounted and call their lifecycle hooks
        @child_components.each do |child|
          child.mounted = true
          child.component_mounted if child.respond_to?(:component_mounted)
        end

        component_mounted if respond_to?(:component_mounted)
      rescue => e
        component_raised(e) if respond_to?(:component_raised)
        raise e
      end
    end

    # Hydrate this component against server-rendered DOM.
    #
    # Unlike mount, which builds a fresh DOM tree via VDOM::Renderer, hydrate
    # reuses the existing DOM produced by the server: it builds the VDOM,
    # associates it with the existing nodes, and only attaches event listeners
    # and refs (plus wiring child components). The first client render must
    # match the server HTML, which is why state is seeded from
    # window.__FUNICULAR_STATE__ before calling this.
    def hydrate(dom_element)
      return if @mounted
      raise "hydrate: missing server DOM element" unless dom_element

      begin
        component_will_mount if respond_to?(:component_will_mount)

        # The router/start sets the container; without it, unmount could not
        # detach this subtree later. Derive it from the existing DOM.
        @container ||= dom_element.parentNode
        @dom_element = dom_element

        new_vdom = build_vdom

        if hydration_match?(new_vdom, dom_element)
          # Wire child components first so their instances exist for collection.
          hydrate_child_components(new_vdom, dom_element)

          # Reuse the same positional walks as mount: they skip Component vnodes
          # (children manage their own events/refs during their own hydrate).
          bind_events(dom_element, new_vdom)
          collect_refs(dom_element, new_vdom)
          collect_child_components(new_vdom)
        else
          # Server and client disagree on structure (nondeterministic render or
          # stale state). Recover by discarding the server DOM and rendering a
          # fresh tree, the same way mount does. The page stays usable; only the
          # first-paint reuse is lost for this subtree.
          warn_hydration_mismatch(new_vdom, dom_element)
          @dom_element = full_render_fallback(new_vdom, dom_element)
        end

        @vdom = new_vdom
        @mounted = true

        load_suspense_data if self.class.suspense_definitions.any?

        @child_components.each do |child|
          unless child.mounted
            child.mounted = true
            child.component_mounted if child.respond_to?(:component_mounted)
          end
        end

        component_mounted if respond_to?(:component_mounted)
      rescue => e
        component_raised(e) if respond_to?(:component_raised)
        raise e
      end
    end

    # Unmount component from DOM
    def unmount
      return unless @mounted
      # puts "==> Unmounting: #{self.class} id: #{@__debug_id__}"

      begin
        component_will_unmount if respond_to?(:component_will_unmount)

        # Unmount child components first
        # puts "  > Unmounting children: #{@child_components.map(&:class).join(', ')}"
        @child_components.each do |child|
          child.unmount if child.respond_to?(:unmount)
        end
        @child_components = [] #: Array[Funicular::Component]

        cleanup_events
        cleanup_suspense_timers
        @container.removeChild(@dom_element) if @container && @dom_element
        @mounted = false
        @dom_element = nil
        @vdom = nil
        @refs = {}

        # Unregister component from debugging in development mode
        Funicular::Debug.unregister_component(@__debug_id__) if @__debug_id__

        component_unmounted if respond_to?(:component_unmounted)
      rescue => e
        component_raised(e) if respond_to?(:component_raised)
        raise e
      end
    end

    # Override this method in subclasses to define render logic
    def render
      raise "Subclasses must implement render"
    end

    # Build VDOM tree from render method
    # Called by VDOM::Renderer, Differ, and Patcher
    def build_vdom
      self.class.validate_dsl_conflicts!
      previous_rendering = @rendering
      previous_children = @current_children
      @rendering = true
      @current_children = nil
      begin
        result = render
      ensure
        @rendering = previous_rendering
        @current_children = previous_children
      end

      # Convert render result to VNode
      vnode = normalize_vnode(result)

      # Add data-component attribute to the root element
      if Funicular.env.development? && vnode
        add_data_component_attribute(vnode)
      end

      vnode
    end

    # Bind event handlers to DOM elements
    # Called by VDOM::Renderer and Patcher
    def bind_events(dom_element, vnode)
      # Skip Component vnodes - they manage their own events
      return if vnode.is_a?(VDOM::Component)
      return unless vnode.is_a?(VDOM::Element)

      event_types = [] #: Array[String]

      vnode.props.each do |key, value|
        key_str = key.to_s
        next unless VDOM.event_attribute?(key_str)

        event_name = key_str[2..-1]&.downcase || ""
        event_types << event_name

        # addEventListener expects a block, not a Proc
        callback_id = case value
        when Symbol
          result = dom_element.addEventListener(event_name) do |event|
            begin
              self.send(value, event)
            rescue => e
              component_raised(e) if respond_to?(:component_raised)
              raise e
            end
          end
          result
        when Method
          result = dom_element.addEventListener(event_name) do |event|
            begin
              # @type var value: Method
              # Check if Method expects arguments (arity)
              if value.arity == 0
                value.call
              else
                value.call(event)
              end
            rescue => e
              component_raised(e) if respond_to?(:component_raised)
              raise e
            end
          end
          result
        when Proc
          result = dom_element.addEventListener(event_name) do |event|
            begin
              # @type var value: Proc
              # Check if Proc expects arguments (arity)
              if value.arity == 0
                value.call
              else
                value.call(event)
              end
            rescue => e
              component_raised(e) if respond_to?(:component_raised)
              raise e
            end
          end
          result
        else
          raise "Invalid event handler: #{value.class}. Must be Symbol, Method, or Proc."
        end

        @event_listeners << callback_id
      end

      # Add debug attribute for DevTools
      if Funicular::Debug.enabled? && event_types.length > 0
        dom_element.setAttribute("data-event-listeners", event_types.join(","))
      end

      # Recursively bind events for children
      if vnode.children && dom_element.children
        children = dom_element.children.to_a
        vnode.children.each_with_index do |child_vnode, index|
          if child_vnode.is_a?(VDOM::Element)
            child_element = children[index]
            bind_events(child_element, child_vnode) if child_element
          elsif child_vnode.is_a?(VDOM::Component)
            # Component vnodes handle their own events in render_component
            # Skip them here to avoid duplicate event binding
          end
        end
      end
    end

    # Collect ref elements from VDOM
    # Called by VDOM::Renderer and Patcher
    def collect_refs(dom_element, vnode, refs_map = {})
      # Skip Component vnodes - they manage their own refs
      return refs_map if vnode.is_a?(VDOM::Component)
      return refs_map unless vnode.is_a?(VDOM::Element)

      if vnode.props[:ref]
        ref_name = vnode.props[:ref].to_sym
        @refs[ref_name] = dom_element
        refs_map[ref_name] = dom_element
      end

      if vnode.children && dom_element.children
        children = dom_element.children.to_a
        vnode.children.each_with_index do |child_vnode, index|
          if child_vnode.is_a?(VDOM::Element)
            child_element = children[index]
            collect_refs(child_element, child_vnode, refs_map) if child_element
          elsif child_vnode.is_a?(VDOM::Component)
            # Component vnodes handle their own refs in render_component
            # Skip them here to avoid duplicate processing
          end
        end
      end

      refs_map
    end

    # Cleanup event listeners
    # Called by VDOM::Patcher
    def cleanup_events
      @event_listeners.each do |callback_id|
        JS::Object.removeEventListener(callback_id)
      end
      @event_listeners = [] #: Array[untyped]

      # NOTE: Do NOT cleanup child component events here!
      # Child components manage their own events and will cleanup
      # when they themselves re-render or unmount
    end

    # Cleanup pending suspense timers
    def cleanup_suspense_timers
      return unless @suspense_pending_timers
      @suspense_pending_timers.each do |timer_id|
        JS.global.clearTimeout(timer_id)
      end
      @suspense_pending_timers = [] #: Array[untyped]
    end

    private

    public

    def normalize_vnode_for_view(value)
      normalize_vnode(value)
    end

    # Internal element factory shared by the Tags mixin, FormBuilder, and
    # the framework helpers. One instance per component; ViewContext itself
    # is stateless (the render cursor lives on the component).
    def __view__
      @__view__ ||= ViewContext.new(self)
    end

    def routes
      @runtime.routes
    end

    # Bareword DSL helpers available inside render (self is the component).
    def component(component_class, props = {}, &block)
      __view__.component(component_class, props, &block)
    end

    def form_for(model_key, options = {}, &block)
      build_form_for(__view__, model_key, options, &block)
    end

    def link_to(path, **options, &block)
      build_link_to(__view__, path, **options, &block)
    end

    def button_to(path, method: :post, **options, &block)
      build_button_to(__view__, path, method: method, **options, &block)
    end

    def suspense(name, fallback:, error: nil, &block)
      render_suspense(name, fallback: fallback, error: error, &block)
    end

    def add_child_from_view(child)
      unless @rendering
        raise Funicular::RenderContextError,
          "view DSL called outside render (tags may only be used while the component is rendering)"
      end
      current_children = @current_children
      return unless current_children

      normalized = normalize_vnode(child)
      current_children << normalized if normalized
    end

    def build_form_for(h, model_key, options = {}, &block)
      on_submit = options.delete(:on_submit)
      form_class = options.delete(:class)

      submit_handler = if on_submit
        ->(event) do
          event.preventDefault
          form_data = collect_form_data(event, model_key)

          case on_submit
          when Symbol
            send(on_submit, form_data)
          when Method
            on_submit.call(form_data)
          when Proc
            on_submit.call(form_data)
          else
            raise "on_submit must be Symbol, Method, or Proc, got #{on_submit.class}"
          end
        end
      else
        ->(event) { event.preventDefault }
      end

      h.form({ onsubmit: submit_handler, class: form_class }.merge(options)) do
        builder = Funicular::FormBuilder.new(self, h, model_key, options)
        block.call(builder)
      end
    end

    def build_link_to(h, path, method: :get, **options, &block)
      merged_options = options.merge(href: path)
      merged_options[:onclick] = ->(event) {
        event.preventDefault
        if method.to_s.downcase.to_sym == :get
          handle_link_click(path)
        else
          handle_link_with_method(path, method)
        end
      }
      h.a(merged_options, &block)
    end

    def build_button_to(h, path, method: :post, **options, &block)
      merged_options = options.merge(
        type: options[:type] || "button",
        onclick: -> { handle_link_with_method(path, method) }
      )
      h.button(merged_options, &block)
    end

    private

    # Normalize state value for storage. Primitives are already auto-
    # converted to Ruby native values by picoruby-wasm, so only composite
    # JS::Object values (array / plain object / function / symbol / bigint)
    # and nested Ruby collections need handling here.
    def normalize_state_value(value)
      case value
      when Hash
        normalized = {} #: Hash[untyped, untyped]
        value.each { |k, v| normalized[k] = normalize_state_value(v) }
        normalized
      when Array
        value.map { |v| normalize_state_value(v) }
      when JS::Object
        if value.typeof == :array
          value.to_a.map { |v| normalize_state_value(v) }
        else
          value
        end
      else
        value
      end
    end

    # Re-render component (called by update)
    def re_render
      return unless @mounted

      new_vdom = build_vdom
      patches = VDOM::Differ.diff(@vdom, new_vdom)

      # Always cleanup and rebind events to avoid stale event listeners
      cleanup_events

      unless patches.empty?
        new_dom_element = VDOM::Patcher.new(nil, @runtime).apply(@dom_element, patches)
        # apply returns JS::Object (it must accept text-node patches), but
        # the component's root is always an Element. Narrow to JS::Element.
        @dom_element = new_dom_element if new_dom_element.is_a?(JS::Element)
      end

      bind_events(@dom_element, new_vdom)
      collect_refs(@dom_element, new_vdom)
      collect_child_components(new_vdom)

      # Mark child components as mounted and call their lifecycle hooks
      @child_components.each do |child|
        unless child.mounted
          child.mounted = true
          child.component_mounted if child.respond_to?(:component_mounted)
        end
      end

      @vdom = new_vdom
    end

    # Add data-component attribute to the root element
    def add_data_component_attribute(vnode)
      return unless vnode.is_a?(VDOM::Element)
      vnode.props[:'data-component'] = self.class.to_s
      vnode.props[:'data-component-id'] = @__debug_id__.to_s if @__debug_id__
    end

    # Normalize render result to VNode
    def normalize_vnode(value)
      case value
      when VDOM::VNode
        _ = value
      when String
        VDOM::Text.new(value)
      when Integer, Float
        VDOM::Text.new(value.to_s)
      when Array
        # Arrays are typically return values from iterators like .each or .map
        # The elements have already been added to @current_children during iteration
        # Return nil to avoid duplicate rendering
        nil
      when nil
        VDOM::Text.new("")
      when Class
        # If it's a component class, create a component VNode
        if value.ancestors.include?(Funicular::Component)
          VDOM::Component.new(value, {})
        else
          VDOM::Text.new(value.to_s)
        end
      else
        VDOM::Text.new(value.to_s)
      end
    end

    # Lightweight structural check: the root tag of the freshly built VDOM
    # must match the server-rendered element. A mismatch means server and
    # client disagree (nondeterministic render or stale state); the caller
    # falls back to a full client render.
    def hydration_match?(vnode, dom_element)
      return true unless vnode.is_a?(VDOM::Element)
      actual = dom_element[:tagName]
      return true unless actual  # non-element node; let later steps surface issues
      vnode.tag.to_s.downcase == actual.to_s.downcase
    end

    # Emit a development-only warning describing a hydration mismatch. Uses
    # puts so the message reaches the browser console (same idiom as the
    # ErrorBoundary logger), and is silent in production.
    def warn_hydration_mismatch(vnode, dom_element)
      return unless Funicular.env.development?
      expected = vnode.is_a?(VDOM::Element) ? vnode.tag.to_s.downcase : vnode.class.to_s
      got = dom_element[:tagName].to_s.downcase
      puts "[Funicular] Hydration mismatch: expected <#{expected}>, found <#{got}>; " \
           "falling back to full client render"
    end

    # Recover from a hydration mismatch by rendering a fresh DOM tree and
    # swapping it in for the server-rendered node. Mirrors mount, minus the
    # appendChild: the stale node already has a place in the document, so we
    # replaceChild instead.
    def full_render_fallback(new_vdom, server_dom)
      fresh = VDOM::Renderer.new(nil, @runtime).render(new_vdom)
      parent = server_dom.parentNode
      parent.replaceChild(fresh, server_dom) if parent
      bind_events(fresh, new_vdom)
      collect_refs(fresh, new_vdom)
      collect_child_components(new_vdom)
      fresh
    end

    # Walk the VDOM and existing DOM in parallel to hydrate nested components.
    # Uses the same positional indexing as bind_events/collect_refs so the
    # three walks agree on which DOM node maps to which vnode.
    def hydrate_child_components(vnode, dom_element)
      return unless vnode.is_a?(VDOM::Element)
      return unless dom_element

      dom_children = dom_element.children.to_a
      vnode.children.each_with_index do |child, index|
        child_dom = dom_children[index]
        next unless child_dom

        if child.is_a?(VDOM::Component)
          instance = child.component_class.new(child.props)
          instance.runtime = child.runtime || @runtime
          instance.children = child.children
          child.instance = instance
          instance.hydrate(child_dom)
        elsif child.is_a?(VDOM::Element)
          hydrate_child_components(child, child_dom)
        end
      end
    end

    # Collect child component instances from VDOM tree
    def collect_child_components(vnode)
      @child_components = [] #: Array[Funicular::Component]
      collect_child_components_recursive(vnode, @child_components)
    end

    def collect_child_components_recursive(vnode, components)
      if vnode.is_a?(VDOM::Component)
        components << vnode.instance if vnode.instance
        # Recursively collect from child component's vdom
        if vnode.instance && vnode.instance.vdom
          collect_child_components_recursive(vnode.instance.vdom, components)
        end
      elsif vnode.is_a?(VDOM::Element)
        vnode.children&.each do |child|
          # @type var child: VDOM::VNode
          collect_child_components_recursive(child, components)
        end
      end
    end

    def collect_form_data(event, model_key)
      form_data = collect_dom_form_data(event)
      return form_data unless form_data.empty?

      collect_state_form_data(model_key)
    end

    def collect_dom_form_data(event)
      form = event_target(event)
      return {} unless form

      elements = form[:elements]
      return {} unless elements

      data = {} #: Hash[Symbol, untyped]
      length_value = elements[:length]
      length = length_value ? length_value.to_i : 0
      i = 0
      while i < length
        field = elements[i]
        add_form_field_value(data, field) if field
        i += 1
      end
      data
    end

    def event_target(event)
      event[:target]
    rescue
      nil
    end

    def add_form_field_value(data, field)
      name = field[:name].to_s
      return if name.empty?

      type = field[:type].to_s.downcase
      return if %w[submit button reset].include?(type)
      return if type == "radio" && !field[:checked]

      value = if type == "checkbox"
        field[:checked]
      elsif type == "file"
        field[:files]
      else
        field[:value]
      end

      data[name.to_sym] = value
    end

    def collect_state_form_data(model_key)
      model_data = state[model_key]
      if model_data.is_a?(Hash)
        model_data
      elsif model_data.respond_to?(:instance_variables)
        data = {} #: Hash[Symbol, untyped]
        model_data.instance_variables.each do |var|
          key = var.to_s.sub('@', '').to_sym
          data[key] = model_data.instance_variable_get(var)
        end
        data
      else
        {} #: Hash[Symbol, untyped]
      end
    end

    # Handle router navigation (navigate using History API)
    def handle_link_click(path)
      @runtime.router&.navigate(path)
    end

    # Handle link action via Fetch API
    def handle_link_with_method(path, method)
      # Call appropriate HTTP method
      case method.to_s.downcase.to_sym
      when :get
        HTTP.get(path) { |response| handle_link_response(response, path, method) }
      when :post
        HTTP.post(path) { |response| handle_link_response(response, path, method) }
      when :put
        HTTP.put(path) { |response| handle_link_response(response, path, method) }
      when :patch
        HTTP.patch(path) { |response| handle_link_response(response, path, method) }
      when :delete
        HTTP.delete(path) { |response| handle_link_response(response, path, method) }
      else
        raise "Unsupported HTTP method: #{method}"
      end
    end

    # Handle response from link action (can be overridden by subclasses)
    def handle_link_response(response, path, method)
      if response.error?
        puts "Link action failed (#{method.to_s.upcase} #{path}): #{response.error_message}"
      end
    end

    # Transition Helpers
    # These methods provide a declarative way to animate element removal/addition
    # using CSS transitions, inspired by Vue.js and Alpine.js transition systems

    # Remove an element via CSS transition animation
    #
    # @param element_id [String] DOM element ID (without '#' prefix)
    # @param from [String] CSS classes to remove before animation
    # @param to [String] CSS classes to add for leave animation
    # @param duration [Integer] Animation duration in milliseconds (default: 300)
    # @param callback [Proc] Block called after animation completes
    #
    # @example Remove message with fade out
    #   remove_via("message-123",
    #     "opacity-100 max-h-screen"
    #     "opacity-0 max-h-0",
    #     duration: 500,
    #   ) do
    #     patch(messages: updated_messages)
    #   end
    def remove_via(element_id, from, to, duration: 300, &callback)
      element = JS.document.getElementById(element_id)

      unless element
        callback.call if callback
        return
      end

      element.classList.remove(*from.split(" ")) unless from.empty?
      element.classList.add(*to.split(" ")) unless to.empty?

      JS.global.setTimeout(duration) do
        callback&.call
      end
    end

    # Add an element via CSS transition animation
    #
    # @param element_id [String] DOM element ID (without '#' prefix)
    # @param from [String] CSS classes to remove before animation
    # @param to [String] CSS classes to add for leave animation
    # @param duration [Integer] Animation duration in milliseconds (default: 300)
    # @param callback [Proc] Block called after animation completes
    #
    # @example Add message with fade in
    #   add_via("message-456",
    #     "opacity-0 scale-95",
    #     "opacity-100 scale-100",
    #     duration: 300
    #   )
    def add_via(element_id, from, to, duration: 300, &callback)
      element = JS.document.getElementById(element_id)

      unless element
        callback.call if callback
        return
      end

      element.classList.add(*from.split(" ")) unless from.empty?

      sleep_ms 10

      element.classList.remove(*from.split(" ")) unless from.empty?
      element.classList.add(*to.split(" ")) unless to.empty?

      JS.global.setTimeout(duration) do
        callback&.call
      end
    end
  end
end
