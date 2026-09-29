# Tests for the REST wiring of decisions 5/6: responses decode through
# the shared codec, and successful REST calls mirror rows into the
# replica through the single apply entry point BEFORE user callbacks
# run. HTTP is stubbed at the module level (each Picotest file runs in
# its own VM); the replica handle is injected by overriding
# Model.replica_db, the same seam DB.boot will use.

module Funicular
  module HTTP
    class << self
      # A queued response wins over the fixed $wt_response, so one test
      # can script a 304 followed by a 200.
      def get(url, headers: nil, &block)
        $wt_calls << ["GET", url]
        $wt_headers << headers
        response = $wt_queue.empty? ? $wt_response : $wt_queue.shift
        block.call(response) if block
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
    $wt_headers = []
    $wt_queue = []
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

      # Local reads (the 304 path answers from the replica) go through
      # the same in-memory handle.
      def self.local_db
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

  # ---- server-side validation errors (422 with { errors: record.errors }) ----

  def test_create_maps_a_422_errors_hash_onto_errors
    $wt_response = Funicular::HTTP::Response.new(422,
      { "errors" => { "title" => ["can't be blank", "is too short"],
                      "base" => "nope" } })
    got = nil
    WtPost.create(title: "x") { |r, e| got = e }
    assert_equal(true, got.is_a?(Funicular::Model::Errors))
    assert_equal(["can't be blank", "is too short"], got[:title])
    assert_equal(["nope"], got[:base])
    assert_equal("Title can't be blank, Title is too short, Base nope", got.to_s)
  end

  def test_update_replaces_the_records_errors_from_a_422
    post = WtPost.new({ "id" => 9, "title" => "old" })
    post.title = ""
    $wt_response = Funicular::HTTP::Response.new(422,
      { "errors" => { "title" => ["can't be blank"] } })
    got = nil
    post.update { |r, e| got = e }
    assert_equal(["can't be blank"], post.errors[:title])
    assert_equal(true, got.equal?(post.errors))
  end

  def test_other_error_shapes_stay_strings
    $wt_response = Funicular::HTTP::Response.new(422, { "errors" => ["a", "b"] })
    got = nil
    WtPost.create(title: "x") { |r, e| got = e }
    assert_equal("a, b", got)
    $wt_response = Funicular::HTTP::Response.new(500, { "error" => "boom" })
    WtPost.create(title: "x") { |r, e| got = e }
    assert_equal("boom", got)
  end

  # ---- conditional GET: the replica as an HTTP cache ----

  def tagged(data, etag, cache_control = nil)
    Funicular::HTTP::Response.new(200, data, etag, cache_control)
  end

  def not_modified
    Funicular::HTTP::Response.new(304, nil, "\"v1\"")
  end

  def test_all_remembers_the_etag_and_revalidates
    $wt_response = tagged([{ "id" => 2, "title" => "b" }, { "id" => 1, "title" => "a" }], "\"v1\"")
    WtPost.all { |r, e| }
    assert_equal([nil], $wt_headers)
    stored = Funicular::DB.read_meta($wt_db, "http:/wt_posts")
    assert_equal({ "etag" => "\"v1\"", "ids" => [2, 1] }, JSON.parse(stored))

    $wt_response = not_modified
    got = nil
    err = nil
    WtPost.all { |r, e| got = r; err = e }
    assert_equal({ "If-None-Match" => "\"v1\"" }, $wt_headers[1])
    assert_nil(err)
    assert_equal([2, 1], got.map { |p| p.id })
    assert_equal("b", got[0].title)
    # No upsert on a 304: one change event from the first fetch only.
    assert_equal(1, $wt_notified)
  end

  def test_find_revalidates_a_single_record
    $wt_response = tagged({ "id" => 7, "title" => "found" }, "W/\"abc\"")
    WtPost.find(7) { |r, e| }
    $wt_response = not_modified
    got = nil
    WtPost.find(7) { |r, e| got = r }
    assert_equal({ "If-None-Match" => "W/\"abc\"" }, $wt_headers[1])
    assert_equal("found", got.title)
  end

  def test_a_304_with_rows_missing_from_the_replica_refetches_once
    $wt_response = tagged([{ "id" => 1, "title" => "a" }], "\"v1\"")
    WtPost.all { |r, e| }
    $wt_db.execute("DELETE FROM wt_posts")
    $wt_queue = [not_modified, tagged([{ "id" => 1, "title" => "again" }], "\"v2\"")]
    got = nil
    WtPost.all { |r, e| got = r }
    assert_equal(3, $wt_calls.size)
    assert_nil($wt_headers[2])
    assert_equal("again", got[0].title)
    assert_equal("\"v2\"", JSON.parse(Funicular::DB.read_meta($wt_db, "http:/wt_posts"))["etag"])
  end

  def test_no_store_and_missing_etags_are_not_remembered
    $wt_response = tagged([{ "id" => 1, "title" => "a" }], "\"v1\"", "no-store")
    WtPost.all { |r, e| }
    assert_nil(Funicular::DB.read_meta($wt_db, "http:/wt_posts"))
    $wt_response = tagged([{ "id" => 1, "title" => "a" }], "\"v1\"")
    WtPost.all { |r, e| }
    assert_equal(false, Funicular::DB.read_meta($wt_db, "http:/wt_posts").nil?)
    $wt_response = ok([{ "id" => 1, "title" => "a" }])
    WtPost.all { |r, e| }
    assert_nil(Funicular::DB.read_meta($wt_db, "http:/wt_posts"))
  end

  def test_partial_representations_merge_into_one_replica_row
    $wt_response = ok([{ "id" => 1, "title" => "summary" }])
    WtPost.all { |r, e| }
    $wt_response = ok({ "id" => 1, "done" => true })
    WtPost.find(1) { |r, e| }
    assert_equal(["summary", 1],
      $wt_db.execute("SELECT title, done FROM wt_posts WHERE id = 1")[0])
    # An explicit null IS written.
    $wt_response = ok({ "id" => 1, "title" => nil })
    WtPost.find(1) { |r, e| }
    assert_equal([nil, 1],
      $wt_db.execute("SELECT title, done FROM wt_posts WHERE id = 1")[0])
    # An id-only row is a no-op on an existing row.
    $wt_response = ok({ "id" => 1 })
    WtPost.find(1) { |r, e| }
    assert_equal([nil, 1],
      $wt_db.execute("SELECT title, done FROM wt_posts WHERE id = 1")[0])
  end

  def test_absorb_lands_rows_like_a_fetch
    WtPost.absorb([{ "id" => 1, "title" => "ssr", "done" => 1 },
                   { "id" => 2, "title" => "seeded" }])
    assert_equal(2, $wt_db.execute("SELECT COUNT(*) FROM wt_posts")[0][0])
    assert_equal(1, $wt_notified)
    assert_equal(true, WtPost.local.find(1).done)
    # Nothing to absorb is nothing done; no replica is nothing done.
    WtPost.absorb([])
    WtPost.absorb(nil)
    WtSession.absorb([{ "id" => 3 }])
    assert_equal(1, $wt_notified)
    assert_equal(0, $wt_calls.size)
  end

  def test_ephemeral_and_unbooted_models_never_send_if_none_match
    $wt_response = tagged({ "id" => 1, "title" => "a" }, "\"v1\"")
    WtSession.find(1) { |s, e| }
    WtSession.find(1) { |s, e| }
    WtBare.find(1) { |s, e| }
    WtBare.find(1) { |s, e| }
    assert_equal([nil, nil, nil, nil], $wt_headers)
  end
end
