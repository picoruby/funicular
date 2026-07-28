# A lazy, chainable query over one local table (docs/local_database.md,
# "Querying"). Chain builders (where/order/limit/offset) each return a NEW
# Relation; SQL executes once, in a materializer.
#
# The `model` handed to the constructor is the query's metadata + row
# factory. Relation calls exactly these methods on it:
#
#   table_name          -> String
#   local_columns       -> Hash[String => Symbol]  (column name -> declared type)
#   local_db            -> handle responding to execute(sql, binds) -> rows
#   replica?            -> bool (delete_all guard)
#   build_from_local    -> (Hash) -> model instance (attrs already decoded)
#   local_table_changed -> void; called after a framework-managed write
#                          (delete_all here) so the model can fire change
#                          events and schedule snapshot persistence
#
# Identifiers in hash conditions and order() are validated against
# local_columns and double-quoted; values cross into SQL through
# Funicular::DB::Codec. Raw SQL fragments pass through untouched, their
# binds encoded by value (Codec.encode_bind).

module Funicular
  class Relation
    # The trailing arguments are internal: chain builders use them to spawn
    # derived relations. Application code passes only `model`.
    def initialize(model, where_sql = [], where_binds = [], order_sql = [],
                   limit = nil, offset = nil)
      @model = model
      @where_sql = where_sql
      @where_binds = where_binds
      @order_sql = order_sql
      @limit = limit
      @offset = offset
    end

    # ---- chain builders --------------------------------------------------

    # where(title: "x")              equality (nil -> IS NULL)
    # where(id: [1, 2])              IN (empty array -> WHERE 1=0)
    # where(id: 1..9)                BETWEEN (exclusive end -> >= AND <)
    # where("title LIKE ?", "a%")    raw fragment with placeholders
    # Multiple where calls AND together.
    def where(conditions = nil, *binds)
      w = @where_sql.dup
      b = @where_binds.dup
      if conditions.is_a?(Hash)
        keys = conditions.keys
        i = 0
        while i < keys.size
          append_condition(w, b, keys[i], conditions[keys[i]])
          i += 1
        end
      elsif conditions.is_a?(String)
        w << "(#{conditions})"
        i = 0
        while i < binds.size
          b << Funicular::DB::Codec.encode_bind(binds[i])
          i += 1
        end
      else
        raise ArgumentError,
          "where expects a Hash or a SQL fragment String, got #{conditions.inspect}"
      end
      Relation.new(@model, w, b, @order_sql, @limit, @offset)
    end

    # order(:created_at)                 ASC
    # order(created_at: :desc)
    # order(:pinned, created_at: :desc)  multiple keys
    def order(*args)
      if args.empty?
        raise ArgumentError, "order requires at least one column"
      end
      o = @order_sql.dup
      i = 0
      while i < args.size
        arg = args[i]
        if arg.is_a?(Hash)
          keys = arg.keys
          j = 0
          while j < keys.size
            o << order_term(keys[j], arg[keys[j]])
            j += 1
          end
        else
          o << order_term(arg, :asc)
        end
        i += 1
      end
      Relation.new(@model, @where_sql, @where_binds, o, @limit, @offset)
    end

    def limit(n)
      Relation.new(@model, @where_sql, @where_binds, @order_sql,
                   slice_arg(n, "limit"), @offset)
    end

    def offset(n)
      Relation.new(@model, @where_sql, @where_binds, @order_sql,
                   @limit, slice_arg(n, "offset"))
    end

    # ---- materializers ---------------------------------------------------

    def to_a
      rows = @model.local_db.execute(select_sql, @where_binds)
      cols = @model.local_columns.keys
      # @type var out: Array[untyped]
      out = []
      i = 0
      while i < rows.size
        out << @model.build_from_local(decode_row(cols, rows[i]))
        i += 1
      end
      out
    end

    def each
      list = to_a
      i = 0
      while i < list.size
        yield list[i]
        i += 1
      end
      list
    end

    # Instance or nil. Narrows the window to one row (never widens: a
    # relation already limited to 0 stays empty).
    def first
      lim = @limit
      lim = (lim.nil? || 1 <= lim) ? 1 : lim
      Relation.new(@model, @where_sql, @where_binds, @order_sql,
                   lim, @offset).to_a[0]
    end

    # SELECT COUNT(*); on a limited/offset relation it counts the window
    # (COUNT over a subquery), matching ActiveRecord.
    def count
      sql = if @limit || @offset
        "SELECT COUNT(*) FROM (#{select_sql})"
      else
        "SELECT COUNT(*) FROM #{quoted_table}#{where_clause}"
      end
      single_value(sql)
    end

    def exists?
      if @limit || @offset
        0 < count
      else
        sql = "SELECT 1 FROM #{quoted_table}#{where_clause} LIMIT 1"
        !@model.local_db.execute(sql, @where_binds).empty?
      end
    end

    def find(id)
      record = find_by(id: id)
      unless record
        raise Funicular::RecordNotFound,
          "Couldn't find #{model_label} with id=#{id}"
      end
      record
    end

    def find_by(conditions)
      where(conditions).first
    end

    # Bulk delete, `storage :local` models only; returns the number of
    # deleted rows. Raises on a relation carrying order/limit/offset (say
    # what you mean with a plain condition).
    def delete_all
      if @model.replica?
        raise Funicular::DB::ReplicaWriteError,
          "delete_all is not available on replica models; the server owns " \
          "replica rows (deletions reach the replica through destroy)"
      end
      if @limit || @offset || !@order_sql.empty?
        raise ArgumentError,
          "delete_all does not support order/limit/offset"
      end
      # RETURNING counts the deletions inside the one statement; reading
      # SELECT changes() afterwards would race other Tasks writing on the
      # same connection between the two calls.
      rows = @model.local_db.execute(
        "DELETE FROM #{quoted_table}#{where_clause} RETURNING \"id\"",
        @where_binds)
      count = rows.size
      # Framework-managed writes must notify (docs, "Querying"); a delete
      # that removed nothing changed nothing.
      @model.local_table_changed if 0 < count
      count
    end

    # The SELECT this relation will run (debugging aid; binds not inlined).
    def to_sql
      select_sql
    end

    # ---- internal --------------------------------------------------------

    private

    def append_condition(w, b, col, value)
      name = validate_column(col)
      q = quote(name)
      type = @model.local_columns[name]
      codec = Funicular::DB::Codec
      if value.nil?
        w << "#{q} IS NULL"
      elsif value.is_a?(Array)
        if value.empty?
          w << "1=0"
        else
          # @type var marks: Array[String]
          marks = []
          i = 0
          while i < value.size
            marks << "?"
            b << codec.encode(type, value[i])
            i += 1
          end
          w << "#{q} IN (#{marks.join(", ")})"
        end
      elsif value.is_a?(Range)
        b << codec.encode(type, value.begin)
        b << codec.encode(type, value.end)
        if value.exclude_end?
          w << "(#{q} >= ? AND #{q} < ?)"
        else
          w << "#{q} BETWEEN ? AND ?"
        end
      else
        w << "#{q} = ?"
        b << codec.encode(type, value)
      end
    end

    def order_term(col, dir)
      d = dir.to_s.downcase
      unless d == "asc" || d == "desc"
        raise ArgumentError,
          "order direction must be :asc or :desc, got #{dir.inspect}"
      end
      "#{quote(validate_column(col))} #{d == "asc" ? "ASC" : "DESC"}"
    end

    def validate_column(col)
      name = col.to_s
      unless @model.local_columns.has_key?(name)
        raise ArgumentError,
          "unknown column #{name.inspect} for table \"#{@model.table_name}\""
      end
      name
    end

    def quote(name)
      "\"#{name}\""
    end

    def quoted_table
      quote(@model.table_name)
    end

    def select_sql
      cols = @model.local_columns.keys
      # @type var quoted: Array[String]
      quoted = []
      i = 0
      while i < cols.size
        quoted << quote(cols[i])
        i += 1
      end
      "SELECT #{quoted.join(", ")} FROM #{quoted_table}" \
        "#{where_clause}#{order_clause}#{slice_clause}"
    end

    def where_clause
      w = @where_sql
      w.empty? ? "" : " WHERE #{w.join(" AND ")}"
    end

    def order_clause
      o = @order_sql
      o.empty? ? "" : " ORDER BY #{o.join(", ")}"
    end

    # LIMIT -1 OFFSET n is how SQLite spells offset-without-limit.
    def slice_clause
      lim = @limit
      off = @offset
      if lim
        off ? " LIMIT #{lim} OFFSET #{off}" : " LIMIT #{lim}"
      elsif off
        " LIMIT -1 OFFSET #{off}"
      else
        ""
      end
    end

    def slice_arg(n, label)
      return nil if n.nil?
      unless n.is_a?(Integer) && 0 <= n
        raise ArgumentError, "#{label} must be a non-negative Integer, got #{n.inspect}"
      end
      n
    end

    def decode_row(cols, row)
      codec = Funicular::DB::Codec
      columns = @model.local_columns
      # @type var attrs: Hash[String, untyped]
      attrs = {}
      i = 0
      while i < cols.size
        name = cols[i]
        raw = row.is_a?(Hash) ? row[name] : row[i]
        attrs[name] = codec.decode(columns[name], raw)
        i += 1
      end
      attrs
    end

    def single_value(sql)
      row = @model.local_db.execute(sql, @where_binds)[0]
      row.is_a?(Hash) ? row.values[0] : row[0]
    end

    def model_label
      m = @model
      m.respond_to?(:name) ? m.name : m.table_name
    end
  end
end
