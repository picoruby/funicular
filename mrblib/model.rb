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

    def self.load_schema(schema_data)
      @schema = schema_data["attributes"]
      @endpoints = schema_data["endpoints"]
      # Replica column metadata derives from the schema; drop any cache.
      @local_columns = nil

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
        { with: Regexp.new(opts["with"], bits) }
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
      if snake.end_with?("y")
        "#{snake[0, snake.length - 1]}ies"
      else
        "#{snake}s"
      end
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
    # id type follows the server. Local models get their columns from the
    # migrate fold once the migration runner lands.
    def self.local_columns
      if ephemeral?
        raise Funicular::DB::NoTableError,
          "#{to_s} is storage :ephemeral; it has no local table"
      end
      if local?
        raise Funicular::DB::UnavailableError,
          "#{to_s}: local tables are not built yet (migrations run at DB boot)"
      end
      cols = @local_columns
      return cols if cols
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
      @local_columns = derived
    end

    # The handle local queries run against. Arrives with Funicular::DB.boot
    # (a later change); until then every materializer fails loud.
    def self.local_db
      raise Funicular::DB::UnavailableError,
        "#{to_s}: the local database is not booted"
    end

    def self.build_from_local(attrs)
      new(attrs)
    end

    def initialize(attributes = {})
      @changed_attributes = {}
      # Set attributes based on schema. Key-presence lookups, not `||`:
      # a string-keyed false (boolean columns) must not fall through to the
      # symbol key and come back nil.
      self.class.schema.each do |name, config|
        value = if attributes.has_key?(name)
          attributes[name]
        else
          sym = name.to_sym
          attributes.has_key?(sym) ? attributes[sym] : nil
        end
        instance_variable_set("@#{name}", value)
      end
    end

    def self.all(params = {}, &block)
      endpoint = @endpoints["all"]
      return unless endpoint

      path = endpoint["path"]
      if params && !params.empty?
        path = "#{path}?#{URI.encode_www_form(params)}"
      end

      HTTP.get(path) do |response|
        if response.error?
          block.call(nil, response.error_message) if block
        else
          instances = response.data.map { |attrs| new(attrs) }
          block.call(instances, nil) if block
        end
      end
    end

    def self.find(id = nil, endpoint_name: "find", model_class: nil, &block)
      endpoint = @endpoints[endpoint_name]
      return unless endpoint

      path = endpoint["path"]
      path = path.gsub(":id", id.to_s) if id

      HTTP.get(path) do |response|
        if response.error?
          block.call(nil, response.error_message) if block
        else
          klass = model_class || self
          instance = klass.new(response.data)
          block.call(instance, nil) if block
        end
      end
    end

    def self.create(attrs, model_class: nil, &block)
      endpoint = @endpoints["create"]
      return unless endpoint

      # Validate on the client before the request (mirrors ActiveRecord#save).
      candidate = new(attrs)
      unless candidate.valid?
        block.call(nil, candidate.errors) if block
        return
      end

      HTTP.post(endpoint["path"], attrs) do |response|
        if response.error?
          block.call(nil, response.error_message) if block
        else
          klass = model_class || self
          instance = klass.new(response.data)
          block.call(instance, nil) if block
        end
      end
    end

    def self.destroy(id = nil, &block)
      endpoint = @endpoints["destroy"]
      return unless endpoint

      path = id ? endpoint["path"].gsub(":id", id.to_s) : endpoint["path"]

      HTTP.delete(path) do |response|
        if response.error?
          block.call(nil, response.error_message) if block
        else
          block.call(true, nil) if block
        end
      end
    end

    def update(attrs = nil, &block)
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

      endpoint = self.class.endpoints["update"]
      path = endpoint["path"].gsub(":id", @id.to_s)

      HTTP.patch(path, json_attrs) do |response|
        if response.error?
          block.call(nil, response.error_message) if block
        else
          # Apply the server's authoritative row (defaults, callbacks and
          # normalizations included) before reporting success.
          response.data.each do |key, value|
            instance_variable_set("@#{key}", value)
          end
          @changed_attributes = {}
          block.call(self, nil) if block
        end
      end
    end

    def destroy(&block)
      self.class.destroy(@id, &block)
    end

    def reload(&block)
      self.class.find(@id) do |instance, error|
        if instance
          instance.instance_variables.each do |var|
            instance_variable_set(var, instance.instance_variable_get(var))
          end
          @changed_attributes = {}
        end
        block.call(instance, error) if block
      end
    end
  end
end
