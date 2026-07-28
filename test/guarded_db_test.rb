# Tests for the guarded database handles (docs decision 15): the closed
# allowlist, the execution-time read-only enforcement backed by
# Statement#readonly?, and the statements rejected in every state.

class GuardedDbTest < Picotest::Test
  def setup
    @raw = SQLite3::Database.new(":memory:")
    @raw.execute("CREATE TABLE gk (id INTEGER PRIMARY KEY, name TEXT)")
    @raw.execute("INSERT INTO gk (name) VALUES ('seed')")
    @writer = Funicular::DB::GuardedDatabase.new(@raw)
    @reader = Funicular::DB::GuardedDatabase.new(@raw, true)
  end

  def teardown
    @raw.close
  end

  # ---- the closed allowlist ----

  def test_escape_hatches_do_not_exist_in_any_state
    forbidden = [:persist, :close, :serialize, :deserialize, :backup,
                 :results_as_hash=]
    forbidden_size = forbidden.size
    i = 0
    while i < forbidden_size
      assert_equal(false, @writer.respond_to?(forbidden[i]))
      assert_equal(false, @reader.respond_to?(forbidden[i]))
      i += 1
    end
  end

  # ---- writable handle ----

  def test_writer_writes_and_reads
    @writer.execute("INSERT INTO gk (name) VALUES (?)", ["two"])
    assert_equal(2, @writer.get_first_value("SELECT COUNT(*) FROM gk"))
    assert_equal([1, "seed"], @writer.get_first_row(
      "SELECT id, name FROM gk WHERE id = ?", [1]))
    seen = []
    @writer.execute("SELECT name FROM gk ORDER BY id") do |row|
      seen << row[0]
    end
    assert_equal(["seed", "two"], seen)
  end

  def test_transaction_yields_the_proxy_and_preserves_exceptions
    caught = nil
    begin
      @writer.transaction do |t|
        assert_equal(true, t == @writer)
        t.execute("INSERT INTO gk (name) VALUES ('doomed')")
        raise ArgumentError, "boom"
      end
    rescue ArgumentError => e
      caught = e.message
    end
    assert_equal("boom", caught)
    assert_equal(1, @writer.get_first_value("SELECT COUNT(*) FROM gk"))
  end

  def test_transaction_mode_is_validated
    assert_raise(ArgumentError) { @writer.transaction(:evil) }
  end

  # ---- read-only enforcement ----

  def test_reader_reads_but_cannot_write
    assert_equal("seed",
      @reader.get_first_value("SELECT name FROM gk WHERE id = 1"))
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      @reader.execute("INSERT INTO gk (name) VALUES ('nope')")
    end
    assert_raise(Funicular::DB::ReadOnlyTabError) do
      @reader.execute("UPDATE gk SET name = 'nope'")
    end
    assert_equal(1, @raw.execute("SELECT COUNT(*) FROM gk")[0][0])
  end

  def test_prepared_write_is_refused_at_execution_time
    stmt = @reader.prepare("INSERT INTO gk (name) VALUES (?)")
    assert_raise(Funicular::DB::ReadOnlyTabError) { stmt.execute("x") }
    assert_raise(Funicular::DB::ReadOnlyTabError) { stmt.step }
    stmt.close
    assert_equal(1, @raw.execute("SELECT COUNT(*) FROM gk")[0][0])
  end

  def test_lockdown_catches_statements_prepared_while_writable
    stmt = @writer.prepare("INSERT INTO gk (name) VALUES (?)")
    @writer.__become_read_only
    assert_equal(true, @writer.read_only?)
    assert_raise(Funicular::DB::ReadOnlyTabError) { stmt.execute("x") }
    stmt.close
    # Reads keep working after the lockdown.
    assert_equal("seed",
      @writer.get_first_value("SELECT name FROM gk WHERE id = 1"))
  end

  # ---- statements rejected in every state ----

  def test_attach_detach_and_pragma_query_only_are_rejected
    assert_raise(ArgumentError) do
      @writer.execute("ATTACH DATABASE ':memory:' AS x")
    end
    assert_raise(ArgumentError) { @writer.execute("DETACH DATABASE x") }
    assert_raise(ArgumentError) { @writer.execute("PRAGMA query_only = ON") }
    assert_raise(ArgumentError) { @reader.execute("PRAGMA query_only = OFF") }
    assert_raise(ArgumentError) { @reader.execute("pragma QUERY_ONLY") }
  end

  def test_comment_prefixes_do_not_smuggle_forbidden_statements
    assert_raise(ArgumentError) do
      @writer.execute("  /* sneak */ attach database 'f' as y")
    end
    assert_raise(ArgumentError) do
      @writer.execute("-- c\nATTACH DATABASE 'f' AS z")
    end
  end

  def test_read_pragmas_stay_available
    rows = @reader.execute("PRAGMA table_info(gk)")
    assert_equal(2, rows.size)
  end

  def test_pragma_rejection_matches_the_pragma_name_only
    # Even a TABLE named query_only stays inspectable...
    @raw.execute("CREATE TABLE query_only (id INTEGER PRIMARY KEY)")
    assert_equal(1, @reader.execute("PRAGMA table_info(query_only)").size)
    assert_equal(1, @reader.execute("PRAGMA table_info('query_only')").size)
    assert_equal(2,
      @reader.execute("PRAGMA table_info(gk) /* query_only */").size)
    # ...while every spelling of the query_only PRAGMA itself is caught.
    assert_raise(ArgumentError) do
      @writer.execute("PRAGMA main.query_only = ON")
    end
    assert_raise(ArgumentError) do
      @writer.execute("PRAGMA \"query_only\" = ON")
    end
    assert_raise(ArgumentError) { @writer.execute("PRAGMA [query_only]") }
  end

  # ---- guarded result sets ----

  def test_query_yields_a_guarded_resultset_and_closes_it
    got = nil
    inside = nil
    @writer.query("SELECT name FROM gk ORDER BY id") do |rs|
      inside = rs.is_a?(Funicular::DB::GuardedResultSet)
      got = rs.next
    end
    assert_equal(true, inside)
    assert_equal(["seed"], got)
    rows = @reader.query("SELECT COUNT(*) FROM gk").to_a
    assert_equal([[1]], rows)
  end

  def test_resultset_next_rechecks_the_read_only_state
    # A write+RETURNING result set created while writable must refuse to
    # step once the handle went read-only -- stepping IS the write.
    rs = @writer.query("INSERT INTO gk (name) VALUES ('r') RETURNING \"id\"")
    @writer.__become_read_only
    assert_raise(Funicular::DB::ReadOnlyTabError) { rs.next }
    assert_raise(Funicular::DB::ReadOnlyTabError) { rs.reset }
    rs.close
    assert_equal(1, @raw.execute("SELECT COUNT(*) FROM gk")[0][0])
  end

  # ---- guarded statements ----

  def test_statement_surface_and_block_form
    stmt = @writer.prepare("SELECT name FROM gk ORDER BY id")
    assert_equal(true, stmt.readonly?)
    assert_equal([["seed"]], stmt.execute)
    assert_equal(false, stmt.closed?)
    stmt.close
    assert_equal(true, stmt.closed?)
    closed_inside = nil
    @writer.prepare("SELECT COUNT(*) FROM gk") do |s|
      closed_inside = s.closed?
    end
    assert_equal(false, closed_inside)
  end
end
