# Tests for the change-event bus (docs decision 10): subscribe/
# unsubscribe, notify_changed's two forms, post-commit coalescing and
# rollback discard inside guarded transactions, and next-tick delivery
# (nothing is delivered synchronously; one drain per tick; events
# raised by subscribers belong to the next tick; a raising subscriber
# is isolated). A manual tick scheduler makes the ticks deterministic;
# one test exercises the default JS setTimeout(0) scheduler for real.

class EventBusTest < Picotest::Test
  def setup
    $bus_db = SQLite3::Database.new(":memory:")
    $bus_db.execute("CREATE TABLE ev (id INTEGER PRIMARY KEY, n TEXT)")
    @guard = Funicular::DB::GuardedDatabase.new($bus_db)
    @events = []
    @subs = []
    $bus_ticks = 0
    Funicular::DB.__set_tick_scheduler(proc { $bus_ticks += 1 })
  end

  def teardown
    subs_size = @subs.size
    i = 0
    while i < subs_size
      Funicular::DB.unsubscribe(@subs[i])
      i += 1
    end
    # Flush anything left in the tick buffer, then restore the default.
    Funicular::DB.__drain_events
    Funicular::DB.__set_tick_scheduler(nil)
    $bus_db.close
  end

  def define_models
    return if Object.const_defined?(:BusDraft)

    Object.const_set(:BusDraft, Class.new(Funicular::Model))
    BusDraft.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :name
        end
      end
    end

    Object.const_set(:BusPost, Class.new(Funicular::Model))
    BusPost.class_eval do
      table_name "bus_posts"
    end

    Object.const_set(:BusSession, Class.new(Funicular::Model))
    BusSession.class_eval do
      storage :ephemeral
    end
  end

  def listen(role, table)
    events = @events
    id = Funicular::DB.subscribe(role, table) do |r, t|
      events << [r, t]
    end
    @subs << id
    id
  end

  def tick
    Funicular::DB.__drain_events
  end

  # ---- next-tick delivery ----

  def test_nothing_is_delivered_synchronously
    listen(:local, "ev")
    Funicular::DB.notify_changed(:local, "ev")
    assert_equal([], @events)
    assert_equal(1, $bus_ticks)
    tick
    assert_equal([[:local, "ev"]], @events)
  end

  def test_events_coalesce_within_one_tick_and_one_drain_is_scheduled
    listen(:local, "ev")
    listen(:local, "other")
    Funicular::DB.notify_changed(:local, "ev")
    Funicular::DB.notify_changed(:local, "ev")
    Funicular::DB.notify_changed(:local, "other")
    Funicular::DB.notify_changed(:local, "ev")
    assert_equal(1, $bus_ticks)
    tick
    assert_equal([[:local, "ev"], [:local, "other"]], @events)
  end

  def test_subscriber_raised_events_belong_to_the_next_tick
    events = @events
    @subs << Funicular::DB.subscribe(:local, "one") do |r, t|
      events << :one_start
      Funicular::DB.notify_changed(:local, "two")
      events << :one_end
    end
    @subs << Funicular::DB.subscribe(:local, "two") do |r, t|
      events << :two
    end
    Funicular::DB.notify_changed(:local, "one")
    tick
    # Never nested into the running delivery...
    assert_equal([:one_start, :one_end], @events)
    # ...but not dropped either: it scheduled its own drain.
    assert_equal(2, $bus_ticks)
    tick
    assert_equal([:one_start, :one_end, :two], @events)
  end

  def test_the_default_scheduler_delivers_on_a_real_js_tick
    Funicular::DB.__set_tick_scheduler(nil)
    listen(:local, "ev")
    Funicular::DB.notify_changed(:local, "ev")
    assert_equal([], @events)
    waited = 0
    while @events.empty? && waited < 50
      JS.global.eval("new Promise((r) => setTimeout(r, 10))").await
      waited += 1
    end
    assert_equal([[:local, "ev"]], @events)
  end

  # ---- the two notify forms ----

  def test_model_form_resolves_role_and_table
    define_models
    listen(:local, "bus_drafts")
    listen(:replica, "bus_posts")
    Funicular::DB.notify_changed(BusDraft)
    Funicular::DB.notify_changed(BusPost)
    tick
    assert_equal([[:local, "bus_drafts"], [:replica, "bus_posts"]], @events)
  end

  def test_ephemeral_model_has_no_table_to_notify_about
    define_models
    assert_raise(Funicular::DB::NoTableError) do
      Funicular::DB.notify_changed(BusSession)
    end
  end

  def test_role_is_validated
    assert_raise(ArgumentError) do
      Funicular::DB.notify_changed(:bogus, "ev")
    end
    assert_raise(ArgumentError) do
      Funicular::DB.subscribe(:bogus, "ev") { }
    end
  end

  def test_unsubscribe_stops_delivery
    id = listen(:local, "ev")
    Funicular::DB.notify_changed(:local, "ev")
    tick
    Funicular::DB.unsubscribe(id)
    Funicular::DB.notify_changed(:local, "ev")
    tick
    assert_equal(1, @events.size)
  end

  # ---- post-commit semantics ----

  def test_transaction_coalesces_and_fires_after_commit
    listen(:local, "ev")
    listen(:local, "other")
    inside_ticks = nil
    @guard.transaction do
      Funicular::DB.notify_changed(:local, "ev")
      Funicular::DB.notify_changed(:local, "ev")
      Funicular::DB.notify_changed(:local, "other")
      inside_ticks = $bus_ticks
    end
    # Nothing even reached the tick buffer before COMMIT.
    assert_equal(0, inside_ticks)
    tick
    assert_equal([[:local, "ev"], [:local, "other"]], @events)
  end

  def test_blockless_transaction_defers_until_manual_commit
    listen(:local, "ev")
    @guard.transaction
    Funicular::DB.notify_changed(:local, "ev")
    assert_equal(0, $bus_ticks)
    @guard.commit
    assert_equal(1, $bus_ticks)
    tick
    assert_equal([[:local, "ev"]], @events)
  end

  def test_blockless_transaction_rollback_discards
    listen(:local, "ev")
    @guard.transaction
    @guard.execute("INSERT INTO ev (n) VALUES ('x')")
    Funicular::DB.notify_changed(:local, "ev")
    @guard.rollback
    tick
    assert_equal([], @events)
    assert_equal(0, $bus_db.execute("SELECT COUNT(*) FROM ev")[0][0])
  end

  def test_deferral_is_tracked_per_database_role
    replica_raw = SQLite3::Database.new(":memory:")
    replica_guard = Funicular::DB::GuardedDatabase.new(replica_raw, :replica)
    listen(:local, "ev")
    listen(:replica, "rev")
    @guard.transaction
    Funicular::DB.notify_changed(:local, "ev")
    replica_guard.transaction
    Funicular::DB.notify_changed(:replica, "rev")
    replica_guard.rollback
    @guard.commit
    tick
    # The rolled-back replica event is gone; the committed local one
    # fired -- one shared depth counter would deliver both or neither.
    assert_equal([[:local, "ev"]], @events)
    replica_raw.close
  end

  def test_only_the_matching_role_defers
    listen(:replica, "rev")
    ticks_inside = nil
    @guard.transaction do
      # A replica event during a LOCAL transaction is not part of it:
      # the replica database has no transaction open.
      Funicular::DB.notify_changed(:replica, "rev")
      ticks_inside = $bus_ticks
    end
    assert_equal(1, ticks_inside)
    tick
    assert_equal([[:replica, "rev"]], @events)
  end

  def test_rollback_discards_pending_events
    listen(:local, "ev")
    begin
      @guard.transaction do
        Funicular::DB.notify_changed(:local, "ev")
        raise ArgumentError, "boom"
      end
    rescue ArgumentError
    end
    tick
    assert_equal([], @events)
    Funicular::DB.notify_changed(:local, "ev")
    tick
    assert_equal([[:local, "ev"]], @events)
  end

  # ---- subscriber isolation ----

  def test_a_raising_subscriber_is_isolated
    events = @events
    @subs << Funicular::DB.subscribe(:local, "ev") do |r, t|
      raise "broken watcher"
    end
    listen(:local, "ev")
    Funicular::DB.notify_changed(:local, "ev")
    tick
    assert_equal([[:local, "ev"]], @events)
    Funicular::DB.notify_changed(:local, "ev")
    tick
    assert_equal(2, @events.size)
  end

  def test_model_on_change_and_off_change
    define_models
    events = @events
    sub = BusDraft.on_change { |r, t| events << :changed }
    Funicular::DB.notify_changed(BusDraft)
    tick
    assert_equal([:changed], @events)
    BusDraft.off_change(sub)
    Funicular::DB.notify_changed(BusDraft)
    tick
    assert_equal(1, @events.size)
  end

  def test_on_change_contract
    define_models
    assert_raise(Funicular::DB::NoTableError) do
      BusSession.on_change { }
    end
    assert_raise(ArgumentError) { BusPost.on_change }
  end

  def test_local_table_changed_feeds_the_bus
    define_models
    listen(:local, "bus_drafts")
    BusDraft.local_table_changed
    tick
    assert_equal([[:local, "bus_drafts"]], @events)
  end
end
