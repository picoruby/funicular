# Tests for the replica-table plumbing: schema-derived DDL, the
# canonical-JSON fingerprint, and the upsert/delete write-through entry
# points, against a real ":memory:" database. Boot wiring (which decides
# WHEN these run) is a later change; here the handle is passed in.

class ReplicaSchemaTest < Picotest::Test
  POST_SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "title" => { "type" => "string" },
      "done" => { "type" => "boolean" },
      "created_at" => { "type" => "datetime" },
      "avatar" => { "type" => "binary" },
    },
    "endpoints" => {},
  }

  NOTE_SCHEMA = {
    "attributes" => {
      "id" => { "type" => "string" },
      "body" => { "type" => "text" },
    },
    "endpoints" => {},
  }

  NO_ID_SCHEMA = {
    "attributes" => {
      "label" => { "type" => "string" },
    },
    "endpoints" => {},
  }

  def setup
    $rep_db = SQLite3::Database.new(":memory:")
    $rep_notified = 0
    define_models
  end

  def teardown
    $rep_db.close
  end

  def define_models
    return if Object.const_defined?(:RepPost)

    Object.const_set(:RepPost, Class.new(Funicular::Model))
    RepPost.class_eval do
      table_name "rep_posts"

      def self.local_table_changed
        $rep_notified += 1
      end
    end
    RepPost.load_schema(POST_SCHEMA)

    Object.const_set(:RepNote, Class.new(Funicular::Model))
    RepNote.class_eval do
      table_name "rep_notes"
    end
    RepNote.load_schema(NOTE_SCHEMA)

    Object.const_set(:RepNoId, Class.new(Funicular::Model))
    RepNoId.class_eval do
      table_name "rep_no_ids"
    end
    RepNoId.load_schema(NO_ID_SCHEMA)
  end

  def table_columns(table)
    # @type var names: Array[String]
    names = []
    rows = $rep_db.execute("PRAGMA table_info(\"#{table}\")")
    i = 0
    rows_size = rows.size
    while i < rows_size
      names << rows[i][1]
      i += 1
    end
    names
  end

  # ---- DDL derivation ----

  def test_ddl_follows_the_server_id_type_and_excludes_binary
    ddl = Funicular::DB.replica_table_ddl(RepPost)
    assert_equal(true, ddl.include?("\"id\" INTEGER PRIMARY KEY"))
    assert_equal(false, ddl.include?("avatar"))
    assert_equal(true,
      Funicular::DB.replica_table_ddl(RepNote).include?("\"id\" TEXT PRIMARY KEY"))
  end

  def test_schema_without_id_raises_pointing_at_ephemeral
    raised = false
    begin
      Funicular::DB.replica_table_ddl(RepNoId)
    rescue ArgumentError => e
      raised = true
      assert_equal(true, e.message.include?("ephemeral"))
    end
    assert_equal(true, raised)
  end

  # ---- fingerprint ----

  def test_first_build_creates_tables_and_stores_the_fingerprint
    assert_equal(true, Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote]))
    assert_equal(["id", "title", "done", "created_at"], table_columns("rep_posts"))
    assert_equal(["id", "body"], table_columns("rep_notes"))
  end

  def test_matching_fingerprint_keeps_data
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    $rep_db.execute("INSERT INTO rep_posts (id, title) VALUES (1, 'kept')")
    assert_equal(false, Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote]))
    assert_equal("kept", $rep_db.execute("SELECT title FROM rep_posts")[0][0])
  end

  def test_changed_schema_rebuilds_empty
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    $rep_db.execute("INSERT INTO rep_posts (id, title) VALUES (1, 'doomed')")
    grown = Class.new(Funicular::Model)
    grown.class_eval do
      table_name "rep_posts"
    end
    grown.load_schema({
      "attributes" => {
        "id" => { "type" => "integer" },
        "title" => { "type" => "string" },
        "done" => { "type" => "boolean" },
        "created_at" => { "type" => "datetime" },
        "rank" => { "type" => "integer" },
      },
      "endpoints" => {},
    })
    assert_equal(true, Funicular::DB.build_replica_tables($rep_db, [grown, RepNote]))
    assert_equal(["id", "title", "done", "created_at", "rank"],
                 table_columns("rep_posts"))
    assert_equal(0, $rep_db.execute("SELECT COUNT(*) FROM rep_posts")[0][0])
  end

  def test_removed_models_lose_their_tables_on_rebuild
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    $rep_db.execute("INSERT INTO rep_notes (id, body) VALUES ('u1', 'stale')")
    assert_equal(true, Funicular::DB.build_replica_tables($rep_db, [RepPost]))
    remaining = $rep_db.execute(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'rep_notes'")
    assert_equal([], remaining)
    assert_equal(0, $rep_db.execute("SELECT COUNT(*) FROM rep_posts")[0][0])
  end

  def test_duplicate_replica_table_names_fail_loud
    twin = Class.new(Funicular::Model)
    twin.class_eval do
      table_name "rep_posts"
    end
    twin.load_schema(NOTE_SCHEMA)
    assert_raise(ArgumentError) do
      Funicular::DB.build_replica_tables($rep_db, [RepPost, twin])
    end
    # Case-insensitively too: "Rep_Posts" IS "rep_posts" to SQLite.
    cased = Class.new(Funicular::Model)
    cased.class_eval do
      table_name "Rep_Posts"
    end
    cased.load_schema(NOTE_SCHEMA)
    assert_raise(ArgumentError) do
      Funicular::DB.build_replica_tables($rep_db, [RepPost, cased])
    end
  end

  def test_funicular_meta_is_protected
    meta_model = Class.new(Funicular::Model)
    meta_model.class_eval do
      table_name "Funicular_Meta"
    end
    meta_model.load_schema(NOTE_SCHEMA)
    assert_raise(ArgumentError) do
      Funicular::DB.build_replica_tables($rep_db, [meta_model])
    end
    # A stale fingerprint claiming funicular_meta must not drop it: the
    # per-table migration versions live there.
    Funicular::DB.store_meta($rep_db, "replica_fingerprint",
      JSON.generate(["v1", [["funicular_meta", [["id", "string"]]]]]))
    Funicular::DB.store_meta($rep_db, "table_version:mig_x", "3")
    assert_equal(true, Funicular::DB.build_replica_tables($rep_db, [RepPost]))
    assert_equal("3", Funicular::DB.read_meta($rep_db, "table_version:mig_x"))
  end

  def test_fingerprint_ignores_model_order
    assert_equal(Funicular::DB.canonical_replica_schema([RepPost, RepNote]),
                 Funicular::DB.canonical_replica_schema([RepNote, RepPost]))
  end

  # ---- upsert / delete ----

  def test_upsert_inserts_then_replaces_through_the_codec
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    Funicular::DB.replica_upsert($rep_db, RepPost,
      { "id" => 1, "title" => "a", "done" => true,
        "created_at" => "2024-01-02T09:00:00+09:00" })
    row = $rep_db.execute(
      "SELECT title, done, created_at FROM rep_posts WHERE id = 1")[0]
    assert_equal(["a", 1, "2024-01-02T00:00:00Z"], row)
    Funicular::DB.replica_upsert($rep_db, RepPost,
      { "id" => 1, "title" => "b", "done" => false })
    assert_equal(1, $rep_db.execute("SELECT COUNT(*) FROM rep_posts")[0][0])
    assert_equal("b", $rep_db.execute("SELECT title FROM rep_posts")[0][0])
    assert_equal(2, $rep_notified)
  end

  def test_upsert_stores_null_for_absent_keys
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    Funicular::DB.replica_upsert($rep_db, RepPost, { "id" => 5, "title" => "t" })
    assert_nil($rep_db.execute("SELECT done FROM rep_posts WHERE id = 5")[0][0])
  end

  def test_upsert_without_id_raises_and_does_not_notify
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    notified_before = $rep_notified
    assert_raise(ArgumentError) do
      Funicular::DB.replica_upsert($rep_db, RepPost, { "title" => "lost" })
    end
    assert_equal(notified_before, $rep_notified)
  end

  def test_delete_notifies_only_when_the_row_existed
    Funicular::DB.build_replica_tables($rep_db, [RepPost, RepNote])
    Funicular::DB.replica_upsert($rep_db, RepPost, { "id" => 1, "title" => "x" })
    notified_before = $rep_notified
    assert_equal(true, Funicular::DB.replica_delete($rep_db, RepPost, 1))
    assert_equal(notified_before + 1, $rep_notified)
    assert_equal(false, Funicular::DB.replica_delete($rep_db, RepPost, 1))
    assert_equal(notified_before + 1, $rep_notified)
  end
end
