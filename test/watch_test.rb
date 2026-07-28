# Tests for Component#watch (docs decision 10, "Reactivity"): initial
# materialization into state, re-evaluation on change events,
# re-subscription per evaluation (branchy blocks), the Relation-only
# contract, and unsubscription on unmount -- lifecycle-hook exceptions
# included. Components stay headless (never mounted), so set_state's
# re_render is a no-op; a manual tick scheduler drives the bus.

class WatchTest < Picotest::Test
  def setup
    $watch_db = SQLite3::Database.new(":memory:")
    define_models
    define_components
    Funicular::DB.apply_local_migrations($watch_db, WatchTodo)
    Funicular::DB.apply_local_migrations($watch_db, WatchNote)
    $watch_ticks = 0
    Funicular::DB.__set_tick_scheduler(proc { $watch_ticks += 1 })
    @component = WatchComponent.new
  end

  def teardown
    @component.cleanup_watches
    Funicular::DB.__drain_events
    Funicular::DB.__set_tick_scheduler(nil)
    $watch_db.close
  end

  def define_models
    return if Object.const_defined?(:WatchTodo)

    Object.const_set(:WatchTodo, Class.new(Funicular::Model))
    WatchTodo.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :title
          t.boolean :done, default: false, null: false
        end
      end

      def self.local_db
        $watch_db
      end
    end

    Object.const_set(:WatchNote, Class.new(Funicular::Model))
    WatchNote.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :body
        end
      end

      def self.local_db
        $watch_db
      end
    end

    # Declared but never migrated: materializing raises in SQLite.
    Object.const_set(:WatchBroken, Class.new(Funicular::Model))
    WatchBroken.class_eval do
      table_name "watch_missing_table"
      storage :local do
        migrate 1 do |t|
          t.string :x
        end
      end

      def self.local_db
        $watch_db
      end
    end
  end

  def define_components
    return if Object.const_defined?(:WatchComponent)

    Object.const_set(:WatchComponent, Class.new(Funicular::Component))
    WatchComponent.class_eval do
      def render
        nil
      end
    end

    Object.const_set(:WatchBoomComponent, Class.new(Funicular::Component))
    WatchBoomComponent.class_eval do
      def render
        nil
      end

      def component_will_unmount
        raise "boom in unmount hook"
      end
    end

    Object.const_set(:WatchMountBoomComponent,
                     Class.new(Funicular::Component))
    WatchMountBoomComponent.class_eval do
      def render
        nil
      end

      def component_will_mount
        raise "boom in mount hook"
      end
    end
  end

  def tick
    Funicular::DB.__drain_events
  end

  def titles(records)
    # @type var out: Array[untyped]
    out = []
    records_size = records.size
    i = 0
    while i < records_size
      out << records[i].title
      i += 1
    end
    out
  end

  # ---- the contract ----

  def test_watch_materializes_the_relation_into_state
    WatchTodo.create(title: "a")
    WatchTodo.create(title: "b", done: true)
    @component.watch(:todos) do
      WatchTodo.local.where(done: false).order(:id)
    end
    assert_equal(["a"], titles(@component.state[:todos]))
  end

  def test_watch_requires_a_relation
    raised = false
    begin
      @component.watch(:bad) { [1, 2, 3] }
    rescue ArgumentError => e
      raised = true
      assert_equal(true, e.message.include?("on_change"))
    end
    assert_equal(true, raised)
    assert_raise(ArgumentError) { @component.watch(:worse) }
  end

  # ---- re-evaluation on change events ----

  def test_change_events_reevaluate_and_patch_state
    @component.watch(:todos) { WatchTodo.local.order(:id) }
    assert_equal([], @component.state[:todos])
    WatchTodo.create(title: "later")
    assert_equal([], @component.state[:todos])
    tick
    assert_equal(["later"], titles(@component.state[:todos]))
    WatchTodo.create(title: "and again")
    tick
    assert_equal(["later", "and again"], titles(@component.state[:todos]))
  end

  def test_branchy_blocks_resubscribe_per_evaluation
    use_notes = false
    @component.watch(:items) do
      use_notes ? WatchNote.local.order(:id) : WatchTodo.local.order(:id)
    end
    use_notes = true
    # This todo event re-evaluates the block, which now returns the
    # NOTES relation -- and must re-subscribe accordingly.
    WatchTodo.create(title: "flip")
    tick
    assert_equal([], @component.state[:items])
    # Todo changes no longer reach the watch...
    WatchTodo.create(title: "ignored")
    tick
    assert_equal([], @component.state[:items])
    # ...note changes do.
    WatchNote.create(body: "seen")
    tick
    assert_equal(1, @component.state[:items].size)
  end

  # ---- materialization failures ----

  def test_failed_initial_materialization_leaves_no_subscription
    raised = false
    begin
      @component.watch(:broken) { WatchBroken.local }
    rescue SQLite3::Exception
      raised = true
    end
    assert_equal(true, raised)
    watches = @component.instance_variable_get("@__watches")
    assert_equal(true, watches.nil? || watches[:broken].nil?)
  end

  def test_failed_reevaluation_keeps_the_previous_subscription
    fail_mode = false
    @component.watch(:todos) do
      fail_mode ? WatchBroken.local : WatchTodo.local.order(:id)
    end
    fail_mode = true
    WatchTodo.create(title: "one")
    tick
    # The re-evaluation raised (isolated by the bus); state unchanged,
    # but the previous healthy subscription survived...
    assert_equal([], @component.state[:todos])
    fail_mode = false
    WatchTodo.create(title: "two")
    tick
    # ...so the next healthy evaluation catches up.
    assert_equal(["one", "two"], titles(@component.state[:todos]))
  end

  # ---- unmount ----

  def test_unmount_unsubscribes_watches
    # watch first (unmounted, no DOM), then pretend to be mounted so
    # unmount's full path runs headlessly.
    @component.watch(:todos) { WatchTodo.local.order(:id) }
    @component.instance_variable_set("@mounted", true)
    @component.unmount
    WatchTodo.create(title: "after unmount")
    tick
    assert_equal([], @component.state[:todos])
  end

  def test_failed_mount_releases_watch_subscriptions
    component = WatchMountBoomComponent.new
    component.watch(:todos) { WatchTodo.local.order(:id) }
    raised = false
    begin
      component.mount(nil)
    rescue RuntimeError
      raised = true
    end
    assert_equal(true, raised)
    # A failed mount never reaches unmount: the rescue path must have
    # released the subscription, or this event would re-evaluate.
    WatchTodo.create(title: "after failed mount")
    tick
    assert_equal([], component.state[:todos])
  end

  def test_failed_hydrate_releases_watch_subscriptions
    component = WatchComponent.new
    component.watch(:todos) { WatchTodo.local.order(:id) }
    raised = false
    begin
      # A nil server element must take the same cleanup path as every
      # other hydrate failure.
      component.hydrate(nil)
    rescue RuntimeError
      raised = true
    end
    assert_equal(true, raised)
    WatchTodo.create(title: "after failed hydrate")
    tick
    assert_equal([], component.state[:todos])
  end

  def test_unmount_unsubscribes_even_when_a_lifecycle_hook_raises
    component = WatchBoomComponent.new
    component.watch(:todos) { WatchTodo.local.order(:id) }
    component.instance_variable_set("@mounted", true)
    raised = false
    begin
      component.unmount
    rescue RuntimeError
      raised = true
    end
    assert_equal(true, raised)
    WatchTodo.create(title: "zombie?")
    tick
    assert_equal([], component.state[:todos])
  end
end
