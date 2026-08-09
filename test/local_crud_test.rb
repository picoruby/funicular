# Tests for storage :local CRUD and the bare-class alias, on a real
# ":memory:" database. The boot machinery does not exist yet, so the
# test model overrides local_db (the same override point DB.boot will
# wire) and counts local_table_changed notifications.

class LocalCrudTest < Picotest::Test
  def setup
    $crud_db = SQLite3::Database.new(":memory:")
    $crud_notified = 0
    define_model
    Funicular::DB.apply_local_migrations($crud_db, CrudDraft)
  end

  def teardown
    $crud_db.close
  end

  def define_model
    return if Object.const_defined?(:CrudDraft)

    Object.const_set(:CrudDraft, Class.new(Funicular::Model))
    CrudDraft.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :title
          t.text :body
          t.boolean :done, default: false, null: false
          t.string :note, default: "N/A"
          t.string :model_class
          t.datetime :due_at
          t.timestamps
        end
      end
      validates :title, presence: true

      def self.local_db
        $crud_db
      end

      def self.local_table_changed
        $crud_notified += 1
      end
    end
  end

  # ---- create ----

  def test_create_returns_a_persisted_instance
    draft = CrudDraft.create(title: "hello")
    assert_equal(true, draft.id.is_a?(Integer))
    assert_equal(false, draft.new_record?)
    assert_equal(1, CrudDraft.count)
    assert_equal(1, $crud_notified)
  end

  def test_create_syncs_sql_defaults_back_into_the_instance
    draft = CrudDraft.create(title: "hello")
    assert_equal(false, draft.done)
  end

  def test_create_sets_timestamps
    draft = CrudDraft.create(title: "stamped")
    assert_equal(true, draft.created_at.is_a?(Time))
    assert_equal(true, draft.updated_at.is_a?(Time))
  end

  def test_create_encodes_and_decodes_types
    due = Funicular::DB::Codec.iso_to_time("2023-11-14T22:13:20Z")
    draft = CrudDraft.create(title: "typed", done: true, due_at: due)
    raw = $crud_db.execute(
      "SELECT done, due_at FROM crud_drafts WHERE id = ?", [draft.id])[0]
    assert_equal(1, raw[0])
    assert_equal("2023-11-14T22:13:20Z", raw[1])
    found = CrudDraft.find(draft.id)
    assert_equal(true, found.done)
    assert_equal(due.to_i, found.due_at.to_i)
  end

  def test_create_returns_the_unsaved_instance_when_invalid
    draft = CrudDraft.create({})
    assert_equal(true, draft.new_record?)
    assert_equal(false, draft.valid?)
    assert_equal(0, CrudDraft.count)
    assert_equal(0, $crud_notified)
  end

  def test_create_distinguishes_omitted_from_explicit_nil
    # Omitted: the SQL DEFAULT applies.
    omitted = CrudDraft.create(title: "a")
    assert_equal("N/A", omitted.note)
    # Explicit nil on a nullable column with a default: NULL, not "N/A".
    explicit = CrudDraft.create(title: "b", note: nil)
    assert_nil(explicit.note)
    raw = $crud_db.execute(
      "SELECT note FROM crud_drafts WHERE id = ?", [explicit.id])[0]
    assert_nil(raw[0])
    # Explicit nil on a NOT NULL column: the constraint fires, exactly
    # like the same nil on update.
    assert_raise(SQLite3::ConstraintException) do
      CrudDraft.create(title: "c", done: nil)
    end
  end

  def test_create_merges_positional_hash_and_keywords
    draft = CrudDraft.create({ title: "positional" }, done: true)
    assert_equal("positional", draft.title)
    assert_equal(true, draft.done)
  end

  def test_create_keywords_win_on_the_same_key
    draft = CrudDraft.create({ title: "hash" }, title: "keyword")
    assert_equal("keyword", draft.title)
    # Per attribute, not per literal key: a string-keyed positional hash
    # loses to the symbol keyword as well.
    stringy = CrudDraft.create({ "title" => "hash" }, title: "keyword")
    assert_equal("keyword", stringy.title)
  end

  def test_create_model_class_is_an_ordinary_column_on_local_models
    draft = CrudDraft.create(title: "x", model_class: "example")
    assert_equal("example", draft.model_class)
    assert_equal("example", CrudDraft.find(draft.id).model_class)
  end

  def test_create_ids_come_from_the_insert_itself
    a = CrudDraft.create(title: "a")
    b = CrudDraft.create(title: "b")
    assert_equal(false, a.id == b.id)
    assert_equal("a", CrudDraft.find(a.id).title)
    assert_equal("b", CrudDraft.find(b.id).title)
  end

  def test_create_takes_no_block
    assert_raise(ArgumentError) do
      CrudDraft.create(title: "x") { |r, e| }
    end
  end

  def test_writers_are_column_specific
    # Regression: writers generated in a while loop once all captured the
    # SAME loop variable and wrote to the last column (updated_at).
    draft = CrudDraft.create(title: "t")
    draft.title = "t2"
    draft.body = "b2"
    assert_equal("t2", draft.title)
    assert_equal("b2", draft.body)
  end

  def test_user_defined_accessors_are_preserved
    unless Object.const_defined?(:CrudShouty)
      Object.const_set(:CrudShouty, Class.new(Funicular::Model))
      CrudShouty.class_eval do
        table_name "crud_shouties"
        storage :local do
          migrate 1 do |t|
            t.string :title
            t.string :plain
          end
        end

        def self.local_db
          $crud_db
        end

        # A hand-written reader must survive the lazy accessor
        # generation; only the missing writer is generated.
        def title
          "#{@title}!"
        end
      end
    end
    Funicular::DB.apply_local_migrations($crud_db, CrudShouty)
    record = CrudShouty.create(title: "loud", plain: "quiet")
    assert_equal("loud!", record.title)
    assert_equal("quiet", record.plain)
    found = CrudShouty.find(record.id)
    assert_equal(true, found.update(title: "still"))
    assert_equal("still!", CrudShouty.find(record.id).title)
  end

  def test_user_defined_writer_is_wrapped_for_dirty_tracking
    unless Object.const_defined?(:CrudTrimmy)
      Object.const_set(:CrudTrimmy, Class.new(Funicular::Model))
      CrudTrimmy.class_eval do
        table_name "crud_trimmies"
        storage :local do
          migrate 1 do |t|
            t.string :title
          end
        end

        def self.local_db
          $crud_db
        end

        def self.local_table_changed
          $crud_notified += 1
        end

        # A normalizing writer: it must keep running AND stay tracked.
        def title=(value)
          @title = value.to_s.strip
        end
      end
    end
    Funicular::DB.apply_local_migrations($crud_db, CrudTrimmy)
    # The writer applies on create too, not only on update.
    record = CrudTrimmy.create(title: "  start  ")
    assert_equal("start", record.title)
    assert_equal("start", $crud_db.execute(
      "SELECT title FROM crud_trimmies WHERE id = ?", [record.id])[0][0])
    found = CrudTrimmy.find(record.id)
    assert_equal(true, found.update(title: "  new  "))
    assert_equal("new", found.title)
    raw = $crud_db.execute(
      "SELECT title FROM crud_trimmies WHERE id = ?", [record.id])[0]
    assert_equal("new", raw[0])
    # A value that normalizes back to the persisted one stays clean.
    notified_before = $crud_notified
    assert_equal(true, found.update(title: " new "))
    assert_equal(notified_before, $crud_notified)
  end

  # ---- bare-class alias ----

  def test_all_is_the_whole_table_relation
    CrudDraft.create(title: "a")
    CrudDraft.create(title: "b")
    relation = CrudDraft.all
    assert_equal(true, relation.is_a?(Funicular::Relation))
    assert_equal(2, relation.to_a.size)
  end

  def test_all_takes_no_block_and_no_params
    assert_raise(ArgumentError) { CrudDraft.all { |r, e| } }
    assert_raise(ArgumentError) { CrudDraft.all(page: 2) }
  end

  def test_class_level_query_methods
    CrudDraft.create(title: "a", done: true)
    CrudDraft.create(title: "b")
    CrudDraft.create(title: "c")
    assert_equal(3, CrudDraft.count)
    assert_equal(true, CrudDraft.exists?)
    assert_equal("a", CrudDraft.order(:id).first.title)
    assert_equal(1, CrudDraft.where(done: true).count)
    assert_equal("b", CrudDraft.find_by(title: "b").title)
    assert_equal(2, CrudDraft.order(:id).limit(2).to_a.size)
    assert_equal(1, CrudDraft.order(:id).offset(2).to_a.size)
    assert_equal(2, CrudDraft.where(done: false).delete_all)
    assert_equal(1, CrudDraft.count)
  end

  def test_alias_is_absent_on_non_local_models
    replica = Class.new(Funicular::Model)
    assert_raise(NoMethodError) { replica.where(done: true) }
    assert_raise(NoMethodError) { replica.delete_all }
  end

  def test_class_find_returns_or_raises
    draft = CrudDraft.create(title: "findable")
    assert_equal("findable", CrudDraft.find(draft.id).title)
    assert_raise(Funicular::RecordNotFound) { CrudDraft.find(999) }
    assert_raise(ArgumentError) { CrudDraft.find(draft.id) { |r, e| } }
  end

  def test_class_destroy
    draft = CrudDraft.create(title: "doomed")
    assert_equal(true, CrudDraft.destroy(draft.id))
    assert_equal(0, CrudDraft.count)
    assert_raise(Funicular::RecordNotFound) { CrudDraft.destroy(999) }
  end

  # ---- update ----

  def test_update_persists_and_bumps_updated_at
    draft = CrudDraft.create(title: "old")
    $crud_db.execute(
      "UPDATE crud_drafts SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?",
      [draft.id])
    record = CrudDraft.find(draft.id)
    notified_before = $crud_notified
    assert_equal(true, record.update(title: "new"))
    raw = $crud_db.execute(
      "SELECT title, updated_at FROM crud_drafts WHERE id = ?", [draft.id])[0]
    assert_equal("new", raw[0])
    assert_equal(false, raw[1] == "2000-01-01T00:00:00Z")
    assert_equal(notified_before + 1, $crud_notified)
  end

  def test_update_with_no_actual_change_is_a_noop
    draft = CrudDraft.create(title: "same")
    $crud_db.execute(
      "UPDATE crud_drafts SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?",
      [draft.id])
    record = CrudDraft.find(draft.id)
    notified_before = $crud_notified
    assert_equal(true, record.update({}))
    assert_equal(true, record.update(title: "same"))
    raw = $crud_db.execute(
      "SELECT updated_at FROM crud_drafts WHERE id = ?", [draft.id])[0]
    assert_equal("2000-01-01T00:00:00Z", raw[0])
    assert_equal(notified_before, $crud_notified)
  end

  def test_reverting_to_the_persisted_value_cancels_the_change
    draft = CrudDraft.create(title: "original")
    $crud_db.execute(
      "UPDATE crud_drafts SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?",
      [draft.id])
    record = CrudDraft.find(draft.id)
    record.title = "temporary"
    record.title = "original"
    notified_before = $crud_notified
    assert_equal(true, record.update)
    raw = $crud_db.execute(
      "SELECT title, updated_at FROM crud_drafts WHERE id = ?", [draft.id])[0]
    assert_equal("original", raw[0])
    assert_equal("2000-01-01T00:00:00Z", raw[1])
    assert_equal(notified_before, $crud_notified)
  end

  def test_revert_is_clean_on_the_created_instance_too
    draft = CrudDraft.create(title: "orig")
    draft.body = "tmp"
    draft.body = nil
    notified_before = $crud_notified
    assert_equal(true, draft.update)
    assert_equal(notified_before, $crud_notified)
  end

  def test_update_syncs_normalized_values_back_into_the_instance
    draft = CrudDraft.create(title: "t")
    assert_equal(true, draft.update(due_at: "2026-01-01T09:00:00+09:00"))
    utc = Funicular::DB::Codec.iso_to_time("2026-01-01T00:00:00Z")
    # The instance carries what the table stores: the decoded Time, not
    # the offset string that was assigned.
    assert_equal(true, draft.due_at.is_a?(Time))
    assert_equal(utc.to_i, draft.due_at.to_i)
    found = CrudDraft.find(draft.id)
    assert_equal(utc.to_i, found.due_at.to_i)
    # The baseline matches too: assigning the equivalent Time is clean.
    notified_before = $crud_notified
    assert_equal(true, draft.update(due_at: utc))
    assert_equal(notified_before, $crud_notified)
  end

  def test_update_validation_failure_returns_false
    draft = CrudDraft.create(title: "valid")
    notified_before = $crud_notified
    assert_equal(false, draft.update(title: nil))
    raw = $crud_db.execute(
      "SELECT title FROM crud_drafts WHERE id = ?", [draft.id])[0]
    assert_equal("valid", raw[0])
    assert_equal(notified_before, $crud_notified)
  end

  def test_update_on_a_new_record_raises
    assert_raise(ArgumentError) do
      CrudDraft.new(title: "floating").update(title: "x")
    end
  end

  def test_update_takes_no_block
    draft = CrudDraft.create(title: "x")
    assert_raise(ArgumentError) do
      draft.update(title: "y") { |r, e| }
    end
  end

  # ---- destroy / reload ----

  def test_destroy_removes_the_row
    draft = CrudDraft.create(title: "bye")
    notified_before = $crud_notified
    assert_equal(true, draft.destroy)
    assert_equal(0, CrudDraft.count)
    assert_equal(notified_before + 1, $crud_notified)
  end

  def test_destroy_on_a_new_record_raises
    assert_raise(ArgumentError) { CrudDraft.new(title: "x").destroy }
    draft = CrudDraft.create(title: "x")
    assert_raise(ArgumentError) { draft.destroy { |ok, e| } }
  end

  def test_reload_rereads_the_row
    draft = CrudDraft.create(title: "before")
    $crud_db.execute(
      "UPDATE crud_drafts SET title = 'after' WHERE id = ?", [draft.id])
    assert_equal(draft, draft.reload)
    assert_equal("after", draft.title)
    assert_raise(ArgumentError) { draft.reload { |r, e| } }
  end

  def test_destroy_of_an_already_deleted_row_does_not_notify
    draft = CrudDraft.create(title: "gone")
    $crud_db.execute("DELETE FROM crud_drafts WHERE id = ?", [draft.id])
    notified_before = $crud_notified
    assert_equal(true, draft.destroy)
    assert_equal(notified_before, $crud_notified)
  end

  def test_reload_on_a_deleted_row_raises
    draft = CrudDraft.create(title: "gone")
    $crud_db.execute("DELETE FROM crud_drafts WHERE id = ?", [draft.id])
    assert_raise(Funicular::RecordNotFound) { draft.reload }
  end

  def test_update_on_a_deleted_row_raises_keeps_changes_and_does_not_notify
    draft = CrudDraft.create(title: "gone")
    $crud_db.execute("DELETE FROM crud_drafts WHERE id = ?", [draft.id])
    notified_before = $crud_notified
    assert_raise(Funicular::RecordNotFound) { draft.update(title: "new") }
    assert_equal(notified_before, $crud_notified)
    assert_equal("new", draft.title)
    pending = draft.instance_variable_get("@changed_attributes")
    assert_equal("new", pending["title"])
  end

  def test_failed_update_reverts_the_internal_updated_at_stamp
    draft = CrudDraft.create(title: "t")
    record = CrudDraft.find(draft.id)
    assert_raise(SQLite3::ConstraintException) { record.update(done: nil) }
    # Back to the persisted value: the record is now genuinely clean --
    # unless the failed update left its internal updated_at stamp dirty.
    record.done = false
    notified_before = $crud_notified
    assert_equal(true, record.update)
    assert_equal(notified_before, $crud_notified)
  end

  def test_failed_encode_also_reverts_the_stamp
    draft = CrudDraft.create(title: "t")
    record = CrudDraft.find(draft.id)
    assert_raise(ArgumentError) { record.update(due_at: "invalid") }
    record.due_at = nil
    notified_before = $crud_notified
    assert_equal(true, record.update)
    assert_equal(notified_before, $crud_notified)
  end

  def test_constraint_violations_escape_as_sqlite_exception
    draft = CrudDraft.create(title: "x")
    # done is NOT NULL: a raw nil assignment slips past presence
    # validation (only title is validated) and must fail loud in SQLite.
    assert_raise(SQLite3::ConstraintException) do
      draft.update(done: nil)
    end
  end
end
