# Tests for the model-side declaration DSL of the local database layer:
# storage / migrate recording and version rules / refresh / table_name /
# the `.local` entry point and the schema-derived replica columns.
# Nothing here needs a database: migrate blocks are only recorded, and
# Relation chains are lazy (materializing without DB.boot fails loud).

class ModelDslTest < Picotest::Test
  SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "title" => { "type" => "string" },
      "done" => { "type" => "boolean" },
      "avatar" => { "type" => "binary" },
      "created_at" => { "type" => "datetime" },
    },
    "endpoints" => {},
  }

  def setup
    return if Object.const_defined?(:DslPost)

    Object.const_set(:DslPost, Class.new(Funicular::Model))
    DslPost.load_schema(SCHEMA)

    # No schema loaded on purpose (local_columns must fail loud).
    Object.const_set(:DslCategory, Class.new(Funicular::Model))

    Object.const_set(:DslSession, Class.new(Funicular::Model))
    DslSession.class_eval do
      storage :ephemeral
    end

    Object.const_set(:DslDraft, Class.new(Funicular::Model))
    DslDraft.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
        migrate 2 do |t|
          t.boolean :done
        end
      end
    end
  end

  # ---- storage axis ----

  def test_default_storage_is_replica
    assert_equal(:replica, DslPost.storage_kind)
    assert_equal(true, DslPost.replica?)
    assert_equal(false, DslPost.ephemeral?)
    assert_equal(false, DslPost.local?)
  end

  def test_storage_ephemeral
    assert_equal(true, DslSession.ephemeral?)
    assert_equal(false, DslSession.replica?)
  end

  def test_storage_local_records_migrations_without_running_them
    assert_equal(true, DslDraft.local?)
    migrations = DslDraft.local_migrations
    assert_equal(2, migrations.size)
    assert_equal(1, migrations[0][:version])
    assert_equal(2, migrations[1][:version])
    assert_equal(false, migrations[0][:reset])
  end

  def test_storage_rejects_unknown_kind
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) { storage :cloud }
    end
  end

  def test_storage_non_local_rejects_block
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :ephemeral do
        end
      end
    end
  end

  def test_storage_local_requires_block
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) { storage :local }
    end
  end

  def test_storage_local_requires_at_least_one_migration
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :local do
        end
      end
    end
  end

  # ---- migrate version rules ----

  def test_migrate_outside_storage_block_raises
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        migrate 1 do |t|
        end
      end
    end
  end

  def test_migrate_requires_block
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :local do
          migrate 1
        end
      end
    end
  end

  def test_migrate_version_must_be_a_positive_integer
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :local do
          migrate 0 do |t|
          end
        end
      end
    end
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :local do
          migrate "1" do |t|
          end
        end
      end
    end
  end

  def test_first_migration_must_be_version_one
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :local do
          migrate 2 do |t|
          end
        end
      end
    end
  end

  def test_first_migration_may_be_a_reset_baseline_at_any_version
    klass = Class.new(Funicular::Model) do
      storage :local do
        migrate 5, reset: true do |t|
        end
        migrate 6 do |t|
        end
      end
    end
    migrations = klass.local_migrations
    assert_equal(5, migrations[0][:version])
    assert_equal(true, migrations[0][:reset])
  end

  def test_migration_versions_must_be_contiguous
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) do
        storage :local do
          migrate 1 do |t|
          end
          migrate 3 do |t|
          end
        end
      end
    end
  end

  # ---- refresh axis ----

  def test_refresh_manual_is_accepted
    klass = Class.new(Funicular::Model) { refresh :manual }
    assert_equal(:manual, klass.refresh_mode)
  end

  def test_refresh_defaults_to_manual
    assert_equal(:manual, DslPost.refresh_mode)
  end

  def test_refresh_auto_and_live_are_not_yet_supported
    assert_raise(NotImplementedError) do
      Class.new(Funicular::Model) { refresh :auto }
    end
    assert_raise(NotImplementedError) do
      Class.new(Funicular::Model) { refresh :live }
    end
  end

  def test_refresh_rejects_unknown_mode
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) { refresh :sometimes }
    end
  end

  # ---- table_name ----

  def test_table_name_naive_pluralization
    assert_equal("dsl_posts", DslPost.table_name)
  end

  def test_table_name_y_becomes_ies
    assert_equal("dsl_categories", DslCategory.table_name)
  end

  def test_table_name_override
    unless Object.const_defined?(:DslThing)
      Object.const_set(:DslThing, Class.new(Funicular::Model))
      DslThing.class_eval do
        table_name "gadgets"
      end
    end
    assert_equal("gadgets", DslThing.table_name)
  end

  # ---- .local entry point ----

  def test_local_on_ephemeral_raises_no_table_error
    assert_raise(Funicular::DB::NoTableError) { DslSession.local }
  end

  def test_local_returns_a_whole_table_relation
    assert_equal(true, DslPost.local.is_a?(Funicular::Relation))
    assert_equal(true, DslDraft.local.is_a?(Funicular::Relation))
  end

  def test_local_chain_builds_without_a_database
    rel = DslPost.local.where(done: true).order(created_at: :desc).limit(3)
    assert_equal(true, rel.is_a?(Funicular::Relation))
  end

  def test_materializing_without_boot_fails_loud
    assert_raise(Funicular::DB::UnavailableError) { DslPost.local.count }
    assert_raise(Funicular::DB::UnavailableError) do
      DslPost.local.where(done: false).to_a
    end
  end

  # ---- replica column derivation ----

  def test_replica_columns_derive_from_schema_excluding_binary
    expected = {
      "id" => :integer,
      "title" => :string,
      "done" => :boolean,
      "created_at" => :datetime,
    }
    assert_equal(expected, DslPost.local_columns)
  end

  def test_local_columns_without_schema_fails_loud
    assert_raise(Funicular::DB::UnavailableError) { DslCategory.local_columns }
  end

  def test_local_columns_on_local_model_fold_the_migrate_blocks
    expected = { "id" => :integer, "title" => :string, "done" => :boolean }
    assert_equal(expected, DslDraft.local_columns)
  end

  def test_local_columns_on_ephemeral_raises_no_table_error
    assert_raise(Funicular::DB::NoTableError) { DslSession.local_columns }
  end

  def test_build_from_local
    record = DslPost.build_from_local({ "title" => "hello", "done" => false })
    assert_equal("hello", record.title)
    assert_equal(false, record.done)
  end
end
