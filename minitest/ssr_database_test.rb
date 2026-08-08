# frozen_string_literal: true

require "test_helper"

# The SSR contract for the local database (docs decision 18): model
# class bodies evaluate under CRuby -- declarations are recorded, no
# SQLite is touched -- but booting the database or materializing a
# local query on the server fails loud with UnavailableError, never an
# empty result.
class SSRDatabaseTest < Minitest::Test
  def setup
    # Loads the mrblib runtime under CRuby and flips Funicular.server
    # to true, exactly like a Rails SSR render.
    Funicular::SSR::Runtime.load_framework!
  end

  def test_boot_refuses_on_the_server
    error = assert_raises(Funicular::DB::UnavailableError) do
      Funicular::DB.boot(models: [], metadata: {})
    end
    assert_includes error.message, "SSR"
    # The refusal is a clean raise, not a failed state: nothing to
    # tear down, nothing latched.
    assert_equal :unbooted, Funicular::DB.boot_state
  end

  def test_a_local_class_body_evaluates_but_materializing_raises
    model = Class.new(Funicular::Model) do
      table_name "ssr_drafts"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
      end
    end
    # The declaration side worked: storage recorded, no SQLite touched.
    assert_equal true, model.local?
    # Materializing is where the server says no.
    assert_raises(Funicular::DB::UnavailableError) { model.count }
    assert_raises(Funicular::DB::UnavailableError) { model.local.to_a }
    assert_raises(Funicular::DB::UnavailableError) do
      model.local_create(title: "nope")
    end
  end

  def test_association_declarations_evaluate_but_reading_raises
    # Named constants, because the conventions read the class name:
    # SsrPost -> ssr_post_id, :ssr_comment -> SsrComment.
    Object.const_set(:SsrComment, Class.new(Funicular::Model) do
      storage :local do
        migrate 1 do |t|
          t.integer :ssr_post_id
        end
      end
    end)
    Object.const_set(:SsrPost, Class.new(Funicular::Model))
    # Declared after the constant exists, the way a `class SsrPost <
    # Funicular::Model` body reads: has_many derives its foreign key
    # from the declaring class name.
    SsrPost.class_eval do
      storage :local do
        migrate 1 do |t|
          t.integer :ssr_comment_id
        end
      end
      belongs_to :ssr_comment
      has_many :ssr_comments
    end
    # The declaration side worked: nothing resolved, no SQLite touched.
    record = SsrPost.new(ssr_comment_id: 1)
    # Reading one is a local query, and the server has no local database.
    assert_raises(Funicular::DB::UnavailableError) { record.ssr_comment }
    assert_raises(Funicular::DB::UnavailableError) { record.ssr_comments.to_a }
  ensure
    Object.send(:remove_const, :SsrPost) if Object.const_defined?(:SsrPost)
    Object.send(:remove_const, :SsrComment) if Object.const_defined?(:SsrComment)
  end
end
