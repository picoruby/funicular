# Bareword component DSL (0.4.0): collision detection, render context
# guard, the p-tag guard, and the styles cleanroom. The CRuby twin is
# minitest/dsl_test.rb; behaviors that differ between the VMs (attr_*
# firing method_added on CRuby but not on mruby) are asserted in the
# suite that observes them.
class DSLTest < Picotest::Test
  def test_bareword_render_builds_nested_tree
    klass = Class.new(Funicular::Component) do
      def initialize_state
        { items: ["a", "b"] }
      end

      def render
        div(class: "list") do
          h1 { "title" }
          ul do
            state[:items].each_with_index do |item, i|
              li(key: i) { item }
            end
          end
        end
      end
    end

    vnode = klass.new.build_vdom

    assert_equal("div", vnode.tag)
    assert_equal(["h1", "ul"], vnode.children.map { |c| c.tag })
    assert_equal(2, vnode.children[1].children.size)
  end

  def test_defining_reserved_tag_name_raises_at_class_definition
    assert_raise(Funicular::DSLCollisionError) do
      Class.new(Funicular::Component) do
        def label
        end
      end
    end
  end

  def test_attr_accessor_collision_is_caught_at_first_build
    # attr_accessor does not fire method_added on mruby; the mount-time
    # sweep catches it instead.
    klass = Class.new(Funicular::Component) do
      attr_accessor :label

      def render
        div { "x" }
      end
    end

    assert_raise(Funicular::DSLCollisionError) { klass.new.build_vdom }
  end

  def test_included_module_collision_is_caught_at_first_build
    mod = Module.new do
      def select
      end
    end
    klass = Class.new(Funicular::Component) do
      def render
        div { "x" }
      end
    end
    klass.include(mod)

    assert_raise(Funicular::DSLCollisionError) { klass.new.build_vdom }
  end

  def test_allow_dsl_override_restores_user_method_and_tag_escape_hatch
    klass = Class.new(Funicular::Component) do
      allow_dsl_override :label

      def label
        "custom"
      end

      def render
        div { tag(:label) { label } }
      end
    end

    vnode = klass.new.build_vdom

    assert_equal("label", vnode.children.first.tag)
    assert_equal(["custom"], vnode.children.first.children)
  end

  def test_render_with_parameter_raises_migration_error
    klass = Class.new(Funicular::Component) do
      def render(h)
        h
      end
    end

    assert_raise(Funicular::DSLCollisionError) { klass.new.build_vdom }
  end

  def test_p_with_non_hash_raises_with_hint
    klass = Class.new(Funicular::Component) do
      def render
        div { p "debug me" }
      end
    end

    assert_raise(ArgumentError) { klass.new.build_vdom }
  end

  def test_p_with_hash_builds_paragraph
    klass = Class.new(Funicular::Component) do
      def render
        p(class: "para") { "text" }
      end
    end

    vnode = klass.new.build_vdom

    assert_equal("p", vnode.tag)
    assert_equal(["text"], vnode.children)
  end

  def test_tag_outside_render_raises
    klass = Class.new(Funicular::Component) do
      def render
        div { "x" }
      end
    end
    component = klass.new
    component.build_vdom

    assert_raise(Funicular::RenderContextError) { component.div { "outside" } }
  end

  def test_bareword_styles_definition_and_method_access
    klass = Class.new(Funicular::Component) do
      styles do
        shell "app-shell"
        display "display-class"
        button base: "btn", variants: { primary: "btn--primary" }, active: "btn--on"
      end

      def render
        div(class: styles.shell) do
          span(class: styles.display) { "d" }
          button(class: styles.button(:primary)) { "b" }
          a(class: styles[:button, true] | "extra") { "x" }
        end
      end
    end

    vnode = klass.new.build_vdom

    assert_equal("app-shell", vnode.props[:class])
    assert_equal("display-class", vnode.children[0].props[:class])
    assert_equal("btn btn--primary", vnode.children[1].props[:class])
    assert_equal("btn btn--on extra", vnode.children[2].props[:class])
  end

  def test_unknown_style_raises
    klass = Class.new(Funicular::Component) do
      styles do
        shell "app-shell"
      end

      def render
        div { "x" }
      end
    end
    component = klass.new

    assert_raise(NoMethodError) { component.styles.typo_name }
    assert_raise(ArgumentError) { component.styles[:typo] }
  end

  def test_bareword_helper_call_inside_styles_block_raises
    assert_raise(ArgumentError) do
      Class.new(Funicular::Component) do
        styles do
          button base: helper_that_does_not_exist("x")
        end
      end
    end
  end

  def test_duplicate_style_definition_raises
    assert_raise(ArgumentError) do
      Class.new(Funicular::Component) do
        styles do
          shell "a"
          shell "b"
        end
      end
    end
  end

  def test_suspense_fallback_runs_bareword_in_own_component
    klass = Class.new(Funicular::Component) do
      use_suspense :user, ->(resolve, _reject) { resolve.call("u") }

      def render
        div do
          suspense(:user, fallback: -> { span { "loading" } }) do |res|
            span { res[:user] }
          end
        end
      end
    end

    component = klass.new
    vnode = component.build_vdom
    assert_equal("loading", vnode.children.first.children.first)

    component.instance_variable_get(:@suspense_data)[:user] = "u"
    component.instance_variable_get(:@suspense_states)[:user] = :resolved
    vnode = component.build_vdom
    assert_equal("u", vnode.children.first.children.first)
  end

  def test_link_to_forwards_method_kwarg
    klass = Class.new(Funicular::Component) do
      attr_reader :action

      def render
        link_to("/x", method: :delete, class: "danger") { "Del" }
      end

      def handle_link_with_method(path, method)
        @action = [path, method]
      end
    end

    component = klass.new
    vnode = component.build_vdom

    assert_equal("danger", vnode.props[:class])
    vnode.props[:onclick].call(FakeEvent.new)
    assert_equal(["/x", :delete], component.action)
  end

  class FakeEvent
    def preventDefault; end
  end
end
