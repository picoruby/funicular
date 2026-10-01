# Tests for associations derived from the server schema: load_schema
# turns each belongs_to entry into a reader, and -- for a conventional
# foreign key -- into the inverse has_many on the target. A derived
# association connects replica models the client carries, and it yields
# to a hand-written declaration, to an attribute, and to a method of the
# same name. An entry of the model's own schema outranks an inverse,
# in either load order.

class SchemaAssociationTest < Picotest::Test
  def setup
    Funicular::DB.__set_local_database_enabled(true)
    $sa_db = SQLite3::Database.new(":memory:")
    define_models
    Funicular::DB.build_replica_tables($sa_db,
      [SaPost, SaUser, SaComment, SaTag, SaNote, SaLabel, SaReview, SaBadge,
       SaSecret, SaAttachment])
  end

  def teardown
    $sa_db.close
    Funicular::DB.__set_local_database_enabled(false)
  end

  def model(name, &block)
    klass = Class.new(Funicular::Model)
    Object.const_set(name, klass)
    klass.class_eval do
      def self.local_db
        $sa_db
      end

      def self.replica_db
        $sa_db
      end

      def self.local_table_changed
        nil
      end
    end
    klass.class_eval(&block) if block
    klass
  end

  def attributes(*names)
    # @type var out: Hash[String, untyped]
    out = { "id" => { "type" => "integer", "readonly" => true } }
    names.each { |name| out[name] = { "type" => name.end_with?("_id") ? "integer" : "string" } }
    out
  end

  def belongs_to(class_name, foreign_key)
    { "kind" => "belongs_to", "class_name" => class_name, "foreign_key" => foreign_key }
  end

  def has_many(class_name, foreign_key)
    { "kind" => "has_many", "class_name" => class_name, "foreign_key" => foreign_key }
  end

  def define_models
    return if Object.const_defined?(:SaPost)

    model(:SaPost)
    model(:SaUser)
    model(:SaComment)
    # A hand-written declaration: the derived one must not replace it.
    model(:SaTag) { belongs_to :sa_post, foreign_key: :alt_post_id }
    model(:SaNote)
    model(:SaLabel)
    model(:SaReview)
    model(:SaBadge)
    model(:SaAttachment)
    model(:SaSession) { storage :ephemeral }
    # A private method of the association's name.
    model(:SaSecret) do
      def sa_post
        :mine
      end
      private :sa_post

      def reveal
        sa_post
      end
    end
    # A client-only model that merely shares the name a schema points at.
    model(:SaDraft) do
      storage :local do
        migrate 1 do |t|
          t.string :sa_attachments
        end
      end
    end

    # Inverse FIRST: SaReview derives SaPost#sa_reviews (by sa_post_id),
    # then SaPost's own schema declares sa_reviews by target_post_id.
    SaReview.load_schema({
      "attributes" => attributes("sa_post_id", "target_post_id"),
      "associations" => { "sa_post" => belongs_to("SaPost", "sa_post_id") },
    })
    SaPost.load_schema({
      "attributes" => attributes("title"),
      "associations" => { "sa_reviews" => has_many("SaReview", "target_post_id") },
    })

    # Schema entry FIRST: SaUser declares sa_badges by owner_id, then
    # SaBadge would derive the inverse of that name by sa_user_id. The
    # attribute sa_labels is loaded before SaLabel derives the inverse
    # of that name.
    SaUser.load_schema({
      "attributes" => attributes("name", "sa_labels"),
      "associations" => { "sa_badges" => has_many("SaBadge", "owner_id") },
    })
    SaBadge.load_schema({
      "attributes" => attributes("sa_user_id", "owner_id"),
      "associations" => { "sa_user" => belongs_to("SaUser", "sa_user_id") },
    })

    SaComment.load_schema({
      "attributes" => attributes("body", "sa_post_id", "author_id", "ghost_id", "sa_session_id"),
      "associations" => {
        "sa_post" => belongs_to("SaPost", "sa_post_id"),
        # ActiveRecord hands a leading "::" through.
        "author" => belongs_to("::SaUser", "author_id"),
        "ghost" => belongs_to("SaNowhere", "ghost_id"),
        "sa_session" => belongs_to("SaSession", "sa_session_id"),
        "weird" => { "kind" => "belong_to", "class_name" => "SaPost", "foreign_key" => "sa_post_id" },
      },
    })

    SaTag.load_schema({
      "attributes" => attributes("sa_post_id", "alt_post_id"),
      "associations" => { "sa_post" => belongs_to("SaPost", "sa_post_id") },
    })

    SaLabel.load_schema({
      "attributes" => attributes("sa_user_id"),
      "associations" => { "sa_user" => belongs_to("SaUser", "sa_user_id") },
    })

    # SaNote derives SaPost#sa_notes; a test then loads the SaPost schema
    # AGAIN with an attribute of that name (the late-schema order).
    SaNote.load_schema({
      "attributes" => attributes("sa_post_id"),
      "associations" => { "sa_post" => belongs_to("SaPost", "sa_post_id") },
    })

    SaSecret.load_schema({
      "attributes" => attributes("sa_post_id"),
      "associations" => { "sa_post" => belongs_to("SaPost", "sa_post_id") },
    })

    SaAttachment.load_schema({
      "attributes" => attributes("sa_draft_id"),
      "associations" => { "sa_draft" => belongs_to("SaDraft", "sa_draft_id") },
    })
  end

  def upsert(klass, attrs)
    Funicular::DB.replica_upsert($sa_db, klass, attrs)
  end

  def defined_on?(klass, name)
    klass.instance_methods.include?(name)
  end

  def test_belongs_to_derives_a_reader
    upsert(SaPost, { "id" => 1, "title" => "hello" })
    upsert(SaUser, { "id" => 7, "name" => "alice" })
    upsert(SaComment, { "id" => 10, "sa_post_id" => 1, "author_id" => 7 })
    comment = SaComment.local.find(10)
    assert_equal("hello", comment.sa_post.title)
    # class_name arrived as "::SaUser".
    assert_equal("alice", comment.author.name)
  end

  def test_a_conventional_foreign_key_derives_the_inverse_has_many
    upsert(SaPost, { "id" => 1, "title" => "hello" })
    upsert(SaComment, { "id" => 10, "sa_post_id" => 1, "body" => "a" })
    upsert(SaComment, { "id" => 11, "sa_post_id" => 1, "body" => "b" })
    upsert(SaComment, { "id" => 12, "sa_post_id" => 2, "body" => "c" })
    post = SaPost.local.find(1)
    assert_equal(["a", "b"], post.sa_comments.order(:id).to_a.map { |c| c.body })
  end

  def test_an_unconventional_foreign_key_derives_no_inverse
    # author_id -> SaUser: `user.sa_comments` would be a guess.
    assert_equal(false, defined_on?(SaUser, :sa_comments))
  end

  def test_a_model_the_client_does_not_carry_derives_nothing
    assert_equal(false, defined_on?(SaComment, :ghost))
  end

  def test_an_unknown_kind_derives_nothing
    assert_equal(false, defined_on?(SaComment, :weird))
  end

  def test_only_replica_models_take_part
    # Ephemeral target.
    assert_equal(false, defined_on?(SaComment, :sa_session))
    # A storage :local model of the same name is not the Rails model:
    # no reader toward it, and no inverse on it -- its column survives.
    assert_equal(false, defined_on?(SaAttachment, :sa_draft))
    assert_equal(false, SaDraft.__associations.has_key?(:sa_attachments))
    draft = SaDraft.new(sa_attachments: "a.png,b.png")
    assert_equal("a.png,b.png", draft.sa_attachments)
  end

  def test_a_hand_written_declaration_wins
    upsert(SaPost, { "id" => 1, "title" => "by sa_post_id" })
    upsert(SaPost, { "id" => 2, "title" => "by alt_post_id" })
    upsert(SaTag, { "id" => 5, "sa_post_id" => 1, "alt_post_id" => 2 })
    assert_equal("by alt_post_id", SaTag.local.find(5).sa_post.title)
  end

  def test_a_private_method_of_the_same_name_is_kept
    assert_equal(false, SaSecret.__associations.has_key?(:sa_post))
    assert_equal(:mine, SaSecret.new({ "id" => 1, "sa_post_id" => 1 }).reveal)
    assert_equal(false, defined_on?(SaSecret, :sa_post))
  end

  def test_a_schema_entry_replaces_an_inverse_that_arrived_first
    upsert(SaPost, { "id" => 1, "title" => "hello" })
    upsert(SaReview, { "id" => 20, "sa_post_id" => 1, "target_post_id" => 9 })
    upsert(SaReview, { "id" => 21, "sa_post_id" => 9, "target_post_id" => 1 })
    assert_equal([21], SaPost.local.find(1).sa_reviews.to_a.map { |r| r.id })
  end

  def test_a_schema_entry_keeps_its_name_from_a_later_inverse
    upsert(SaUser, { "id" => 7, "name" => "alice" })
    upsert(SaBadge, { "id" => 30, "sa_user_id" => 7, "owner_id" => 8 })
    upsert(SaBadge, { "id" => 31, "sa_user_id" => 8, "owner_id" => 7 })
    assert_equal([31], SaUser.local.find(7).sa_badges.to_a.map { |b| b.id })
  end

  def test_an_attribute_loaded_first_keeps_its_name
    upsert(SaUser, { "id" => 7, "name" => "alice", "sa_labels" => "red,blue" })
    assert_equal("red,blue", SaUser.local.find(7).sa_labels)
    assert_equal(false, SaUser.__associations.has_key?(:sa_labels))
  end

  def test_an_attribute_loaded_later_replaces_the_derived_association
    assert_equal(true, SaPost.__associations.has_key?(:sa_notes))
    SaPost.load_schema({ "attributes" => attributes("title", "sa_notes") })
    assert_equal(false, SaPost.__associations.has_key?(:sa_notes))
    post = SaPost.new({ "id" => 1, "sa_notes" => "plain attribute" })
    assert_equal("plain attribute", post.sa_notes)
  end

  def test_without_the_local_database_nothing_derives
    Funicular::DB.__set_local_database_enabled(false)
    parent = model(:SaOffParent)
    child = model(:SaOffChild)
    parent.load_schema({ "attributes" => attributes("title") })
    child.load_schema({
      "attributes" => attributes("sa_off_parent_id"),
      "associations" => { "sa_off_parent" => belongs_to("SaOffParent", "sa_off_parent_id") },
    })
    assert_equal(false, defined_on?(child, :sa_off_parent))
    assert_equal(false, defined_on?(parent, :sa_off_children))
  end
end
