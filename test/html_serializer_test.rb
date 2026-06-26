# HTMLSerializer is the one piece of genuinely shared SSR logic: the same
# string-emitting code runs under CRuby (Rails server, covered by
# minitest/ssr_test.rb) and under PicoRuby/mruby (this file). Keeping both
# suites in lockstep guards against mruby/CRuby divergence in the shared
# subset, which is the main risk of the SSR feature.
class HTMLSerializerTest < Picotest::Test
  def serialize(vnode)
    Funicular::VDOM::HTMLSerializer.serialize(vnode)
  end

  def el(tag, props = {}, children = [])
    Funicular::VDOM::Element.new(tag, props, children)
  end

  def test_serializes_element_with_attributes
    assert_equal('<div class="box" id="x"></div>',
                 serialize(el('div', {class: 'box', id: 'x'})))
  end

  def test_serializes_nested_children
    inner = el('span', {}, ['hi'])
    assert_equal('<div><span>hi</span></div>',
                 serialize(el('div', {}, [inner])))
  end

  def test_escapes_text_content
    assert_equal('<p>a &amp; b &lt;c&gt;</p>',
                 serialize(el('p', {}, ['a & b <c>'])))
  end

  def test_escapes_attribute_values
    assert_equal('<div title="&quot;hi&quot;"></div>',
                 serialize(el('div', {title: '"hi"'})))
  end

  def test_skips_event_handlers
    assert_equal('<button>Go</button>',
                 serialize(el('button', {onclick: :handle}, ['Go'])))
  end

  def test_boolean_attribute_present_when_true
    assert_equal('<input disabled="disabled">',
                 serialize(el('input', {disabled: true})))
  end

  def test_boolean_attribute_absent_when_false
    assert_equal('<input>',
                 serialize(el('input', {disabled: false})))
  end

  def test_void_element_has_no_closing_tag
    assert_equal('<br>', serialize(el('br')))
    assert_equal('<img src="/a.png">', serialize(el('img', {src: '/a.png'})))
  end

  def test_serializes_custom_element
    component = Class.new(Funicular::Component).new
    vnode = component.tag(:'custom-element', {id: 'x'}) { 'hi' }
    assert_equal('<custom-element id="x">hi</custom-element>', serialize(vnode))
  end

  def test_blocks_javascript_uri
    assert_equal('<a>x</a>',
                 serialize(el('a', {href: 'javascript:alert(1)'}, ['x'])))
  end

  def test_text_vnode_is_escaped
    assert_equal('&lt;b&gt;',
                 serialize(Funicular::VDOM::Text.new('<b>')))
  end

  def test_nil_vnode_serializes_to_empty_string
    assert_equal('', serialize(nil))
  end
end
