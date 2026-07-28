# Funicular::DB is the client-side database engine behind the local
# database layer (docs/local_database.md). This file holds the pieces the
# query layer depends on: the error vocabulary and the shared value codec.
#
# SSR contract: this file only defines modules/classes at load time and
# never touches SQLite3 or JS, so it is safe to load on CRuby.

module Funicular
  # Raised by Relation#find (and, on `storage :local` models, the bare-class
  # alias) when no row matches. Named after the ActiveRecord counterpart.
  class RecordNotFound < StandardError; end

  module DB
    class Error < StandardError; end

    # `.local` on a `storage :ephemeral` model: there is no table behind it.
    class NoTableError < Error; end

    # Local write attempted on a tab that lost (or never ran) the writer
    # election, or a destructive operation (flush/wipe/reset_local) there.
    class ReadOnlyTabError < Error; end

    # Local bulk write attempted on a replica table. The server owns replica
    # rows; deletions reach the replica through write-through destroy.
    class ReplicaWriteError < Error; end

    # The persisted local schema is NEWER than the code's declarations
    # (deploy rollback). The whole local DB fails loud; see the docs.
    class SchemaTooNewError < Error; end

    # A local query was materialized where no local database can exist
    # (SSR) or before boot completed.
    class UnavailableError < Error; end

    # The user_key/anonymous_only/application_id declaration is invalid
    # (docs decision 12); startup must not proceed.
    class ConfigError < Error; end

    # One shared codec for values crossing the Ruby/SQLite boundary.
    # Applied identically to local writes, reads, condition binds, and REST
    # response initialization, so both sides of a model return the same
    # Ruby types for the same attribute.
    #
    #   boolean  true/false <-> INTEGER 1/0
    #   datetime Time <-> ISO 8601 TEXT normalized to UTC at fixed
    #            (second) precision -- arbitrary offsets or precisions
    #            would not sort chronologically as strings
    #
    # Every other declared type passes through untouched.
    module Codec
      # Ruby value -> SQLite bind/storage value for a column of `type`.
      def self.encode(type, value)
        return nil if value.nil?
        if type == :boolean
          return 1 if value == true
          return 0 if value == false
          value
        elsif type == :datetime
          if value.is_a?(Time)
            time_to_iso(value)
          elsif value.is_a?(String)
            # Strings are re-normalized (offsets folded into UTC, fractions
            # truncated) so stored TEXT always sorts chronologically;
            # malformed input raises ArgumentError here, not at query time.
            time_to_iso(iso_to_time(value))
          else
            value
          end
        else
          value
        end
      end

      # SQLite value -> Ruby value for a column of `type`.
      def self.decode(type, value)
        return nil if value.nil?
        if type == :boolean
          return value unless value.is_a?(Integer)
          value == 0 ? false : true
        elsif type == :datetime
          value.is_a?(String) ? iso_to_time(value) : value
        else
          value
        end
      end

      # Type-less encoding for raw-SQL-fragment binds, where no column (and
      # so no declared type) is known. Converts by value instead.
      def self.encode_bind(value)
        return 1 if value == true
        return 0 if value == false
        return time_to_iso(value) if value.is_a?(Time)
        value
      end

      # Format a Time as UTC ISO 8601 at second precision. Derived from the
      # epoch (Time#to_i), so the host's local time zone never leaks in.
      def self.time_to_iso(time)
        epoch = time.to_i
        days = epoch / 86400
        secs = epoch % 86400
        civil = civil_from_days(days)
        zpad(civil[0], 4) + "-" + zpad(civil[1], 2) + "-" + zpad(civil[2], 2) +
          "T" + zpad(secs / 3600, 2) + ":" + zpad((secs % 3600) / 60, 2) +
          ":" + zpad(secs % 60, 2) + "Z"
      end

      # Parse "YYYY-MM-DD[T ]HH:MM:SS[.fff][Z|+HH:MM|-HH:MM]" into a Time.
      # Fractional seconds are truncated (the codec's fixed precision);
      # a missing zone designator is read as UTC. Raises ArgumentError on
      # anything malformed.
      def self.iso_to_time(str)
        len = str.length
        if len < 19
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
        year = digits_at(str, 0, 4)
        sep_at(str, 4, 45)   # '-'
        mon = digits_at(str, 5, 2)
        sep_at(str, 7, 45)   # '-'
        day = digits_at(str, 8, 2)
        t = str.getbyte(10)
        unless t == 84 || t == 32 # 'T' or ' '
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
        hour = digits_at(str, 11, 2)
        sep_at(str, 13, 58)  # ':'
        min = digits_at(str, 14, 2)
        sep_at(str, 16, 58)  # ':'
        sec = digits_at(str, 17, 2)
        if mon < 1 || 12 < mon || day < 1 || days_in_month(year, mon) < day ||
           23 < hour || 59 < min || 60 < sec
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
        pos = 19
        if str.getbyte(pos) == 46 # '.'
          pos += 1
          digit_seen = false
          c = str.getbyte(pos)
          while c && 48 <= c && c <= 57
            digit_seen = true
            pos += 1
            c = str.getbyte(pos)
          end
          unless digit_seen
            raise ArgumentError, "invalid datetime: #{str.inspect}"
          end
        end
        offset = 0
        zone = str.getbyte(pos)
        if zone.nil?
          # no designator: read as UTC
        elsif zone == 90 || zone == 122 # 'Z' or 'z'
          pos += 1
        elsif zone == 43 # '+'
          offset = zone_offset(str, pos)
          pos += 6
        elsif zone == 45 # '-'
          offset = -zone_offset(str, pos)
          pos += 6
        else
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
        unless pos == len
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
        epoch = days_from_civil(year, mon, day) * 86400 +
                hour * 3600 + min * 60 + sec - offset
        Time.at(epoch)
      end

      # --- calendar arithmetic (Howard Hinnant's civil algorithms) --------

      # Days since 1970-01-01 -> [year, month, day].
      def self.civil_from_days(days)
        z = days + 719468
        era = (0 <= z ? z : z - 146096) / 146097
        doe = z - era * 146097
        yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        y = yoe + era * 400
        doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        mp = (5 * doy + 2) / 153
        d = doy - (153 * mp + 2) / 5 + 1
        m = mp < 10 ? mp + 3 : mp - 9
        y += 1 if m <= 2
        [y, m, d]
      end

      # [year, month, day] -> days since 1970-01-01.
      def self.days_from_civil(y, m, d)
        y -= 1 if m <= 2
        era = (0 <= y ? y : y - 399) / 400
        yoe = y - era * 400
        doy = (153 * (m <= 2 ? m + 9 : m - 3) + 2) / 5 + d - 1
        doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        era * 146097 + doe - 719468
      end

      def self.days_in_month(year, mon)
        return 31 if mon == 1 || mon == 3 || mon == 5 || mon == 7 ||
                     mon == 8 || mon == 10 || mon == 12
        return 30 unless mon == 2
        (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
      end

      # Parse the "HH:MM" part of a "+HH:MM" zone tail starting at `pos`
      # (the sign byte) and return it in seconds, always positive.
      def self.zone_offset(str, pos)
        oh = digits_at(str, pos + 1, 2)
        sep_at(str, pos + 3, 58) # ':'
        om = digits_at(str, pos + 4, 2)
        if 23 < oh || 59 < om
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
        oh * 3600 + om * 60
      end

      # Read `len` decimal digits at byte offset `pos` as an Integer.
      def self.digits_at(str, pos, len)
        v = 0
        i = 0
        while i < len
          c = str.getbyte(pos + i)
          if c.nil? || c < 48 || 57 < c
            raise ArgumentError, "invalid datetime: #{str.inspect}"
          end
          v = v * 10 + (c - 48)
          i += 1
        end
        v
      end

      # Assert the byte at `pos` is `code`.
      def self.sep_at(str, pos, code)
        unless str.getbyte(pos) == code
          raise ArgumentError, "invalid datetime: #{str.inspect}"
        end
      end

      def self.zpad(n, width)
        s = n.to_s
        while s.length < width
          s = "0" + s
        end
        s
      end
    end

    # ---- client-only tables: the migrate blocks -------------------------
    #
    # `storage :local do migrate N do |t| ... end end` blocks are recorded
    # by the model DSL and executed here, per table, at boot. The `t`
    # yielded to a block is a TableBuilder: a pure recorder whose
    # operations the runner below renders into DDL, and whose column
    # operations fold into the model's local_columns metadata.
    class TableBuilder
      attr_reader :ops

      def initialize
        @ops = []
      end

      def string(name, default: nil, null: true)
        add_column(:string, name, default, null)
      end

      def text(name, default: nil, null: true)
        add_column(:text, name, default, null)
      end

      def integer(name, default: nil, null: true)
        add_column(:integer, name, default, null)
      end

      def float(name, default: nil, null: true)
        add_column(:float, name, default, null)
      end

      def boolean(name, default: nil, null: true)
        add_column(:boolean, name, default, null)
      end

      def datetime(name, default: nil, null: true)
        add_column(:datetime, name, default, null)
      end

      # created_at/updated_at, maintained automatically by the local CRUD.
      def timestamps
        add_column(:datetime, :created_at, nil, true)
        add_column(:datetime, :updated_at, nil, true)
      end

      def index(*columns)
        @ops << [:index, identifier_list(columns)]
      end

      def remove_index(*columns)
        @ops << [:remove_index, identifier_list(columns)]
      end

      def rename(old_name, new_name)
        @ops << [:rename, DB.validate_identifier(old_name),
                 DB.validate_identifier(new_name)]
      end

      def remove(name)
        @ops << [:remove, DB.validate_identifier(name)]
      end

      # Raw-SQL escape hatch; runs as-is and does not affect the column
      # fold (whatever it does is invisible to local_columns).
      def execute(sql)
        @ops << [:execute, sql]
      end

      private

      def add_column(type, name, default, null)
        n = DB.validate_identifier(name)
        if n == "id"
          raise ArgumentError,
            "the id column is implicit (INTEGER PRIMARY KEY); do not declare it"
        end
        @ops << [:add_column, n, type, default, null]
      end

      def identifier_list(columns)
        if columns.empty?
          raise ArgumentError, "at least one column is required"
        end
        # @type var names: Array[String]
        names = []
        i = 0
        while i < columns.size
          names << DB.validate_identifier(columns[i])
          i += 1
        end
        names
      end
    end

    SQL_TYPES = {
      string: "TEXT",
      text: "TEXT",
      integer: "INTEGER",
      float: "REAL",
      boolean: "INTEGER",
      datetime: "TEXT",
    }

    # One key/value metadata table in the local database holds the applied
    # migration version per table (and, later, the replica fingerprint).
    META_TABLE = "funicular_meta"

    # The metadata table belongs to the framework: no model -- local or
    # replica -- may claim its name (SQLite table names are
    # case-insensitive, so the check is too).
    def self.guard_reserved_table(table)
      if table.downcase == META_TABLE
        raise ArgumentError,
          "\"#{table}\" is reserved for framework metadata; pick " \
          "another table_name"
      end
      table
    end

    # SQL identifiers this layer interpolates (table and column names) must
    # be plain: ASCII letter or underscore first, then letters, digits,
    # underscores. Returns the name as a String.
    def self.validate_identifier(name)
      s = name.to_s
      i = 0
      while i < s.length
        c = s.getbyte(i)
        ok = c && (c == 95 || # '_'
                   (97 <= c && c <= 122) || # a-z
                   (65 <= c && c <= 90) ||  # A-Z
                   (0 < i && 48 <= c && c <= 57)) # 0-9, not first
        unless ok
          raise ArgumentError, "invalid SQL identifier: #{name.inspect}"
        end
        i += 1
      end
      if s.empty?
        raise ArgumentError, "invalid SQL identifier: #{name.inspect}"
      end
      s
    end

    # The index of the block the table is (re)built from: the NEWEST
    # `reset: true` block, or the first block when none is marked. Blocks
    # before it are superseded history -- they may stay in the code (the
    # docs only say they MAY be deleted) but are never folded or applied.
    def self.baseline_index(migrations)
      base = 0
      i = 0
      while i < migrations.size
        base = i if migrations[i][:reset]
        i += 1
      end
      base
    end

    # Fold a model's migrate blocks into column metadata (column name ->
    # declared type), the implicit id included. Pure: no database touched,
    # usable before boot. Folding starts at the baseline, so a reset block
    # may redefine columns that also appear in the superseded history.
    def self.fold_local_columns(model)
      fold_builders(collect_builders(model), model.local_migrations, model)
    end

    # The fold over ALREADY-collected builders: the migration runner
    # evaluates each migrate block exactly once per run and feeds the same
    # recorded operations to this validation and to the DDL.
    def self.fold_builders(builders, migrations, model)
      # @type var columns: Hash[String, Symbol]
      columns = { "id" => :integer }
      i = migrations ? baseline_index(migrations) : 0
      while i < builders.size
        fold_ops(columns, builders[i].ops, model)
        i += 1
      end
      columns
    end

    # Bring one model's local table to its declared schema. Fresh and
    # below-baseline tables are rebuilt from the baseline (see
    # baseline_index); tables between baseline and max get exactly the
    # missing blocks; a
    # table NEWER than the declarations raises SchemaTooNewError (deploy
    # rollback; the whole-DB lockdown is wired at boot). All applied work
    # runs in one transaction. When an incremental upgrade fails in
    # development the table is rebuilt from scratch instead (never in
    # production). Returns the version the table is at afterwards.
    def self.apply_local_migrations(db, model)
      migrations = model.local_migrations
      unless migrations
        raise ArgumentError,
          "#{model} has no migrate blocks (is it storage :local?)"
      end
      # Evaluate every migrate block exactly ONCE for this run, then
      # validate the retained chain before any SQL: the fold catches
      # errors SQLite itself would accept as plain DDL (renaming or
      # removing the implicit id, most notably), and the very same
      # recorded operations feed the DDL below. Fold errors are
      # ArgumentError, so the development auto-reset below never eats
      # them -- a broken declaration fails the same way everywhere.
      builders = collect_builders(model)
      fold_builders(builders, migrations, model)
      table = guard_reserved_table(validate_identifier(model.table_name))
      baseline = migrations[baseline_index(migrations)][:version]
      max = migrations[migrations.size - 1][:version]
      stored = stored_table_version(db, table)
      if max < stored
        raise SchemaTooNewError,
          "\"#{table}\" is at migration #{stored} but the code only " \
          "declares up to #{max} (deploy rollback?); the local database " \
          "refuses to run backwards"
      end
      return max if stored == max
      if stored < baseline
        rebuild_local_table(db, model, builders)
      else
        begin
          db.transaction do
            apply_blocks(db, model, stored, builders)
            store_table_version(db, table, max)
          end
        rescue SQLite3::Exception => e
          # Explicit re-raise: a bare `raise` would not re-raise on the
          # mruby VM (it raises a fresh empty RuntimeError).
          raise e unless Funicular.env.development?
          # Dev auto-reset: a dirty development table beats hand-repair.
          rebuild_local_table(db, model, builders)
        end
      end
      max
    end

    # Drop and rebuild from the baseline, in one transaction: the fresh
    # path, the below-baseline path, reset_local, and the dev auto-reset
    # all land here. Returns the resulting version.
    def self.rebuild_local_table(db, model, builders = nil)
      migrations = model.local_migrations
      unless migrations
        raise ArgumentError,
          "#{model} has no migrate blocks (is it storage :local?)"
      end
      # When entered directly (reset_local; apply passes its builders in)
      # evaluate the blocks once and validate before any SQL, exactly
      # like apply_local_migrations.
      unless builders
        builders = collect_builders(model)
        fold_builders(builders, migrations, model)
      end
      table = guard_reserved_table(validate_identifier(model.table_name))
      max = migrations[migrations.size - 1][:version]
      db.transaction do
        db.execute("DROP TABLE IF EXISTS \"#{table}\"")
        apply_blocks(db, model, 0, builders)
        store_table_version(db, table, max)
      end
      max
    end

    def self.stored_table_version(db, table)
      value = read_meta(db, "table_version:#{table}")
      value ? value.to_i : 0
    end

    def self.store_table_version(db, table, version)
      store_meta(db, "table_version:#{table}", version.to_s)
    end

    def self.read_meta(db, key)
      ensure_meta_table(db)
      rows = db.execute("SELECT value FROM \"#{META_TABLE}\" WHERE key = ?",
                        [key])
      row = rows[0]
      return nil unless row
      row.is_a?(Hash) ? row.values[0] : row[0]
    end

    def self.store_meta(db, key, value)
      ensure_meta_table(db)
      db.execute("INSERT OR REPLACE INTO \"#{META_TABLE}\" (key, value) " \
                 "VALUES (?, ?)", [key, value])
    end

    def self.ensure_meta_table(db)
      db.execute("CREATE TABLE IF NOT EXISTS \"#{META_TABLE}\" " \
                 "(key TEXT PRIMARY KEY, value TEXT)")
    end

    # Run every migrate block against a fresh TableBuilder, returning the
    # recorded operations in declaration order. The runner calls this
    # exactly once per migration run; local_columns is the only other
    # caller. Blocks should stay deterministic and side-effect free.
    def self.collect_builders(model)
      migrations = model.local_migrations
      unless migrations
        raise ArgumentError,
          "#{model} has no migrate blocks (is it storage :local?)"
      end
      # @type var builders: Array[TableBuilder]
      builders = []
      i = 0
      while i < migrations.size
        t = TableBuilder.new
        migrations[i][:block].call(t)
        builders << t
        i += 1
      end
      builders
    end

    # Apply one block's column effects to the running fold. Unknown or
    # duplicate names fail here, before any SQL runs.
    def self.fold_ops(columns, ops, model)
      i = 0
      while i < ops.size
        op = ops[i]
        kind = op[0]
        if kind == :add_column
          name = op[1]
          if columns.has_key?(name)
            raise ArgumentError,
              "duplicate column #{name.inspect} in #{model.table_name} migrations"
          end
          guard_reserved_column(name, model)
          columns[name] = op[2]
        elsif kind == :rename
          old_name = op[1]
          guard_id(old_name, model)
          type = columns[old_name]
          unless type
            raise ArgumentError,
              "rename of unknown column #{old_name.inspect} in " \
              "#{model.table_name} migrations"
          end
          if columns.has_key?(op[2])
            raise ArgumentError,
              "duplicate column #{op[2].inspect} in #{model.table_name} migrations"
          end
          guard_reserved_column(op[2], model)
          columns.delete(old_name)
          columns[op[2]] = type
        elsif kind == :remove
          name = op[1]
          guard_id(name, model)
          unless columns.has_key?(name)
            raise ArgumentError,
              "remove of unknown column #{name.inspect} in " \
              "#{model.table_name} migrations"
          end
          columns.delete(name)
        end
        # index/remove_index/execute do not affect the fold
        i += 1
      end
    end

    def self.guard_id(name, model)
      if name == "id"
        raise ArgumentError,
          "the id column is implicit and cannot be renamed or removed " \
          "(#{model.table_name} migrations)"
      end
    end

    # A column name must not shadow the model API: the generated reader
    # would clobber anything the BASE Funicular::Model instance already
    # responds to (destroy, reload, update, valid?, errors, class, hash,
    # ...). Checking against the base class -- never the subclass -- keeps
    # a model's own generated accessors from tripping the guard when its
    # blocks are folded again.
    def self.guard_reserved_column(name, model)
      # The __ prefix is the framework-internal namespace (__custom_*
      # writer stashes, __local_* helpers): a column named __custom_title
      # would clobber the alias that wraps a hand-written title= writer.
      if name.start_with?("__")
        raise ArgumentError,
          "column names starting with __ are reserved for framework " \
          "internals (#{model.table_name} migrations); rename " \
          "#{name.inspect}"
      end
      reserved = @reserved_column_names
      unless reserved
        # Both lists: instance_methods alone omits private methods, and a
        # column named "initialize" or "method_missing" must be rejected
        # just as hard as "destroy".
        reserved = Funicular::Model.instance_methods +
                   Funicular::Model.private_instance_methods
        @reserved_column_names = reserved
      end
      if reserved.include?(name.to_sym)
        raise ArgumentError,
          "column name #{name.inspect} collides with a Funicular::Model " \
          "method (#{model.table_name} migrations); rename the column"
      end
    end

    # Apply every block at or after the baseline with version >
    # from_version (pre-baseline history is never applied), using the
    # builders the caller already collected and validated. The first
    # block applied onto a dropped/absent table runs in create mode (its
    # column ops become the CREATE TABLE); everything later alters.
    def self.apply_blocks(db, model, from_version, builders)
      migrations = model.local_migrations
      table = validate_identifier(model.table_name)
      i = baseline_index(migrations)
      creating = from_version < migrations[i][:version]
      while i < migrations.size
        if from_version < migrations[i][:version]
          run_block(db, table, builders[i], creating)
          creating = false
        end
        i += 1
      end
    end

    def self.run_block(db, table, builder, create_mode)
      ops = builder.ops
      if create_mode
        # @type var defs: Array[String]
        defs = ["\"id\" INTEGER PRIMARY KEY"]
        i = 0
        while i < ops.size
          op = ops[i]
          defs << column_ddl(op) if op[0] == :add_column
          i += 1
        end
        db.execute("CREATE TABLE \"#{table}\" (#{defs.join(", ")})")
        i = 0
        while i < ops.size
          op = ops[i]
          kind = op[0]
          if kind == :add_column
            # already part of the CREATE TABLE
          elsif kind == :index || kind == :remove_index || kind == :execute
            run_alter_op(db, table, op)
          else
            raise ArgumentError,
              "#{kind} needs an existing table; not allowed in the block " \
              "that creates \"#{table}\""
          end
          i += 1
        end
      else
        i = 0
        while i < ops.size
          run_alter_op(db, table, ops[i])
          i += 1
        end
      end
    end

    def self.run_alter_op(db, table, op)
      kind = op[0]
      if kind == :add_column
        db.execute("ALTER TABLE \"#{table}\" ADD COLUMN #{column_ddl(op)}")
      elsif kind == :rename
        db.execute("ALTER TABLE \"#{table}\" RENAME COLUMN \"#{op[1]}\" " \
                   "TO \"#{op[2]}\"")
      elsif kind == :remove
        db.execute("ALTER TABLE \"#{table}\" DROP COLUMN \"#{op[1]}\"")
      elsif kind == :index
        db.execute("CREATE INDEX \"#{index_name(table, op[1])}\" " \
                   "ON \"#{table}\" (#{quoted_list(op[1])})")
      elsif kind == :remove_index
        db.execute("DROP INDEX \"#{index_name(table, op[1])}\"")
      elsif kind == :execute
        db.execute(op[1])
      else
        raise ArgumentError, "unknown migration op #{kind.inspect}"
      end
    end

    # op: [:add_column, name, type, default, null]
    def self.column_ddl(op)
      sql = "\"#{op[1]}\" #{SQL_TYPES[op[2]]}"
      default = op[3]
      unless default.nil?
        sql += " DEFAULT #{default_literal(op[2], default)}"
      end
      sql += " NOT NULL" unless op[4]
      sql
    end

    # Defaults go through the shared codec, so `default: false` stores 0
    # and a Time default stores the canonical UTC string.
    def self.default_literal(type, value)
      encoded = Codec.encode(type, value)
      if encoded.is_a?(String)
        "'#{encoded.gsub("'", "''")}'"
      else
        encoded.to_s
      end
    end

    def self.index_name(table, columns)
      "index_#{table}_on_#{columns.join("_")}"
    end

    # ---- change-event bus (docs decision 10) ----------------------------
    #
    # Framework writes announce themselves per [database role, table];
    # watch and Model.on_change ride these events. They fire POST-COMMIT
    # only: inside a guarded transaction block they coalesce (one event
    # per [role, table]) and flush after COMMIT -- or vanish with the
    # rollback. Delivery drains a queue iteratively, so an event raised
    # BY a subscriber never nests delivery inside delivery, and a
    # raising subscriber is isolated from the rest.

    def self.subscribe(role, table, &handler)
      unless handler
        raise ArgumentError, "subscribe requires a block"
      end
      validate_role(role)
      subs = (@subscriptions ||= {}) # steep:ignore UnannotatedEmptyCollection
      serial = (@subscription_serial || 0) + 1
      @subscription_serial = serial
      subs[serial] = [role, table.to_s, handler]
      serial
    end

    def self.unsubscribe(id)
      subs = @subscriptions
      subs.delete(id) if subs
      nil
    end

    # The raw-SQL protocol (docs, "Querying"): after writing through a
    # guarded handle yourself, tell the framework. Preferred form is the
    # model class -- it knows both its database role and its table; the
    # explicit (role, table) pair exists because a bare table name would
    # be ambiguous between the two databases.
    def self.notify_changed(target, table = nil)
      if table.nil?
        model = target
        if model.ephemeral?
          raise NoTableError,
            "#{model.to_s} is storage :ephemeral; there is no table to " \
            "notify about"
        end
        return notify_changed(model.local? ? :local : :replica,
                              model.table_name)
      end
      role = validate_role(target)
      name = table.to_s
      # Defer only under an open transaction on the SAME database: local
      # and replica are separate SQLite databases with independent
      # transactions, so their pending events never mix.
      if 0 < deferral_depth(role)
        seen = pending_seen(role)
        key = "#{role}:#{name}"
        unless seen.has_key?(key)
          seen[key] = true
          pending_order(role) << [role, name]
        end
      else
        enqueue_delivery(role, name)
      end
      nil
    end

    def self.validate_role(role)
      return role if role == :local
      return role if role == :replica
      raise ArgumentError,
        "role must be :local or :replica, got #{role.inspect}"
    end

    def self.deferral_depth(role)
      depths = @deferral_depths
      value = depths ? depths[role] : nil
      value || 0
    end

    def self.pending_seen(role)
      all = (@pending_seen ||= {}) # steep:ignore UnannotatedEmptyCollection
      all[role] ||= {}
    end

    def self.pending_order(role)
      all = (@pending_orders ||= {}) # steep:ignore UnannotatedEmptyCollection
      all[role] ||= []
    end

    # Transaction hooks (GuardedDatabase), tracked PER ROLE: the local
    # and replica databases transact independently. Only the outermost
    # commit of a role flushes its pending events; a rollback at depth
    # zero discards them.
    def self.__begin_deferral(role)
      depths = (@deferral_depths ||= {}) # steep:ignore UnannotatedEmptyCollection
      depths[role] = deferral_depth(role) + 1
    end

    def self.__commit_deferral(role)
      depths = (@deferral_depths ||= {}) # steep:ignore UnannotatedEmptyCollection
      depth = deferral_depth(role)
      depths[role] = depth - 1 if 0 < depth
      return unless deferral_depth(role) == 0
      order = pending_order(role)
      clear_pending(role)
      order_size = order.size
      i = 0
      while i < order_size
        event = order[i]
        enqueue_delivery(event[0], event[1])
        i += 1
      end
    end

    def self.__rollback_deferral(role)
      depths = (@deferral_depths ||= {}) # steep:ignore UnannotatedEmptyCollection
      depth = deferral_depth(role)
      depths[role] = depth - 1 if 0 < depth
      clear_pending(role) if deferral_depth(role) == 0
    end

    def self.clear_pending(role)
      seen_all = @pending_seen
      seen_all.delete(role) if seen_all
      order_all = @pending_orders
      order_all.delete(role) if order_all
      nil
    end

    # Delivery belongs to the NEXT tick (docs decision 10): a write that
    # happens during a component update must never patch watchers
    # synchronously into that update. Until the scheduled drain runs,
    # events collapse per [role, table]; the first event of a tick
    # schedules exactly one drain.
    def self.enqueue_delivery(role, table)
      pending = (@tick_events ||= {}) # steep:ignore UnannotatedEmptyCollection
      key = "#{role}:#{table}"
      unless pending.has_key?(key)
        pending[key] = true
        order = (@tick_order ||= []) # steep:ignore UnannotatedEmptyCollection
        order << [role, table]
      end
      return nil if @drain_scheduled
      @drain_scheduled = true
      schedule_drain
      nil
    end

    # Boot/tests may install their own scheduler (it must eventually
    # call __drain_events once). The default rides JS setTimeout(0); on
    # CRuby (SSR, native tests) there is no JS event loop AND no
    # component can be mid-update, so draining immediately is safe.
    def self.__set_tick_scheduler(scheduler)
      @tick_scheduler = scheduler
    end

    def self.schedule_drain
      scheduler = @tick_scheduler
      if scheduler
        scheduler.call
      elsif Object.const_defined?(:JS)
        JS.global.setTimeout(0) do
          __drain_events
        end
      else
        __drain_events
      end
      nil
    end

    def self.__drain_events
      # Un-schedule FIRST: events raised by the subscribers below belong
      # to the next tick and must get a drain of their own.
      @drain_scheduled = false
      order = @tick_order
      @tick_order = []
      @tick_events = {}
      return nil unless order
      order_size = order.size
      i = 0
      while i < order_size
        event = order[i]
        deliver_event(event[0], event[1])
        i += 1
      end
      nil
    end

    def self.deliver_event(role, table)
      subs = @subscriptions
      return unless subs
      # Snapshot the ids: a handler may (un)subscribe during delivery.
      ids = subs.keys
      ids_size = ids.size
      i = 0
      while i < ids_size
        entry = subs[ids[i]]
        if entry && entry[0] == role && entry[1] == table
          begin
            entry[2].call(role, table)
          rescue => e
            # Subscriber isolation: one broken watcher must not starve
            # the others (docs decision 10).
            puts "[Funicular] change subscriber raised: " \
                 "#{e.class}: #{e.message}"
          end
        end
        i += 1
      end
    end

    # ---- guarded database handles (docs decision 15) --------------------
    #
    # Funicular::DB.local/.replica hand out these proxies, never raw
    # connections. The allowlist is CLOSED: persist/close/serialize/
    # deserialize/backup do not exist here in ANY state, so no caller
    # can snapshot, close, or swap the database out from under the
    # framework. Read-only enforcement happens at every execution entry
    # via Statement#readonly? -- a statement prepared while writable is
    # still refused once the handle went read-only.

    # Statements that subvert framework control are rejected in every
    # state: ATTACH/DETACH escape to other database files, and
    # PRAGMA query_only would lift (or fake) the read-only lockdown.
    # sqlite3_stmt_readonly classifies all three as read-only, so the
    # statement-level check alone would let them through.
    def self.guard_statement_sql(sql)
      s = sql.to_s
      i = skip_sql_blanks(s, 0)
      head = read_sql_word(s, i)
      word = head[0]
      if word == "attach" || word == "detach"
        raise ArgumentError,
          "ATTACH/DETACH are not available through the guarded " \
          "database handle"
      end
      # Only the PRAGMA NAME decides (read pragmas stay available):
      # "PRAGMA table_info(query_only)" is fine, "PRAGMA query_only",
      # "PRAGMA main.query_only = OFF" and quoted spellings are not.
      if word == "pragma" && pragma_name(s, head[1]) == "query_only"
        raise ArgumentError,
          "PRAGMA query_only is managed by the framework and cannot be " \
          "issued through the guarded database handle"
      end
    end

    # The first keyword of a statement, lowercased, with leading
    # whitespace and -- and /* */ comments skipped (a comment prefix
    # must not smuggle ATTACH past the guard).
    def self.statement_head(sql)
      s = sql.to_s
      read_sql_word(s, skip_sql_blanks(s, 0))[0]
    end

    # The [schema.]name of a PRAGMA statement, starting right after the
    # PRAGMA keyword (pos). Quoted names ("x", 'x', `x`, [x]) resolve to
    # their inner text so quoting cannot smuggle query_only past the
    # guard.
    def self.pragma_name(s, pos)
      i = skip_sql_blanks(s, pos)
      token = read_sql_token(s, i)
      name = token[0]
      i = skip_sql_blanks(s, token[1])
      if s.getbyte(i) == 46 # '.': schema-qualified, the name follows
        token = read_sql_token(s, skip_sql_blanks(s, i + 1))
        name = token[0]
      end
      name
    end

    # Skip whitespace and -- / /* */ comments; returns the next index.
    def self.skip_sql_blanks(s, i)
      len = s.length
      while i < len
        c = s.getbyte(i)
        if c == 32 || c == 9 || c == 10 || c == 13
          i += 1
        elsif c == 45 && s.getbyte(i + 1) == 45 # "--" line comment
          i += 2
          while i < len && !(s.getbyte(i) == 10)
            i += 1
          end
        elsif c == 47 && s.getbyte(i + 1) == 42 # "/*" block comment
          i += 2
          while i < len && !(s.getbyte(i) == 42 && s.getbyte(i + 1) == 47)
            i += 1
          end
          i += 2
        else
          break
        end
      end
      i
    end

    # Read a bare identifier/keyword at i: [downcased word, next index].
    def self.read_sql_word(s, i)
      len = s.length
      start = i
      while i < len
        c = s.getbyte(i)
        unless c && ((97 <= c && c <= 122) || (65 <= c && c <= 90) ||
                     (48 <= c && c <= 57) || c == 95)
          break
        end
        i += 1
      end
      word = s[start, i - start]
      [word ? word.downcase : "", i]
    end

    # Like read_sql_word, but also resolves quoted identifiers to their
    # inner text.
    def self.read_sql_token(s, i)
      c = s.getbyte(i)
      closer = nil
      if c == 91 # [ closes with ]
        closer = 93
      elsif c == 34 # "
        closer = 34
      elsif c == 39 # '
        closer = 39
      elsif c == 96 # `
        closer = 96
      end
      return read_sql_word(s, i) unless closer
      len = s.length
      j = i + 1
      start = j
      while j < len && !(s.getbyte(j) == closer)
        j += 1
      end
      word = s[start, j - start]
      [word ? word.downcase : "", j + 1]
    end

    # The one execution-time gate every guarded entry point shares:
    # read-only handles run read-only statements only, no matter when
    # the statement (or its result set) was created.
    def self.enforce_read_only(read_only, raw_stmt)
      if read_only && !raw_stmt.readonly?
        raise ReadOnlyTabError,
          "this tab cannot write to the local database (read-only state)"
      end
    end

    class GuardedStatement
      def initialize(stmt, guard)
        @stmt = stmt
        @guard = guard
      end

      def bind_params(*bind_vars)
        @stmt.bind_params(*bind_vars)
      end

      def readonly?
        @stmt.readonly?
      end

      def columns
        @stmt.columns
      end

      def close
        @stmt.close
      end

      def closed?
        @stmt.closed?
      end

      # Returns materialized rows, never the raw ResultSet (the closed
      # allowlist would otherwise leak through it).
      def execute(*bind_vars)
        check_writable
        @stmt.execute(*bind_vars).to_a
      end

      def step
        check_writable
        @stmt.step
      end

      private

      def check_writable
        DB.enforce_read_only(@guard.read_only?, @stmt)
      end
    end

    # Wraps a raw ResultSet so stepping it re-checks the read-only state
    # every time: a write+RETURNING result set created while writable
    # must refuse to step after the handle went read-only.
    class GuardedResultSet
      def initialize(rs, stmt, guard)
        @rs = rs
        @stmt = stmt
        @guard = guard
      end

      def next
        check_writable
        @rs.next
      end

      def each
        row = self.next
        while row
          yield row
          row = self.next
        end
        self
      end

      def to_a
        # @type var rows: Array[untyped]
        rows = []
        row = self.next
        while row
          rows << row
          row = self.next
        end
        rows
      end

      # reset rebinds and re-runs the statement: same gate as stepping.
      def reset(*bind_params)
        check_writable
        @rs.reset(*bind_params)
      end

      def eof?
        @rs.eof?
      end

      def close
        @rs.close
      end

      def closed?
        @rs.closed?
      end

      def columns
        @rs.columns
      end

      def types
        @rs.types
      end

      private

      def check_writable
        DB.enforce_read_only(@guard.read_only?, @stmt)
      end
    end

    class GuardedDatabase
      def initialize(db, role = :local, read_only = false)
        @db = db
        @role = DB.validate_role(role)
        @read_only = read_only
      end

      # Which database this handle fronts (:local or :replica); event
      # deferral is tracked per role.
      def role
        @role
      end

      def read_only?
        @read_only
      end

      # One-way by design: persistent_reader tabs stay readers for the
      # life of the page and the terminal latch only ever tightens.
      def __become_read_only
        @read_only = true
      end

      def execute(sql, bind_vars = [])
        prepare(sql) do |stmt|
          rows = stmt.execute(*bind_vars)
          if block_given?
            rows_size = rows.size
            i = 0
            while i < rows_size
              yield rows[i]
              i += 1
            end
          end
          rows
        end
      end

      def prepare(sql)
        DB.guard_statement_sql(sql)
        stmt = GuardedStatement.new(@db.prepare(sql), self)
        return stmt unless block_given?
        begin
          yield stmt
        ensure
          stmt.close unless stmt.closed?
        end
      end

      # SQLite3::Database#query equivalent: a result set you step through
      # yourself -- wrapped, so neither the raw connection nor the raw
      # ResultSet ever surfaces. With a block the set is closed for you.
      def query(sql, bind_vars = [])
        DB.guard_statement_sql(sql)
        stmt = @db.prepare(sql)
        stmt.bind_params(*bind_vars) unless bind_vars.empty?
        result = GuardedResultSet.new(
          SQLite3::ResultSet.new(@db, stmt), stmt, self)
        return result unless block_given?
        begin
          yield result
        ensure
          result.close
        end
      end

      def get_first_row(sql, bind_vars = [])
        execute(sql, bind_vars)[0]
      end

      def get_first_value(sql, bind_vars = [])
        row = execute(sql, bind_vars)[0]
        return nil unless row
        row.is_a?(Hash) ? row.values[0] : row[0]
      end

      # Yields THIS proxy (docs decision 15), so raw connections never
      # surface through the transaction block either.
      def transaction(mode = :deferred)
        mode_sql = if mode == :deferred
          "DEFERRED"
        elsif mode == :immediate
          "IMMEDIATE"
        elsif mode == :exclusive
          "EXCLUSIVE"
        else
          raise ArgumentError, "invalid transaction mode #{mode.inspect}"
        end
        execute("BEGIN #{mode_sql} TRANSACTION")
        # Deferral starts with the transaction ITSELF, block or not:
        # change events raised before COMMIT coalesce and fire only
        # after it -- or vanish with the rollback (docs decision 10).
        # commit/rollback below settle it, so the raw blockless form
        # (transaction / execute / notify_changed / rollback) honors the
        # same contract.
        DB.__begin_deferral(@role)
        return true unless block_given?
        aborting = false
        begin
          yield self
        rescue => e
          aborting = true
          # Explicit re-raise: a bare `raise` would not re-raise on the
          # mruby VM.
          raise e
        ensure
          aborting ? rollback : commit
        end
      end

      def commit
        execute("COMMIT TRANSACTION")
        DB.__commit_deferral(@role)
        true
      end

      def rollback
        execute("ROLLBACK TRANSACTION")
        DB.__rollback_deferral(@role)
        true
      end
    end

    # ---- writer election (docs decision 14) -----------------------------
    #
    # One tab per namespace persists. The election runs ONCE at boot
    # with Web Locks' ifAvailable: granted makes this tab the
    # persistent_writer (the lock is held by a promise resolved only at
    # release), not granted makes it a persistent_reader for the LIFE of
    # the page -- no promotion in v1, reload to write. No Web Locks API
    # at all (or an API failure) means volatile: everything works,
    # nothing persists.

    # The JS side, installed once via eval. Tests (and exotic hosts) may
    # inject their own Locks API as globalThis.__funicularLocksApi; the
    # real navigator.locks is the fallback.
    LOCK_SHIM_JS = <<~'FUNICULAR_LOCK_JS'
      (() => {
        if (globalThis.__funicularLocks) return;
        globalThis.__funicularLocks = {
          holds: {},
          acquire(name) {
            return new Promise((resolveAcquire) => {
              // Injection seam: undefined falls through to the real
              // navigator.locks; anything else (an object, or null to
              // simulate ABSENCE even where the host has real locks --
              // Node ships navigator.locks) is taken as-is.
              const injected = globalThis.__funicularLocksApi;
              const locks = (injected === undefined)
                ? (globalThis.navigator && globalThis.navigator.locks)
                : injected;
              if (!locks || !locks.request) {
                resolveAcquire("unsupported");
                return;
              }
              try {
                const requested = locks.request(
                  name, { ifAvailable: true }, (lock) => {
                    if (!lock) {
                      resolveAcquire("busy");
                      return null;
                    }
                    return new Promise((release) => {
                      globalThis.__funicularLocks.holds[name] = release;
                      resolveAcquire("acquired");
                    });
                  });
                Promise.resolve(requested).catch(() => {
                  resolveAcquire("error");
                });
              } catch (e) {
                resolveAcquire("error");
              }
            });
          },
          release(name) {
            const release = globalThis.__funicularLocks.holds[name];
            if (!release) return false;
            delete globalThis.__funicularLocks.holds[name];
            release();
            return true;
          }
        };
      })()
    FUNICULAR_LOCK_JS

    # :unbooted -> :persistent_writer | :persistent_reader | :volatile.
    # ("volatile" is deliberately distinct from storage :ephemeral.)
    def self.durability
      @durability || :unbooted
    end

    # Boot/test seam; election itself is one-shot.
    def self.__set_durability(state)
      @durability = state
    end

    def self.elect_writer(lock_name)
      unless durability == :unbooted
        raise Error,
          "the writer election already ran (this tab is #{durability})"
      end
      # Claim the slot BEFORE awaiting: the await suspends this Task,
      # and a concurrent elect_writer from another Task must fail the
      # one-shot check meanwhile -- two elections could otherwise hold
      # two locks with only one of them releasable.
      @durability = :electing
      begin
        install_lock_shim
        # @type var shim: untyped
        shim = JS.global[:__funicularLocks]
        result = shim.acquire(lock_name).await.to_s
      rescue => e
        @durability = :unbooted
        # Explicit re-raise: a bare `raise` would not re-raise on the
        # mruby VM.
        raise e
      end
      state = if result == "acquired"
        :persistent_writer
      elsif result == "busy"
        :persistent_reader
      else
        # "unsupported" (no Web Locks) or an API error: by-design
        # absence drops the page to volatile (docs decision 14).
        :volatile
      end
      @writer_lock_name = lock_name if state == :persistent_writer
      @durability = state
      state
    end

    def self.install_lock_shim
      return if @lock_shim_installed
      # @type var global: untyped
      global = JS.global
      global.eval(LOCK_SHIM_JS)
      @lock_shim_installed = true
    end

    # Terminal step-down (docs decision 13) and teardown: resolving the
    # holding promise lets a NEW tab win the next election. No-op unless
    # this tab holds the lock.
    def self.release_writer_lock
      name = @writer_lock_name
      return false unless name
      @writer_lock_name = nil
      # @type var shim: untyped
      shim = JS.global[:__funicularLocks]
      shim.release(name)
      # Stepping down is one-way: another tab can win the lock from now
      # on, so THIS tab must never persist again. It becomes a
      # non-persisting reader, exactly like a tab that lost the
      # election (docs decision 13).
      @durability = :persistent_reader
      true
    end

    # ---- namespace identity (docs decisions 12/13) ----------------------
    #
    # One browser profile can hold data for several apps and several
    # users, so everything durable -- the two snapshot keys, the Web
    # Lock name, the identity the Rails session tracks for epoch
    # rotation -- hangs off ONE identity: a typed, versioned tuple
    # encoded as canonical JSON. STRUCTURE separates the fields, not a
    # delimiter, so a user_key of "anonymous" (or one containing any
    # separator) can never collide with the anonymous identity or with
    # another application's.

    # ["v1", app, "anonymous"] or ["v1", app, "user", key] as a JSON
    # string. Empty application_id/user_key fail loud: they would fold
    # distinct namespaces into one.
    def self.namespace_identity(application_id, user_key, anonymous)
      app = application_id.to_s
      if app.empty?
        raise ConfigError,
          "application_id must be configured (Funicular.configure)"
      end
      return JSON.generate(["v1", app, "anonymous"]) if anonymous
      key = user_key.to_s
      if key.empty?
        raise ConfigError, "user_key must not be empty"
      end
      JSON.generate(["v1", app, "user", key])
    end

    # The declaration rules, checked authoritatively on the CLIENT (docs
    # decision 12: only the client knows whether storage :local models
    # are declared). user_key_configured says whether a user_key SOURCE
    # is declared at all; user_key is the value it resolved to for THIS
    # page load -- nil while signed out. Configuration errors key off
    # the flag, the anonymous/user choice keys off the value: a
    # signed-out visit to an app with local models boots into the
    # anonymous namespace instead of failing.
    def self.resolve_namespace(application_id:, user_key:,
                               user_key_configured:, anonymous_only:,
                               local_models:)
      if user_key_configured && anonymous_only
        raise ConfigError,
          "user_key and anonymous_only are mutually exclusive; " \
          "configure exactly one"
      end
      if !user_key_configured && !anonymous_only && local_models
        raise ConfigError,
          "storage :local models are declared but no user_key is " \
          "configured; set config.user_key, or anonymous_only = true " \
          "to accept one shared anonymous namespace"
      end
      # nil is the legitimate signed-out state. An EMPTY string is a
      # broken user_key source: it falls through to namespace_identity's
      # ConfigError, because silently folding it into the shared
      # anonymous namespace would mix distinct users' data.
      namespace_identity(application_id, user_key, user_key.nil?)
    end

    # Everything durable derives its name from the identity string.

    def self.snapshot_key(identity, role)
      unless role == :replica || role == :local
        raise ArgumentError,
          "role must be :replica or :local, got #{role.inspect}"
      end
      "funicular:snapshot:#{role}:#{identity}"
    end

    def self.lock_name(identity)
      "funicular:lock:#{identity}"
    end

    # ---- replica tables: schema-derived DDL + fingerprint ---------------
    #
    # Replica tables mirror server data; their shape is DERIVED from the
    # server-delivered schema (docs decision 6), never migrated by hand.
    # The fingerprint is the canonical schema JSON itself, stored in the
    # meta table and compared by string equality.

    REPLICA_FINGERPRINT_KEY = "replica_fingerprint"

    # CREATE TABLE for one replica model. The id column type follows the
    # server (:integer -> INTEGER, anything else -> TEXT for UUIDs); a
    # schema without an id cannot be mirrored by row identity.
    def self.replica_table_ddl(model)
      columns = model.local_columns
      id_type = columns["id"]
      unless id_type
        raise ArgumentError,
          "#{model.table_name}: the server schema has no id attribute; " \
          "rows cannot be mirrored -- declare storage :ephemeral"
      end
      table = validate_identifier(model.table_name)
      # @type var defs: Array[String]
      defs = ["\"id\" #{id_type == :integer ? "INTEGER" : "TEXT"} PRIMARY KEY"]
      names = columns.keys
      names_size = names.size
      i = 0
      while i < names_size
        name = names[i]
        unless name == "id"
          defs << "\"#{validate_identifier(name)}\" " \
                  "#{SQL_TYPES[columns[name]] || "TEXT"}"
        end
        i += 1
      end
      "CREATE TABLE \"#{table}\" (#{defs.join(", ")})"
    end

    # The canonical schema JSON: only DDL-affecting data (table names,
    # column names and types, the id type), tables and columns sorted by
    # name so hash ordering never leaks in. This string IS the
    # fingerprint -- no digest (docs decision 6).
    def self.canonical_replica_schema(models)
      # @type var tables: Array[untyped]
      tables = []
      models_size = models.size
      i = 0
      while i < models_size
        model = models[i]
        columns = model.local_columns
        names = columns.keys.sort
        # @type var cols: Array[untyped]
        cols = []
        names_size = names.size
        j = 0
        while j < names_size
          cols << [names[j], columns[names[j]].to_s]
          j += 1
        end
        tables << [model.table_name, cols]
        i += 1
      end
      # Plain array comparison: entries are [table_name, columns], so the
      # sort is deterministic down to the column definitions without a
      # comparator block.
      tables.sort!
      JSON.generate(["v1", tables])
    end

    # Bring the replica database to the declared schema. A matching
    # fingerprint keeps every table and its data; a mismatch (or a fresh
    # database) drops and recreates ALL replica tables EMPTY -- they
    # refill on the app's next explicit fetch -- and stores the new
    # fingerprint. One transaction. Returns true when tables were
    # (re)built.
    # The replica lives in its own database -- storage :local tables are
    # in the OTHER database and can legitimately share names with
    # replica tables (that is why notify_changed takes a database role).
    # Only the framework's meta table needs shielding here.
    def self.build_replica_tables(db, models)
      # Duplicate checks compare ASCII-lowercased keys: SQLite table
      # names are case-insensitive even when quoted. SQL statements keep
      # the original validated spelling (the hash VALUES).
      # @type var tables: Hash[String, String]
      tables = {}
      models_size = models.size
      i = 0
      while i < models_size
        name = guard_reserved_table(validate_identifier(models[i].table_name))
        key = name.downcase
        if tables.has_key?(key)
          raise ArgumentError,
            "two replica models declare the table \"#{name}\" " \
            "(SQLite table names are case-insensitive); give one of " \
            "them another table_name"
        end
        tables[key] = name
        i += 1
      end
      fingerprint = canonical_replica_schema(models)
      stored = read_meta(db, REPLICA_FINGERPRINT_KEY)
      return false if stored == fingerprint
      # Drop the UNION of old and new table names: a model REMOVED from
      # the declared set must not leave its stale table (and data)
      # behind. The old names come from the stored fingerprint itself --
      # it IS the canonical schema JSON.
      old_names = stale_replica_tables(stored)
      old_size = old_names.size
      i = 0
      while i < old_size
        begin
          # @type var old_name: String
          old_name = validate_identifier(old_names[i])
          # @type var old_key: String
          old_key = old_name.downcase
          unless old_key == META_TABLE || tables.has_key?(old_key)
            tables[old_key] = old_name
          end
        rescue ArgumentError
          # A corrupted meta row must not smuggle SQL into DROP TABLE.
        end
        i += 1
      end
      db.transaction do
        keys = tables.keys
        keys_size = keys.size
        i = 0
        while i < keys_size
          db.execute("DROP TABLE IF EXISTS \"#{tables[keys[i]]}\"")
          i += 1
        end
        i = 0
        while i < models_size
          db.execute(replica_table_ddl(models[i]))
          i += 1
        end
        store_meta(db, REPLICA_FINGERPRINT_KEY, fingerprint)
      end
      true
    end

    # The table names recorded in a stored canonical fingerprint; empty
    # when absent or unparsable (fail-safe: nothing extra to drop).
    def self.stale_replica_tables(stored)
      # @type var names: Array[String]
      names = []
      return names unless stored
      begin
        parsed = JSON.parse(stored)
      rescue
        return names
      end
      return names unless parsed.is_a?(Array)
      list = parsed[1]
      return names unless list.is_a?(Array)
      list_size = list.size
      i = 0
      while i < list_size
        entry = list[i]
        names << entry[0].to_s if entry.is_a?(Array)
        i += 1
      end
      names
    end

    # Apply one server-authoritative row: THE single write-through entry
    # point (docs decision 5) -- fetch-through, create/update responses,
    # and future Cable sync all land here. Whole-row INSERT OR REPLACE
    # through the codec; keys absent from attrs store NULL (the server
    # row is authoritative, there is no partial merge). Fires the
    # model's change hook.
    def self.replica_upsert(db, model, attrs)
      replica_upsert_row(db, model, attrs)
      model.local_table_changed
      true
    end

    # Batch apply for whole-collection fetches: every row lands -- or,
    # when any row fails (a malformed value, most likely), NONE does --
    # inside ONE transaction, and the change hook fires once after the
    # commit: a 50-row fetch is one event, not fifty.
    def self.replica_upsert_all(db, model, rows)
      rows_size = rows.size
      return true if rows_size == 0
      db.transaction do
        i = 0
        while i < rows_size
          replica_upsert_row(db, model, rows[i])
          i += 1
        end
      end
      model.local_table_changed
      true
    end

    class << self
      # NOT a public entry point: writing a row without the change
      # notification would bypass the apply-path contract. Only
      # replica_upsert and replica_upsert_all come through here.
      private def replica_upsert_row(db, model, attrs)
        columns = model.local_columns
        table = validate_identifier(model.table_name)
        names = columns.keys
        # @type var cols: Array[String]
        cols = []
        # @type var marks: Array[String]
        marks = []
        # @type var binds: Array[untyped]
        binds = []
        id_present = false
        names_size = names.size
        i = 0
        while i < names_size
          name = names[i]
          if attrs.has_key?(name)
            value = attrs[name]
          elsif attrs.has_key?(name.to_sym)
            value = attrs[name.to_sym]
          else
            value = nil
          end
          id_present = true if name == "id" && !value.nil?
          cols << "\"#{name}\""
          marks << "?"
          binds << Codec.encode(columns[name], value)
          i += 1
        end
        unless id_present
          raise ArgumentError,
            "replica upsert into #{model.table_name} requires an id; " \
            "the server row has none"
        end
        db.execute("INSERT OR REPLACE INTO \"#{table}\" " \
                   "(#{cols.join(", ")}) VALUES (#{marks.join(", ")})", binds)
      end
    end

    # Remove one mirrored row (write-through destroy). Notifies only
    # when the row existed; RETURNING keeps the check inside the one
    # statement (no changes() race).
    def self.replica_delete(db, model, id)
      table = validate_identifier(model.table_name)
      rows = db.execute(
        "DELETE FROM \"#{table}\" WHERE \"id\" = ? RETURNING \"id\"",
        [Codec.encode(model.local_columns["id"], id)])
      deleted = !rows.empty?
      model.local_table_changed if deleted
      deleted
    end

    def self.quoted_list(columns)
      # @type var quoted: Array[String]
      quoted = []
      i = 0
      while i < columns.size
        quoted << "\"#{columns[i]}\""
        i += 1
      end
      quoted.join(", ")
    end
  end
end
