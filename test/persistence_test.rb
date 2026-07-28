# Tests for the persistence core (docs decisions 11/16): the snapshot
# round trip through a fake store, the debounced auto-persist riding the
# post-commit event funnel, flush per durability state, failure
# reporting, the availability -> volatile classification (real
# IndexedDB.open under Node has no indexedDB global), and the
# navigator.storage.persist shim. Boot wiring (which decides WHEN these
# run) is a later change; here handles and identity are passed in.

class PersistenceTest < Picotest::Test
  class FakeStore
    attr_reader :data, :put_count

    def initialize
      @data = {}
      @put_count = 0
    end

    def [](key)
      @data[key]
    end

    def []=(key, value)
      @put_count += 1
      @data[key] = value
    end

    def delete(key)
      @data.delete(key)
      nil
    end
  end

  class PutBrokenError < StandardError; end
  class GetBrokenError < StandardError; end

  class BrokenStore
    def [](key)
      raise GetBrokenError, "get failed"
    end

    def []=(key, value)
      raise PutBrokenError, "put failed"
    end
  end

  def setup
    $per_db = SQLite3::Database.new(":memory:")
    $per_db.execute(
      "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    $per_store = FakeStore.new
    $per_identity = Funicular::DB.namespace_identity("app", nil, true)
    Funicular::DB.__set_durability(:persistent_writer)
    Funicular::DB.__set_snapshot_store($per_store)
    Funicular::DB.__set_snapshot_identity($per_identity)
    Funicular::DB.__register_database(:local, $per_db, [])
    Funicular::DB.__register_database(:replica, nil, [])
  end

  def teardown
    Funicular::DB.cancel_persist_timers
    Funicular::DB.__set_durability(:unbooted)
    Funicular::DB.__set_snapshot_store(nil)
    Funicular::DB.__set_snapshot_identity(nil)
    Funicular::DB.__register_database(:local, nil, [])
    Funicular::DB.__register_database(:replica, nil, [])
    Funicular::DB.__reset_config
    JS.global.eval(
      "delete globalThis.__funicularStorageApi; " \
      "delete globalThis.document")
    $per_db.close
  end

  def local_key
    Funicular::DB.snapshot_key($per_identity, :local)
  end

  def pump(ms)
    JS.global.eval("new Promise((r) => setTimeout(r, #{ms}))").await
  end

  def test_configure_runs_with_bareword_config
    Funicular::DB.configure do
      config.local_debounce_ms = 123
      config.replica_debounce_ms = 4567
    end
    assert_equal(123, Funicular::DB.config.local_debounce_ms)
    assert_equal(4567, Funicular::DB.config.replica_debounce_ms)
  end

  def test_snapshot_round_trip
    $per_db.execute("INSERT INTO items (name) VALUES ('alpha')")
    $per_db.execute("INSERT INTO items (name) VALUES ('beta')")
    assert_equal(true, Funicular::DB.persist_snapshot(:local))
    assert_equal(true, $per_store.data.has_key?(local_key))

    fresh = SQLite3::Database.new(":memory:")
    Funicular::DB.__register_database(:local, fresh, [])
    assert_equal(true, Funicular::DB.restore_snapshot(:local))
    rows = fresh.execute("SELECT name FROM items ORDER BY id")
    assert_equal([["alpha"], ["beta"]], rows)
    fresh.close
  end

  def test_persist_refuses_off_writer_states
    Funicular::DB.__set_durability(:persistent_reader)
    assert_equal(false, Funicular::DB.persist_snapshot(:local))
    Funicular::DB.__set_durability(:volatile)
    assert_equal(false, Funicular::DB.persist_snapshot(:local))
    assert_equal(0, $per_store.put_count)
  end

  def test_restore_returns_false_without_snapshot
    assert_equal(false, Funicular::DB.restore_snapshot(:local))
  end

  def test_restore_read_errors_propagate
    # Docs decision 16: storage exists but could not be read -- the
    # boot must fail loud on top of it, never continue empty.
    Funicular::DB.__set_snapshot_store(BrokenStore.new)
    assert_raise(GetBrokenError) do
      Funicular::DB.restore_snapshot(:local)
    end
  end

  def test_persist_failure_reports_and_returns_false
    $per_hook_errors = []
    Funicular::DB.configure do
      config.on_persist_error = ->(e) { $per_hook_errors << e }
    end
    Funicular::DB.__set_snapshot_store(BrokenStore.new)
    assert_equal(false, Funicular::DB.persist_snapshot(:local))
    assert_equal(1, $per_hook_errors.size)
    assert_equal(PutBrokenError, $per_hook_errors[0].class)
  end

  def test_flush_persists_now_and_cancels_the_debounce
    Funicular::DB.configure do
      config.local_debounce_ms = 30
    end
    Funicular::DB.notify_changed(:local, "items")
    assert_equal(true, Funicular::DB.flush)
    assert_equal(1, $per_store.put_count)
    # The armed timer was cancelled: the quiet window passing must not
    # snapshot a second time.
    pump(60)
    assert_equal(1, $per_store.put_count)
  end

  def test_flush_raises_on_a_reader
    Funicular::DB.__set_durability(:persistent_reader)
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.flush
    end
  end

  def test_flush_is_a_noop_on_volatile
    Funicular::DB.__set_durability(:volatile)
    assert_equal(false, Funicular::DB.flush)
    assert_equal(0, $per_store.put_count)
  end

  def test_debounce_persists_after_the_quiet_window
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    Funicular::DB.notify_changed(:local, "items")
    assert_equal(0, $per_store.put_count)
    pump(60)
    assert_equal(1, $per_store.put_count)
    assert_equal(true, $per_store.data.has_key?(local_key))
  end

  def test_debounce_rearms_per_write
    Funicular::DB.configure do
      config.local_debounce_ms = 60
    end
    Funicular::DB.notify_changed(:local, "items")
    pump(40)
    # Still inside the first window: this write pushes the timer back.
    Funicular::DB.notify_changed(:local, "items")
    pump(40)
    # 80ms since the FIRST write, but only 40 since the second.
    assert_equal(0, $per_store.put_count)
    pump(60)
    assert_equal(1, $per_store.put_count)
  end

  def test_persist_refuses_mid_transaction_and_rearms_at_commit
    # serialize would copy UNCOMMITTED pages; a persist landing inside
    # an open transaction (stale timer, visibilitychange, in-block
    # flush) must defer to the settle instead.
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    guarded = Funicular::DB::GuardedDatabase.new($per_db, :local)
    guarded.transaction do
      $per_db.execute("INSERT INTO items (name) VALUES ('mid')")
      assert_equal(false, Funicular::DB.persist_snapshot(:local))
      assert_equal(0, $per_store.put_count)
    end
    pump(60)
    assert_equal(1, $per_store.put_count)
  end

  def test_flush_inside_a_transaction_defers_the_local_snapshot
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    guarded = Funicular::DB::GuardedDatabase.new($per_db, :local)
    guarded.transaction do
      $per_db.execute("INSERT INTO items (name) VALUES ('committed')")
      assert_equal(false, Funicular::DB.flush)
      assert_equal(0, $per_store.put_count)
    end
    pump(60)
    assert_equal(1, $per_store.put_count)
  end

  def test_rolled_back_rows_never_reach_a_snapshot
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    guarded = Funicular::DB::GuardedDatabase.new($per_db, :local)
    begin
      guarded.transaction do
        $per_db.execute("INSERT INTO items (name) VALUES ('ghost')")
        # The mid-transaction refusal parks the persist; the ROLLBACK
        # settle re-arms it, and the snapshot must hold the committed
        # (= empty) state.
        assert_equal(false, Funicular::DB.persist_snapshot(:local))
        raise "boom"
      end
    rescue => e
      raise e unless e.message == "boom"
    end
    pump(60)
    assert_equal(1, $per_store.put_count)
    fresh = SQLite3::Database.new(":memory:")
    Funicular::DB.__register_database(:local, fresh, [])
    assert_equal(true, Funicular::DB.restore_snapshot(:local))
    assert_equal([[0]], fresh.execute("SELECT COUNT(*) FROM items"))
    fresh.close
  end

  def test_stale_timer_callback_leaves_the_replacement_alone
    # A timer whose JS deadline passed before its clearTimeout has its
    # callback QUEUED already; when it finally runs it must not touch
    # the replacement timer's bookkeeping (or snapshot).
    Funicular::DB.configure do
      config.local_debounce_ms = 30
    end
    Funicular::DB.notify_changed(:local, "items")
    stale = Funicular::DB.__persist_timer_token(:local)
    # The re-arm bumps the token; `stale` now names the dead timer.
    Funicular::DB.notify_changed(:local, "items")
    Funicular::DB.__persist_timer_fired(:local, stale)
    assert_equal(0, $per_store.put_count)
    # The replacement stayed under management: flush cancels it, and
    # nothing double-fires afterwards.
    assert_equal(true, Funicular::DB.flush)
    pump(70)
    assert_equal(1, $per_store.put_count)
  end

  def test_cancel_invalidates_queued_timer_callbacks
    Funicular::DB.configure do
      config.local_debounce_ms = 30
    end
    Funicular::DB.notify_changed(:local, "items")
    queued = Funicular::DB.__persist_timer_token(:local)
    Funicular::DB.cancel_persist_timers
    # The callback was (hypothetically) already queued when the cancel
    # ran: replaying it must be a no-op.
    Funicular::DB.__persist_timer_fired(:local, queued)
    assert_equal(0, $per_store.put_count)
  end

  def test_transaction_schedules_at_commit_only
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    guarded = Funicular::DB::GuardedDatabase.new($per_db, :local)
    guarded.transaction do
      Funicular::DB.notify_changed(:local, "items")
      pump(60)
      # Deferred: the write is not committed, nothing may be armed.
      assert_equal(0, $per_store.put_count)
    end
    pump(60)
    assert_equal(1, $per_store.put_count)
  end

  def test_rollback_schedules_nothing
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    guarded = Funicular::DB::GuardedDatabase.new($per_db, :local)
    begin
      guarded.transaction do
        Funicular::DB.notify_changed(:local, "items")
        raise "boom"
      end
    rescue => e
      raise e unless e.message == "boom"
    end
    pump(60)
    assert_equal(0, $per_store.put_count)
  end

  def test_open_snapshot_store_unavailable_becomes_volatile
    # Under Node there is no globalThis.indexedDB, and the store opens
    # with fallback: false -- by-design absence classifies as volatile
    # (docs decision 16), announced once through on_persist_error.
    $per_hook_errors = []
    Funicular::DB.configure do
      config.on_persist_error = ->(e) { $per_hook_errors << e }
    end
    Funicular::DB.__set_snapshot_store(nil)
    assert_equal(nil, Funicular::DB.open_snapshot_store)
    assert_equal(:volatile, Funicular::DB.durability)
    assert_equal(1, $per_hook_errors.size)
    assert_equal(IndexedDB::NotSupportedError, $per_hook_errors[0].class)
    # The failure is sticky: a second open neither retries nor
    # announces again.
    assert_equal(nil, Funicular::DB.open_snapshot_store)
    assert_equal(1, $per_hook_errors.size)
  end

  def test_visibility_flush_persists_when_hidden
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    JS.global.eval(
      "globalThis.document = { visibilityState: 'hidden' }")
    Funicular::DB.notify_changed(:local, "items")
    Funicular::DB.__visibility_flush
    assert_equal(1, $per_store.put_count)
    # The debounce timer was cancelled along the way.
    pump(60)
    assert_equal(1, $per_store.put_count)
  end

  def test_visibility_flush_ignores_a_visible_page
    JS.global.eval(
      "globalThis.document = { visibilityState: 'visible' }")
    Funicular::DB.__visibility_flush
    assert_equal(0, $per_store.put_count)
  end

  def test_request_persistent_storage_results
    JS.global.eval(
      "globalThis.__funicularStorageApi = " \
      "{ persist: () => Promise.resolve(true) }")
    assert_equal(:granted, Funicular::DB.request_persistent_storage)
    JS.global.eval(
      "globalThis.__funicularStorageApi = " \
      "{ persist: () => Promise.resolve(false) }")
    assert_equal(:denied, Funicular::DB.request_persistent_storage)
    JS.global.eval("globalThis.__funicularStorageApi = null")
    assert_equal(:unsupported, Funicular::DB.request_persistent_storage)
  end

  def test_request_persistent_storage_respects_the_opt_out
    Funicular::DB.configure do
      config.request_persistent_storage = false
    end
    assert_equal(:disabled, Funicular::DB.request_persistent_storage)
  end
end
