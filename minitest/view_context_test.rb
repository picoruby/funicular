# frozen_string_literal: true

require "test_helper"

class ViewContextTest < Minitest::Test
  def setup
    Funicular::SSR::Runtime.load_framework!
  end

  def test_explicit_state_styles_and_resources_do_not_collide_with_html_methods
    klass = Class.new(Funicular::Component) do
      styles { |css| css.define :hash, "hash-class" }

      use_suspense :data, ->(resolve, _reject) { resolve.call("loaded") }

      def initialize_state
        { class: "state-class", hash: "state-hash" }
      end

      def render(h)
        h.data(class: h.styles[:hash]) do
          "#{state[:class]} #{state[:hash]} #{h.resources[:data]}"
        end
      end
    end

    component = klass.new
    component.instance_variable_get(:@suspense_data)[:data] = "loaded"
    component.instance_variable_get(:@suspense_states)[:data] = :resolved

    vnode = component.build_vdom

    assert_equal "data", vnode.tag
    assert_equal "hash-class", vnode.props[:class]
    assert_equal ["state-class state-hash loaded"], vnode.children
  end

  def test_component_children_are_vdom_children_not_props
    child = Class.new(Funicular::Component) do
      def render(h)
        h.div { children }
      end
    end

    parent = Class.new(Funicular::Component) do
      define_method(:render) do |h|
        h.component(child, title: "x") do |hh|
          hh.span { "inside" }
        end
      end
    end

    vnode = parent.new.build_vdom

    assert_instance_of Funicular::VDOM::Component, vnode
    assert_equal({ title: "x" }, vnode.props)
    refute_includes vnode.props.keys, :children_block
    assert_equal 1, vnode.children.length
    assert_equal "span", vnode.children.first.tag
  end

  def test_route_helpers_are_runtime_scoped
    router_a = Funicular::Router.new(nil)
    router_b = Funicular::Router.new(nil)
    router_a.get("/users/:id", to: Class.new(Funicular::Component), as: "user")
    router_b.get("/accounts/:id", to: Class.new(Funicular::Component), as: "user")

    component_a = Class.new(Funicular::Component).new
    component_b = Class.new(Funicular::Component).new
    component_a.runtime = Funicular::Runtime.new(router_a)
    component_b.runtime = Funicular::Runtime.new(router_b)

    assert_equal "/users/7", Funicular::ViewContext.new(component_a).routes.user_path(7)
    assert_equal "/accounts/7", Funicular::ViewContext.new(component_b).routes.user_path(7)
  end

  def test_child_collector_is_restored_when_render_raises
    klass = Class.new(Funicular::Component) do
      attr_reader :captured

      def render(h)
        begin
          h.div do |hh|
            hh.span { "before" }
            raise "boom"
          end
        rescue
          @captured = current_children
          h.div { "after" }
        end
      end
    end

    instance = klass.new
    vnode = instance.build_vdom

    assert_nil instance.current_children
    assert_equal "div", vnode.tag
    assert_equal ["after"], vnode.children
  end
end
