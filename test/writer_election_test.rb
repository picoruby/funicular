# Tests for the writer election (docs decision 14) against a fake Web
# Locks API injected through the shim's __funicularLocksApi seam:
# granted -> persistent_writer (lock held), busy -> persistent_reader,
# API absent or failing -> volatile; release lets the next election win.

class WriterElectionTest < Picotest::Test
  FAKE_JS = <<~'FUNICULAR_LOCK_FAKE'
    globalThis.__lockFake = {
      mode: "grant",
      requests: [],
      releases: 0,
    };
    globalThis.__funicularLocksApi = {
      request(name, opts, cb) {
        const fake = globalThis.__lockFake;
        fake.requests.push([name, !!(opts && opts.ifAvailable)]);
        if (fake.mode === "throw") {
          throw new Error("locks broke");
        }
        if (fake.mode === "busy") {
          return Promise.resolve(cb(null));
        }
        const held = cb({ name: name });
        Promise.resolve(held).then(() => { fake.releases += 1; });
        return Promise.resolve(held);
      }
    };
  FUNICULAR_LOCK_FAKE

  def setup
    JS.global.eval(FAKE_JS)
  end

  def teardown
    Funicular::DB.release_writer_lock
    Funicular::DB.__set_durability(:unbooted)
    JS.global.eval(FAKE_JS)
  end

  def fake_state
    JSON.parse(JS.global.eval(
      "JSON.stringify(globalThis.__lockFake)").to_s)
  end

  def test_granted_lock_makes_the_persistent_writer
    assert_equal(:unbooted, Funicular::DB.durability)
    state = Funicular::DB.elect_writer("funicular:lock:test")
    assert_equal(:persistent_writer, state)
    assert_equal(:persistent_writer, Funicular::DB.durability)
    requests = fake_state["requests"]
    assert_equal([["funicular:lock:test", true]], requests)
  end

  def test_busy_lock_makes_a_persistent_reader
    JS.global.eval("globalThis.__lockFake.mode = 'busy'")
    assert_equal(:persistent_reader,
                 Funicular::DB.elect_writer("funicular:lock:test"))
  end

  def test_absent_api_means_volatile
    # Neither the injected API nor navigator.locks (absent under Node).
    JS.global.eval("globalThis.__funicularLocksApi = null")
    assert_equal(:volatile,
                 Funicular::DB.elect_writer("funicular:lock:test"))
  end

  def test_api_failure_means_volatile
    JS.global.eval("globalThis.__lockFake.mode = 'throw'")
    assert_equal(:volatile,
                 Funicular::DB.elect_writer("funicular:lock:test"))
  end

  def test_release_frees_the_lock_for_the_next_election
    Funicular::DB.elect_writer("funicular:lock:test")
    assert_equal(true, Funicular::DB.release_writer_lock)
    # Stepping down is one-way: from here on this tab must never gate a
    # persist on being the writer again.
    assert_equal(:persistent_reader, Funicular::DB.durability)
    # The holding promise resolves on a microtask; give it a tick.
    JS.global.eval("new Promise((r) => setTimeout(r, 10))").await
    assert_equal(1, fake_state["releases"])
    # A fresh election (new page in reality) wins again.
    Funicular::DB.__set_durability(:unbooted)
    assert_equal(:persistent_writer,
                 Funicular::DB.elect_writer("funicular:lock:test"))
  end

  def test_election_is_one_shot
    Funicular::DB.elect_writer("funicular:lock:test")
    assert_raise(Funicular::DB::Error) do
      Funicular::DB.elect_writer("funicular:lock:test")
    end
  end

  def test_election_in_flight_blocks_reentry
    # The awaiting Task suspends mid-election: a concurrent call must
    # hit the one-shot guard while the state is :electing.
    Funicular::DB.__set_durability(:electing)
    assert_raise(Funicular::DB::Error) do
      Funicular::DB.elect_writer("funicular:lock:test")
    end
  end

  def test_release_without_a_lock_is_a_noop
    assert_equal(false, Funicular::DB.release_writer_lock)
    JS.global.eval("globalThis.__lockFake.mode = 'busy'")
    Funicular::DB.elect_writer("funicular:lock:test")
    # Readers hold nothing to release.
    assert_equal(false, Funicular::DB.release_writer_lock)
  end
end
