# Tests for the local-query foundation: the shared value codec and the
# lazy Relation SQL builder, run against a real SQLite ":memory:" database.
# The model protocol Relation consumes (table_name / local_columns /
# local_db / replica? / build_from_local) is provided by a stub here; the
# real Funicular::Model wiring has its own tests.

class RelationStubRecord
  attr_reader :attrs

  def initialize(attrs)
    @attrs = attrs
  end
end

class RelationStubModel
  def initialize(db, table, columns, replica)
    @db = db
    @table = table
    @columns = columns
    @replica = replica
  end

  def table_name
    @table
  end

  def local_columns
    @columns
  end

  def local_db
    @db
  end

  def replica?
    @replica
  end

  def build_from_local(attrs)
    RelationStubRecord.new(attrs)
  end
end

class CodecTest < Picotest::Test
  def codec
    Funicular::DB::Codec
  end

  def test_boolean_encode
    assert_equal(1, codec.encode(:boolean, true))
    assert_equal(0, codec.encode(:boolean, false))
    assert_nil(codec.encode(:boolean, nil))
    assert_equal(1, codec.encode(:boolean, 1))
  end

  def test_boolean_decode
    assert_equal(true, codec.decode(:boolean, 1))
    assert_equal(false, codec.decode(:boolean, 0))
    assert_nil(codec.decode(:boolean, nil))
    assert_equal(true, codec.decode(:boolean, true))
  end

  def test_datetime_encode_epoch_zero
    assert_equal("1970-01-01T00:00:00Z", codec.encode(:datetime, Time.at(0)))
  end

  def test_datetime_encode_known_epoch
    assert_equal("2023-11-14T22:13:20Z", codec.encode(:datetime, Time.at(1700000000)))
  end

  def test_datetime_encode_passes_strings_through
    assert_equal("2020-01-01T00:00:00Z", codec.encode(:datetime, "2020-01-01T00:00:00Z"))
  end

  def test_datetime_roundtrip
    t = Time.at(1700000000)
    assert_equal(t.to_i, codec.decode(:datetime, codec.encode(:datetime, t)).to_i)
  end

  def test_datetime_decode_utc
    assert_equal(1700000000, codec.decode(:datetime, "2023-11-14T22:13:20Z").to_i)
  end

  def test_datetime_decode_offset
    with_offset = codec.decode(:datetime, "2020-01-01T09:00:00+09:00")
    utc = codec.decode(:datetime, "2020-01-01T00:00:00Z")
    assert_equal(utc.to_i, with_offset.to_i)
  end

  def test_datetime_decode_fraction_truncated
    plain = codec.decode(:datetime, "2020-01-01T00:00:00Z")
    frac = codec.decode(:datetime, "2020-01-01T00:00:00.123Z")
    assert_equal(plain.to_i, frac.to_i)
  end

  def test_datetime_decode_space_separator_and_no_zone_is_utc
    assert_equal(codec.decode(:datetime, "2020-01-01T00:00:00Z").to_i,
                 codec.decode(:datetime, "2020-01-01 00:00:00").to_i)
  end

  def test_datetime_decode_malformed_raises
    assert_raise(ArgumentError) { codec.iso_to_time("garbage") }
    assert_raise(ArgumentError) { codec.iso_to_time("2020-13-01T00:00:00Z") }
    assert_raise(ArgumentError) { codec.iso_to_time("2020-01-01T00:00:00X") }
    assert_raise(ArgumentError) { codec.iso_to_time("2020-01-01T00:00:00Ztrailing") }
  end

  def test_other_types_pass_through
    assert_equal(42, codec.encode(:integer, 42))
    assert_equal("x", codec.decode(:string, "x"))
  end

  def test_encode_bind_is_value_based
    assert_equal(1, codec.encode_bind(true))
    assert_equal(0, codec.encode_bind(false))
    assert_equal("1970-01-01T00:00:00Z", codec.encode_bind(Time.at(0)))
    assert_equal(5, codec.encode_bind(5))
    assert_equal("x", codec.encode_bind("x"))
  end
end

class RelationTest < Picotest::Test
  COLUMNS = {
    "id" => :integer,
    "title" => :string,
    "done" => :boolean,
    "score" => :float,
    "created_at" => :datetime,
  }

  def setup
    @db = SQLite3::Database.new(":memory:")
    @db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, " \
                "done INTEGER, score REAL, created_at TEXT)")
    @model = RelationStubModel.new(@db, "posts", COLUMNS, false)
    seed = [
      [1, "alpha", 0, 1.5, "2024-01-01T00:00:00Z"],
      [2, "bravo", 1, 2.5, "2024-01-02T00:00:00Z"],
      [3, "charlie", 0, 3.5, "2024-01-03T00:00:00Z"],
      [4, "delta", 1, 4.5, "2024-01-04T00:00:00Z"],
      [5, "echo", 0, nil, "2024-01-05T00:00:00Z"],
    ]
    i = 0
    while i < seed.size
      @db.execute("INSERT INTO posts VALUES (?, ?, ?, ?, ?)", seed[i])
      i += 1
    end
  end

  def teardown
    @db.close
  end

  def rel
    Funicular::Relation.new(@model)
  end

  def ids(records)
    out = []
    i = 0
    while i < records.size
      out << records[i].attrs["id"]
      i += 1
    end
    out
  end

  # ---- laziness and chaining ----

  def test_chain_builders_return_new_relations
    base = rel
    filtered = base.where(done: false)
    assert_equal(5, base.count)
    assert_equal(3, filtered.count)
  end

  def test_multiple_where_calls_and_together
    assert_equal([3], ids(rel.where(done: false).where("score > ?", 2.0).to_a))
  end

  # ---- condition forms ----

  def test_where_equality_with_boolean_encoding
    assert_equal([2, 4], ids(rel.where(done: true).order(:id).to_a))
  end

  def test_where_array_becomes_in
    assert_equal([1, 3], ids(rel.where(id: [1, 3]).order(:id).to_a))
  end

  def test_where_empty_array_is_always_empty
    assert_equal(0, rel.where(id: []).count)
    assert_equal([], rel.where(id: []).to_a)
  end

  def test_where_nil_becomes_is_null
    assert_equal([5], ids(rel.where(score: nil).to_a))
  end

  def test_where_inclusive_range_is_between
    assert_equal([2, 3, 4], ids(rel.where(id: 2..4).order(:id).to_a))
  end

  def test_where_exclusive_range_excludes_end
    assert_equal([2, 3], ids(rel.where(id: 2...4).order(:id).to_a))
  end

  def test_where_range_of_times_uses_codec
    from = Funicular::DB::Codec.iso_to_time("2024-01-02T00:00:00Z")
    to = Funicular::DB::Codec.iso_to_time("2024-01-04T00:00:00Z")
    assert_equal([2, 3], ids(rel.where(created_at: from...to).order(:id).to_a))
  end

  def test_where_raw_fragment_with_placeholders
    assert_equal([4], ids(rel.where("score > ? AND done = ?", 3.0, true).to_a))
  end

  def test_where_unknown_column_raises
    assert_raise(ArgumentError) { rel.where(nope: 1) }
  end

  def test_where_unsupported_argument_raises
    assert_raise(ArgumentError) { rel.where(42) }
  end

  # ---- order / limit / offset ----

  def test_order_symbol_is_ascending
    assert_equal([1, 2, 3, 4, 5], ids(rel.order(:id).to_a))
  end

  def test_order_hash_desc
    assert_equal([5, 4, 3, 2, 1], ids(rel.order(id: :desc).to_a))
  end

  def test_order_multiple_keys
    assert_equal([2, 4, 1, 3, 5], ids(rel.order(done: :desc, id: :asc).to_a))
    assert_equal([1, 3, 5, 2, 4], ids(rel.order(:done).order(:id).to_a))
  end

  def test_order_unknown_column_raises
    assert_raise(ArgumentError) { rel.order(:nope) }
  end

  def test_order_bad_direction_raises
    assert_raise(ArgumentError) { rel.order(id: :sideways) }
  end

  def test_limit_and_offset
    assert_equal([3, 4], ids(rel.order(:id).limit(2).offset(2).to_a))
  end

  def test_offset_without_limit
    assert_equal([3, 4, 5], ids(rel.order(:id).offset(2).to_a))
  end

  def test_limit_rejects_bad_arguments
    assert_raise(ArgumentError) { rel.limit(-1) }
    assert_raise(ArgumentError) { rel.offset("2") }
  end

  # ---- materializers ----

  def test_to_a_decodes_types
    record = rel.where(id: [2]).to_a[0]
    assert_equal(true, record.attrs["done"])
    created = record.attrs["created_at"]
    assert_equal(true, created.is_a?(Time))
    assert_equal(Funicular::DB::Codec.iso_to_time("2024-01-02T00:00:00Z").to_i, created.to_i)
  end

  def test_each_yields_and_returns_records
    seen = []
    returned = rel.order(:id).limit(2).each { |r| seen << r.attrs["id"] }
    assert_equal([1, 2], seen)
    assert_equal(2, returned.size)
  end

  def test_first_respects_order_and_returns_nil_when_empty
    assert_equal(5, rel.order(id: :desc).first.attrs["id"])
    assert_nil(rel.where(id: []).first)
  end

  def test_count_plain_and_windowed
    assert_equal(5, rel.count)
    assert_equal(2, rel.limit(2).count)
    assert_equal(1, rel.order(:id).offset(4).count)
  end

  def test_exists
    assert_equal(true, rel.where(done: true).exists?)
    assert_equal(false, rel.where(id: []).exists?)
    assert_equal(false, rel.offset(5).exists?)
  end

  def test_find_returns_record_or_raises
    assert_equal("bravo", rel.find(2).attrs["title"])
    assert_raise(Funicular::RecordNotFound) { rel.find(99) }
  end

  def test_find_by_returns_nil_when_missing
    assert_equal("bravo", rel.find_by(title: "bravo").attrs["title"])
    assert_nil(rel.find_by(id: 99))
  end

  # ---- delete_all ----

  def test_delete_all_with_condition
    assert_equal(2, rel.where(done: true).delete_all)
    assert_equal([1, 3, 5], ids(rel.order(:id).to_a))
  end

  def test_delete_all_whole_table
    assert_equal(5, rel.delete_all)
    assert_equal(0, rel.count)
  end

  def test_delete_all_rejects_order_limit_offset
    assert_raise(ArgumentError) { rel.order(:id).delete_all }
    assert_raise(ArgumentError) { rel.limit(1).delete_all }
    assert_raise(ArgumentError) { rel.offset(1).delete_all }
  end

  def test_delete_all_on_replica_raises
    replica = Funicular::Relation.new(RelationStubModel.new(@db, "posts", COLUMNS, true))
    assert_raise(Funicular::DB::ReplicaWriteError) { replica.delete_all }
    assert_equal(5, rel.count)
  end
end
