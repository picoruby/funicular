# Tests for wipe + the mutation generation (docs decision 17): both
# databases dropped and rebuilt empty, both snapshot keys deleted, and
# in-flight REST responses discarded instead of applied. The HTTP stub
# here DEFERS responses (each Picotest file runs in its own VM), so a
# wipe can land between issue and response exactly like in flight.

module Funicular
  module HTTP
    class << self
      def get(url, &block)
        $wipe_pending << block
      end

      def post(url, body = nil, &block)
        $wipe_pending << block
      end

      def patch(url, body = nil, &block)
        $wipe_pending << block
      end

      def delete(url, &block)
        $wipe_pending << block
      end
    end
  end
end

class WipeTest < Picotest::Test
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

  class DeleteBrokenError < StandardError; end

  class DeleteBrokenStore < FakeStore
    def delete(key)
      raise DeleteBrokenError, "delete failed"
    end
  end

  class SlowStore < FakeStore
    def delete(key)
      # Suspend the wiping Task mid-delete, exactly where a scheduled
      # drain would sneak in.
      JS.global.eval("new Promise((r) => setTimeout(r, 15))").await
      super
    end
  end

  class OrderProbeStore < FakeStore
    def delete(key)
      # Recorded at delete time: when the rebuild really precedes the
      # snapshot deletes, the table is already empty here.
      $wipe_probe << $wipe_local_db.execute(
        "SELECT COUNT(*) FROM wipe_drafts")[0][0]
      super
    end
  end

  NOTE_SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "body" => { "type" => "string" },
    },
    "endpoints" => {
      "all" => { "path" => "/wipe_notes" },
    },
  }

  def setup
    $wipe_pending = []
    $wipe_local_db = SQLite3::Database.new(":memory:")
    $wipe_replica_db = SQLite3::Database.new(":memory:")
    $wipe_store = FakeStore.new
    $wipe_identity = Funicular::DB.namespace_identity("app", nil, true)
    define_models
    Funicular::DB.apply_local_migrations($wipe_local_db, WipeDraft)
    Funicular::DB.build_replica_tables($wipe_replica_db, [WipeNote])
    Funicular::DB.__register_database(:local, $wipe_local_db, [WipeDraft])
    Funicular::DB.__register_database(:replica, $wipe_replica_db,
                                      [WipeNote])
    Funicular::DB.__set_durability(:persistent_writer)
    Funicular::DB.__set_snapshot_store($wipe_store)
    Funicular::DB.__set_snapshot_identity($wipe_identity)
  end

  def teardown
    Funicular::DB.cancel_persist_timers
    Funicular::DB.__set_durability(:unbooted)
    Funicular::DB.__set_snapshot_store(nil)
    Funicular::DB.__set_snapshot_identity(nil)
    Funicular::DB.__register_database(:local, nil, [])
    Funicular::DB.__register_database(:replica, nil, [])
    Funicular::DB.__reset_config
    $wipe_local_db.close
    $wipe_replica_db.close
  end

  def define_models
    return if Object.const_defined?(:WipeDraft)

    Object.const_set(:WipeDraft, Class.new(Funicular::Model))
    WipeDraft.class_eval do
      table_name "wipe_drafts"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
      end
    end

    Object.const_set(:WipeNote, Class.new(Funicular::Model))
    WipeNote.class_eval do
      table_name "wipe_notes"

      def self.replica_db
        $wipe_replica_db
      end
    end
    WipeNote.load_schema(NOTE_SCHEMA)
  end

  def pump(ms)
    JS.global.eval("new Promise((r) => setTimeout(r, #{ms}))").await
  end

  def respond(payload)
    block = $wipe_pending.shift
    block.call(Funicular::HTTP::Response.new(200, payload))
  end

  def test_wipe_requires_a_booted_writer_or_volatile_tab
    Funicular::DB.__set_durability(:persistent_reader)
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.wipe
    end
    Funicular::DB.__set_durability(:unbooted)
    assert_raise(Funicular::DB::Error) do
      Funicular::DB.wipe
    end
  end

  def test_wipe_refuses_during_an_open_transaction
    # The rebuild would nest into (or be rolled back with) the open
    # transaction, so the refusal must come BEFORE any side effect.
    before = Funicular::DB.mutation_generation
    key = Funicular::DB.snapshot_key($wipe_identity, :local)
    $wipe_store.data[key] = "kept"
    $wipe_local_db.execute("BEGIN")
    $wipe_local_db.execute(
      "INSERT INTO wipe_drafts (title) VALUES ('open')")
    begin
      assert_raise(Funicular::DB::Error) do
        Funicular::DB.wipe
      end
    ensure
      $wipe_local_db.execute("ROLLBACK")
    end
    assert_equal(before, Funicular::DB.mutation_generation)
    assert_equal("kept", $wipe_store.data[key])
    # The replica side guards identically.
    $wipe_replica_db.execute("BEGIN")
    begin
      assert_raise(Funicular::DB::Error) do
        Funicular::DB.wipe
      end
    ensure
      $wipe_replica_db.execute("ROLLBACK")
    end
    assert_equal(before, Funicular::DB.mutation_generation)
  end

  def test_snapshot_deletes_run_after_the_rebuild
    # The deletes are the only operations in wipe that suspend this
    # Task; anything before them must already be settled, or another
    # Task could open a transaction behind the transaction check
    # (TOCTOU) and the rebuild would run into it.
    $wipe_probe = []
    Funicular::DB.__set_snapshot_store(OrderProbeStore.new)
    $wipe_local_db.execute(
      "INSERT INTO wipe_drafts (title) VALUES ('secret')")
    Funicular::DB.wipe
    assert_equal([0, 0], $wipe_probe)
  end

  def test_failed_snapshot_delete_notifies_no_watcher
    # A failing delete leaves the old snapshot able to resurrect on
    # reload, so wipe raises WITHOUT telling any watcher (a component
    # must never render a "wiped" state that is not durable) and
    # without arming a fresh persist.
    Funicular::DB.configure do
      config.local_debounce_ms = 10
      config.replica_debounce_ms = 10
    end
    broken = DeleteBrokenStore.new
    Funicular::DB.__set_snapshot_store(broken)
    $wipe_events = 0
    sub = Funicular::DB.subscribe(:local, "wipe_drafts") do |_r, _t|
      $wipe_events += 1
    end
    assert_raise(DeleteBrokenError) do
      Funicular::DB.wipe
    end
    # Past both debounce windows: no watcher ran, no snapshot landed.
    pump(40)
    assert_equal(0, $wipe_events)
    assert_equal(0, broken.put_count)
    Funicular::DB.unsubscribe(sub)
  end

  def test_prewipe_queued_events_are_superseded_by_the_wipe_event
    # A change event queued BEFORE the wipe must not slip out during
    # the snapshot deletes (the store here suspends mid-delete): the
    # watcher hears from the wipe exactly once, afterwards.
    Funicular::DB.__set_snapshot_store(SlowStore.new)
    $wipe_events = 0
    sub = Funicular::DB.subscribe(:local, "wipe_drafts") do |_r, _t|
      $wipe_events += 1
    end
    Funicular::DB.notify_changed(:local, "wipe_drafts")
    Funicular::DB.wipe
    pump(40)
    assert_equal(1, $wipe_events)
    Funicular::DB.unsubscribe(sub)
  end

  def test_wipe_from_a_subscriber_stops_the_running_drain
    # The running drain holds its events in a local variable, out of
    # clear_tick_events' reach: the generation bump must stop it. The
    # second subscriber (and every later event of the drain) hears only
    # from the wipe's own notification, one tick later.
    $wipe_first = 0
    $wipe_second = 0
    sub1 = Funicular::DB.subscribe(:local, "wipe_drafts") do |_r, _t|
      $wipe_first += 1
      Funicular::DB.wipe if $wipe_first == 1
    end
    sub2 = Funicular::DB.subscribe(:local, "wipe_drafts") do |_r, _t|
      $wipe_second += 1
    end
    Funicular::DB.notify_changed(:local, "wipe_drafts")
    pump(30)
    # First subscriber: the pre-wipe event plus the wipe's own.
    # Second subscriber: ONLY the wipe's own.
    assert_equal(2, $wipe_first)
    assert_equal(1, $wipe_second)
    Funicular::DB.unsubscribe(sub1)
    Funicular::DB.unsubscribe(sub2)
  end

  def test_prewipe_queued_events_die_with_a_failed_wipe
    Funicular::DB.__set_snapshot_store(DeleteBrokenStore.new)
    $wipe_events = 0
    sub = Funicular::DB.subscribe(:local, "wipe_drafts") do |_r, _t|
      $wipe_events += 1
    end
    Funicular::DB.notify_changed(:local, "wipe_drafts")
    assert_raise(DeleteBrokenError) do
      Funicular::DB.wipe
    end
    pump(10)
    assert_equal(0, $wipe_events)
    Funicular::DB.unsubscribe(sub)
  end

  def test_wipe_advances_the_generation_first
    before = Funicular::DB.mutation_generation
    assert_equal(true, Funicular::DB.wipe)
    assert_equal(before + 1, Funicular::DB.mutation_generation)
    assert_equal(true, Funicular::DB.stale_generation?(before))
  end

  def test_wipe_empties_and_rebuilds_both_databases
    $wipe_local_db.execute(
      "INSERT INTO wipe_drafts (title) VALUES ('secret')")
    $wipe_replica_db.execute(
      "INSERT INTO wipe_notes (id, body) VALUES (1, 'mirrored')")
    Funicular::DB.wipe
    # Empty but queryable, schema intact: the migration state and the
    # fingerprint were rebuilt from scratch.
    assert_equal([[0]],
                 $wipe_local_db.execute("SELECT COUNT(*) FROM wipe_drafts"))
    assert_equal([[0]],
                 $wipe_replica_db.execute("SELECT COUNT(*) FROM wipe_notes"))
    assert_equal(1, Funicular::DB.stored_table_version(
                      $wipe_local_db, "wipe_drafts"))
    fingerprint = Funicular::DB.read_meta(
      $wipe_replica_db, Funicular::DB::REPLICA_FINGERPRINT_KEY)
    assert_equal(Funicular::DB.canonical_replica_schema([WipeNote]),
                 fingerprint)
  end

  def test_wipe_drops_a_table_whose_name_contains_a_quote
    $wipe_local_db.execute(
      'CREATE TABLE "wipe""quoted" (id INTEGER PRIMARY KEY)')
    Funicular::DB.wipe
    rows = $wipe_local_db.execute(
      "SELECT name FROM sqlite_master WHERE name = ?", ['wipe"quoted'])
    assert_equal([], rows)
  end

  def test_wipe_deletes_only_this_namespaces_snapshots
    local_key = Funicular::DB.snapshot_key($wipe_identity, :local)
    replica_key = Funicular::DB.snapshot_key($wipe_identity, :replica)
    other = Funicular::DB.namespace_identity("app", "someone-else", false)
    other_key = Funicular::DB.snapshot_key(other, :local)
    $wipe_store.data[local_key] = "old-local"
    $wipe_store.data[replica_key] = "old-replica"
    $wipe_store.data[other_key] = "kept"
    Funicular::DB.wipe
    assert_equal(false, $wipe_store.data.has_key?(local_key))
    assert_equal(false, $wipe_store.data.has_key?(replica_key))
    assert_equal("kept", $wipe_store.data[other_key])
  end

  def test_wipe_invalidates_queued_timer_callbacks
    Funicular::DB.configure do
      config.local_debounce_ms = 20
    end
    Funicular::DB.notify_changed(:local, "wipe_drafts")
    stale = Funicular::DB.__persist_timer_token(:local)
    Funicular::DB.wipe
    # A callback already queued when the wipe cancelled its timer must
    # come up stale.
    Funicular::DB.__persist_timer_fired(:local, stale)
    assert_equal(0, $wipe_store.put_count)
  end

  def test_post_wipe_snapshots_hold_the_wiped_state
    Funicular::DB.configure do
      config.local_debounce_ms = 20
      config.replica_debounce_ms = 20
    end
    $wipe_local_db.execute(
      "INSERT INTO wipe_drafts (title) VALUES ('secret')")
    assert_equal(true, Funicular::DB.flush)
    Funicular::DB.wipe
    # wipe's own change notifications re-arm the debounce; the fresh
    # snapshots must hold the EMPTY state.
    pump(60)
    fresh = SQLite3::Database.new(":memory:")
    Funicular::DB.__register_database(:local, fresh, [WipeDraft])
    assert_equal(true, Funicular::DB.restore_snapshot(:local))
    assert_equal([[0]], fresh.execute("SELECT COUNT(*) FROM wipe_drafts"))
    fresh.close
  end

  def test_wipe_notifies_each_table_once_queryable
    $wipe_seen = []
    local_sub = Funicular::DB.subscribe(:local, "wipe_drafts") do |_r, _t|
      # Queryable already: the handler runs strictly after the rebuild.
      count = $wipe_local_db.execute("SELECT COUNT(*) FROM wipe_drafts")
      $wipe_seen << [:local, count[0][0]]
    end
    replica_sub = Funicular::DB.subscribe(:replica, "wipe_notes") do |_r, _t|
      count = $wipe_replica_db.execute("SELECT COUNT(*) FROM wipe_notes")
      $wipe_seen << [:replica, count[0][0]]
    end
    Funicular::DB.wipe
    assert_equal([], $wipe_seen)
    pump(10)
    assert_equal(true, $wipe_seen.include?([:local, 0]))
    assert_equal(true, $wipe_seen.include?([:replica, 0]))
    Funicular::DB.unsubscribe(local_sub)
    Funicular::DB.unsubscribe(replica_sub)
  end

  def test_stale_rest_response_is_discarded
    $wipe_result = :untouched
    $wipe_error = nil
    WipeNote.all do |result, error|
      $wipe_result = result
      $wipe_error = error
    end
    Funicular::DB.wipe
    respond([{ "id" => 1, "body" => "resurrected?" }])
    assert_equal(nil, $wipe_result)
    assert_equal(Funicular::DB::Error, $wipe_error.class)
    # Nothing was applied: a logout can never resurrect the previous
    # session's rows.
    assert_equal([[0]],
                 $wipe_replica_db.execute("SELECT COUNT(*) FROM wipe_notes"))
  end

  def test_stale_error_wins_over_an_http_error
    # A request issued before the wipe that completes with an HTTP
    # error after it is STALE first: the callback must see the
    # discard, not the original error_message.
    $wipe_error = nil
    WipeNote.all do |_result, error|
      $wipe_error = error
    end
    Funicular::DB.wipe
    block = $wipe_pending.shift
    block.call(Funicular::HTTP::Response.new(500, nil))
    assert_equal(Funicular::DB::Error, $wipe_error.class)
  end

  def test_a_fresh_request_after_the_wipe_applies_normally
    Funicular::DB.wipe
    $wipe_result = nil
    WipeNote.all do |result, error|
      $wipe_result = result
    end
    respond([{ "id" => 2, "body" => "new session" }])
    assert_equal(1, $wipe_result.size)
    assert_equal([[1]],
                 $wipe_replica_db.execute("SELECT COUNT(*) FROM wipe_notes"))
  end

  def test_wipe_works_on_a_volatile_tab_without_a_store
    Funicular::DB.__set_durability(:volatile)
    Funicular::DB.__set_snapshot_store(nil)
    $wipe_local_db.execute(
      "INSERT INTO wipe_drafts (title) VALUES ('secret')")
    assert_equal(true, Funicular::DB.wipe)
    assert_equal([[0]],
                 $wipe_local_db.execute("SELECT COUNT(*) FROM wipe_drafts"))
  end
end
