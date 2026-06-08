class VDOMDifferTest < Picotest::Test
  def setup
    @differ = Funicular::VDOM::Differ
  end

  # Basic diff tests
  def test_diff_returns_replace_when_old_is_nil
    new_node = Funicular::VDOM::Element.new('div')
    patches = @differ.diff(nil, new_node)
    assert_equal([[:replace, new_node, nil]], patches)
  end

  def test_diff_returns_remove_when_new_is_nil
    old_node = Funicular::VDOM::Element.new('div')
    patches = @differ.diff(old_node, nil)
    assert_equal([[:remove, old_node]], patches)
  end

  def test_diff_text_node_no_change
    old_node = Funicular::VDOM::Text.new('hello')
    new_node = Funicular::VDOM::Text.new('hello')
    patches = @differ.diff(old_node, new_node)
    assert_equal([], patches)
  end

  def test_diff_text_node_changed
    old_node = Funicular::VDOM::Text.new('hello')
    new_node = Funicular::VDOM::Text.new('world')
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:replace, new_node, old_node]], patches)
  end

  def test_diff_element_different_tag
    old_node = Funicular::VDOM::Element.new('div')
    new_node = Funicular::VDOM::Element.new('span')
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:replace, new_node, old_node]], patches)
  end

  def test_diff_element_same_tag_no_props_change
    old_node = Funicular::VDOM::Element.new('div', {class: 'foo'})
    new_node = Funicular::VDOM::Element.new('div', {class: 'foo'})
    patches = @differ.diff(old_node, new_node)
    assert_equal([], patches)
  end

  def test_diff_element_props_changed
    old_node = Funicular::VDOM::Element.new('div', {class: 'foo'})
    new_node = Funicular::VDOM::Element.new('div', {class: 'bar'})
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:props, {class: 'bar'}]], patches)
  end

  def test_diff_element_props_added
    old_node = Funicular::VDOM::Element.new('div')
    new_node = Funicular::VDOM::Element.new('div', {class: 'foo'})
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:props, {class: 'foo'}]], patches)
  end

  def test_diff_element_props_removed
    old_node = Funicular::VDOM::Element.new('div', {class: 'foo'})
    new_node = Funicular::VDOM::Element.new('div')
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:props, {class: nil}]], patches)
  end

  # Children diff tests - index-based (no keys)
  # Test via Element diff since diff_children is private
  def test_diff_children_by_index_no_change
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li'),
      Funicular::VDOM::Element.new('li')
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li'),
      Funicular::VDOM::Element.new('li')
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal([], patches)
  end

  def test_diff_children_by_index_child_changed
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {class: 'foo'}),
      Funicular::VDOM::Element.new('li')
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {class: 'bar'}),
      Funicular::VDOM::Element.new('li')
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(0, patches[0][0]) # Child index 0
    assert_equal([[:props, {class: 'bar'}]], patches[0][1])
  end

  def test_diff_children_by_index_child_added
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li')
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li'),
      Funicular::VDOM::Element.new('li')
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(1, patches[0][0]) # Child index 1
    new_li = new_element.children[1]
    assert_equal([[:replace, new_li, nil]], patches[0][1])
  end

  def test_diff_children_by_index_child_removed
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li'),
      Funicular::VDOM::Element.new('li')
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li')
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(1, patches[0][0]) # Child index 1
    old_li = old_element.children[1]
    assert_equal([[:remove, old_li]], patches[0][1])
  end

  # Children diff tests - key-based
  def test_diff_children_with_keys_no_change
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'b'})
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'b'})
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal([], patches)
  end

  def test_diff_children_with_keys_reordered
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a', class: 'first'}),
      Funicular::VDOM::Element.new('li', {key: 'b', class: 'second'})
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'b', class: 'second'}),
      Funicular::VDOM::Element.new('li', {key: 'a', class: 'first'})
    ])
    patches = @differ.diff(old_element, new_element)
    # No content changes (just position swap) means no patches.
    # Reorder-only is not considered a change in the current implementation.
    assert_equal([], patches)
  end

  def test_diff_children_with_keys_element_added
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'b'})
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'c'}),
      Funicular::VDOM::Element.new('li', {key: 'b'})
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(:keyed_children, patches[0][0])
    ops = patches[0][1]
    removes = patches[0][2]
    # 'a' kept at index 0
    assert_equal(:keep, ops[0][0])
    assert_equal(0, ops[0][1]) # old_index
    assert_equal(0, ops[0][2]) # new_index
    # 'c' inserted at new_index 1
    assert_equal(:insert, ops[1][0])
    assert_equal(1, ops[1][1]) # new_index
    assert_equal('c', ops[1][2].key)
    # 'b' kept (old_index=1 -> new_index=2)
    assert_equal(:keep, ops[2][0])
    assert_equal(1, ops[2][1]) # old_index
    assert_equal(2, ops[2][2]) # new_index
    # No removes
    assert_equal([], removes)
  end

  def test_diff_children_with_keys_element_removed
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'b'}),
      Funicular::VDOM::Element.new('li', {key: 'c'})
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'c'})
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(:keyed_children, patches[0][0])
    ops = patches[0][1]
    removes = patches[0][2]
    # 'a' kept at old_index=0 -> new_index=0
    assert_equal(:keep, ops[0][0])
    assert_equal(0, ops[0][1])
    assert_equal(0, ops[0][2])
    # 'c' kept at old_index=2 -> new_index=1
    assert_equal(:keep, ops[1][0])
    assert_equal(2, ops[1][1])
    assert_equal(1, ops[1][2])
    # 'b' (old_index=1) removed
    assert_equal(1, removes.length)
    assert_equal(1, removes[0][0]) # old_index
    assert_equal('b', removes[0][1].key)
  end

  def test_diff_children_with_keys_removes_unmatched_unkeyed_old
    # Regression: switching from an unkeyed placeholder to a keyed list must
    # remove the placeholder. Previously unkeyed unmatched old children were
    # left in place, so e.g. a "Loading..." node never disappeared once the
    # keyed message list replaced it.
    old_element = Funicular::VDOM::Element.new('div', {}, [
      Funicular::VDOM::Element.new('div', {}) # unkeyed placeholder
    ])
    new_element = Funicular::VDOM::Element.new('div', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('li', {key: 'b'})
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(:keyed_children, patches[0][0])
    ops = patches[0][1]
    removes = patches[0][2]
    # both keyed children inserted
    assert_equal(:insert, ops[0][0])
    assert_equal('a', ops[0][2].key)
    assert_equal(:insert, ops[1][0])
    assert_equal('b', ops[1][2].key)
    # the unkeyed placeholder at old_index 0 is removed
    assert_equal(1, removes.length)
    assert_equal(0, removes[0][0]) # old_index
    assert_nil(removes[0][1].key)
  end

  def test_diff_children_with_keys_element_props_changed
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a', class: 'foo'}),
      Funicular::VDOM::Element.new('li', {key: 'b', class: 'bar'})
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a', class: 'baz'}),
      Funicular::VDOM::Element.new('li', {key: 'b', class: 'bar'})
    ])
    patches = @differ.diff(old_element, new_element)
    assert_equal(1, patches.length)
    assert_equal(:keyed_children, patches[0][0])
    ops = patches[0][1]
    # 'a' kept with props change
    assert_equal(:keep, ops[0][0])
    assert_equal(0, ops[0][1]) # old_index
    assert_equal(0, ops[0][2]) # new_index
    assert_equal([[:props, {class: 'baz'}]], ops[0][3]) # child_patches
    # 'b' kept with no change
    assert_equal(:keep, ops[1][0])
    assert_equal([], ops[1][3])
  end

  def test_diff_children_with_keys_mixed_with_without_keys
    old_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('span') # No key
    ])
    new_element = Funicular::VDOM::Element.new('ul', {}, [
      Funicular::VDOM::Element.new('li', {key: 'a'}),
      Funicular::VDOM::Element.new('p') # No key, different tag
    ])
    patches = @differ.diff(old_element, new_element)
    # Should detect change in unkeyed child at index 1
    assert_equal(1, patches.length)
    assert_equal(:keyed_children, patches[0][0])
    ops = patches[0][1]
    # 'a' kept
    assert_equal(:keep, ops[0][0])
    # unkeyed span->p triggers replace inside keep
    assert_equal(:keep, ops[1][0])
    assert_equal(1, ops[1][1]) # old_index
    assert_equal(1, ops[1][2]) # new_index
    assert_equal([[:replace, new_element.children[1], old_element.children[1]]], ops[1][3])
  end

  # Component diff tests
  def test_diff_component_different_class
    old_node = Funicular::VDOM::Component.new(String, {foo: 'bar'})
    new_node = Funicular::VDOM::Component.new(Array, {foo: 'bar'})
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:replace, new_node, old_node]], patches)
  end

  def test_diff_component_same_class_same_props
    old_node = Funicular::VDOM::Component.new(String, {foo: 'bar'})
    new_node = Funicular::VDOM::Component.new(String, {foo: 'bar'})
    patches = @differ.diff(old_node, new_node)
    assert_equal([], patches)
  end

  def test_diff_component_same_class_different_props_without_preserve
    old_node = Funicular::VDOM::Component.new(String, {foo: 'bar'})
    new_node = Funicular::VDOM::Component.new(String, {foo: 'baz'})
    patches = @differ.diff(old_node, new_node)
    assert_equal([[:replace, new_node, old_node]], patches)
  end
end
