module JS
  class Object
  end
  class Element < Object
  end
end

class ComponentDomWalkTest < Picotest::Test
  class NodeList < JS::Object
    def initialize(nodes)
      @nodes = nodes
    end

    def to_a
      @nodes.dup
    end
  end

  class Node
    attr_reader :value, :listeners, :child_nodes

    def initialize(type, value = nil, child_nodes = [])
      @type = type
      @value = value
      @child_nodes = child_nodes
      @listeners = []
    end

    def [](key)
      case key.to_s
      when 'nodeType' then @type
      when 'childNodes' then NodeList.new(@child_nodes)
      when 'ownerDocument' then self
      end
    end

    def createTextNode(value)
      Node.new(3, value)
    end

    def removeChild(node)
      @child_nodes.delete_if { |n| n.equal?(node) }
    end

    def replaceChild(new_node, old_node)
      @child_nodes[@child_nodes.index { |n| n.equal?(old_node) }] = new_node
    end

    def addEventListener(name)
      @listeners << name
    end

    def setAttribute(_key, _value); end
  end

  def el(tag, props = {}, children = [])
    Funicular::VDOM::Element.new(tag, props, children)
  end

  def test_events_and_refs_reach_elements_after_text
    button = Node.new(1)
    input = Node.new(1)
    root = Node.new(1, nil, [Node.new(3, 'label'), button, input])
    vnode = el('div', {}, ['label', el('button', { onclick: :clicked }), el('input', { ref: :field })])
    component = Funicular::Component.new

    component.bind_events(root, vnode)

    assert_equal(['click'], button.listeners)
    assert_equal(input, component.collect_refs(root, vnode)[:field])
  end

  def test_hydration_restores_text_boundaries_before_hydrating_children
    child_root = Node.new(1)
    root = Node.new(1, nil, [Node.new(8), Node.new(3, 'a'), Node.new(8), Node.new(3, 'b'), child_root])
    child = Class.new(Funicular::Component) do
      attr_reader :hydrated_into

      def hydrate(dom_element)
        @hydrated_into = dom_element
      end
    end
    vnode = el('div', {}, [nil, 'a', 'b', Funicular::VDOM::Component.new(child)])

    Funicular::Component.new.send(:hydrate_child_components, vnode, root)

    assert_equal(['', 'a', 'b', nil], root.child_nodes.map { |n| n.value })
    assert_equal(child_root, vnode.children[3].instance.hydrated_into)
  end
end
