class DebugTest < Picotest::Test
  # A plain object graph stands in for a component: the inspector only
  # reads instance variables, and a cycle between two nodes is exactly the
  # shape (Runtime <-> Router <-> mounted component) that made Object#inspect
  # recurse without bound.
  class Node
    attr_accessor :peer, :label

    def initialize(label)
      @label = label
      @peer = nil
    end
  end

  def setup
    @ids = []
  end

  def teardown
    @ids.each { |id| Funicular::Debug.unregister_component(id) }
  end

  def register(object)
    id = Funicular::Debug.register_component(object)
    @ids << id
    id
  end

  def test_instance_variables_survive_a_cyclic_graph
    a = Node.new("a")
    b = Node.new("b")
    a.peer = b
    b.peer = a
    holder = Node.new("holder")
    holder.peer = a

    ivars = JSON.parse(Funicular::Debug.get_component_instance_variables(register(holder)))
    assert_equal('"holder"', ivars["@label"])
    assert_equal(true, ivars["@peer"].start_with?("#<DebugTest::Node"))
    # Bounded by depth, not by the cycle: the text stays small.
    assert_equal(true, ivars["@peer"].size < 300)
  end

  def test_state_values_are_truncated_by_depth_and_size
    holder = Node.new("state")
    holder.instance_variable_set(:@state, {
      count: 1,
      items: (1..30).to_a,
      nested: { deep: { deeper: { deepest: [1] } } }
    })

    state = JSON.parse(Funicular::Debug.get_component_state(register(holder)))
    assert_equal("1", state["count"])
    assert_equal(true, state["items"].include?("...5 more"))
    # nested (depth 0) -> deep (1) -> deeper (2) -> the array sits at the
    # depth limit and is summarized.
    assert_equal("{:deep => {:deeper => {:deepest => [...1 items]}}}", state["nested"])
  end

  def test_leaf_values_keep_their_full_inspect
    holder = Node.new("leaf")
    holder.instance_variable_set(:@state, { name: "x\"y", sym: :s, none: nil })

    state = JSON.parse(Funicular::Debug.get_component_state(register(holder)))
    assert_equal('"x\"y"', state["name"])
    assert_equal(":s", state["sym"])
    assert_equal("nil", state["none"])
  end
end
