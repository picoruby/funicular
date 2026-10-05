# frozen_string_literal: true

require "test_helper"

# Exercises Funicular::Schema::Associations: deriving a schema's
# belongs_to associations from ActiveRecord-style reflections, gated by
# the attribute allowlist, and the escape hatches of `associations:`.
class SchemaAssociationsTest < Minitest::Test
  KlassStub = Struct.new(:name)

  # resolved: the class name ActiveRecord resolves class_name to (inside
  # the model's namespace), or :missing when no such class loads.
  # primary_key: the target column the foreign key points at.
  Reflection = Struct.new(:name, :class_name, :foreign_key, :polymorphic,
                          :resolved, :primary_key) do
    def polymorphic? = polymorphic

    def klass
      raise NameError, "uninitialized constant #{class_name}" if resolved == :missing

      KlassStub.new(resolved || class_name.delete_prefix("::"))
    end

    def association_primary_key
      klass
      primary_key || "id"
    end
  end

  # The slice of ActiveRecord::Reflection::ClassMethods the builder reads.
  class Comment
    REFLECTIONS = [
      Reflection.new(:post, "Post", "post_id", false),
      Reflection.new(:author, "User", "author_id", false),
      Reflection.new(:secret, "Secret", "secret_id", false),
      Reflection.new(:commentable, "Commentable", "commentable_id", true),
      Reflection.new(:tenant, "Tenant", %w[tenant_id region_id], false)
    ].freeze

    def self.reflect_on_all_associations(macro)
      macro == :belongs_to ? REFLECTIONS : []
    end
  end

  ATTRIBUTES = {
    "id" => { type: "integer", readonly: true },
    "post_id" => { type: "integer", readonly: false },
    author_id: { type: "integer", readonly: false },
    "commentable_id" => { type: "integer", readonly: false },
    "tenant_id" => { type: "integer", readonly: false },
    "body" => { type: "string", readonly: false }
  }.freeze

  def build(model_class = Comment, **options)
    Funicular::Schema.build(model_class, attributes: ATTRIBUTES, routes: false,
                                         endpoints: {}, **options)[:associations]
  end

  def test_belongs_to_derives_when_its_foreign_key_is_exposed
    assert_equal(
      {
        "post" => { kind: "belongs_to", class_name: "Post", foreign_key: "post_id" },
        "author" => { kind: "belongs_to", class_name: "User", foreign_key: "author_id" }
      },
      build
    )
  end

  def test_an_unexposed_foreign_key_reveals_nothing
    refute build.key?("secret")
  end

  def test_polymorphic_and_composite_keys_do_not_derive
    refute build.key?("commentable")
    refute build.key?("tenant")
  end

  def test_associations_false_derives_nothing
    assert_equal({}, build(associations: false))
  end

  def test_explicit_entries_hide_and_add
    associations = build(associations: {
      "author" => nil,
      replies: { kind: "has_many", class_name: "Comment", foreign_key: "parent_id" }
    })
    assert_equal %w[post replies], associations.keys.sort
    assert_equal({ kind: "has_many", class_name: "Comment", foreign_key: "parent_id" },
                 associations["replies"])
  end

  def test_a_leading_double_colon_is_dropped
    klass = Class.new do
      def self.reflect_on_all_associations(_macro)
        [Reflection.new(:post, "::Post", "post_id", false)]
      end
    end
    assert_equal "Post", build(klass)["post"][:class_name]
  end

  def test_a_hand_written_entry_is_normalized_and_checked
    associations = build(associations: {
      "replies" => { "kind" => :has_many, "class_name" => "Comment", "foreign_key" => :parent_id }
    })
    assert_equal({ kind: "has_many", class_name: "Comment", foreign_key: "parent_id" },
                 associations["replies"])

    error = assert_raises(ArgumentError) do
      build(associations: { "x" => { kind: "belong_to", class_name: "Post", foreign_key: "post_id" } })
    end
    assert_includes error.message, "expected one of belongs_to, has_many"
    error = assert_raises(ArgumentError) do
      build(associations: { "x" => { kind: "belongs_to", class_name: "Post" } })
    end
    assert_includes error.message, "needs class_name: and foreign_key:"
    error = assert_raises(ArgumentError) { build(associations: { "x" => "posts" }) }
    assert_includes error.message, "must be nil or a"
  end

  def reflecting(*reflections)
    Class.new do
      define_singleton_method(:reflect_on_all_associations) { |_macro| reflections }
    end
  end

  def test_a_belongs_to_to_another_primary_key_does_not_derive
    klass = reflecting(Reflection.new(:post, "Post", "post_id", false, nil, "slug"))
    assert_equal({}, build(klass))
  end

  def test_class_name_is_the_class_activerecord_resolves
    klass = reflecting(
      Reflection.new(:post, "Post", "post_id", false, "Blog::Post"),
      Reflection.new(:author, "User", "author_id", false, :missing)
    )
    associations = build(klass)
    assert_equal "Blog::Post", associations["post"][:class_name]
    refute associations.key?("author")
  end

  def test_a_hand_written_belongs_to_needs_an_exposed_foreign_key
    error = assert_raises(ArgumentError) do
      build(associations: { "x" => { kind: "belongs_to", class_name: "User", foreign_key: "writer_id" } })
    end
    assert_includes error.message, "writer_id is not an attribute"
    # has_many's foreign key is a column of the other model.
    associations = build(associations: {
      "replies" => { kind: "has_many", class_name: "Comment", foreign_key: "parent_id" }
    })
    assert associations.key?("replies")
  end

  def test_a_hand_written_class_name_drops_a_leading_double_colon
    associations = build(associations: {
      "x" => { kind: "belongs_to", class_name: "::Post", foreign_key: "post_id" }
    })
    assert_equal "Post", associations["x"][:class_name]
  end

  def test_associations_takes_only_false_nil_or_a_hash
    [true, "post", [:post]].each do |value|
      error = assert_raises(ArgumentError) { build(associations: value) }
      assert_includes error.message, "associations: must be false, nil, or a Hash"
    end
  end

  def test_a_class_without_reflections_derives_nothing
    assert_equal({}, build(nil))
    assert_equal({}, build(Class.new))
  end
end
