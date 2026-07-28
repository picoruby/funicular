# Tests for the client-only-table migration machinery: TableBuilder, the
# column fold, and the runner (baseline rebuild, incremental upgrade,
# SchemaTooNew, rollback, dev auto-reset), against a real ":memory:"
# database. Model classes are real Funicular::Model subclasses so the
# recorded-by-the-DSL path is what runs.

class MigrationTest < Picotest::Test
  def setup
    @db = SQLite3::Database.new(":memory:")
    define_models
  end

  def teardown
    @db.close
    Funicular.env = nil
  end

  def define_models
    return if Object.const_defined?(:MigDocV1)

    # The same table ("mig_docs") declared at three points of its life:
    # version 1 only, versions 1..2, and a squashed reset baseline at 3.
    Object.const_set(:MigDocV1, Class.new(Funicular::Model))
    MigDocV1.class_eval do
      table_name "mig_docs"
      storage :local do
        migrate 1 do |t|
          t.string :title, null: false
          t.text :body
        end
      end
    end

    Object.const_set(:MigDocV2, Class.new(Funicular::Model))
    MigDocV2.class_eval do
      table_name "mig_docs"
      storage :local do
        migrate 1 do |t|
          t.string :title, null: false
          t.text :body
        end
        migrate 2 do |t|
          t.boolean :pinned, default: false, null: false
          t.rename :body, :content
        end
      end
    end

    Object.const_set(:MigDocV3, Class.new(Funicular::Model))
    MigDocV3.class_eval do
      table_name "mig_docs"
      storage :local do
        migrate 3, reset: true do |t|
          t.string :slug
        end
      end
    end

    Object.const_set(:MigGadget, Class.new(Funicular::Model))
    MigGadget.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :name
          t.integer :count, default: 0
          t.timestamps
          t.index :name
        end
        migrate 2 do |t|
          t.remove_index :name
          t.remove :count
          t.execute "INSERT INTO \"mig_gadgets\" (\"name\") VALUES ('seeded')"
        end
      end
    end
  end

  def table_columns(table)
    # @type var names: Array[String]
    names = []
    rows = @db.execute("PRAGMA table_info(\"#{table}\")")
    i = 0
    while i < rows.size
      names << rows[i][1]
      i += 1
    end
    names
  end

  def index_names(table)
    # @type var names: Array[String]
    names = []
    rows = @db.execute(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
      [table])
    i = 0
    while i < rows.size
      names << rows[i][0]
      i += 1
    end
    names
  end

  # ---- fold ----

  def test_fold_includes_implicit_id_and_follows_rename_and_remove
    expected = {
      "id" => :integer,
      "title" => :string,
      "pinned" => :boolean,
      "content" => :text,
    }
    assert_equal(expected, Funicular::DB.fold_local_columns(MigDocV2))
  end

  def test_fold_rejects_duplicate_and_unknown_columns
    dup = Class.new(Funicular::Model)
    dup.class_eval do
      table_name "mig_dups"
      storage :local do
        migrate 1 do |t|
          t.string :a
        end
        migrate 2 do |t|
          t.integer :a
        end
      end
    end
    assert_raise(ArgumentError) { Funicular::DB.fold_local_columns(dup) }

    unknown = Class.new(Funicular::Model)
    unknown.class_eval do
      table_name "mig_unknowns"
      storage :local do
        migrate 1 do |t|
          t.rename :ghost, :spirit
        end
      end
    end
    assert_raise(ArgumentError) { Funicular::DB.fold_local_columns(unknown) }
  end

  def test_builder_guards_identifiers_and_the_implicit_id
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        table_name "mig_bad_ids"
        storage :local do
          migrate 1 do |t|
            t.string :id
          end
        end
      end.local_columns
    end
    assert_raise(ArgumentError) do
      Funicular::DB.validate_identifier("bad\"name")
    end
  end

  # ---- fresh apply / no-op re-apply ----

  def test_fresh_apply_creates_table_and_records_version
    assert_equal(1, Funicular::DB.apply_local_migrations(@db, MigDocV1))
    assert_equal(["id", "title", "body"], table_columns("mig_docs"))
    assert_equal(1, Funicular::DB.stored_table_version(@db, "mig_docs"))
  end

  def test_reapply_is_a_noop_and_keeps_data
    Funicular::DB.apply_local_migrations(@db, MigDocV1)
    @db.execute("INSERT INTO mig_docs (title) VALUES ('kept')")
    assert_equal(1, Funicular::DB.apply_local_migrations(@db, MigDocV1))
    assert_equal("kept", @db.execute("SELECT title FROM mig_docs")[0][0])
  end

  # ---- incremental upgrade ----

  def test_upgrade_applies_only_missing_blocks_and_keeps_data
    Funicular::DB.apply_local_migrations(@db, MigDocV1)
    @db.execute("INSERT INTO mig_docs (title, body) VALUES ('a', 'text')")
    assert_equal(2, Funicular::DB.apply_local_migrations(@db, MigDocV2))
    assert_equal(["id", "title", "content", "pinned"],
                 table_columns("mig_docs"))
    row = @db.execute("SELECT title, content, pinned FROM mig_docs")[0]
    assert_equal(["a", "text", 0], row)
    assert_equal(2, Funicular::DB.stored_table_version(@db, "mig_docs"))
  end

  def test_boolean_default_applies_to_existing_rows
    Funicular::DB.apply_local_migrations(@db, MigDocV1)
    @db.execute("INSERT INTO mig_docs (title) VALUES ('x')")
    Funicular::DB.apply_local_migrations(@db, MigDocV2)
    assert_equal(0, @db.execute("SELECT pinned FROM mig_docs")[0][0])
  end

  # ---- baseline rebuild ----

  def test_below_baseline_rebuilds_and_discards_data
    Funicular::DB.apply_local_migrations(@db, MigDocV2)
    @db.execute("INSERT INTO mig_docs (title) VALUES ('doomed')")
    assert_equal(3, Funicular::DB.apply_local_migrations(@db, MigDocV3))
    assert_equal(["id", "slug"], table_columns("mig_docs"))
    assert_equal(0, @db.execute("SELECT COUNT(*) FROM mig_docs")[0][0])
    assert_equal(3, Funicular::DB.stored_table_version(@db, "mig_docs"))
  end

  # ---- SchemaTooNew ----

  def test_stored_version_newer_than_declared_raises
    Funicular::DB.apply_local_migrations(@db, MigDocV3)
    assert_raise(Funicular::DB::SchemaTooNewError) do
      Funicular::DB.apply_local_migrations(@db, MigDocV2)
    end
    # Untouched: still at version 3 with the version-3 shape.
    assert_equal(3, Funicular::DB.stored_table_version(@db, "mig_docs"))
    assert_equal(["id", "slug"], table_columns("mig_docs"))
  end

  # ---- index / remove / execute ops ----

  def test_index_timestamps_remove_and_execute
    Funicular::DB.apply_local_migrations(@db, MigGadget)
    assert_equal(["id", "name", "created_at", "updated_at"],
                 table_columns("mig_gadgets"))
    assert_equal([], index_names("mig_gadgets"))
    assert_equal("seeded", @db.execute("SELECT name FROM mig_gadgets")[0][0])
    expected = {
      "id" => :integer,
      "name" => :string,
      "created_at" => :datetime,
      "updated_at" => :datetime,
    }
    assert_equal(expected, MigGadget.local_columns)
  end

  def test_index_exists_at_version_one
    v1 = Class.new(Funicular::Model)
    v1.class_eval do
      table_name "mig_gadgets"
      storage :local do
        migrate 1 do |t|
          t.string :name
          t.integer :count, default: 0
          t.timestamps
          t.index :name
        end
      end
    end
    Funicular::DB.apply_local_migrations(@db, v1)
    assert_equal(["index_mig_gadgets_on_name"], index_names("mig_gadgets"))
  end

  # ---- reset: true kept mid-history ----
  # The docs only say pre-reset blocks MAY be deleted: a reset block must
  # act as the baseline even when the superseded history stays in code.

  def reset_history_model(extra_version = nil)
    klass = Class.new(Funicular::Model)
    klass.class_eval do
      table_name "mig_resets"
      storage :local do
        migrate 1 do |t|
          t.string :old_name
          t.string :title
        end
        migrate 2, reset: true do |t|
          t.string :title
          t.string :new_name
        end
        migrate 3 do |t|
          t.integer :rank
        end
        if extra_version
          migrate 4 do |t|
            t.float :score
          end
        end
      end
    end
    klass
  end

  def test_mid_history_reset_is_the_fold_baseline
    expected = {
      "id" => :integer,
      "title" => :string,
      "new_name" => :string,
      "rank" => :integer,
    }
    # No duplicate-column error although the reset block redefines title.
    assert_equal(expected, Funicular::DB.fold_local_columns(reset_history_model))
  end

  def test_fresh_apply_skips_pre_reset_history
    model = reset_history_model
    assert_equal(3, Funicular::DB.apply_local_migrations(@db, model))
    assert_equal(["id", "title", "new_name", "rank"],
                 table_columns("mig_resets"))
    assert_equal(3, Funicular::DB.stored_table_version(@db, "mig_resets"))
  end

  def test_below_mid_history_reset_rebuilds
    v1 = Class.new(Funicular::Model)
    v1.class_eval do
      table_name "mig_resets"
      storage :local do
        migrate 1 do |t|
          t.string :old_name
          t.string :title
        end
      end
    end
    Funicular::DB.apply_local_migrations(@db, v1)
    @db.execute("INSERT INTO mig_resets (old_name) VALUES ('stale')")
    assert_equal(3, Funicular::DB.apply_local_migrations(@db, reset_history_model))
    assert_equal(["id", "title", "new_name", "rank"],
                 table_columns("mig_resets"))
    assert_equal(0, @db.execute("SELECT COUNT(*) FROM mig_resets")[0][0])
  end

  def test_incremental_upgrade_above_mid_history_reset_keeps_data
    Funicular::DB.apply_local_migrations(@db, reset_history_model)
    @db.execute("INSERT INTO mig_resets (title) VALUES ('kept')")
    assert_equal(4, Funicular::DB.apply_local_migrations(@db, reset_history_model(4)))
    assert_equal(["id", "title", "new_name", "rank", "score"],
                 table_columns("mig_resets"))
    assert_equal("kept", @db.execute("SELECT title FROM mig_resets")[0][0])
  end

  def test_incremental_id_rename_or_remove_is_rejected_before_any_sql
    Funicular::DB.apply_local_migrations(@db, MigDocV1)
    @db.execute("INSERT INTO mig_docs (title) VALUES ('intact')")
    renamer = Class.new(Funicular::Model)
    renamer.class_eval do
      table_name "mig_docs"
      storage :local do
        migrate 1 do |t|
          t.string :title, null: false
          t.text :body
        end
        migrate 2 do |t|
          t.rename :id, :legacy_id
        end
      end
    end
    remover = Class.new(Funicular::Model)
    remover.class_eval do
      table_name "mig_docs"
      storage :local do
        migrate 1 do |t|
          t.string :title, null: false
          t.text :body
        end
        migrate 2 do |t|
          t.remove :id
        end
      end
    end
    # SQLite itself would happily rename the PRIMARY KEY column, so the
    # fold must reject this before any DDL runs -- and it must do so even
    # in development (fold errors never trigger the dev auto-reset).
    assert_raise(ArgumentError) do
      Funicular::DB.apply_local_migrations(@db, renamer)
    end
    assert_raise(ArgumentError) do
      Funicular::DB.apply_local_migrations(@db, remover)
    end
    assert_equal(1, Funicular::DB.stored_table_version(@db, "mig_docs"))
    assert_equal(["id", "title", "body"], table_columns("mig_docs"))
    assert_equal("intact", @db.execute("SELECT title FROM mig_docs")[0][0])
  end

  def test_reserved_column_names_are_rejected
    # The generated reader would clobber the model API (or Object's);
    # __-prefixed names would clobber framework internals (the
    # __custom_* stash that wraps hand-written writers, notably).
    bad_names = ["destroy", "class", "errors", "initialize", "__custom_title"]
    bad_names_size = bad_names.size
    i = 0
    while i < bad_names_size
      bad_name = bad_names[i]
      suffix = i
      bad = Class.new(Funicular::Model)
      bad.class_eval do
        table_name "mig_reserved#{suffix}"
        storage :local do
          migrate 1 do |t|
            t.string bad_name
          end
        end
      end
      assert_raise(ArgumentError) { Funicular::DB.fold_local_columns(bad) }
      i += 1
    end
    renamer = Class.new(Funicular::Model)
    renamer.class_eval do
      table_name "mig_reserved_rename"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
        migrate 2 do |t|
          t.rename :title, :reload
        end
      end
    end
    assert_raise(ArgumentError) { Funicular::DB.fold_local_columns(renamer) }
  end

  def test_migrate_blocks_are_evaluated_once_per_run
    $mig_block_runs = 0
    counted = Class.new(Funicular::Model)
    counted.class_eval do
      table_name "mig_counts"
      storage :local do
        migrate 1 do |t|
          $mig_block_runs += 1
          t.string :name
        end
      end
    end
    # Fresh apply: validation and DDL share ONE evaluation of the block.
    Funicular::DB.apply_local_migrations(@db, counted)
    assert_equal(1, $mig_block_runs)
    # A no-op re-application still validates, so exactly one more.
    Funicular::DB.apply_local_migrations(@db, counted)
    assert_equal(2, $mig_block_runs)
  end

  # ---- failure handling ----

  def test_failed_upgrade_rolls_back_in_production
    Funicular.env = "production"
    Funicular::DB.apply_local_migrations(@db, MigDocV1)
    @db.execute("INSERT INTO mig_docs (title) VALUES ('safe')")
    broken = Class.new(Funicular::Model)
    broken.class_eval do
      table_name "mig_docs"
      storage :local do
        migrate 1 do |t|
          t.string :title, null: false
          t.text :body
        end
        migrate 2 do |t|
          t.execute "THIS IS NOT SQL"
        end
      end
    end
    assert_raise(SQLite3::Exception) do
      Funicular::DB.apply_local_migrations(@db, broken)
    end
    assert_equal(1, Funicular::DB.stored_table_version(@db, "mig_docs"))
    assert_equal("safe", @db.execute("SELECT title FROM mig_docs")[0][0])
  end

  def test_failed_upgrade_auto_resets_in_development
    Funicular.env = "development"
    Funicular::DB.apply_local_migrations(@db, MigDocV1)
    @db.execute("INSERT INTO mig_docs (title) VALUES ('dev')")
    # Dirty dev table: the column version 2 wants to add already exists.
    @db.execute("ALTER TABLE mig_docs ADD COLUMN pinned INTEGER")
    assert_equal(2, Funicular::DB.apply_local_migrations(@db, MigDocV2))
    assert_equal(["id", "title", "content", "pinned"],
                 table_columns("mig_docs"))
    assert_equal(0, @db.execute("SELECT COUNT(*) FROM mig_docs")[0][0])
    assert_equal(2, Funicular::DB.stored_table_version(@db, "mig_docs"))
  end
end
