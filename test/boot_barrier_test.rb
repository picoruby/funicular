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

  def test_read_page_metadata_contract
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => ({ dataset: {" \
      "  funicularApplicationId: 'meta_app'," \
      "  funicularUserKey: 'k1'," \
      "  funicularUserKeyConfigured: 'true'," \
      "  funicularEpoch: 'e9' } }) }")
    meta = Funicular::DB.read_page_metadata
    assert_equal("meta_app", meta[:application_id])
    assert_equal("k1", meta[:user_key])
    assert_equal(true, meta[:user_key_configured])
    assert_equal(false, meta[:anonymous_only])
    assert_equal("e9", meta[:epoch])
    # No include tag on the page: the replica-only anonymous default.
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => null }")
    assert_equal({}, Funicular::DB.read_page_metadata)
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
