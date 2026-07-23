module Funicular
  # Raised at class-definition time (method_added) or first mount when a
  # component defines a method whose name collides with the view DSL.
  class DSLCollisionError < StandardError; end

  # Raised when a tag helper is called while the component is not rendering
  # (e.g. from a stale proc or an event handler outside build_vdom).
  class RenderContextError < StandardError; end

  # Bareword tag DSL mixed into Funicular::Component. Tags are real public
  # instance methods so `div(...)` works with self = the component inside
  # `render`. Element construction is delegated to the component's internal
  # ViewContext, which remains the single element factory (FormBuilder and
  # the framework internals keep using it directly).
  module Tags
    # Single source of truth for the tag whitelist. sig/tags.rbs must list
    # one method per entry; test/sig_tags_test.rb enforces that in CI.
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

    HELPER_NAMES = %w[
      tag component form_for link_to button_to suspense
      state props styles resources routes patch
    ]

    # Symbol => :tag | :helper. Component.method_added consults this to turn
    # silent shadowing into a load-time error.
    RESERVED_DSL = {} #: Hash[Symbol, Symbol]
    HTML_TAGS.each { |name| RESERVED_DSL[name.to_sym] = :tag }
    HELPER_NAMES.each { |name| RESERVED_DSL[name.to_sym] = :helper }

    HTML_TAGS.each do |tag_name|
      define_method(tag_name) do |props = {}, &block|
        # @type self: Funicular::Component
        unless props.is_a?(Hash)
          hint = if tag_name == "p"
            " Inside a component, `p` builds a <p> element; use `puts x.inspect` to debug."
          else
            ""
          end
          raise ArgumentError, "#{tag_name}() expects an attributes Hash, got #{props.class}.#{hint}"
        end
        __view__.tag(tag_name, props, &block)
      end
    end

    # Escape hatch: emit any element, including custom elements outside the
    # whitelist or a tag whose bareword is shadowed via allow_dsl_override.
    def tag(name, props = {}, &block)
      # @type self: Funicular::Component
      __view__.tag(name, props, &block)
    end
  end
end
