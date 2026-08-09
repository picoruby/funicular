# Tests for the REST wiring of decisions 5/6: responses decode through
# the shared codec, and successful REST calls mirror rows into the
# replica through the single apply entry point BEFORE user callbacks
# run. HTTP is stubbed at the module level (each Picotest file runs in
# its own VM); the replica handle is injected by overriding
# Model.replica_db, the same seam DB.boot will use.

module Funicular
  module HTTP
    class << self
      def get(url, &block)
        $wt_calls << ["GET", url]
        block.call($wt_response) if block
      end

      def post(url, body = nil, &block)
        $wt_calls << ["POST", url]
        block.call($wt_response) if block
      end

      def patch(url, body = nil, &block)
        $wt_calls << ["PATCH", url]
        block.call($wt_response) if block
      end

      def delete(url, &block)
        $wt_calls << ["DELETE", url]
        block.call($wt_response) if block
      end
    end
  end
end

class RestWriteThroughTest < Picotest::Test
  SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "title" => { "type" => "string" },
      "done" => { "type" => "boolean" },
      "created_at" => { "type" => "datetime" },
    },
    "endpoints" => {
      "all" => { "path" => "/wt_posts" },
      "find" => { "path" => "/wt_posts/:id" },
      "create" => { "path" => "/wt_posts" },
      "update" => { "path" => "/wt_posts/:id" },
      "destroy" => { "path" => "/wt_posts/:id" },
    },
  }

  def setup
    $wt_db = SQLite3::Database.new(":memory:")
    $wt_calls = []
    $wt_response = nil
    $wt_notified = 0
    define_models
    Funicular::DB.build_replica_tables($wt_db, [WtPost])
  end

  def teardown
    $wt_db.close
  end

  def define_models
    return if Object.const_defined?(:WtPost)

    Object.const_set(:WtPost, Class.new(Funicular::Model))
    WtPost.class_eval do
      table_name "wt_posts"

      def self.replica_db
        $wt_db
      end

      def self.local_table_changed
        $wt_notified += 1
      end
    end
    WtPost.load_schema(SCHEMA)

    Object.const_set(:WtSession, Class.new(Funicular::Model))
    WtSession.class_eval do
      storage :ephemeral
    end
    WtSession.load_schema(SCHEMA)

    # No replica_db override: the default nil keeps write-through inert.
    Object.const_set(:WtBare, Class.new(Funicular::Model))
    WtBare.class_eval do
      table_name "wt_bare_posts"
    end
    WtBare.load_schema(SCHEMA)
  end

  def ok(data)
    Funicular::HTTP::Response.new(200, data)
  end

  # ---- codec on REST init ----

  def test_initialize_decodes_rest_types
    post = WtPost.new({ "done" => 1, "created_at" => "2024-01-01T00:00:00Z" })
    assert_equal(true, post.done)
    assert_equal(true, post.created_at.is_a?(Time))
    passthrough = WtPost.new({ "done" => false, "title" => "t" })
    assert_equal(false, passthrough.done)
    assert_equal("t", passthrough.title)
  end

  # ---- write-through ----

  def test_all_upserts_rows_before_the_callback_and_decodes
    $wt_response = ok([
      { "id" => 1, "title" => "a", "done" => true,
        "created_at" => "2024-01-02T09:00:00+09:00" },
      { "id" => 2, "title" => "b", "done" => false,
        "created_at" => "2024-01-03T00:00:00Z" },
    ])
    rows_inside = nil
    got = nil
    WtPost.all do |instances, error|
      rows_inside = $wt_db.execute("SELECT COUNT(*) FROM wt_posts")[0][0]
      got = instances
    end
    assert_equal(2, rows_inside)
    assert_equal(true, got[0].done)
    assert_equal(true, got[0].created_at.is_a?(Time))
    row = $wt_db.execute(
      "SELECT done, created_at FROM wt_posts WHERE id = 1")[0]
    assert_equal([1, "2024-01-02T00:00:00Z"], row)
  end

  def test_all_applies_the_whole_collection_or_nothing
    $wt_response = ok([
      { "id" => 1, "title" => "good" },
      { "id" => 2, "title" => "bad", "created_at" => "not-a-date" },
    ])
    called = false
    raised = false
    begin
      WtPost.all { |instances, e| called = true }
    rescue ArgumentError
      raised = true
    end
    assert_equal(true, raised)
    assert_equal(false, called)
    # The first row rolled back with the second: no partial apply.
    assert_equal(0, $wt_db.execute("SELECT COUNT(*) FROM wt_posts")[0][0])
    assert_equal(0, $wt_notified)
  end

  def test_all_fires_one_change_event_per_batch
    $wt_response = ok([
      { "id" => 1, "title" => "a" },
      { "id" => 2, "title" => "b" },
      { "id" => 3, "title" => "c" },
    ])
    WtPost.all { |instances, e| }
    assert_equal(1, $wt_notified)
  end

  def test_find_upserts_before_the_callback
    $wt_response = ok({ "id" => 7, "title" => "found", "done" => false })
    inside = nil
    WtPost.find(7) do |post, error|
      inside = $wt_db.execute("SELECT title FROM wt_posts WHERE id = 7")[0]
    end
    assert_equal(["found"], inside)
  end

  def test_create_upserts_the_server_row
    $wt_response = ok({ "id" => 3, "title" => "server-normalized",
                        "done" => false })
    WtPost.create(title: "raw")
    assert_equal("server-normalized",
      $wt_db.execute("SELECT title FROM wt_posts WHERE id = 3")[0][0])
  end

  def test_update_upserts_and_applies_decoded_values
    post = WtPost.new({ "id" => 9, "title" => "old" })
    post.title = "sent"
    $wt_response = ok({ "id" => 9, "title" => "SERVER", "done" => true,
                        "created_at" => "2024-02-01T00:00:00Z" })
    inside = nil
    post.update do |updated, error|
      inside = $wt_db.execute("SELECT title FROM wt_posts WHERE id = 9")[0][0]
    end
    assert_equal("SERVER", inside)
    assert_equal("SERVER", post.title)
    assert_equal(true, post.done)
    assert_equal(true, post.created_at.is_a?(Time))
  end

  def test_destroy_deletes_the_replica_row
    Funicular::DB.replica_upsert($wt_db, WtPost, { "id" => 4, "title" => "x" })
    $wt_response = ok(nil)
    inside = nil
    WtPost.destroy(4) do |ok_flag, error|
      inside = $wt_db.execute("SELECT COUNT(*) FROM wt_posts")[0][0]
    end
    assert_equal(0, inside)
  end

  def test_rest_error_writes_nothing
    $wt_response = Funicular::HTTP::Response.new(422, { "errors" => ["nope"] })
    WtPost.create(title: "x") { |r, e| }
    assert_equal(0, $wt_db.execute("SELECT COUNT(*) FROM wt_posts")[0][0])
  end

  def test_disabled_local_database_keeps_rest_working_without_write_through
    assert_equal(false, Funicular::DB.local_database_enabled?)
    $wt_response = ok({ "id" => 1, "title" => "a" })
    got = nil
    WtBare.find(1) { |post, e| got = post }
    assert_equal("a", got.title)
    assert_equal(0, $wt_notified)
  end

  def test_ephemeral_models_do_not_write_through
    $wt_response = ok({ "id" => 1, "title" => "a" })
    WtSession.find(1) { |s, e| }
    assert_equal(0, $wt_db.execute("SELECT COUNT(*) FROM wt_posts")[0][0])
  end
end
