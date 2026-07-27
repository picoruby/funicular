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
  end
end
