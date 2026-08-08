# Tests for belongs_to / has_many (docs/local_database.md,
# "Associations"): the <name>_id convention, the class_name: and
# foreign_key: overrides, lazy target resolution, and the guards around
# both. The model names here are the documentation's own (Post, User,
# Comment), so the derived names -- user_id, post_id, comments ->
# Comment -- are exactly what the docs promise.

class AssociationTest < Picotest::Test
  def setup
    $assoc_db = SQLite3::Database.new(":memory:")
    define_models
    Funicular::DB.apply_local_migrations($assoc_db, User)
    Funicular::DB.apply_local_migrations($assoc_db, Post)
    Funicular::DB.apply_local_migrations($assoc_db, Comment)
    Funicular::DB.apply_local_migrations($assoc_db, Editor)
    Funicular::DB.apply_local_migrations($assoc_db, AssocNs::Note)
    Funicular::DB.apply_local_migrations($assoc_db, AssocDecoy)
  end

  def teardown
    $assoc_db.close
  end

  def define_models
    return if Object.const_defined?(:Post)

    Object.const_set(:Post, Class.new(Funicular::Model))
    Post.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :title
          t.integer :user_id
          t.integer :editor_id
          t.integer :ghost_id
          t.integer :note_id
          t.integer :decoy_id
        end
      end
      belongs_to :user
      has_many :comments
      # Declared BEFORE the target exists (Editor is defined at the
      # bottom of this method): resolution must wait until first read.
      belongs_to :editor, class_name: "Editor", foreign_key: :editor_id
      belongs_to :ghost
      # A namespaced target, the only reason the "::" walk exists.
      belongs_to :note, class_name: "AssocNs::Note", foreign_key: :note_id
      # AssocNs carries no AssocDecoy of its own -- but ::AssocDecoy
      # does exist, and AssocNs (a class) inherits from Object.
      belongs_to :decoy, class_name: "AssocNs::AssocDecoy",
                         foreign_key: :decoy_id
      # Resolves to something that is not a model class.
      belongs_to :bare_module, class_name: "AssocBare", foreign_key: :decoy_id

      def self.local_db
        $assoc_db
      end

      def self.local_table_changed
        nil
      end
    end

    Object.const_set(:User, Class.new(Funicular::Model))
    User.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :name
        end
      end
      has_many :posts
      # Both halves overridden: the target is not the singularized
      # association name, and the key is not derived from User.
      has_many :written_comments, class_name: "Comment",
                                  foreign_key: :author_id

      def self.local_db
        $assoc_db
      end

      def self.local_table_changed
        nil
      end
    end

    Object.const_set(:Comment, Class.new(Funicular::Model))
    Comment.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :body
          t.integer :post_id
          t.integer :author_id
        end
      end

      def self.local_db
        $assoc_db
      end

      def self.local_table_changed
        nil
      end
    end

    # A CLASS used as a namespace: unlike a module, it inherits from
    # Object, which is exactly how a nested miss can fall through to a
    # top-level constant.
    Object.const_set(:AssocNs, Class.new)
    AssocNs.const_set(:Note, Class.new(Funicular::Model))
    AssocNs::Note.class_eval do
      table_name "assoc_notes"
      storage :local do
        migrate 1 do |t|
          t.string :body
        end
      end

      def self.local_db
        $assoc_db
      end

      def self.local_table_changed
        nil
      end
    end

    # The decoy the fall-through would find: a real, queryable model.
    Object.const_set(:AssocDecoy, Class.new(Funicular::Model))
    AssocDecoy.class_eval do
      storage :local do
        migrate 1 do |t|
          t.string :body
        end
      end

      def self.local_db
        $assoc_db
      end

      def self.local_table_changed
        nil
      end
    end

    Object.const_set(:AssocBare, Module.new)

    Object.const_set(:Editor, Class.new(Funicular::Model))
    Editor.class_eval do
      table_name "editors"
      storage :local do
        migrate 1 do |t|
          t.string :name
        end
      end

      def self.local_db
        $assoc_db
      end

      def self.local_table_changed
        nil
      end
    end
  end

  # ---- belongs_to ----

  def test_belongs_to_reads_the_target_through_the_id_convention
    user = User.local_create(name: "ada")
    post = Post.local_create(title: "hello", user_id: user.id)
    assert_equal(user.id, post.user.id)
    assert_equal("ada", post.user.name)
  end

  def test_belongs_to_returns_nil_without_a_foreign_key
    post = Post.local_create(title: "orphan")
    assert_nil(post.user)
  end

  def test_belongs_to_returns_nil_when_the_row_is_gone
    post = Post.local_create(title: "dangling", user_id: 999)
    assert_nil(post.user)
  end

  def test_belongs_to_honours_class_name_and_foreign_key
    editor = Editor.local_create(name: "grace")
    post = Post.local_create(title: "edited", editor_id: editor.id)
    assert_equal(editor.id, post.editor.id)
  end

  # ---- has_many ----

  def test_has_many_returns_a_chainable_relation
    post = Post.local_create(title: "thread")
    other = Post.local_create(title: "elsewhere")
    Comment.local_create(body: "first", post_id: post.id)
    Comment.local_create(body: "second", post_id: post.id)
    Comment.local_create(body: "unrelated", post_id: other.id)

    assert_equal(true, post.comments.is_a?(Funicular::Relation))
    assert_equal(2, post.comments.count)
    # The documented chain: post.comments.order(...).limit(...)
    bodies = post.comments.order(:id).limit(1).to_a.map { |c| c.body }
    assert_equal(["first"], bodies)
  end

  def test_has_many_derives_the_foreign_key_from_the_declaring_class
    user = User.local_create(name: "ada")
    Post.local_create(title: "mine", user_id: user.id)
    Post.local_create(title: "theirs")
    assert_equal(1, user.posts.count)
    assert_equal("mine", user.posts.first.title)
  end

  def test_has_many_honours_class_name_and_foreign_key
    user = User.local_create(name: "ada")
    Comment.local_create(body: "hers", author_id: user.id)
    Comment.local_create(body: "someone else's", author_id: user.id + 1)
    # Neither the conventional target (WrittenComment) nor the
    # conventional key (user_id) is involved.
    assert_equal(1, user.written_comments.count)
    assert_equal("hers", user.written_comments.first.body)
  end

  def test_has_many_on_an_unsaved_parent_is_empty
    # A nil id must not read as IS NULL and adopt every orphan row.
    Comment.local_create(body: "orphan")
    post = Post.new(title: "unsaved")
    assert_nil(post.id)
    assert_equal(0, post.comments.count)
  end

  def test_has_many_relation_watches_the_target_table
    # All watch needs from a relation is its event source: the role and
    # table the change events for these rows carry.
    post = Post.local_create(title: "watched")
    assert_equal([:local, "comments"], post.comments.__event_source)
  end

  # ---- target resolution ----

  def test_the_target_resolves_lazily_at_first_read
    # Post's class body declared `belongs_to :editor` (and :ghost) while
    # neither constant existed: eager resolution would have raised in
    # setup, before any of these tests ran. Editor exists by now, so
    # the first READ is what resolves it.
    editor = Editor.local_create(name: "grace")
    post = Post.local_create(title: "late", editor_id: editor.id)
    assert_equal("grace", post.editor.name)
  end

  def test_an_unresolvable_target_raises_at_first_read
    post = Post.local_create(title: "spooky", ghost_id: 1)
    error = nil
    begin
      post.ghost
    rescue => e
      error = e
    end
    assert_equal(NameError, error.class)
    # The message names the association and the constant it looked for.
    assert_equal(true, error.message.include?("ghost"))
    assert_equal(true, error.message.include?("Ghost"))
  end

  def test_a_namespaced_class_name_resolves_through_the_walk
    note = AssocNs::Note.local_create(body: "nested")
    post = Post.local_create(title: "namespaced", note_id: note.id)
    found = post.note
    assert_equal(AssocNs::Note, found.class)
    assert_equal("nested", found.body)
  end

  def test_a_nested_miss_never_falls_through_to_the_top_level
    # AssocNs has no AssocDecoy; ::AssocDecoy does, and AssocNs inherits from
    # Object. Resolving to that decoy would query a different model's
    # table under the name the app asked for.
    AssocDecoy.local_create(body: "wrong model")
    post = Post.local_create(title: "misnamed", decoy_id: 1)
    error = nil
    begin
      post.decoy
    rescue => e
      error = e
    end
    assert_equal(NameError, error.class)
    assert_equal(true, error.message.include?("AssocNs::AssocDecoy"))
  end

  def test_a_target_that_is_not_a_model_class_is_refused
    post = Post.local_create(title: "module", decoy_id: 1)
    error = nil
    begin
      post.bare_module
    rescue => e
      error = e
    end
    assert_equal(NameError, error.class)
    assert_equal(true, error.message.include?("AssocBare"))
  end

  # ---- declaration guards ----

  def test_unsupported_options_are_refused_at_declaration
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) { has_many :comments, through: :posts }
    end
    assert_raise(ArgumentError) do
      Class.new(Funicular::Model) { belongs_to :owner, polymorphic: true }
    end
  end

  def test_an_association_colliding_with_a_column_raises
    klass = Class.new(Funicular::Model) do
      table_name "collisions"
      storage :local do
        migrate 1 do |t|
          t.string :comments
        end
      end
      has_many :comments
    end
    # The declaration alone is fine; the accessor generation is where
    # the column and the association first meet.
    error = nil
    begin
      klass.local_columns
    rescue => e
      error = e
    end
    assert_equal(ArgumentError, error.class)
    assert_equal(true, error.message.include?("comments"))
  end

  def test_a_schema_attribute_colliding_with_an_association_raises
    # The replica half of the same guard: these accessors come from the
    # REST schema, so the collision surfaces at the boot-time load.
    klass = Class.new(Funicular::Model) do
      belongs_to :author
    end
    error = nil
    begin
      klass.load_schema(
        { "attributes" => { "author" => { "type" => "string" } } })
    rescue => e
      error = e
    end
    assert_equal(ArgumentError, error.class)
    assert_equal(true, error.message.include?("author"))
  end

  def test_an_association_named_after_a_framework_method_raises
    # has_many :errors would replace Validations#errors, and valid?
    # (which calls errors.clear) would then die on a Relation -- with
    # nothing said at declaration or at first read.
    error = nil
    begin
      Class.new(Funicular::Model) { has_many :errors }
    rescue => e
      error = e
    end
    assert_equal(ArgumentError, error.class)
    assert_equal(true, error.message.include?("errors"))
    # Only the framework's own API is reserved; ordinary names pass.
    klass = Class.new(Funicular::Model) { has_many :comments }
    assert_equal(true, klass.__associations.has_key?(:comments))
  end

  def test_declaring_the_same_association_twice_raises
    # Last-one-wins would drop the first reader without a word.
    error = nil
    begin
      Class.new(Funicular::Model) do
        has_many :comments
        has_many :comments, foreign_key: :other_id
      end
    rescue => e
      error = e
    end
    assert_equal(ArgumentError, error.class)
    assert_equal(true, error.message.include?("comments"))
  end
end
