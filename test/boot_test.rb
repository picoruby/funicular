# Tests for DB.boot (docs decision 19): the wiring of namespace,
# election, snapshot store, restore, migrations, replica DDL, and the
# guarded handles -- plus the SchemaTooNew whole-DB lockdown (docs
# decision 7) and Model.reset_local. The Web Locks fake rides the
# shim's injection seam; the snapshot store is injected before boot
# (no store injected = the real IndexedDB open fails under Node =
# the volatile path).

class BootTest < Picotest::Test
  FAKE_JS = <<~'FUNICULAR_BOOT_FAKE'
    globalThis.__lockFake = { mode: "grant" };
    globalThis.__funicularLocksApi = {
      request(name, opts, cb) {
        if (globalThis.__lockFake.mode === "busy") {
          return Promise.resolve(cb(null));
        }
        const held = cb({ name: name });
        return Promise.resolve(held);
      }
    };
    globalThis.__funicularStorageApi = null;
  FUNICULAR_BOOT_FAKE

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

  class SlowGetStore < FakeStore
    def [](key)
      # Suspend the booting Task inside the restore GET.
      JS.global.eval("new Promise((r) => setTimeout(r, 30))").await
      @data[key]
    end
  end

  class GetBrokenStore < FakeStore
    def [](key)
      raise "corrupt snapshot"
    end
  end

  NOTE_SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "body" => { "type" => "string" },
    },
    "endpoints" => {},
  }

  META = {
    local_database: true,
    application_id: "boot_app",
    anonymous_only: true,
  }

  def setup
    JS.global.eval(FAKE_JS)
    $boot_store = FakeStore.new
    define_models
  end

  def teardown
    Funicular::DB.__reset_boot
    Funicular::DB.__set_boot_state(:unbooted)
    Funicular::DB.__reset_config
    JS.global.eval(FAKE_JS)
  end

  def define_models
    return if Object.const_defined?(:BootDraft)

    Object.const_set(:BootDraft, Class.new(Funicular::Model))
    BootDraft.class_eval do
      table_name "boot_drafts"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
      end
    end

    Object.const_set(:BootNote, Class.new(Funicular::Model))
    BootNote.class_eval do
      table_name "boot_notes"
    end
    BootNote.load_schema(NOTE_SCHEMA)

    # Never passed to boot: its rebuild fails on the raw execute, which
    # is exactly what the failed-reset test needs.
    Object.const_set(:BootBrokenDraft, Class.new(Funicular::Model))
    BootBrokenDraft.class_eval do
      table_name "boot_broken"
      storage :local do
        migrate 1 do |t|
          t.string :x
          t.execute "THIS IS NOT SQL"
        end
      end
    end
  end

  def pump(ms)
    JS.global.eval("new Promise((r) => setTimeout(r, #{ms}))").await
  end

  def boot(models = [BootDraft, BootNote], metadata = META)
    Funicular::DB.__set_snapshot_store($boot_store)
    Funicular::DB.boot(models: models, metadata: metadata)
  end

  def test_boot_wires_a_writer_tab
    result = boot([BootDraft, BootNote],
                  { local_database: true, application_id: "boot_app",
                    anonymous_only: true,
                    epoch: "e1" })
    assert_equal(true, result)
    assert_equal(:ready, Funicular::DB.boot_state)
    assert_equal(:persistent_writer, Funicular::DB.durability)
    assert_equal("e1", Funicular::DB.session_epoch)
    # The local table exists and model-level CRUD runs through the
    # guarded funnel.
    draft = BootDraft.local_create(title: "hello")
    assert_equal(false, draft.new_record?)
    assert_equal(1, BootDraft.count)
    # The replica table came from the schema-derived DDL.
    assert_equal([[0]],
                 Funicular::DB.replica.execute(
                   "SELECT COUNT(*) FROM boot_notes"))
    # The raw escape hatches hand out guarded proxies.
    assert_equal(Funicular::DB::GuardedDatabase,
                 Funicular::DB.local.class)
    assert_equal(BootNote.replica_db.class,
                 Funicular::DB.replica.class)
  end

  def test_boot_restores_previous_snapshots
    boot
    BootDraft.local_create(title: "persisted")
    assert_equal(true, Funicular::DB.flush)
    store = $boot_store
    Funicular::DB.__reset_boot
    Funicular::DB.__set_boot_state(:unbooted)
    Funicular::DB.__set_snapshot_store(store)
    assert_equal(true,
                 Funicular::DB.boot(models: [BootDraft, BootNote],
                                    metadata: META))
    assert_equal(1, BootDraft.count)
    assert_equal("persisted", BootDraft.first.title)
  end

  def test_boot_is_one_shot
    boot
    assert_raise(Funicular::DB::Error) do
      Funicular::DB.boot(models: [BootDraft], metadata: META)
    end
  end

  def test_boot_refuses_on_ssr
    Funicular.server = true
    begin
      assert_raise(Funicular::DB::UnavailableError) do
        Funicular::DB.boot(models: [], metadata: {})
      end
    ensure
      Funicular.server = false
    end
    assert_equal(:unbooted, Funicular::DB.boot_state)
  end

  def test_direct_boot_requires_the_opt_in_flag
    assert_raise(Funicular::DB::ConfigError) do
      Funicular::DB.boot(models: [BootDraft],
                         metadata: { application_id: "boot_app",
                                     anonymous_only: true })
    end
    assert_equal(:unbooted, Funicular::DB.boot_state)
    assert_equal(:unbooted, Funicular::DB.durability)
  end

  def test_enabled_boot_requires_application_identity_metadata
    $boot_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $boot_errors = errors }
    end
    result = boot([BootDraft],
                  { local_database: true, anonymous_only: true })
    assert_equal(false, result)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(Funicular::DB::ConfigError, $boot_errors[0].class)
  end

  def test_ssr_runtime_guards_do_not_read_browser_metadata
    JS.global.eval(
      "Object.defineProperty(globalThis, 'document', { configurable: true, " \
      "get: () => { throw new Error('document was read') } })")
    Funicular.server = true
    begin
      assert_raise(Funicular::DB::UnavailableError) do
        Funicular::DB.local
      end
      assert_raise(Funicular::DB::UnavailableError) do
        BootDraft.count
      end
    ensure
      Funicular.server = false
      JS.global.eval("delete globalThis.document")
    end
  end

  def test_reader_boot_locks_local_writes_only
    JS.global.eval("globalThis.__lockFake.mode = 'busy'")
    assert_equal(true, boot)
    assert_equal(:persistent_reader, Funicular::DB.durability)
    # Local writes refuse at the guarded layer...
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      BootDraft.local_create(title: "nope")
    end
    # ...reads work, and the replica stays memory-writable for
    # fetch-through revalidation.
    assert_equal(0, BootDraft.count)
    Funicular::DB.replica.execute(
      "INSERT INTO boot_notes (id, body) VALUES (1, 'ok')")
    assert_equal([[1]],
                 Funicular::DB.replica.execute(
                   "SELECT COUNT(*) FROM boot_notes"))
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.flush
    end
  end

  def test_volatile_boot_without_storage
    # No injected store: the real IndexedDB.open (fallback: false)
    # fails under Node -- by-design absence, the volatile state.
    $boot_volatile_errors = []
    Funicular::DB.configure do
      config.on_persist_error = ->(e) { $boot_volatile_errors << e }
    end
    result = Funicular::DB.boot(models: [BootDraft, BootNote],
                                metadata: META)
    assert_equal(true, result)
    assert_equal(:ready, Funicular::DB.boot_state)
    assert_equal(:volatile, Funicular::DB.durability)
    assert_equal(1, $boot_volatile_errors.size)
    # Everything works, nothing persists.
    BootDraft.local_create(title: "memory only")
    assert_equal(1, BootDraft.count)
    assert_equal(false, Funicular::DB.flush)
    assert_equal(nil, Funicular::DB.snapshot_store)
  end

  class BootOpenError < StandardError; end

  # Swaps the real IndexedDB::KVS.open for a stub raising a
  # NON-availability error: exactly what quota or an unknown
  # DOMException at open looks like.
  def self.break_kvs_open
    kvs = IndexedDB::KVS
    kvs.singleton_class.alias_method(:__funicular_test_open, :open)
    kvs.define_singleton_method(:open) do |_name, fallback: true|
      raise BootTest::BootOpenError, "quota exceeded during open"
    end
  end

  def self.restore_kvs_open
    IndexedDB::KVS.singleton_class.alias_method(:open,
                                                :__funicular_test_open)
  end

  def test_a_non_availability_open_error_fails_the_boot
    # Availability errors mean "no storage BY DESIGN" and go volatile
    # (the test above); ANY other failure at the store open fails the
    # boot per docs decision 16 -- and the writer lock, already won by
    # then, is released so the next tab is not condemned to reader.
    $boot_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $boot_errors = errors }
    end
    BootTest.break_kvs_open
    begin
      # No injected store: the boot must reach the real open path.
      result = Funicular::DB.boot(models: [BootDraft, BootNote],
                                  metadata: META)
    ensure
      BootTest.restore_kvs_open
    end
    assert_equal(false, result)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(1, $boot_errors.size)
    assert_equal(BootOpenError, $boot_errors[0].class)
    # Release is what steps the durability down from the won election.
    assert_equal(:persistent_reader, Funicular::DB.durability)
    assert_raise(Funicular::DB::UnavailableError) do
      Funicular::DB.local
    end
  end

  def test_boot_fails_loud_on_config_errors
    $boot_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $boot_errors = errors }
    end
    # Durable storage is enabled but neither user_key nor anonymous_only
    # is configured.
    result = boot([BootDraft, BootNote],
                  { local_database: true, application_id: "boot_app" })
    assert_equal(false, result)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(1, $boot_errors.size)
    assert_equal(Funicular::DB::ConfigError, $boot_errors[0].class)
  end

  def test_corrupt_snapshot_recovery_wipes_from_the_boot_hook
    # Decision 16's official recovery: a snapshot GET failure fails
    # the boot, and on_boot_error may call DB.wipe to discard the
    # corrupt snapshot before reloading -- so wipe must stay allowed
    # from the :failed state.
    broken = GetBrokenStore.new
    key = Funicular::DB.snapshot_key(
      Funicular::DB.namespace_identity("boot_app", nil, true), :local)
    broken.data[key] = "corrupt"
    $boot_wipe_ran = false
    Funicular::DB.configure do
      config.on_boot_error = ->(_errors) {
        Funicular::DB.wipe
        $boot_wipe_ran = true
      }
    end
    Funicular::DB.__set_snapshot_store(broken)
    result = Funicular::DB.boot(models: [BootDraft, BootNote],
                                metadata: META)
    assert_equal(false, result)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(true, $boot_wipe_ran)
    assert_equal(false, broken.data.has_key?(key))
    # After the hook the writer slot is released (the shim holds
    # nothing), so a NEW tab can win the next election.
    held = JS.global.eval(
      "Object.keys(globalThis.__funicularLocks.holds).length").to_s
    assert_equal("0", held)
    assert_equal(:persistent_reader, Funicular::DB.durability)
    Funicular::DB.__set_durability(:unbooted)
    assert_equal(:persistent_writer,
                 Funicular::DB.elect_writer("funicular:lock:recovered"))
  end

  def test_schema_too_new_locks_down_and_reset_local_recovers
    boot([BootDraft], META)
    raw = Funicular::DB.__registered_database(:local)
    # Simulate a deploy rollback: the stored version outruns the code.
    Funicular::DB.store_table_version(raw, "boot_drafts", 99)
    assert_equal(true, Funicular::DB.flush)
    store = $boot_store
    Funicular::DB.__reset_boot
    Funicular::DB.__set_boot_state(:unbooted)
    Funicular::DB.__set_snapshot_store(store)
    # The boot COMPLETES -- locked down, not failed.
    assert_equal(true,
                 Funicular::DB.boot(models: [BootDraft], metadata: META))
    assert_equal(:ready, Funicular::DB.boot_state)
    # Model-level operations raise...
    assert_raise(Funicular::DB::SchemaTooNewError) do
      BootDraft.count
    end
    # ...while the raw SELECT export path survives...
    assert_equal([[0]],
                 Funicular::DB.local.execute(
                   "SELECT COUNT(*) FROM boot_drafts"))
    # ...and SQLite itself refuses raw writes (query_only).
    write_refused = false
    begin
      Funicular::DB.local.execute(
        "INSERT INTO boot_drafts (title) VALUES ('nope')")
    rescue => e
      write_refused = true
    end
    assert_equal(true, write_refused)
    # reset_local rebuilds from the baseline and lifts the lockdown.
    assert_equal(true, BootDraft.reset_local)
    assert_equal(nil, Funicular::DB.schema_lockdown)
    BootDraft.local_create(title: "recovered")
    assert_equal(1, BootDraft.count)
  end

  def test_reset_local_guards
    JS.global.eval("globalThis.__lockFake.mode = 'busy'")
    boot
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      BootDraft.reset_local
    end
    assert_raise(Funicular::DB::NoTableError) do
      BootNote.reset_local
    end
  end

  def test_handles_stay_hidden_off_the_ready_state
    boot
    assert_equal(0, BootDraft.count)
    # Mid-boot (:booting) and after a failure (:failed) the handles
    # exist internally but must be equally out of reach.
    Funicular::DB.__set_boot_state(:booting)
    assert_raise(Funicular::DB::UnavailableError) do
      Funicular::DB.local
    end
    assert_equal(nil, BootNote.replica_db)
    assert_raise(Funicular::DB::UnavailableError) do
      BootDraft.count
    end
    Funicular::DB.__set_boot_state(:failed)
    assert_raise(Funicular::DB::UnavailableError) do
      Funicular::DB.replica
    end
    Funicular::DB.__set_boot_state(:ready)
    assert_equal(0, BootDraft.count)
  end

  def test_boot_suspended_mid_await_exposes_nothing
    # navigator.storage.persist() stays pending for a while: the boot
    # Task suspends AFTER installing the handles, and another Task
    # (this one) must still see an unbooted database.
    JS.global.eval(
      "globalThis.__funicularStorageApi = { persist: () => " \
      "new Promise((r) => setTimeout(() => r(true), 30)) }")
    Funicular::DB.__set_snapshot_store($boot_store)
    $boot_async_result = nil
    Task.new(name: "boot-test") do
      $boot_async_result = Funicular::DB.boot(
        models: [BootDraft, BootNote], metadata: META)
    end
    pump(10)
    assert_equal(:booting, Funicular::DB.boot_state)
    assert_raise(Funicular::DB::UnavailableError) do
      Funicular::DB.local
    end
    assert_equal(nil, BootNote.replica_db)
    # The raw-DB paths (they bypass the handles) refuse too.
    assert_raise(Funicular::DB::UnavailableError) do
      BootDraft.reset_local
    end
    assert_raise(Funicular::DB::Error) do
      Funicular::DB.wipe
    end
    pump(60)
    assert_equal(true, $boot_async_result)
    assert_equal(:ready, Funicular::DB.boot_state)
    assert_equal(0, BootDraft.count)
  end

  def test_flush_mid_boot_cannot_overwrite_snapshots
    # While the boot Task hangs in the local restore GET, the election
    # is already won and the raw databases are registered -- but they
    # are UNRESTORED. Persisting now would overwrite the stored
    # snapshots with empty images, so the final persistence entry
    # refuses during :booting.
    store = SlowGetStore.new
    Funicular::DB.__set_snapshot_store(store)
    $boot_flush_result = nil
    Task.new(name: "boot-flush-test") do
      $boot_flush_result = Funicular::DB.boot(
        models: [BootDraft, BootNote], metadata: META)
    end
    pump(10)
    assert_equal(:booting, Funicular::DB.boot_state)
    assert_equal(:persistent_writer, Funicular::DB.durability)
    assert_equal(false, Funicular::DB.flush)
    assert_equal(false, Funicular::DB.persist_snapshot(:local))
    assert_equal(0, store.put_count)
    pump(100)
    assert_equal(true, $boot_flush_result)
    assert_equal(:ready, Funicular::DB.boot_state)
  end

  def test_failed_reset_restores_the_sqlite_write_refusal
    # Reach the locked-down state first (a stored version outruns the
    # code), exactly like the recovery test above.
    boot([BootDraft], META)
    raw = Funicular::DB.__registered_database(:local)
    Funicular::DB.store_table_version(raw, "boot_drafts", 99)
    assert_equal(true, Funicular::DB.flush)
    store = $boot_store
    Funicular::DB.__reset_boot
    Funicular::DB.__set_snapshot_store(store)
    Funicular::DB.boot(models: [BootDraft], metadata: META)
    assert_equal(false, Funicular::DB.schema_lockdown.nil?)
    # This reset lifts query_only, then fails mid-rebuild: the lift
    # was provisional and SQLite's own refusal must stand back up.
    reset_failed = false
    begin
      BootBrokenDraft.reset_local
    rescue => e
      reset_failed = true
    end
    assert_equal(true, reset_failed)
    assert_equal(false, Funicular::DB.schema_lockdown.nil?)
    write_refused = false
    begin
      Funicular::DB.local.execute(
        "INSERT INTO boot_drafts (title) VALUES ('nope')")
    rescue => e
      write_refused = true
    end
    assert_equal(true, write_refused)
  end

end
