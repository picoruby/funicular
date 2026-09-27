# Mock JS module for testing without picoruby-wasm dependency
module JS
  class Object
  end
  class Element < Object
  end
end

class VDOMPatcherTest < Picotest::Test
  # Mock childNodes that behaves like JS::Object
  class MockChildNodes < JS::Object
    attr_reader :elements

    def initialize(elements)
      @elements = elements
    end

    def to_a
      @elements.dup
    end
  end

  # Mock DOM classes for testing without JS dependency
  class MockDocument
    def createElement(tag)
      MockElement.new(tag)
    end

    def createTextNode(text)
      MockTextNode.new(text)
    end

    def [](key)
      nil # activeElement and other properties
    end
  end

  class MockElement
    attr_accessor :tag_name, :attributes, :children, :parent_element, :properties
    # Number of times a child was taken out of this element's child list,
    # whether by removeChild or by a move through appendChild/insertBefore/
    # replaceChild. A real DOM detaches and re-attaches a node even when it
    # is inserted before itself, so a keyed patch that does not move a node
    # must not call insertBefore on it at all.
    attr_reader :detach_count

    def initialize(tag)
      @tag_name = tag
      @attributes = {}
      @children = []
      @parent_element = nil
      @properties = {}
      @detach_count = 0
    end

    def setAttribute(key, value)
      @attributes[key] = value
    end

    def removeAttribute(key)
      @attributes.delete(key)
    end

    def appendChild(child)
      detach(child)
      @children << child
      child.parent_element = self if child.respond_to?(:parent_element=)
      child
    end

    def removeChild(child)
      detach(child)
      child.parent_element = nil if child.respond_to?(:parent_element=)
      child
    end

    def replaceChild(new_child, old_child)
      detach(new_child)
      index = @children.index(old_child)
      if index
        @children[index] = new_child
        @detach_count += 1
        new_child.parent_element = self if new_child.respond_to?(:parent_element=)
        old_child.parent_element = nil if old_child.respond_to?(:parent_element=)
      end
      new_child
    end

    def insertBefore(new_child, ref_child)
      # Mirror the DOM: insertBefore(node, node) is a detach + re-attach at
      # the same position, not a no-op.
      self_insert = !ref_child.nil? && new_child.equal?(ref_child)
      own_index = @children.index(new_child) if self_insert
      detach(new_child)
      index = self_insert ? own_index : (ref_child.nil? ? nil : @children.index(ref_child))
      if index
        @children.insert(index, new_child)
      else
        @children << new_child
      end
      new_child.parent_element = self if new_child.respond_to?(:parent_element=)
      new_child
    end

    def [](key)
      case key.to_s
      when 'tagName'
        @tag_name
      when 'childNodes'
        VDOMPatcherTest::MockChildNodes.new(@children)
      else
        @properties[key.to_s]
      end
    end

    def []=(key, value)
      @properties[key.to_s] = value
    end

    def parentElement
      @parent_element
    end

    def is_a?(klass)
      # Mock JS::Element check for patcher compatibility
      if klass == JS::Element
        true
      elsif klass.to_s == 'JS::Object'
        true
      else
        super
      end
    end

    private

    def detach(child)
      index = @children.index { |c| c.equal?(child) }
      return if index.nil?
      @children.delete_at(index)
      @detach_count += 1
    end
  end

  class MockTextNode
    attr_accessor :text_content, :parent_element

    def initialize(text)
      @text_content = text
      @parent_element = nil
    end

    def []=(key, value)
      @text_content = value if key.to_s == 'nodeValue'
    end

    def parentElement
      @parent_element
    end

    def is_a?(klass)
      klass == JS::Object || super
    end
  end

  def setup
    @doc = MockDocument.new
    @patcher = Funicular::VDOM::Patcher.new(@doc)
  end

  # Test props update
  def test_update_props_add_attribute
    element = @doc.createElement('div')
    patches = [[:props, {class: 'foo', id: 'bar'}]]

    @patcher.apply(element, patches)

    assert_equal('foo', element.attributes['class'])
    assert_equal('bar', element.attributes['id'])
  end

  def test_update_props_change_attribute
    element = @doc.createElement('div')
    element.setAttribute('class', 'old')
    patches = [[:props, {class: 'new'}]]

    @patcher.apply(element, patches)

    assert_equal('new', element.attributes['class'])
  end

  def test_update_props_remove_attribute
    element = @doc.createElement('div')
    element.setAttribute('class', 'foo')
    patches = [[:props, {class: nil}]]

    @patcher.apply(element, patches)

    assert_nil(element.attributes['class'])
  end

  def test_update_props_sets_boolean_property
    element = @doc.createElement('button')
    patches = [[:props, {disabled: true}]]

    @patcher.apply(element, patches)

    assert_equal('disabled', element.attributes['disabled'])
    assert_equal(true, element.properties['disabled'])
  end

  def test_update_props_clears_boolean_property
    element = @doc.createElement('button')
    element.setAttribute('disabled', 'disabled')
    element[:disabled] = true
    patches = [[:props, {disabled: false}]]

    @patcher.apply(element, patches)

    assert_nil(element.attributes['disabled'])
    assert_equal(false, element.properties['disabled'])
  end

  def test_update_props_sets_textarea_value_property
    element = @doc.createElement('textarea')
    patches = [[:props, {value: 'hello'}]]

    @patcher.apply(element, patches)

    assert_equal('hello', element.properties['value'])
    assert_nil(element.attributes['value'])
  end

  def test_update_props_skip_event_handlers
    element = @doc.createElement('div')
    patches = [[:props, {onclick: 'handler', class: 'foo'}]]

    @patcher.apply(element, patches)

    # Event handler should be skipped
    assert_nil(element.attributes['onclick'])
    # But other props should be set
    assert_equal('foo', element.attributes['class'])
  end

  def test_update_props_security_checks_are_case_insensitive
    element = @doc.createElement('a')
    patches = [[:props, {'ONCLICK' => 'alert(1)', 'HREF' => 'javascript:alert(2)'}]]

    @patcher.apply(element, patches)

    assert_nil(element.attributes['ONCLICK'])
    assert_nil(element.attributes['HREF'])
  end

  def test_update_props_blocks_obfuscated_javascript_and_srcdoc
    element = @doc.createElement('div')
    patches = [[:props, {href: "java\nscript:alert(1)", srcdoc: '<script>alert(2)</script>'}]]

    @patcher.apply(element, patches)

    assert_nil(element.attributes['href'])
    assert_nil(element.attributes['srcdoc'])
  end

  def test_renderer_blocks_active_attributes
    vnode = Funicular::VDOM::Element.new(
      'a',
      {'ONCLICK' => 'alert(1)', 'HREF' => "java\nscript:alert(2)", 'SRCDOC' => '<script>alert(3)</script>'}
    )

    element = Funicular::VDOM::Renderer.new(@doc).render(vnode)

    assert_nil(element.attributes['ONCLICK'])
    assert_nil(element.attributes['HREF'])
    assert_nil(element.attributes['SRCDOC'])
  end

  # Test element creation from VDOM
  def test_create_text_element
    text_vnode = Funicular::VDOM::Text.new('hello')
    # Access private method for testing
    element = @patcher.send(:create_element, text_vnode)

    assert(element.is_a?(MockTextNode))
    assert_equal('hello', element.text_content)
  end

  def test_create_simple_element
    vnode = Funicular::VDOM::Element.new('div', {class: 'foo'})
    element = @patcher.send(:create_element, vnode)

    assert(element.is_a?(MockElement))
    assert_equal('div', element.tag_name)
    assert_equal('foo', element.attributes['class'])
    assert_equal(0, element.children.length)
  end

  def test_create_element_sets_boolean_property
    vnode = Funicular::VDOM::Element.new('button', {disabled: true})
    element = @patcher.send(:create_element, vnode)

    assert_equal('disabled', element.attributes['disabled'])
    assert_equal(true, element.properties['disabled'])
  end

  def test_create_element_sets_textarea_value_property
    vnode = Funicular::VDOM::Element.new('textarea', {value: 'hello'})
    element = @patcher.send(:create_element, vnode)

    assert_equal('hello', element.properties['value'])
    assert_nil(element.attributes['value'])
    assert_equal(0, element.children.length)
  end

  def test_create_element_with_text_children
    vnode = Funicular::VDOM::Element.new('p', {}, ['hello', 'world'])
    element = @patcher.send(:create_element, vnode)

    assert_equal('p', element.tag_name)
    assert_equal(2, element.children.length)
    assert(element.children[0].is_a?(MockTextNode))
    assert_equal('hello', element.children[0].text_content)
    assert(element.children[1].is_a?(MockTextNode))
    assert_equal('world', element.children[1].text_content)
  end

  def test_create_element_with_element_children
    child1 = Funicular::VDOM::Element.new('span')
    child2 = Funicular::VDOM::Element.new('strong')
    parent = Funicular::VDOM::Element.new('div', {}, [child1, child2])

    element = @patcher.send(:create_element, parent)

    assert_equal('div', element.tag_name)
    assert_equal(2, element.children.length)
    assert(element.children[0].is_a?(MockElement))
    assert_equal('span', element.children[0].tag_name)
    assert(element.children[1].is_a?(MockElement))
    assert_equal('strong', element.children[1].tag_name)
  end

  def test_create_element_with_nested_children
    text = Funicular::VDOM::Text.new('text')
    span = Funicular::VDOM::Element.new('span', {}, [text])
    div = Funicular::VDOM::Element.new('div', {}, [span])

    element = @patcher.send(:create_element, div)

    assert_equal('div', element.tag_name)
    assert_equal(1, element.children.length)
    span_element = element.children[0]
    assert_equal('span', span_element.tag_name)
    assert_equal(1, span_element.children.length)
    assert(span_element.children[0].is_a?(MockTextNode))
    assert_equal('text', span_element.children[0].text_content)
  end

  # Test remove patch
  def test_remove_child
    parent = @doc.createElement('div')
    child = @doc.createElement('span')
    parent.appendChild(child)

    assert_equal(1, parent.children.length)

    patches = [[:remove]]
    @patcher.apply(child, patches)

    assert_equal(0, parent.children.length)
    assert_nil(child.parent_element)
  end

  # Test child index patches
  def test_apply_child_patch_add_new_child
    parent = @doc.createElement('ul')
    existing_child = @doc.createElement('li')
    parent.appendChild(existing_child)

    new_child_vnode = Funicular::VDOM::Element.new('li', {class: 'new'})
    patches = [[1, [[:replace, new_child_vnode]]]]

    @patcher.apply(parent, patches)

    assert_equal(2, parent.children.length)
    assert_equal('new', parent.children[1].attributes['class'])
  end

  def test_apply_child_patch_update_existing_child
    parent = @doc.createElement('ul')
    child = @doc.createElement('li')
    child.setAttribute('class', 'old')
    parent.appendChild(child)

    patches = [[0, [[:props, {class: 'updated'}]]]]

    @patcher.apply(parent, patches)

    assert_equal(1, parent.children.length)
    assert_equal('updated', parent.children[0].attributes['class'])
  end

  def test_apply_empty_patches
    element = @doc.createElement('div')
    result = @patcher.apply(element, [])

    assert_equal(element, result)
  end

  def test_keyed_reorder_keeps_dom_and_vdom_indices_aligned
    first_vdom = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A']),
      Funicular::VDOM::Element.new('li', {key: 'b'}, ['B'])
    ])
    dom = Funicular::VDOM::Renderer.new(@doc).render(first_vdom)
    a_node, b_node = dom.children

    second_vdom = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'b'}, ["B'"]),
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A'])
    ])
    @patcher.apply(dom, Funicular::VDOM::Differ.diff(first_vdom, second_vdom))

    assert_equal([b_node, a_node], dom.children)
    assert_equal("B'", b_node.children[0].text_content)
    # Only b moved; a must not have been detached and re-attached.
    assert_equal(1, dom.detach_count)

    third_vdom = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'b'}, ["B''"]),
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A'])
    ])
    @patcher.apply(dom, Funicular::VDOM::Differ.diff(second_vdom, third_vdom))

    assert_equal("B''", b_node.children[0].text_content)
    assert_equal('A', a_node.children[0].text_content)
    # A content-only change must not touch the child list at all.
    assert_equal(1, dom.detach_count)
  end

  def test_keyed_insert_and_remove_do_not_detach_kept_children
    first_vdom = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A']),
      Funicular::VDOM::Element.new('li', {key: 'b'}, ['B']),
      Funicular::VDOM::Element.new('li', {key: 'c'}, ['C'])
    ])
    dom = Funicular::VDOM::Renderer.new(@doc).render(first_vdom)
    a_node, b_node, c_node = dom.children

    # Remove b, insert d at the front, keep a and c in place.
    second_vdom = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'd'}, ['D']),
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A']),
      Funicular::VDOM::Element.new('li', {key: 'c'}, ['C'])
    ])
    @patcher.apply(dom, Funicular::VDOM::Differ.diff(first_vdom, second_vdom))

    assert_equal(3, dom.children.length)
    assert_equal('D', dom.children[0].children[0].text_content)
    assert(dom.children[1].equal?(a_node))
    assert(dom.children[2].equal?(c_node))
    assert_nil(b_node.parent_element)
    # Exactly one detach: the removal of b.
    assert_equal(1, dom.detach_count)
  end

  class MockComponentInstance
    attr_accessor :dom_element, :vdom, :runtime

    def initialize(dom_element)
      @dom_element = dom_element
      @runtime = nil
    end

    def collect_refs(_element, _vdom); end
    def cleanup_events; end
    def bind_events(_element, _vdom); end
  end

  def test_update_and_rebind_returns_replaced_root
    parent = @doc.createElement('ul')
    old_root = @doc.createElement('li')
    parent.appendChild(old_root)
    instance = MockComponentInstance.new(old_root)

    old_vnode = Funicular::VDOM::Element.new('li', {}, [])
    new_vnode = Funicular::VDOM::Element.new('form', {}, [])
    patches = [[:update_and_rebind, instance, [[:replace, new_vnode, old_vnode]], new_vnode]]

    result = @patcher.apply(old_root, patches)

    assert_equal('form', result.tag_name)
    assert(result.equal?(instance.dom_element))
    assert_equal([result], parent.children)
    assert_nil(old_root.parent_element)
  end

  def test_keyed_children_remove_text_placeholder
    first_vdom = Funicular::VDOM::Element.new('ul', {}, ['Loading...'])
    dom = Funicular::VDOM::Renderer.new(@doc).render(first_vdom)
    placeholder = dom.children[0]
    assert(placeholder.is_a?(MockTextNode))

    second_vdom = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A']),
      Funicular::VDOM::Element.new('li', {key: 'b'}, ['B'])
    ])
    @patcher.apply(dom, Funicular::VDOM::Differ.diff(first_vdom, second_vdom))

    assert_equal(2, dom.children.length)
    assert_equal('A', dom.children[0].children[0].text_content)
    assert_equal('B', dom.children[1].children[0].text_content)
    assert_nil(placeholder.parent_element)
  end

  def test_create_element_from_string
    element = @patcher.send(:create_element, 'hello')

    assert(element.is_a?(MockTextNode))
    assert_equal('hello', element.text_content)
  end

  def test_text_patch_updates_node_in_place
    node = @doc.createTextNode('old')
    @patcher.apply(node, [[:text, 'new']])
    assert_equal('new', node.text_content)
  end

  def test_text_child_change_reuses_dom_node
    first_vdom = Funicular::VDOM::Element.new('p', {}, ['hello'])
    dom = Funicular::VDOM::Renderer.new(@doc).render(first_vdom)
    text_node = dom.children[0]

    second_vdom = Funicular::VDOM::Element.new('p', {}, ['world'])
    @patcher.apply(dom, Funicular::VDOM::Differ.diff(first_vdom, second_vdom))

    assert(dom.children[0].equal?(text_node))
    assert_equal('world', text_node.text_content)
    assert_equal(0, dom.detach_count)
  end

  def test_keyed_children_patch_unkeyed_text_in_place
    first_vdom = Funicular::VDOM::Element.new('ul', {}, [
      'Total: 1',
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A'])
    ])
    dom = Funicular::VDOM::Renderer.new(@doc).render(first_vdom)
    text_node, a_node = dom.children

    second_vdom = Funicular::VDOM::Element.new('ul', {}, [
      'Total: 2',
      Funicular::VDOM::Element.new('li', {key: 'a'}, ['A'])
    ])
    @patcher.apply(dom, Funicular::VDOM::Differ.diff(first_vdom, second_vdom))

    assert(dom.children[0].equal?(text_node))
    assert(dom.children[1].equal?(a_node))
    assert_equal('Total: 2', text_node.text_content)
    assert_equal(0, dom.detach_count)
  end
end
