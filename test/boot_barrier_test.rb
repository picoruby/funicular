# Tests for the schema boot barrier + start gate (docs decision 19,
# wiring half): every request settles exactly once (HTTP errors and
# unappliable schemas included), all-green boots the database and only
# then runs the completion block, any failure marks the boot failed
# and mounts nothing. Page metadata rides a fake document; HTTP
# responses are deferred so the barrier's async nature is real.

module Funicular
  module HTTP
    class << self
      def get(url, &block)
        # Recorded at ISSUE time: the epoch must already be latched
        # when the first schema request leaves.
        log = $bar_epoch_log
        log << Funicular::DB.session_epoch if log
        $bar_pending << [url, block]
      end
    end
  end
end

class BootBarrierTest < Picotest::Test
  FAKE_JS = <<~'FUNICULAR_BARRIER_FAKE'
    globalThis.__funicularLocksApi = {
      request(name, opts, cb) {
        const held = cb({ name: name });
        return Promise.resolve(held);
      }
    };
    globalThis.__funicularStorageApi = null;
    globalThis.document = {
      querySelector(sel) {
        return {
          dataset: {
            funicularLocalDatabase: "true",
            funicularApplicationId: "bar_app",
            funicularAnonymousOnly: "true",
            funicularEpoch: "epoch-7",
          }
        };
      },
      addEventListener(type, fn) {},
      visibilityState: "visible",
    };
  FUNICULAR_BARRIER_FAKE

  USER_SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "name" => { "type" => "string" },
    },
    "endpoints" => {},
  }

  def setup
    JS.global.eval(FAKE_JS)
    $bar_pending = []
    $bar_epoch_log = []
    define_models
  end

  def teardown
    Funicular::DB.__reset_boot
    Funicular::DB.__reset_config
    JS.global.eval(FAKE_JS)
  end

  def define_models
    return if Object.const_defined?(:BarUser)

    Object.const_set(:BarUser, Class.new(Funicular::Model))
    BarUser.class_eval do
      table_name "bar_users"
    end

    Object.const_set(:BarPost, Class.new(Funicular::Model))
    BarPost.class_eval do
      table_name "bar_posts"
    end

    Object.const_set(:BarDraft, Class.new(Funicular::Model))
    BarDraft.class_eval do
      table_name "bar_drafts"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
      end
    end
  end

  def respond(url, response)
    i = 0
    pending_size = $bar_pending.size
    while i < pending_size
      entry = $bar_pending[i]
      if entry[0] == url
        $bar_pending.delete_at(i)
        entry[1].call(response)
        return true
      end
      i += 1
    end
    false
  end

  def ok(data)
    Funicular::HTTP::Response.new(200, data)
  end

  def test_all_green_boots_then_runs_the_block_once
    $bar_done = 0
    Funicular.load_schemas({ BarUser => "bar_user",
                             BarPost => "bar_post" }) do
      $bar_done += 1
    end
    # The block waits for the WHOLE barrier and the boot.
    assert_equal(0, $bar_done)
    assert_equal(true, respond("/api/schema/bar_user", ok(USER_SCHEMA)))
    assert_equal(0, $bar_done)
    assert_equal(true, respond("/api/schema/bar_post", ok(USER_SCHEMA)))
    assert_equal(1, $bar_done)
    assert_equal(:ready, Funicular::DB.boot_state)
    # The page metadata reached the boot: epoch and namespace.
    assert_equal("epoch-7", Funicular::DB.session_epoch)
    # The declared set came from the model registry: the local table
    # exists too.
    assert_equal(0, BarDraft.count)
    assert_equal([[0]],
                 Funicular::DB.replica.execute(
                   "SELECT COUNT(*) FROM bar_users"))
  end

  def test_partial_failure_settles_aggregates_and_never_completes
    $bar_done = 0
    $bar_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $bar_errors = errors }
    end
    Funicular.load_schemas({ BarUser => "bar_user",
                             BarPost => "bar_post" }) do
      $bar_done += 1
    end
    respond("/api/schema/bar_user", ok(USER_SCHEMA))
    # The HTTP failure SETTLES its slot -- the barrier completes
    # instead of hanging -- but the round is a failure.
    respond("/api/schema/bar_post",
            Funicular::HTTP::Response.new(500, nil))
    assert_equal(0, $bar_done)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(1, $bar_errors.size)
    assert_equal(Funicular::DB::Error, $bar_errors[0].class)
    # Even with an empty error body the report stays precise: the
    # schema, the model, and the HTTP status are always named.
    message = $bar_errors[0].message
    assert_equal(true, message.include?("bar_post"))
    assert_equal(true, message.include?("BarPost"))
    assert_equal(true, message.include?("HTTP 500"))
    # start refuses to mount on top of the failure.
    assert_equal(false, Funicular.__boot_for_start)
  end

  def test_start_mounts_nothing_on_a_failed_boot
    # The whole point of the gate: after a failed boot, start returns
    # nil BEFORE any DOM work -- no container lookup, no listener, no
    # mount. The fake document here has no getElementById, so slipping
    # past the gate would raise instead of quietly passing.
    Funicular::DB.configure do
      config.on_boot_error = ->(_errors) {}
    end
    Funicular.load_schemas({ BarUser => "bar_user" }) { }
    respond("/api/schema/bar_user",
            Funicular::HTTP::Response.new(500, nil))
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(nil, Funicular.start(container: "bar_missing"))
  end

  def test_unappliable_schema_settles_as_a_failure
    $bar_done = 0
    $bar_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $bar_errors = errors }
    end
    Funicular.load_schemas({ BarUser => "bar_user",
                             BarPost => "bar_post" }) do
      $bar_done += 1
    end
    # The payload arrives but cannot be applied: it settles as a
    # failure instead of hanging the barrier.
    respond("/api/schema/bar_user", ok({}))
    respond("/api/schema/bar_post", ok(USER_SCHEMA))
    assert_equal(0, $bar_done)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(1, $bar_errors.size)
    # The wrapper names the culprit among several models.
    assert_equal(Funicular::DB::Error, $bar_errors[0].class)
    assert_equal(true, $bar_errors[0].message.include?("bar_user"))
    assert_equal(true, $bar_errors[0].message.include?("BarUser"))
  end

  def test_empty_barrier_with_a_schema_less_replica_model_fails
    # Decision 6: an empty schema set is valid ONLY when no replica
    # model is declared. BarUser is declared (registry) but its schema
    # never arrives -- the boot must fail loud, not run on a missing
    # table.
    $bar_done = 0
    $bar_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $bar_errors = errors }
    end
    BarUser.schema = nil
    BarUser.instance_variable_set(:@local_columns, nil)
    Funicular.load_schemas({}) do
      $bar_done += 1
    end
    assert_equal(0, $bar_done)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_equal(1, $bar_errors.size)
  end

  def test_boot_for_start_boots_local_only_apps
    # No load_schemas round: start's gate boots directly from the
    # registry and the page metadata.
    BarUser.load_schema(USER_SCHEMA)
    BarPost.load_schema(USER_SCHEMA)
    assert_equal(true, Funicular.__boot_for_start)
    assert_equal(:ready, Funicular::DB.boot_state)
    # Already booted: the gate is a cheap true, not a second boot.
    assert_equal(true, Funicular.__boot_for_start)
  end

  def test_disabled_start_bypasses_the_database_for_rest_only_models
    registered = Funicular::Model.instance_variable_get(:@registered_models)
    JS.global.eval(
      "globalThis.__disabledLockCalls = 0; " \
      "globalThis.__funicularLocksApi = { request: () => { " \
      "globalThis.__disabledLockCalls += 1; throw new Error('lock used') } }; " \
      "globalThis.document = { querySelector: (s) => null }")
    Funicular::Model.instance_variable_set(:@registered_models,
                                           [BarUser, BarPost])
    begin
      assert_equal(true, Funicular.__boot_for_start)
      assert_equal(:unbooted, Funicular::DB.boot_state)
      assert_equal(:unbooted, Funicular::DB.durability)
      assert_equal(0, JS.global[:__disabledLockCalls].to_i)
    ensure
      Funicular::Model.instance_variable_set(:@registered_models, registered)
    end
  end

  def test_disabled_start_rejects_an_explicit_local_model
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => null }")
    assert_raise(Funicular::DB::ConfigError) do
      Funicular.start(container: "must_not_be_looked_up") { }
    end
    assert_equal(:unbooted, Funicular::DB.boot_state)
  end

  def test_disabled_runtime_local_apis_fail_as_unavailable
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => null }")
    operations = [
      -> { BarDraft.count },
      -> { BarDraft.on_change { } },
      -> { BarDraft.reset_local },
      -> { Funicular::DB.local },
      -> { Funicular::DB.replica },
      -> { Funicular::DB.flush },
      -> { Funicular::DB.wipe },
    ]
    i = 0
    operations_size = operations.size
    while i < operations_size
      assert_raise(Funicular::DB::UnavailableError) do
        operations[i].call
      end
      i += 1
    end
    error = nil
    begin
      Funicular::DB.local
    rescue => e
      error = e
    end
    assert_equal(true, error.message.include?("local database is disabled"))
    assert_equal(true, error.message.include?("config.local_database = true"))
    # Hook configuration and state inspection remain available.
    Funicular::DB.configure do
      config.on_boot_error = ->(_errors) { }
    end
    assert_equal(:unbooted, Funicular::DB.boot_state)
    assert_equal(:unbooted, Funicular::DB.durability)
  end

  def test_disabled_schema_barrier_loads_rest_schema_without_booting
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => null }")
    $bar_done = 0
    Funicular.load_schemas({ BarUser => "bar_user" }) do
      $bar_done += 1
    end
    respond("/api/schema/bar_user", ok(USER_SCHEMA))
    assert_equal(1, $bar_done)
    assert_equal(:unbooted, Funicular::DB.boot_state)
    assert_equal(:unbooted, Funicular::DB.durability)
  end

  def test_disabled_schema_failure_reports_without_failing_db_state
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => null }")
    $bar_done = 0
    $bar_errors = nil
    Funicular::DB.configure do
      config.on_boot_error = ->(errors) { $bar_errors = errors }
    end
    Funicular.load_schemas({ BarUser => "bar_user" }) do
      $bar_done += 1
    end
    respond("/api/schema/bar_user", Funicular::HTTP::Response.new(500, nil))
    assert_equal(0, $bar_done)
    assert_equal(1, $bar_errors.size)
    assert_equal(:unbooted, Funicular::DB.boot_state)
    assert_equal(:unbooted, Funicular::DB.durability)
  end

  def test_page_epoch_is_latched_before_schema_requests
    # A session rotated DURING schema loading must not slip past the
    # check just because DB.boot (the usual latch point) has not run
    # yet: the barrier arms the page's epoch first.
    Funicular.load_schemas({ BarUser => "bar_user" }) { }
    assert_equal(["epoch-7"], $bar_epoch_log)
    # A page WITHOUT an epoch latches nothing -- the checks stay off,
    # which is distinct from "merely not booted yet".
    Funicular::DB.__reset_boot
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => ({ dataset: {" \
      "  funicularApplicationId: 'bar_app'," \
      "  funicularAnonymousOnly: 'true' } }) }")
    Funicular.load_schemas({ BarUser => "bar_user" }) { }
    assert_equal(["epoch-7", nil], $bar_epoch_log)
  end

  def test_read_page_metadata_contract
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => ({ dataset: {" \
      "  funicularApplicationId: 'meta_app'," \
      "  funicularUserKey: 'k1'," \
      "  funicularUserKeyConfigured: 'true'," \
      "  funicularEpoch: 'e9' } }) }")
    meta = Funicular::DB.read_page_metadata
    assert_equal(true, meta[:local_database])
    assert_equal("meta_app", meta[:application_id])
    assert_equal("k1", meta[:user_key])
    assert_equal(true, meta[:user_key_configured])
    assert_equal(false, meta[:anonymous_only])
    assert_equal("e9", meta[:epoch])
    # No opt-in tag on the page means that the subsystem is disabled.
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => null }")
    assert_equal({}, Funicular::DB.read_page_metadata)
  end

  def test_opt_in_flag_is_latched_from_the_page_once
    JS.global.eval(
      "globalThis.__metaReads = 0; globalThis.__metaEnabled = false; " \
      "globalThis.document = { querySelector: (s) => { " \
      "globalThis.__metaReads += 1; return globalThis.__metaEnabled ? " \
      "{ dataset: { funicularLocalDatabase: 'true' } } : null } }")
    assert_equal(false, Funicular::DB.local_database_enabled?)
    JS.global.eval("globalThis.__metaEnabled = true")
    assert_equal(false, Funicular::DB.local_database_enabled?)
    assert_equal(1, JS.global[:__metaReads].to_i)
  end

  def test_every_model_subclass_registers_itself
    klass = Class.new(Funicular::Model)
    # Ephemeral so the leftover registration never disturbs the boots
    # of the other tests in this VM.
    klass.class_eval do
      storage :ephemeral
    end
    assert_equal(true,
                 Funicular::Model.__registered_models.include?(klass))
  end
end
