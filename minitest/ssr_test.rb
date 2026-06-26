# frozen_string_literal: true

require "test_helper"

# Exercises the SSR half of Funicular under CRuby: the shared HTMLSerializer
# and the full path of loading the mrblib runtime + a fixture app, then
# rendering a routed component to HTML with injected state.
class SSRTest < Minitest::Test
  APP_DIR = File.expand_path("fixtures/funicular_app", __dir__)

  def setup
    Funicular::SSR::Runtime.load_framework!
  end

  # --- HTMLSerializer (pure Ruby) ---------------------------------------

  def serialize(vnode)
    Funicular::VDOM::HTMLSerializer.serialize(vnode)
  end

  def el(tag, props = {}, children = [])
    Funicular::VDOM::Element.new(tag, props, children)
  end

  def test_serializes_element_with_attributes
    assert_equal '<div class="box" id="x"></div>',
                 serialize(el("div", { class: "box", id: "x" }))
  end

  def test_escapes_text_content
    assert_equal "<p>a &amp; b &lt;c&gt;</p>",
                 serialize(el("p", {}, ["a & b <c>"]))
  end

  def test_escapes_attribute_values
    assert_equal '<div title="&quot;hi&quot;"></div>',
                 serialize(el("div", { title: '"hi"' }))
  end

  def test_skips_event_handlers
    html = serialize(el("button", { onclick: :handle }, ["Go"]))
    assert_equal "<button>Go</button>", html
  end

  def test_boolean_attribute_present_and_absent
    assert_equal '<input disabled="disabled">',
                 serialize(el("input", { disabled: true }))
    assert_equal "<input>",
                 serialize(el("input", { disabled: false }))
  end

  def test_void_element_self_closes
    assert_equal "<br>", serialize(el("br"))
    assert_equal '<img src="/a.png">', serialize(el("img", { src: "/a.png" }))
  end

  def test_serializes_custom_element
    component = Class.new(Funicular::Component).new
    vnode = component.tag(:"custom-element", { id: "x" }) { "hi" }
    assert_equal '<custom-element id="x">hi</custom-element>', serialize(vnode)
  end

  def test_blocks_javascript_uri
    assert_equal "<a>x</a>",
                 serialize(el("a", { href: "javascript:alert(1)" }, ["x"]))
  end

  # --- Full SSR render (runtime + fixture app) --------------------------

  def test_render_injects_server_state
    result = Funicular::SSR.render(
      path: "/greet",
      state: { title: "Channels", items: [{ "id" => 1, "name" => "general" },
                                          { "id" => 2, "name" => "random" }] },
      source_dir: APP_DIR
    )

    assert_includes result[:html], "<h1>Channels</h1>"
    assert_includes result[:html], "general"
    assert_includes result[:html], "random"
    assert_equal GreetingComponent, result[:component]
  end

  def test_render_uses_initialize_state_without_injection
    result = Funicular::SSR.render(path: "/greet", source_dir: APP_DIR)
    assert_includes result[:html], "<h1>Default Title</h1>"
  end

  def test_render_unmatched_route_returns_empty
    result = Funicular::SSR.render(path: "/no/such/path", source_dir: APP_DIR)
    assert_equal "", result[:html]
    assert_nil result[:component]
  end

  def test_route_params_become_props
    # Renders without raising; :id from the path is passed as a prop.
    result = Funicular::SSR.render(path: "/greet/42", source_dir: APP_DIR)
    assert_includes result[:html], "greeting"
  end
end
