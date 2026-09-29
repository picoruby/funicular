# On the browser this is picoruby-uri; under CRuby SSR it is the stdlib URI.
# Both encode_www_form the same way (space -> "+", byte-wise %XX).
require 'uri'

module Funicular
  class Model
    include Validations

    attr_reader :id

    class << self
      attr_accessor :schema, :endpoints
    end

    # Every Model subclass registers itself at definition time: the
    # boot (docs decision 19) needs the full declared set -- local
    # models for migrations, replica models for the schema-derived
    # DDL -- without asking the app to enumerate it.
    def self.inherited(subclass)
      Funicular::Model.__register_model(subclass)
    end

    def self.__register_model(subclass)
      registry = (@registered_models ||= []) # steep:ignore UnannotatedEmptyCollection
      registry << subclass
      nil
    end

    def self.__registered_models
      models = Funicular::Model.instance_variable_get(:@registered_models)
      models || []
    end

    def self.load_schema(schema_data)
      @schema = schema_data["attributes"]
      @endpoints = schema_data["endpoints"]
      # Replica column metadata derives from the schema; drop any cache.
      @local_columns = nil
      __assert_no_association_conflict(@schema.keys)

      # Generate attr_accessor dynamically based on schema
      @schema.each do |name, config|
        attr_reader name.to_sym

        unless config["readonly"]
          define_method("#{name}=") do |value|
            # @type self: Model
            instance_variable_set("@#{name}", value)
            @changed_attributes ||= {} # steep:ignore UnannotatedEmptyCollection
            @changed_attributes[name] = value
          end
        end

        # Validations are inlined per attribute by Funicular::Schema.build.
        register_schema_validations(name => config["validations"]) if config["validations"]
      end

      # Backward-compatible: a top-level { attr => rules } block also works.
      register_schema_validations(schema_data["validations"])
    end

    # validations: { "attr" => { "presence" => true, "length" => { "maximum" => 30 } } }
    def self.register_schema_validations(validations)
      return unless validations.is_a?(Hash)
      validations.each do |attribute, rules|
        next unless rules.is_a?(Hash)
        rules.each do |kind, opts|
          options = normalize_validation_options(kind, opts)
          # nil means the options could not be materialized on this runtime
          # (e.g. a format regex the JS RegExp engine rejects): drop that one
          # validator instead of failing the whole schema load.
          next if options.nil?
          add_schema_validator(attribute, kind, options)
        end
      end
    end

    # Turn JSON-shaped validator options into the Ruby options the client
    # validators expect (notably rebuilding a Regexp for `format`). Integer
    # Regexp flags are used so this works the same under CRuby and the client
    # JS RegExp wrapper.
    def self.normalize_validation_options(kind, opts)
      return opts unless opts.is_a?(Hash)
      if kind.to_s == "format" && opts["with"]
        flags = opts["flags"].to_s
        bits = 0
        bits |= Regexp::IGNORECASE if flags.include?("i")
        bits |= Regexp::MULTILINE if flags.include?("m")
        begin
          # Annotated so the record type {with: Regexp} does not reject
          # the boolean flags added below.
          normalized = { with: Regexp.new(opts["with"], bits) } #: Hash[Symbol, untyped]
          normalized[:allow_nil] = true if opts["allow_nil"]
          normalized[:allow_blank] = true if opts["allow_blank"]
          normalized
        rescue => e
          # Schema regex translation is best-effort; a source this engine
          # cannot compile must not take down the whole boot sequence.
          # Name the pattern (truncated) so the offending model/attribute
          # can be found among many schemas loading at boot.
          source = opts["with"].to_s
          source = "#{source[0, 60]}..." if 60 < source.length
          puts "[Funicular] Skipping format validator (#{e.class}: #{e.message}; pattern: #{source})"
          nil
        end
      else
        opts
      end
    end

    # ---- local-database declaration DSL (docs/local_database.md) --------
    #
    #   storage :replica (default)  server data, mirrored into the replica
    #   storage :ephemeral          REST only, no local table
    #   storage :local do ... end   client-only table built by migrate blocks
    #
    # The migrate blocks are only RECORDED at class-definition time (their
    # version rules validated); they execute against the local database at
    # boot, in the migration runner.

    def self.storage(kind, &block)
      # refresh is a replica-only axis: a local table has no server to
      # refresh from, and an ephemeral model has no table at all. The
      # check lives in BOTH declarations because either can come
      # first in the class body.
      # The message reads the kind through an unnarrowed alias: inside
      # the branch below the comparisons leave `kind` with no type
      # steep will call #inspect on.
      # @type var declared: Symbol
      declared = kind
      if @refresh_mode && (kind == :local || kind == :ephemeral)
        raise ArgumentError,
          "storage #{declared.inspect} cannot follow a refresh " \
          "declaration (refresh applies to replica models only)"
      end
      # A storage change invalidates cached column metadata.
      @local_columns = nil
      if kind == :local
        unless block
          raise ArgumentError,
            "storage :local requires a block with migrate declarations"
        end
        @storage_kind = kind
        @local_migrations = []
        @collecting_migrations = true
        begin
          block.call
        ensure
          @collecting_migrations = false
        end
        validate_local_migrations
      elsif kind == :replica || kind == :ephemeral
        if block
          raise ArgumentError, "only storage :local takes a block"
        end
        @storage_kind = kind
      else
        raise ArgumentError,
          "storage must be :replica, :ephemeral, or :local, got #{kind.inspect}"
      end
      kind
    end

    def self.storage_kind
      @storage_kind || :replica
    end

    def self.replica?
      storage_kind == :replica
    end

    def self.ephemeral?
      storage_kind == :ephemeral
    end

    def self.local?
      storage_kind == :local
    end

    # Record one numbered migration block. Only valid inside storage :local.
    def self.migrate(version, reset: false, &block)
      migrations = @local_migrations
      unless @collecting_migrations && migrations
        raise ArgumentError,
          "migrate must be declared inside a storage :local block"
      end
      unless version.is_a?(Integer) && 1 <= version
        raise ArgumentError,
          "migrate version must be a positive Integer, got #{version.inspect}"
      end
      unless block
        raise ArgumentError, "migrate #{version} requires a block"
      end
      migrations << { version: version, reset: reset, block: block }
    end

    def self.local_migrations
      @local_migrations
    end

    # Baseline rules (docs): the first retained block is version 1 unless
    # it is `reset: true` (then any positive version); contiguous after
    # that. A gap means a deleted non-baseline block -- fail at class eval.
    def self.validate_local_migrations
      migrations = @local_migrations
      if migrations.nil? || migrations.empty?
        raise ArgumentError, "storage :local requires at least one migrate block"
      end
      first = migrations[0]
      unless first[:version] == 1 || first[:reset]
        raise ArgumentError,
          "the first migrate block must be version 1 (or reset: true), " \
          "got #{first[:version]}"
      end
      i = 1
      while i < migrations.size
        expected = migrations[i - 1][:version] + 1
        unless migrations[i][:version] == expected
          raise ArgumentError,
            "migrate versions must be contiguous: expected #{expected}, " \
            "got #{migrations[i][:version]}"
        end
        i += 1
      end
    end

    # v1 implements only the default :manual (freshness is explicit fetch);
    # :auto and :live are reserved and rejected at class-definition time.
    def self.refresh(mode)
      kind = @storage_kind
      if kind == :local || kind == :ephemeral
        raise ArgumentError,
          "refresh does not apply to storage #{storage_kind.inspect} " \
          "(refresh applies to replica models only)"
      end
      if mode == :auto
        raise NotImplementedError,
          "refresh :auto is not yet supported (v1 is :manual only)"
      end
      if mode == :live
        raise NotImplementedError,
          "refresh :live is not yet supported (v1 is :manual only)"
      end
      unless mode == :manual
        raise ArgumentError, "refresh must be :manual, got #{mode.inspect}"
      end
      @refresh_mode = mode
    end

    def self.refresh_mode
      @refresh_mode || :manual
    end

    # ---- associations (docs/local_database.md, "Associations") ----------
    #
    # Local-query sugar over the <name>_id convention, and nothing more:
    #
    #   post.user      -> User.local.find_by(id: post.user_id)
    #   post.comments  -> Comment.local.where(post_id: post.id)
    #
    # Readers only. The foreign key is assigned the plain way
    # (post.user_id = user.id), so there is no second, hidden path into
    # the column and no dirty-tracking special case.

    def self.belongs_to(name, class_name: nil, foreign_key: nil, **rest)
      __reject_association_options(:belongs_to, name, rest)
      key = name.to_sym
      target = (class_name || __camelize(key.to_s)).to_s
      fk = (foreign_key || "#{key}_id").to_s
      __register_association(key)
      define_method(key) do
        # @type self: Model
        value = send(fk)
        if value.nil?
          # No foreign key, no target row -- and no query to run.
          nil
        else
          self.class.__association_target(key, target).local.find_by(id: value)
        end
      end
      nil
    end

    def self.has_many(name, class_name: nil, foreign_key: nil, **rest)
      __reject_association_options(:has_many, name, rest)
      key = name.to_sym
      target = (class_name || __camelize(__singularize(key.to_s))).to_s
      fk = (foreign_key || "#{demodulized_snake_name}_id").to_s
      __register_association(key)
      define_method(key) do
        # @type self: Model
        # An unsaved parent owns nothing: the empty-array condition
        # compiles to 1=0, where a nil would read as IS NULL and hand
        # this record every orphan row in the table.
        none = [] #: Array[untyped]
        value = id.nil? ? none : id
        self.class.__association_target(key, target).local.where(fk => value)
      end
      nil
    end

    def self.__reject_association_options(kind, name, rest)
      return nil if rest.empty?
      raise ArgumentError,
        "#{kind} #{name.to_sym.inspect}: #{rest.keys.inspect} not supported " \
        "in v1 (only class_name: and foreign_key:; through, eager loading, " \
        "and polymorphic associations are not implemented)"
    end

    # The registry exists for two readers: the memoized target class,
    # and the column/attribute collision guard.
    def self.__register_association(key)
      registry = (@associations ||= {}) # steep:ignore UnannotatedEmptyCollection
      # Last-one-wins would be the same silent shrug as ignoring
      # through:: the reader defined first is simply gone.
      if registry.has_key?(key)
        raise ArgumentError,
          "#{self}: the association #{key.inspect} is already declared"
      end
      __assert_association_name_free(key)
      registry[key] = { klass: nil }
      nil
    end

    # Unlike every other generated accessor, an association reader is
    # defined unconditionally -- so `has_many :errors` would replace
    # Validations#errors, and valid? (which calls errors.clear) would
    # die on a Relation, at neither declaration nor first read.
    #
    # The reserved set is Funicular::Model's OWN instance API: a
    # subclass's column accessors live on the subclass, so they can
    # never appear here, whenever they are generated. Subtracting
    # Object's keeps generic names (hash, send) out of it. A method the
    # model itself hand-wrote is deliberately NOT covered -- catching
    # it would only work when the `def` precedes the declaration.
    def self.__assert_association_name_free(key)
      # One fixed set per process; the framework's API stops changing
      # once mrblib is loaded, well before any app model declares.
      reserved = Funicular::Model.instance_variable_get(:@reserved_names) ||
        Funicular::Model.instance_variable_set(
          :@reserved_names,
          Funicular::Model.instance_methods - Object.instance_methods)
      return nil unless reserved.include?(key)
      raise ArgumentError,
        "#{self}: the association #{key.inspect} would replace " \
        "Funicular::Model##{key}; pick another name"
    end

    def self.__associations
      @associations || {}
    end

    # Resolved lazily, at first read: model files load in sorted filename
    # order, so `belongs_to :user` in post.rb must not demand the User
    # constant while user.rb is still unloaded. Only successes are
    # memoized -- a class that loads later still resolves.
    def self.__association_target(key, class_name)
      entry = __associations[key]
      cached = entry && entry[:klass]
      return cached if cached
      klass = __resolve_association_constant(key, class_name)
      entry[:klass] = klass if entry
      klass
    end

    # Convention-derived target names never carry "::", so the walk is
    # here for class_name: strings alone.
    def self.__resolve_association_constant(key, class_name)
      parts = class_name.split("::")
      # @type var owner: untyped
      owner = Object
      i = 0
      while i < parts.size
        part = parts[i].to_sym
        # inherit: false. A class used as a namespace inherits from
        # Object, so the default lookup would answer "Admin::User" with
        # the top-level ::User when Admin carries no User of its own --
        # a typo resolving to a DIFFERENT model, in the one path whose
        # job is to fail clearly. const_get takes no such argument here
        # (picoruby: one argument only), but it does not need one: an
        # own constant wins the lookup, and the check below is what
        # decides whether there is one.
        unless owner.is_a?(Module) && owner.const_defined?(part, false)
          raise NameError, __unresolvable_association(key, class_name)
        end
        owner = owner.const_get(part)
        i += 1
      end
      # A module or a plain value has no `.local` behind it; same
      # verdict, same message.
      unless owner.is_a?(Class)
        raise NameError, __unresolvable_association(key, class_name)
      end
      owner
    end

    def self.__unresolvable_association(key, class_name)
      "#{self}: association #{key.inspect} cannot resolve the model " \
      "class #{class_name}; declare class_name:, or make sure the model " \
      "is one the client carries"
    end

    # A column (or REST attribute) named like a declared association:
    # the association reader would shadow it silently while the
    # generated writer kept writing the column. Raised where the two
    # first meet -- the accessor generation, which is the first instance
    # path on local models and the schema load on the others.
    def self.__assert_no_association_conflict(names)
      registry = @associations
      return nil unless registry
      i = 0
      while i < names.size
        name = names[i]
        if registry.has_key?(name.to_sym)
          raise ArgumentError,
            "#{self}: the association #{name.to_sym.inspect} and the " \
            "attribute of the same name would shadow each other; rename one"
        end
        i += 1
      end
      nil
    end

    # Reader and override in one: `table_name` returns the table name
    # (naive pluralization of the class name: +s, y->ies),
    # `table_name "things"` overrides it.
    def self.table_name(explicit = nil)
      if explicit
        @table_name = explicit.to_s
      else
        @table_name ||= derive_table_name
      end
    end

    def self.derive_table_name
      __pluralize(demodulized_snake_name)
    end

    # "Admin::BlogPost" -> "blog_post". The singular half of
    # derive_table_name; has_many reuses it for the foreign key.
    def self.demodulized_snake_name
      parts = to_s.split("::")
      base = parts[parts.size - 1] || ""
      snake = ""
      i = 0
      while i < base.length
        c = base.getbyte(i)
        if c && 65 <= c && c <= 90 # A-Z
          snake += "_" unless i == 0
          snake += (c + 32).chr
        else
          char = base[i]
          snake += char if char
        end
        i += 1
      end
      snake
    end

    def self.__pluralize(name)
      if name.end_with?("y")
        "#{name[0, name.length - 1]}ies"
      else
        "#{name}s"
      end
    end

    # The exact inverse of __pluralize. Irregular names are the caller's
    # job, through class_name: -- the same deal table_name offers.
    def self.__singularize(name)
      if name.end_with?("ies")
        "#{name[0, name.length - 3]}y"
      elsif name.end_with?("s")
        name[0, name.length - 1].to_s
      else
        name
      end
    end

    def self.__camelize(name)
      parts = name.split("_")
      out = ""
      i = 0
      while i < parts.size
        part = parts[i]
        head = part[0]
        if head
          out += head.upcase
          out += part[1, part.length - 1].to_s
        end
        i += 1
      end
      out
    end

    # The marked local/cache view (source-of-truth contract): a Relation
    # over the whole local table. Ephemeral models have no table behind it.
    def self.local
      if ephemeral?
        raise Funicular::DB::NoTableError,
          "#{to_s} is storage :ephemeral; it has no local table"
      end
      Relation.new(self)
    end

    # ---- Relation protocol (see mrblib/relation.rb) ---------------------

    # Column name -> declared type. For replica models this derives from
    # the server schema: binary attributes never reach the replica and the
    # id type follows the server. Local models fold their migrate blocks
    # (pure metadata; works before boot).
    def self.local_columns
      if ephemeral?
        raise Funicular::DB::NoTableError,
          "#{to_s} is storage :ephemeral; it has no local table"
      end
      cols = @local_columns
      return cols if cols
      if local?
        # The fold runs HERE, lazily, not at class-definition time: the
        # docs promise migrate blocks are only recorded at class eval.
        # Any instance path (new/create/find) lands here first, so the
        # accessors exist before they can be called.
        folded = Funicular::DB.fold_local_columns(self)
        define_local_accessors(folded)
        @local_columns = folded
      else
        @local_columns = derive_replica_columns
      end
    end

    def self.derive_replica_columns
      sch = @schema
      unless sch
        raise Funicular::DB::UnavailableError,
          "#{to_s}: no schema loaded; replica columns derive from the " \
          "server schema at boot"
      end
      # @type var derived: Hash[String, Symbol]
      derived = {}
      names = sch.keys
      i = 0
      while i < names.size
        attr_name = names[i]
        type = (sch[attr_name]["type"] || "string").to_sym
        derived[attr_name] = type unless type == :binary
        i += 1
      end
      derived
    end

    # The handle local queries run against: the guarded proxy for this
    # model's storage role, installed by Funicular::DB.boot. Before the boot
    # every materializer fails loud (UnavailableError -- SSR included).
    # Storage-local models also encounter the SchemaTooNew lockdown here,
    # the funnel every model-level local operation passes through.
    def self.local_db
      Funicular::DB.__model_local_db(self)
    end

    # The handle REST write-through applies replica rows to: the
    # guarded replica proxy from DB.boot -- raw connections are never
    # exposed globally. While it is nil (not booted), write-through
    # stays inert and REST works standalone.
    def self.replica_db
      Funicular::DB.__model_replica_db
    end

    # Drop this table and rebuild it from its migrate baseline (docs
    # decision 7): the programmatic reset for one client-only table.
    # Writer (or volatile) tab only; lifts a SchemaTooNew lockdown
    # when the whole declared set passes again afterwards.
    def self.reset_local
      unless local?
        raise Funicular::DB::NoTableError,
          "#{to_s} is not storage :local; reset_local rebuilds " \
          "client-only tables"
      end
      Funicular::DB.reset_local_table(self)
    end

    def self.build_from_local(attrs)
      record = new({})
      record.__hydrate_local(attrs)
      record
    end

    # Called by Relation#delete_all, the local CRUD writers, and the
    # replica apply path after a framework-managed write: the change-
    # event bus takes it from here (snapshot scheduling joins in at
    # boot).
    def self.local_table_changed
      Funicular::DB.notify_changed(self)
    end

    # The public change-subscription primitive (docs decision 10):
    # watch's Relation-only contract covers lists; for hashes, counts,
    # or raw-SQL-derived state, subscribe here and patch state in the
    # handler. Returns a subscription for off_change.
    def self.on_change(&block)
      unless block
        raise ArgumentError, "on_change requires a block"
      end
      if ephemeral?
        raise Funicular::DB::NoTableError,
          "#{to_s} is storage :ephemeral; it has no local table to watch"
      end
      Funicular::DB.__ensure_local_database_enabled(:on_change)
      Funicular::DB.subscribe(replica? ? :replica : :local,
                              table_name, &block)
    end

    def self.off_change(subscription)
      Funicular::DB.unsubscribe(subscription)
    end

    # ---- write-through (docs decision 5) --------------------------------
    # Successful REST responses mirror rows into the replica through the
    # single apply entry point, BEFORE user callbacks run. Inert on
    # non-replica models and until DB.boot installs the replica handle.

    def self.__write_through_upsert(attrs)
      return unless replica?
      db = replica_db
      return unless db
      Funicular::DB.replica_upsert(db, self, attrs)
    end

    def self.__write_through_upsert_all(rows)
      return unless replica?
      db = replica_db
      return unless db
      Funicular::DB.replica_upsert_all(db, self, rows)
    end

    def self.__write_through_delete(id)
      return unless replica?
      db = replica_db
      return unless db
      Funicular::DB.replica_delete(db, self, id)
    end

    # Absorb rows this page already holds -- the state a server-rendered
    # page arrived with, say -- into the replica, exactly as a fetched
    # collection would land (one transaction, one change event). The
    # SSR payload is the first representation of the resource this page
    # saw; absorbing it lets a `watch` start from it instead of from an
    # empty table. A no-op without a replica.
    def self.absorb(rows)
      return nil if rows.nil? || rows.empty?
      __write_through_upsert_all(rows)
      nil
    end

    # Generate attribute readers/writers from the migrate fold, mirroring
    # what load_schema does from the REST schema. Methods the model class
    # ALREADY defines (a hand-written reader like `def title`) are
    # preserved: only the missing half of each accessor pair is
    # generated. The snapshot is taken before anything is generated, so
    # our own accessors never mask a later regeneration.
    def self.define_local_accessors(columns)
      existing = instance_methods
      names = columns.keys
      __assert_no_association_conflict(names)
      names_size = names.size
      i = 0
      while i < names_size
        name = names[i]
        # One method call per column: the writer's closure must capture
        # its own `name` binding. Creating it inside this while body
        # would share ONE variable across every writer (unlike an each
        # block parameter), leaving all of them bound to the last column.
        define_local_accessor(name, existing) unless name == "id"
        i += 1
      end
    end

    # Writers track dirtiness against @local_baseline -- the values as
    # last persisted/loaded -- not against the previous assignment, so
    # assigning a value BACK cancels the change and the documented
    # "update with no actual changes is a no-op" holds across
    # intermediate assignments. A hand-written writer is kept and
    # WRAPPED: it runs first, then the resulting ivar (its normalized
    # value) feeds the same tracking -- otherwise custom writers would
    # silently opt out of dirty tracking and update would no-op.
    def self.define_local_accessor(name, existing)
      attr_reader name.to_sym unless existing.include?(name.to_sym)
      custom = "__custom_#{name}="
      return if existing.include?(custom.to_sym)
      if existing.include?("#{name}=".to_sym)
        alias_method custom, "#{name}="
        define_method("#{name}=") do |value|
          # @type self: Model
          old = instance_variable_get("@#{name}")
          send(custom, value)
          __track_local_change(name, instance_variable_get("@#{name}"), old)
        end
      else
        define_method("#{name}=") do |value|
          # @type self: Model
          old = instance_variable_get("@#{name}")
          instance_variable_set("@#{name}", value)
          __track_local_change(name, value, old)
        end
      end
    end

    # Merge bare keywords over the positional attrs hash so a keyword
    # wins per ATTRIBUTE, not per literal key: initialize reads string
    # keys first, so the keyword's string-keyed twin must go away too.
    def self.merge_keyword_attrs(attrs, kw)
      return attrs if kw.empty?
      merged = attrs.merge(kw)
      keys = kw.keys
      keys_size = keys.size
      i = 0
      while i < keys_size
        merged.delete(keys[i].to_s)
        i += 1
      end
      merged
    end

    # Synchronous, validated create for storage :local (docs, "Local
    # models"): returns the instance -- persisted with its assigned id,
    # or unsaved (id nil) with errors when validation fails.
    def self.local_create(attrs = {})
      unless local?
        if replica?
          raise Funicular::DB::ReplicaWriteError,
            "#{to_s}.local_create is not available on replica models; " \
            "the server owns replica rows (use #{to_s}.create)"
        end
        raise Funicular::DB::NoTableError,
          "#{to_s} has no local table; local_create is available only on " \
          "storage :local models"
      end
      record = new(attrs)
      return record unless record.valid?
      record.__local_insert
      record
    end

    # ---- bare-class alias (source-of-truth contract) ---------------------
    # On storage :local models the bare class IS the local view, so the
    # ActiveRecord-style query methods hang off it directly. On other
    # storage kinds they do not exist -- the error points at `.local`.

    def self.local_query(method_name)
      unless local?
        raise NoMethodError,
          "#{to_s}.#{method_name} only exists on storage :local models; " \
          "the marked local view is #{to_s}.local.#{method_name}"
      end
      local
    end

    def self.where(conditions = nil, *binds)
      local_query("where").where(conditions, *binds)
    end

    def self.order(*args)
      local_query("order").order(*args)
    end

    def self.limit(n)
      local_query("limit").limit(n)
    end

    def self.offset(n)
      local_query("offset").offset(n)
    end

    def self.count
      local_query("count").count
    end

    def self.first
      local_query("first").first
    end

    def self.exists?
      local_query("exists?").exists?
    end

    def self.find_by(conditions)
      local_query("find_by").find_by(conditions)
    end

    def self.delete_all
      local_query("delete_all").delete_all
    end

    def initialize(attributes = {})
      @changed_attributes = {}
      # Attribute names come from the REST schema, or from the migrate
      # fold on storage :local models (which have no REST schema).
      # Key-presence lookups, not `||`: a string-keyed false (boolean
      # columns) must not fall through to the symbol key and come back
      # nil.
      klass = self.class
      is_local = klass.local?
      names = is_local ? klass.local_columns.keys : klass.schema.keys
      # Which attributes were EXPLICITLY given (even as nil) is recorded:
      # the local INSERT path must distinguish "omitted, apply the SQL
      # DEFAULT" from "explicit nil, bind NULL".
      # @type var provided: Hash[String, bool]
      provided = {}
      names_size = names.size
      i = 0
      while i < names_size
        name = names[i]
        sym = name.to_sym
        if attributes.has_key?(name)
          value = attributes[name]
          provided[name] = true
        elsif attributes.has_key?(sym)
          value = attributes[sym]
          provided[name] = true
        else
          value = nil
        end
        if is_local && provided[name] && !(name == "id")
          # User input goes through the writer, so a hand-written
          # normalizing writer applies on create exactly as on update.
          # Hydration from the database does NOT come through here (see
          # build_from_local / __hydrate_local): stored values are
          # already normalized.
          send("#{name}=", value)
        else
          unless is_local || value.nil?
            # REST values pass through the shared codec, so JSON strings
            # and 1/0 become the same Ruby types local queries return
            # (docs decision 8: Post.all and Post.local.find agree).
            value = Funicular::DB::Codec.decode(
              klass.rest_attribute_type(name), value)
          end
          instance_variable_set("@#{name}", value)
        end
        i += 1
      end
      @provided_attributes = provided
    end

    # The schema-declared type of a REST attribute (nil when unknown);
    # feeds the shared codec on the REST side.
    def self.rest_attribute_type(name)
      sch = @schema
      return nil unless sch
      config = sch[name]
      return nil unless config
      (config["type"] || "string").to_sym
    end

    # A record not yet in the local table (docs: "a new record is one
    # whose id is nil; create assigns the id from the inserted row").
    def new_record?
      @id.nil?
    end

    # Shared dirty tracking behind every generated/wrapped local writer.
    def __track_local_change(name, value, old)
      @changed_attributes ||= {} # steep:ignore UnannotatedEmptyCollection
      baseline = @local_baseline
      if baseline && baseline.has_key?(name)
        if value == baseline[name]
          @changed_attributes.delete(name)
        else
          @changed_attributes[name] = value
        end
      elsif !(value == old)
        # No baseline yet (a hand-built record): previous-value compare.
        @changed_attributes[name] = value
      end
    end

    # ---- REST: endpoints and paths ---------------------------------------

    # Raised when a REST call names an endpoint the schema does not
    # declare. Endpoints derive from the Rails routes (Funicular::Schema)
    # or are listed by hand; either way a missing one is a bug to fix,
    # never a silent no-op.
    class EndpointError < StandardError; end

    # Canonical endpoint name -> the Rails action it derives from (for
    # the EndpointError hint).
    ENDPOINT_ACTIONS = {
      "all" => "index",
      "find" => "show",
      "create" => "create",
      "update" => "update",
      "destroy" => "destroy",
    }

    def self.__endpoint(name)
      eps = @endpoints
      endpoint = eps ? eps[name] : nil
      if endpoint.nil?
        available = eps && !eps.empty? ? eps.keys.join(", ") : "none"
        action = ENDPOINT_ACTIONS[name] || name
        raise EndpointError,
          "#{to_s} has no '#{name}' endpoint (available: #{available}); " \
          "declare it in the schema or add a route for " \
          "#{derive_table_name}##{action}"
      end
      endpoint
    end

    # Fill the :name segments of an endpoint path. Values come from
    # source (a Hash keyed by String or Symbol, or nil); one segment
    # still empty afterwards takes identifier -- the record id, whatever
    # the route calls it (:id, :slug, ...). Anything still missing is
    # an ArgumentError: a request never leaves with a literal ":post_id"
    # in its URL. Returns [path, consumed], consumed being the source
    # keys used, as Strings, so a caller can keep them out of the
    # query string.
    def self.__expand_path(path, source, identifier, context)
      segments = path.split("/")
      # @type var consumed: Array[String]
      consumed = []
      # @type var missing: Array[Integer]
      missing = []
      i = 0
      while i < segments.size
        segment = segments[i]
        if segment.start_with?(":")
          name = segment[1..-1].to_s
          value = __path_value(source, name)
          if value.nil?
            missing << i
          else
            segments[i] = __path_segment(value)
            consumed << name
          end
        end
        i += 1
      end
      if missing.size == 1 && !identifier.nil?
        segments[missing[0]] = __path_segment(identifier)
        missing = []
      end
      unless missing.empty?
        raise ArgumentError,
          "missing #{segments[missing[0]]} for #{context}; pass it as a " \
          "keyword or fix the route"
      end
      [segments.join("/"), consumed]
    end

    def self.__path_value(source, name)
      return nil unless source
      return source[name] if source.has_key?(name)
      sym = name.to_sym
      return source[sym] if source.has_key?(sym)
      nil
    end

    # A value as one URL path segment: form-encoded (so "/" and "?"
    # cannot break out of the segment), with the space as %20, not "+".
    def self.__path_segment(value)
      URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end

    # params minus the keys the path consumed: what becomes the query
    # string.
    def self.__query_params(params, consumed)
      # @type var query: Hash[untyped, untyped]
      query = {}
      return query if params.nil?
      params.each do |key, value|
        query[key] = value unless consumed.include?(key.to_s)
      end
      query
    end

    # The attributes of this record, as a path source for the instance
    # methods (update/destroy/reload): /posts/:post_id/comments/:id
    # fills from @post_id and @id.
    def __path_source
      # @type var source: Hash[String, untyped]
      source = {}
      names = self.class.schema.keys
      i = 0
      while i < names.size
        name = names[i]
        source[name] = instance_variable_get("@#{name}")
        i += 1
      end
      source
    end

    # The Errors a Rails action rendered with
    # `render json: { errors: record.errors }, status: :unprocessable_content`,
    # nil when the failure body has another shape (a plain message).
    def self.__server_errors(response)
      data = response.data
      return nil unless data.is_a?(Hash)
      hash = data["errors"]
      return nil unless hash.is_a?(Hash)
      Errors.from_hash(hash)
    end

    # ---- REST: conditional GET (the replica as an HTTP cache) ------------
    #
    # A replica model remembers the ETag of every GET it made, keyed by
    # path, in the replica database's meta table (per user namespace,
    # gone with wipe). The next GET of the same path carries
    # If-None-Match; a 304 is answered from the replica rows the entry
    # lists -- no upsert, so no change event. Rails answers 304 through
    # Rack::ETag + Rack::ConditionalGet with no controller code, and
    # `stale?`/`fresh_when` skip the rendering too. A response with
    # Cache-Control: no-store is never remembered.

    HTTP_CACHE_PREFIX = "http:"

    def self.__http_cache_db
      return nil unless replica?
      replica_db
    end

    def self.__http_cache_entry(path)
      db = __http_cache_db
      return nil unless db
      raw = Funicular::DB.read_meta(db, "#{HTTP_CACHE_PREFIX}#{path}")
      return nil unless raw
      begin
        entry = JSON.parse(raw)
      rescue
        return nil
      end
      return nil unless entry.is_a?(Hash)
      return nil unless entry["etag"] && entry["ids"].is_a?(Array)
      entry
    end

    def self.__store_http_cache_entry(path, response, ids)
      db = __http_cache_db
      return unless db
      key = "#{HTTP_CACHE_PREFIX}#{path}"
      etag = response.etag
      if etag.nil? || response.no_store? || ids.include?(nil)
        # Nothing to validate against next time; drop a stale entry too.
        Funicular::DB.delete_meta(db, key)
        return
      end
      Funicular::DB.store_meta(db, key,
        JSON.generate({ "etag" => etag, "ids" => ids }))
    end

    def self.__forget_http_cache_entry(path)
      db = __http_cache_db
      return unless db
      Funicular::DB.delete_meta(db, "#{HTTP_CACHE_PREFIX}#{path}")
    end

    # The instances a 304 stands for, in the order the server last sent
    # them; nil when any row is missing from the replica (the entry is
    # then unusable and the caller refetches unconditionally).
    def self.__instances_from_replica(ids)
      # @type var instances: Array[Model]
      instances = []
      i = 0
      while i < ids.size
        record = local.find_by(id: ids[i])
        return nil unless record
        instances << record
        i += 1
      end
      instances
    end

    def self.__log_not_modified(path)
      puts "[Funicular::HTTP] GET #{path} 304 -> replica" if Funicular.env.development?
    end

    # ---- REST: the uniform interface ------------------------------------

    # params fill the path's :segments first (Comment.all(post_id: 3)
    # -> GET /posts/3/comments); the rest becomes the query string.
    # endpoint_name: names a collection route other than index
    # (`get :published, on: :collection` -> "published").
    def self.all(params = {}, endpoint_name: "all", **rest, &block)
      # Bare keywords are params too (Post.all(page: 2), as before
      # endpoint_name: existed); endpoint_name: is reserved. String keys
      # arrive as keywords as well, so this is a plain merge.
      unless rest.empty?
        # @type var merged: Hash[untyped, untyped]
        merged = {}
        params.each { |key, value| merged[key] = value } if params
        rest.each { |key, value| merged[key] = value }
        params = merged
      end
      if local?
        # The bare class is an alias for .local: Draft.all IS the
        # whole-table Relation, and there is no REST side to call.
        if block
          raise ArgumentError,
            "#{to_s}.all takes no block on storage :local (no REST side)"
        end
        unless params.nil? || params.empty?
          raise ArgumentError,
            "#{to_s}.all takes no params on storage :local (no REST side)"
        end
        return local
      end
      endpoint = __endpoint(endpoint_name)
      expanded = __expand_path(endpoint["path"], params, nil, "#{to_s}.all")
      path = expanded[0]
      query = __query_params(params, expanded[1])
      path = "#{path}?#{URI.encode_www_form(query)}" unless query.empty?
      __fetch_collection(path, true, &block)
    end

    # GET a collection into the replica (fetch-through, docs decision 5).
    # conditional: consult the ETag cache. A 304 the cache cannot honor
    # (rows gone from the replica) retries once unconditionally.
    def self.__fetch_collection(path, conditional, &block)
      entry = conditional ? __http_cache_entry(path) : nil
      headers = entry ? { "If-None-Match" => entry["etag"] } : nil
      # A wipe between issue and response makes the response stale: it
      # is discarded, never applied -- a logout can never resurrect the
      # previous session's rows (docs decision 17).
      generation = Funicular::DB.mutation_generation
      HTTP.get(path, headers: headers) do |response|
        if Funicular::DB.stale_generation?(generation)
          block.call(nil, Funicular::DB.stale_response_error) if block
        elsif response.not_modified?
          instances = entry ? __instances_from_replica(entry["ids"]) : nil
          if instances
            __log_not_modified(path)
            block.call(instances, nil) if block
          elsif conditional
            __forget_http_cache_entry(path)
            __fetch_collection(path, false, &block)
          else
            block.call(nil, "unexpected 304 for GET #{path}") if block
          end
        elsif response.error?
          block.call(nil, response.error_message) if block
        else
          rows = response.data
          rows_size = rows.size
          # Fetch-through (docs decision 5): the whole collection lands
          # in the replica -- one transaction, one change event -- before
          # anything else sees it.
          __write_through_upsert_all(rows)
          # @type var instances: Array[Model]
          instances = []
          # @type var ids: Array[untyped]
          ids = []
          i = 0
          while i < rows_size
            row = rows[i]
            instances << new(row)
            ids << (row.is_a?(Hash) ? row["id"] : nil)
            i += 1
          end
          __store_http_cache_entry(path, response, ids)
          block.call(instances, nil) if block
        end
      end
    end

    # path_params fill the path's other :segments
    # (Comment.find(7, post_id: 3) -> GET /posts/3/comments/7); id fills
    # the one left, whatever the route calls it.
    def self.find(id = nil, endpoint_name: "find", model_class: nil, **path_params, &block)
      if local?
        if block
          raise ArgumentError,
            "#{to_s}.find is synchronous on storage :local and takes no block"
        end
        return local.find(id)
      end
      endpoint = __endpoint(endpoint_name)
      expanded = __expand_path(endpoint["path"], path_params, id, "#{to_s}.find")
      __fetch_record(expanded[0], model_class || self, true, &block)
    end

    # GET one record into klass's replica. The ETag cache is klass's:
    # Session.find(model_class: User) caches under User.
    def self.__fetch_record(path, klass, conditional, &block)
      entry = conditional ? klass.__http_cache_entry(path) : nil
      headers = entry ? { "If-None-Match" => entry["etag"] } : nil
      generation = Funicular::DB.mutation_generation
      HTTP.get(path, headers: headers) do |response|
        if Funicular::DB.stale_generation?(generation)
          block.call(nil, Funicular::DB.stale_response_error) if block
        elsif response.not_modified?
          # @type var ids: Array[untyped]
          ids = entry ? entry["ids"] : []
          instances = ids.size == 1 ? klass.__instances_from_replica(ids) : nil
          if instances
            klass.__log_not_modified(path)
            block.call(instances[0], nil) if block
          elsif conditional
            klass.__forget_http_cache_entry(path)
            __fetch_record(path, klass, false, &block)
          else
            block.call(nil, "unexpected 304 for GET #{path}") if block
          end
        elsif response.error?
          block.call(nil, response.error_message) if block
        else
          data = response.data
          klass.__write_through_upsert(data)
          instance = klass.new(data)
          id = data.is_a?(Hash) ? data["id"] : nil
          klass.__store_http_cache_entry(path, response, [id])
          block.call(instance, nil) if block
        end
      end
    end

    # attrs may be a braced Hash (arrives positionally), bare keywords,
    # or both -- keywords are merged in and win on the same key. The
    # model_class: keyword is reserved for REST models only; on
    # storage :local it is an ordinary attribute, so a column may be
    # named model_class.
    # The model_class: and endpoint_name: keywords are reserved for
    # REST models only; on storage :local they are ordinary attributes,
    # so a column may carry either name. attrs fill the path's
    # :segments too (Comment.create(post_id: 3, body: "..") -> POST
    # /posts/3/comments) and travel whole in the body.
    def self.create(attrs = {}, **kw, &block)
      if local?
        if block
          raise ArgumentError,
            "#{to_s}.create is synchronous on storage :local and takes no block"
        end
        return local_create(merge_keyword_attrs(attrs, kw))
      end
      model_class = kw.delete(:model_class)
      endpoint_name = kw.delete(:endpoint_name)
      attrs = merge_keyword_attrs(attrs, kw)
      endpoint = __endpoint(endpoint_name ? endpoint_name.to_s : "create")

      # Validate on the client before the request (mirrors ActiveRecord#save).
      candidate = new(attrs)
      unless candidate.valid?
        block.call(nil, candidate.errors) if block
        return
      end

      expanded = __expand_path(endpoint["path"], attrs, nil, "#{to_s}.create")
      generation = Funicular::DB.mutation_generation
      HTTP.post(expanded[0], attrs) do |response|
        if Funicular::DB.stale_generation?(generation)
          block.call(nil, Funicular::DB.stale_response_error) if block
        elsif response.error?
          # A 422 with { errors: record.errors } lands on the candidate
          # exactly as a client-side failure would.
          server_errors = __server_errors(response)
          if server_errors
            candidate.__replace_errors(server_errors)
            block.call(nil, server_errors) if block
          else
            block.call(nil, response.error_message) if block
          end
        else
          klass = model_class || self
          klass.__write_through_upsert(response.data)
          instance = klass.new(response.data)
          block.call(instance, nil) if block
        end
      end
    end

    # path_params fill the path's other :segments; id fills the one left.
    def self.destroy(id = nil, **path_params, &block)
      if local?
        if block
          raise ArgumentError,
            "#{to_s}.destroy is synchronous on storage :local and takes no block"
        end
        return local.find(id).destroy
      end
      endpoint = __endpoint("destroy")
      expanded = __expand_path(endpoint["path"], path_params, id, "#{to_s}.destroy")
      __delete_record(expanded[0], id, &block)
    end

    def self.__delete_record(path, id, &block)
      generation = Funicular::DB.mutation_generation
      HTTP.delete(path) do |response|
        if Funicular::DB.stale_generation?(generation)
          block.call(nil, Funicular::DB.stale_response_error) if block
        elsif response.error?
          block.call(nil, response.error_message) if block
        else
          __write_through_delete(id) unless id.nil?
          block.call(true, nil) if block
        end
      end
    end

    def update(attrs = nil, &block)
      if self.class.local?
        if block
          raise ArgumentError,
            "update is synchronous on storage :local and takes no block"
        end
        return __local_update(attrs)
      end
      if attrs
        attrs.each { |k, v| send("#{k}=", v) }
      end

      # Validate on the client before the request (mirrors ActiveRecord#save).
      unless valid?
        block.call(nil, errors) if block
        return
      end

      json_attrs = @changed_attributes.reject do |name, value|
        schema = self.class.schema[name]
        schema && schema["type"] == "binary"
      end

      # Nothing to send (no changes, or binary-only changes that travel via
      # FileUpload): a successful no-op, reported like any success.
      if json_attrs.empty?
        block.call(self, nil) if block
        return
      end

      endpoint = self.class.__endpoint("update")
      expanded = self.class.__expand_path(endpoint["path"], __path_source, @id,
        "#{self.class.to_s}#update")

      generation = Funicular::DB.mutation_generation
      HTTP.patch(expanded[0], json_attrs) do |response|
        if Funicular::DB.stale_generation?(generation)
          block.call(nil, Funicular::DB.stale_response_error) if block
        elsif response.error?
          # A 422 with { errors: record.errors }: the server's verdict
          # replaces this record's errors, like a failed client-side
          # valid? would.
          server_errors = self.class.__server_errors(response)
          if server_errors
            __replace_errors(server_errors)
            block.call(nil, server_errors) if block
          else
            block.call(nil, response.error_message) if block
          end
        else
          data = response.data
          # The replica holds the server's row before the callback runs
          # (docs decision 4).
          self.class.__write_through_upsert(data)
          # Apply the server's authoritative row (defaults, callbacks and
          # normalizations included) through the codec before reporting
          # success.
          keys = data.keys
          keys_size = keys.size
          i = 0
          while i < keys_size
            key = keys[i]
            value = data[key]
            unless value.nil?
              value = Funicular::DB::Codec.decode(
                self.class.rest_attribute_type(key.to_s), value)
            end
            instance_variable_set("@#{key}", value)
            i += 1
          end
          @changed_attributes = {}
          block.call(self, nil) if block
        end
      end
    end

    def destroy(&block)
      if self.class.local?
        if block
          raise ArgumentError,
            "destroy is synchronous on storage :local and takes no block"
        end
        return __local_destroy
      end
      klass = self.class
      endpoint = klass.__endpoint("destroy")
      expanded = klass.__expand_path(endpoint["path"], __path_source, @id,
        "#{klass.to_s}#destroy")
      klass.__delete_record(expanded[0], @id, &block)
    end

    def reload(&block)
      if self.class.local?
        if block
          raise ArgumentError,
            "reload is synchronous on storage :local and takes no block"
        end
        __sync_from_row
        @changed_attributes = {}
        return self
      end
      klass = self.class
      endpoint = klass.__endpoint("find")
      expanded = klass.__expand_path(endpoint["path"], __path_source, @id,
        "#{klass.to_s}#reload")
      klass.__fetch_record(expanded[0], klass, true) do |instance, error|
        if instance
          instance.instance_variables.each do |var|
            instance_variable_set(var, instance.instance_variable_get(var))
          end
          @changed_attributes = {}
        end
        block.call(instance, error) if block
      end
    end

    # ---- storage :local write internals (framework use) ------------------
    # All three writers notify local_table_changed, the hook the change-
    # event bus and snapshot scheduling attach to at boot. SQLite
    # constraint violations escape as SQLite3::Exception on purpose: they
    # are bugs, not user-facing validation (docs, "Local models").

    # INSERT this (validated) record. Columns that were never given (nil
    # and not explicitly provided) are left out so SQL DEFAULTs apply; an
    # EXPLICIT nil binds NULL and answers to NOT NULL like any write. The
    # row is read back afterwards, so the instance reflects what the
    # table actually stores.
    def __local_insert
      klass = self.class
      columns = klass.local_columns
      codec = Funicular::DB::Codec
      now = Time.now
      if columns.has_key?("created_at") && instance_variable_get("@created_at").nil?
        instance_variable_set("@created_at", now)
      end
      if columns.has_key?("updated_at") && instance_variable_get("@updated_at").nil?
        instance_variable_set("@updated_at", now)
      end
      names = columns.keys
      # @type var cols: Array[String]
      cols = []
      # @type var marks: Array[String]
      marks = []
      # @type var binds: Array[untyped]
      binds = []
      provided = @provided_attributes
      names_size = names.size
      i = 0
      while i < names_size
        name = names[i]
        unless name == "id"
          value = instance_variable_get("@#{name}")
          if !value.nil? || (provided && provided[name])
            cols << "\"#{name}\""
            marks << "?"
            binds << codec.encode(columns[name], value)
          end
        end
        i += 1
      end
      db = klass.local_db
      # RETURNING makes the INSERT itself hand back the id. A separate
      # SELECT last_insert_rowid() would read connection-global state:
      # another Task inserting into the same database between the two
      # statements would overwrite it, and this instance would adopt the
      # other Task's id (and then sync from the other Task's row).
      sql = if cols.empty?
        "INSERT INTO \"#{klass.table_name}\" DEFAULT VALUES RETURNING \"id\""
      else
        "INSERT INTO \"#{klass.table_name}\" (#{cols.join(", ")}) " \
          "VALUES (#{marks.join(", ")}) RETURNING \"id\""
      end
      row = db.execute(sql, binds)[0]
      @id = row.is_a?(Hash) ? row.values[0] : row[0]
      __sync_from_row
      @changed_attributes = {}
      klass.local_table_changed
      self
    end

    # Validated, synchronous update: true/false. An update with no actual
    # changes is a no-op that returns true and does not touch updated_at.
    def __local_update(attrs)
      if attrs
        keys = attrs.keys
        keys_size = keys.size
        i = 0
        while i < keys_size
          send("#{keys[i]}=", attrs[keys[i]])
          i += 1
        end
      end
      if new_record?
        raise ArgumentError,
          "cannot update a record that is not in the local table; use create"
      end
      return false unless valid?
      changed = @changed_attributes
      return true if changed.empty?
      klass = self.class
      columns = klass.local_columns
      codec = Funicular::DB::Codec
      # The updated_at stamp is a FRAMEWORK change: remember what it
      # replaced so a failed UPDATE can put it back -- otherwise a later,
      # genuinely change-free update would write (and notify) for the
      # leftover stamp alone. The USER's changes stay put on failure.
      stamped = false
      prev_stamp_ivar = nil
      prev_stamp_changed = nil
      had_stamp_changed = false
      # The rescue below must already be armed while the stamp is set and
      # the binds are encoded: Codec.encode raises ArgumentError on a
      # malformed datetime, and that failure has to revert the stamp too.
      begin
        if columns.has_key?("updated_at")
          stamped = true
          prev_stamp_ivar = instance_variable_get("@updated_at")
          had_stamp_changed = changed.has_key?("updated_at")
          prev_stamp_changed = changed["updated_at"]
          stamp = Time.now
          instance_variable_set("@updated_at", stamp)
          changed["updated_at"] = stamp
        end
        # @type var sets: Array[String]
        sets = []
        # @type var binds: Array[untyped]
        binds = []
        names = changed.keys
        names_size = names.size
        i = 0
        while i < names_size
          name = names[i]
          sets << "\"#{name}\" = ?"
          binds << codec.encode(columns[name], changed[name])
          i += 1
        end
        binds << @id
        # RETURNING answers "did the row exist?" inside the one UPDATE:
        # checking afterwards (even via the read-back below) would race a
        # concurrent delete + id-reusing re-create between the statements.
        updated = klass.local_db.execute(
          "UPDATE \"#{klass.table_name}\" SET #{sets.join(", ")} " \
            "WHERE \"id\" = ? RETURNING \"id\"", binds)
        if updated.empty?
          raise Funicular::RecordNotFound,
            "Couldn't find #{klass.to_s} with id=#{@id}"
        end
        # Re-read the row: the codec may have normalized what was written
        # (offset datetime strings fold into UTC, fractional seconds
        # truncate) and only the table knows the final values -- the
        # instance and the dirty-tracking baseline must reflect them, so a
        # re-fetch returns the same types this instance now carries.
        __sync_from_row
      rescue => e
        if stamped
          instance_variable_set("@updated_at", prev_stamp_ivar)
          if had_stamp_changed
            changed["updated_at"] = prev_stamp_changed
          else
            changed.delete("updated_at")
          end
        end
        # Explicit re-raise: a bare `raise` would not re-raise on the
        # mruby VM.
        raise e
      end
      @changed_attributes = {}
      klass.local_table_changed
      true
    end

    def __local_destroy
      if new_record?
        raise ArgumentError,
          "cannot destroy a record that is not in the local table"
      end
      klass = self.class
      # RETURNING makes the DELETE itself report what it removed. A
      # separate SELECT changes() would read connection-global state that
      # another Task's write between the two statements overwrites --
      # dropping (or fabricating) the change notification.
      rows = klass.local_db.execute(
        "DELETE FROM \"#{klass.table_name}\" WHERE \"id\" = ? " \
          "RETURNING \"id\"", [@id])
      klass.local_table_changed unless rows.empty?
      true
    end

    # Re-read this record's row and decode it into the instance.
    def __sync_from_row
      klass = self.class
      columns = klass.local_columns
      codec = Funicular::DB::Codec
      names = columns.keys
      # @type var quoted: Array[String]
      quoted = []
      names_size = names.size
      i = 0
      while i < names_size
        quoted << "\"#{names[i]}\""
        i += 1
      end
      row = klass.local_db.execute(
        "SELECT #{quoted.join(", ")} FROM \"#{klass.table_name}\" " \
          "WHERE \"id\" = ?", [@id])[0]
      unless row
        # The row is gone (another instance's destroy, delete_all, ...):
        # fail loud instead of keeping stale attributes. On the update
        # path this fires BEFORE changes are cleared and before
        # local_table_changed, so a 0-row UPDATE neither discards the
        # pending changes nor notifies.
        raise Funicular::RecordNotFound,
          "Couldn't find #{klass.to_s} with id=#{@id}"
      end
      # @type var baseline: Hash[String, untyped]
      baseline = {}
      i = 0
      while i < names_size
        name = names[i]
        raw = row.is_a?(Hash) ? row[name] : row[i]
        decoded = codec.decode(columns[name], raw)
        instance_variable_set("@#{name}", decoded)
        baseline[name] = decoded
        i += 1
      end
      @local_baseline = baseline
    end

    # Hydrate this record from an already-decoded row: ivars are set
    # DIRECTLY (stored values are normalized; user writers must not run
    # again), the row becomes the dirty-tracking baseline, and nothing
    # is dirty.
    def __hydrate_local(attrs)
      keys = attrs.keys
      keys_size = keys.size
      i = 0
      while i < keys_size
        instance_variable_set("@#{keys[i]}", attrs[keys[i]])
        i += 1
      end
      __set_local_baseline(attrs)
      @changed_attributes = {}
    end

    # Install the dirty-tracking baseline (see define_local_accessor).
    # Framework use: called with the decoded row a record was built from.
    def __set_local_baseline(attrs)
      # @type var baseline: Hash[String, untyped]
      baseline = {}
      keys = attrs.keys
      keys_size = keys.size
      i = 0
      while i < keys_size
        baseline[keys[i].to_s] = attrs[keys[i]]
        i += 1
      end
      @local_baseline = baseline
    end
  end
end
