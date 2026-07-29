# Tests for the session-epoch terminal latch (docs decision 13, client
# half) and http.rb's exactly-once settle -- against the REAL fetch,
# talking to a local node:http server whose X-Funicular-Epoch header
# the tests control. The latch's writer step-down is exercised through
# a real boot.

class EpochTest < Picotest::Test
  SERVER_JS = <<~'FUNICULAR_EPOCH_SERVER'
    (() => {
      if (globalThis.__epochSrvPort) {
        return Promise.resolve(globalThis.__epochSrvPort);
      }
      return import("node:http").then((http) => {
        globalThis.__epochHeader = "e1";
        globalThis.__epochSend = true;
        const srv = http.createServer((req, res) => {
          globalThis.__epochHits = (globalThis.__epochHits || 0) + 1;
          const headers = { "Content-Type": "application/json" };
          if (globalThis.__epochSend) {
            headers["X-Funicular-Epoch"] = globalThis.__epochHeader;
          }
          res.writeHead(200, headers);
          res.end(JSON.stringify({ "id": 1, "title": "from server" }));
        });
        srv.unref();
        return new Promise((resolve) => {
          srv.listen(0, "127.0.0.1", () => {
            globalThis.__epochSrvPort = srv.address().port;
            resolve(globalThis.__epochSrvPort);
          });
        });
      });
    })()
  FUNICULAR_EPOCH_SERVER

  LOCKS_JS = <<~'FUNICULAR_EPOCH_LOCKS'
    globalThis.__funicularLocksApi = {
      request(name, opts, cb) {
        const held = cb({ name: name });
        return Promise.resolve(held);
      }
    };
    globalThis.__funicularStorageApi = null;
  FUNICULAR_EPOCH_LOCKS

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

  # A store whose put suspends long enough for the epoch mismatch to
  # land mid-write; it records when the put completed and whether the
  # writer lock was still held at that moment.
  class SlowPutStore
    attr_reader :data, :put_count

    def initialize
      @data = {}
      @put_count = 0
    end

    def [](key)
      @data[key]
    end

    def []=(key, value)
      $epoch_order << :put_start
      EpochTest.pump(200)
      @put_count += 1
      @data[key] = value
      $epoch_lock_at_put = Funicular::DB.durability
      $epoch_order << :put_done
    end

    def delete(key)
      @data.delete(key)
      nil
    end
  end

  # A store whose GET suspends: the boot parks inside the local
  # restore long enough for a mismatch to land mid-boot.
  class SlowGetStore
    def initialize
      @data = {}
    end

    def [](key)
      EpochTest.pump(200)
      @data[key]
    end

    def []=(key, value)
      @data[key] = value
    end

    def delete(key)
      @data.delete(key)
      nil
    end
  end

  def setup
    JS.global.eval(LOCKS_JS)
    # The epoch check latches lazily off the page's DOM: no leftover
    # fake document (this suite's or another's) may leak an epoch in.
    JS.global.eval("delete globalThis.document;")
    $epoch_port = JS.global.eval(SERVER_JS).await.to_s.to_i
    JS.global.eval(
      "globalThis.__epochHeader = 'e1'; globalThis.__epochSend = true;" \
      " globalThis.__epochHits = 0")
    define_models
  end

  def teardown
    Funicular::DB.__reset_boot
    Funicular::DB.__reset_config
    JS.global.eval(LOCKS_JS)
    JS.global.eval("delete globalThis.document;")
  end

  def define_models
    return if Object.const_defined?(:EpochDraft)

    Object.const_set(:EpochDraft, Class.new(Funicular::Model))
    EpochDraft.class_eval do
      table_name "epoch_drafts"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
      end
    end
  end

  # Sliced awaits: the Node runner exits after ~100 fully idle
  # cycles (~100 ms), so no single timer await may sleep longer.
  # A class method so the store fakes can wait through it too.
  def self.pump(ms)
    elapsed = 0
    while elapsed < ms
      slice = ms - elapsed
      slice = 50 if 50 < slice
      JS.global.eval("new Promise((r) => setTimeout(r, #{slice}))").await
      elapsed += slice
    end
    nil
  end

  def pump(ms)
    EpochTest.pump(ms)
  end

  def server_url
    "http://127.0.0.1:#{$epoch_port}/thing"
  end

  def get_once(url)
    $epoch_calls = 0
    $epoch_response = nil
    Funicular::HTTP.get(url) do |response|
      $epoch_calls += 1
      $epoch_response = response
    end
    assert_equal(1, $epoch_calls)
    $epoch_response
  end

  def test_rejected_fetch_settles_exactly_once_with_an_error
    response = get_once("http://127.0.0.1:1/unreachable")
    assert_equal(0, response.status)
    assert_equal(true, !response.error_message.nil?)
  end

  def test_an_exception_in_the_callers_block_never_settles_twice
    $epoch_calls = 0
    raised = false
    begin
      Funicular::HTTP.get(server_url) do |_response|
        $epoch_calls += 1
        raise "boom"
      end
    rescue => e
      raised = e.message == "boom"
    end
    assert_equal(true, raised)
    assert_equal(1, $epoch_calls)
  end

  def test_no_page_epoch_means_checks_off
    # The server DOES send e1, but this page never received an epoch:
    # the response passes untouched.
    response = get_once(server_url)
    assert_equal(200, response.status)
    assert_equal("from server", response.data["title"])
    assert_equal(false, Funicular::DB.session_terminated?)
  end

  def test_matching_epoch_delivers
    Funicular::DB.__set_session_epoch("e1")
    response = get_once(server_url)
    assert_equal(200, response.status)
    assert_equal(false, Funicular::DB.session_terminated?)
  end

  def test_the_first_ever_response_is_checked_via_the_lazy_latch
    # Pre-boot, pre-barrier HTTP (an ephemeral model's REST call, a
    # direct HTTP.get at app init) is epoch-checked too: nothing has
    # latched the page's epoch yet, so the check itself must read it
    # off the page. The server belongs to a NEWER session (e1) -- the
    # very first response this page ever sees is discarded and the
    # page goes terminal.
    Funicular::DB.configure do
      config.on_session_change = -> {}
    end
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => ({ dataset: {" \
      "  funicularApplicationId: 'epoch_app'," \
      "  funicularAnonymousOnly: 'true'," \
      "  funicularEpoch: 'e-page' } }) }")
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
    assert_equal("e-page", Funicular::DB.session_epoch)
  end

  def test_the_lazy_latch_delivers_when_the_page_epoch_matches
    JS.global.eval(
      "globalThis.document = { querySelector: (s) => ({ dataset: {" \
      "  funicularApplicationId: 'epoch_app'," \
      "  funicularAnonymousOnly: 'true'," \
      "  funicularEpoch: 'e1' } }) }")
    response = get_once(server_url)
    assert_equal(200, response.status)
    assert_equal(false, Funicular::DB.session_terminated?)
    # The latch held on to what it read: later responses compare
    # against the same value without re-reading the DOM.
    assert_equal("e1", Funicular::DB.session_epoch)
  end

  def test_rotated_epoch_discards_and_terminates
    $epoch_changed = 0
    Funicular::DB.configure do
      config.on_session_change = -> { $epoch_changed += 1 }
    end
    Funicular::DB.__set_session_epoch("e0")
    response = get_once(server_url)
    # Discarded: the caller settles with an error, never the payload.
    assert_equal(0, response.status)
    assert_equal(true, response.error_message.include?("session"))
    assert_equal(true, Funicular::DB.session_terminated?)
    assert_equal(1, $epoch_changed)
    # A later request -- even one whose response would carry a
    # matching epoch -- is refused at issue time, and the hook does
    # not fire again.
    JS.global.eval("globalThis.__epochHeader = 'e0'")
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(1, $epoch_changed)
  end

  def test_terminal_page_never_issues_new_requests
    # Discarding responses is not enough: a request issued AFTER the
    # terminal verdict would already have executed under the NEW
    # session's cookies server-side -- an old screen's click could
    # mutate another user's data. It must never leave the page.
    Funicular::DB.configure do
      config.on_session_change = -> {}
    end
    Funicular::DB.__set_session_epoch("e0")
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
    hits = JS.global.eval("globalThis.__epochHits").to_s.to_i
    $epoch_calls = 0
    $epoch_response = nil
    Funicular::HTTP.post(server_url, { "title" => "late" }) do |r|
      $epoch_calls += 1
      $epoch_response = r
    end
    # Settled exactly once, synchronously, with the session error.
    assert_equal(1, $epoch_calls)
    assert_equal(0, $epoch_response.status)
    assert_equal(true,
                 $epoch_response.error_message.include?("session"))
    # And the server never saw it.
    pump(100)
    assert_equal(hits,
                 JS.global.eval("globalThis.__epochHits").to_s.to_i)
  end

  def test_missing_header_counts_as_a_mismatch
    Funicular::DB.configure do
      config.on_session_change = -> {}
    end
    Funicular::DB.__set_session_epoch("e1")
    JS.global.eval("globalThis.__epochSend = false")
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
  end

  def test_terminal_writer_steps_down_completely
    Funicular::DB.configure do
      config.on_session_change = -> {}
      # Wide enough that the timer cannot fire during the fetch
      # below; the terminal cancel is what must stop it.
      config.local_debounce_ms = 500
    end
    store = FakeStore.new
    Funicular::DB.__set_snapshot_store(store)
    assert_equal(true,
                 Funicular::DB.boot(
                   models: [EpochDraft],
                   metadata: { application_id: "epoch_app",
                               anonymous_only: true, epoch: "e0" }))
    assert_equal(:persistent_writer, Funicular::DB.durability)
    EpochDraft.local_create(title: "before")
    # The rotated response terminates the session.
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
    # Lock released (a new tab could win), one-way reader status.
    assert_equal(:persistent_reader, Funicular::DB.durability)
    # Both handles became a non-persistent read view.
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.local.execute(
        "INSERT INTO epoch_drafts (title) VALUES ('after')")
    end
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.replica.execute("CREATE TABLE nope (id INTEGER)")
    end
    assert_equal(1, Funicular::DB.local.execute(
                      "SELECT COUNT(*) FROM epoch_drafts")[0][0])
    # Model-level writes refuse, persistence is dead, flush raises.
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      EpochDraft.local_create(title: "nope")
    end
    assert_equal(false, Funicular::DB.persist_snapshot(:local))
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.flush
    end
    # The armed debounce from the pre-terminal write cannot fire a
    # snapshot either (its 500 ms deadline passes inside this wait).
    pump(600)
    assert_equal(0, store.put_count)
  end

  def test_terminal_waits_out_an_inflight_snapshot_before_releasing
    # A put already past persist_snapshot's checks when the epoch
    # mismatch lands keeps running inside the store. The step-down
    # must wait it out BEFORE releasing the writer lock: released
    # earlier, a fresh tab could boot as the writer while the old
    # session's image is still landing over its store.
    $epoch_order = []
    $epoch_lock_at_put = nil
    Funicular::DB.configure do
      config.on_session_change = -> { $epoch_order << :released }
    end
    store = SlowPutStore.new
    Funicular::DB.__set_snapshot_store(store)
    assert_equal(true,
                 Funicular::DB.boot(
                   models: [EpochDraft],
                   metadata: { application_id: "epoch_app",
                               anonymous_only: true, epoch: "e0" }))
    EpochDraft.local_create(title: "inflight")
    Task.new(name: "epoch_flusher") { Funicular::DB.flush }
    # Let the flush enter the store put and suspend inside it.
    pump(50)
    assert_equal([:put_start], $epoch_order)
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
    # The put completed while the lock was STILL held; the hook (and
    # the release before it) came strictly after.
    assert_equal([:put_start, :put_done, :released], $epoch_order)
    assert_equal(:persistent_writer, $epoch_lock_at_put)
    assert_equal(:persistent_reader, Funicular::DB.durability)
    # flush's second role never started: the terminal check refused it
    # at the persist entry.
    assert_equal(1, store.put_count)
  end

  def test_epoch_mismatch_during_the_election_aborts_the_boot
    # A mismatch landing while the boot awaits the writer election
    # finds no lock and no handles to tear down; the boot itself must
    # notice on resume and abort -- and the lock the election acquired
    # AFTER the termination must be released again, or a terminal page
    # would hold the writer slot with writable handles.
    $epoch_boot_errors = nil
    Funicular::DB.configure do
      config.on_session_change = -> {}
      config.on_boot_error = ->(errors) { $epoch_boot_errors = errors }
    end
    JS.global.eval(<<~'FUNICULAR_EPOCH_SLOW_LOCKS')
      globalThis.__funicularLocksApi = {
        request(name, opts, cb) {
          return new Promise((resolve) => {
            setTimeout(() => { resolve(cb({ name: name })); }, 200);
          });
        }
      };
    FUNICULAR_EPOCH_SLOW_LOCKS
    Funicular::DB.__set_snapshot_store(FakeStore.new)
    $epoch_boot_result = :pending
    Task.new(name: "epoch_booter") do
      $epoch_boot_result = Funicular::DB.boot(
        models: [EpochDraft],
        metadata: { application_id: "epoch_app",
                    anonymous_only: true, epoch: "e0" })
    end
    pump(50)
    assert_equal(:booting, Funicular::DB.boot_state)
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
    # Let the election grant and the boot notice the termination.
    pump(300)
    assert_equal(false, $epoch_boot_result)
    assert_equal(:failed, Funicular::DB.boot_state)
    # Releasing the late lock is what steps the durability down.
    assert_equal(:persistent_reader, Funicular::DB.durability)
    assert_equal(1, $epoch_boot_errors.size)
    assert_raise(Funicular::DB::UnavailableError) do
      Funicular::DB.local
    end
  end

  def test_epoch_mismatch_during_the_restore_aborts_the_boot
    # Here the boot already HOLDS the lock and suspends inside the
    # local-snapshot read: the mismatch releases the lock right away,
    # and the resuming boot must abort instead of installing writable
    # handles over the terminal page.
    Funicular::DB.configure do
      config.on_session_change = -> {}
      config.on_boot_error = ->(_errors) {}
    end
    Funicular::DB.__set_snapshot_store(SlowGetStore.new)
    $epoch_boot_result = :pending
    Task.new(name: "epoch_restore_booter") do
      $epoch_boot_result = Funicular::DB.boot(
        models: [EpochDraft],
        metadata: { application_id: "epoch_app",
                    anonymous_only: true, epoch: "e0" })
    end
    pump(50)
    assert_equal(:persistent_writer, Funicular::DB.durability)
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(:persistent_reader, Funicular::DB.durability)
    pump(400)
    assert_equal(false, $epoch_boot_result)
    assert_equal(:failed, Funicular::DB.boot_state)
    assert_raise(Funicular::DB::UnavailableError) do
      Funicular::DB.replica
    end
  end

  def test_terminal_volatile_page_refuses_the_raw_rebuild_paths
    # A terminated VOLATILE page never steps down to
    # :persistent_reader (there is no lock to release), so wipe's and
    # reset_local's durability checks alone would still let these raw
    # paths through -- the latch itself must refuse them.
    Funicular::DB.configure do
      config.on_session_change = -> {}
    end
    JS.global.eval("globalThis.__funicularLocksApi = null")
    Funicular::DB.__set_snapshot_store(FakeStore.new)
    assert_equal(true,
                 Funicular::DB.boot(
                   models: [EpochDraft],
                   metadata: { application_id: "epoch_app",
                               anonymous_only: true, epoch: "e0" }))
    assert_equal(:volatile, Funicular::DB.durability)
    response = get_once(server_url)
    assert_equal(0, response.status)
    assert_equal(true, Funicular::DB.session_terminated?)
    # Exactly the gap under test: the durability did NOT change.
    assert_equal(:volatile, Funicular::DB.durability)
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      Funicular::DB.wipe
    end
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      EpochDraft.reset_local
    end
  end
end
