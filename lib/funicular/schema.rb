# frozen_string_literal: true

module Funicular
  # Derives client-side validation rules from an ActiveModel/ActiveRecord
  # class so they can be embedded in the JSON returned by a schema controller
  # and reused by Funicular::Model on the client.
  #
  # Security model: validations are derived ONLY for the attribute names the
  # caller passes (the schema's existing attribute allowlist), so nothing
  # outside the already-public schema is ever introspected. A per-attribute
  # `except` denylist suppresses specific validator kinds.
  module Schema
    # Validator kinds that have a client-side counterpart in
    # Funicular::Model::Validations. Others (notably :uniqueness, which needs
    # the database, and any custom validator) are skipped.
    SUPPORTED_KINDS = %i[
      presence absence length format numericality
      inclusion exclusion acceptance confirmation
    ].freeze

    # Build a full schema hash, merging derived validations inline into each
    # attribute entry (the shape Funicular::Model.load_schema consumes):
    #
    #   Funicular::Schema.build(User,
    #     attributes: { "display_name" => { type: "string", readonly: false } },
    #     endpoints:  { "update" => { method: "PATCH", path: "/users/:id" } },
    #     except:     { username: [:format] })
    #   # => { attributes: { "display_name" => { type:, readonly:,
    #   #        validations: { "presence" => true, "length" => {...} } } },
    #   #      endpoints: {...} }
    #
    # Only the attributes you declare are introspected (allowlist); `except`
    # drops specific kinds per attribute (denylist).
    def self.build(model_class, attributes:, endpoints: {}, except: {})
      merged = {}
      attributes.each do |name, definition|
        rules = rules_for(model_class, name, except_kinds(except, name))
        merged[name] = rules.empty? ? definition : definition.merge(validations: rules)
      end
      { attributes: merged, endpoints: endpoints }
    end

    # Returns { "attr" => { "presence" => true, "length" => { "maximum" => 30 } } }
    # for the given attribute names only. Useful when emitting validations as a
    # separate block rather than inline (see #build for the inline form).
    def self.validations_for(model_class, attribute_names, except: {})
      result = {}
      attribute_names.each do |name|
        rules = rules_for(model_class, name, except_kinds(except, name))
        result[name.to_s] = rules unless rules.empty?
      end
      result
    end

    # Derive the { kind => options } rules for a single attribute.
    def self.rules_for(model_class, name, skip_kinds)
      attr = name.to_sym
      rules = {}
      model_class.validators_on(attr).each do |validator|
        kind = validator.kind
        next unless SUPPORTED_KINDS.include?(kind)
        next if skip_kinds.include?(kind)
        # Conditional/context validators can't be evaluated on the client.
        next if conditional?(validator.options)

        serialized = serialize(kind, validator.options)
        next if serialized.nil?
        rules[kind.to_s] = serialized
      end
      rules
    end

    def self.except_kinds(except, name)
      Array(except[name.to_sym] || except[name.to_s]).map(&:to_sym)
    end

    def self.conditional?(options)
      options.key?(:if) || options.key?(:unless) || options.key?(:on)
    end

    def self.serialize(kind, options)
      case kind
      when :presence, :absence, :acceptance, :confirmation
        true
      when :length
        serialize_length(options)
      when :numericality
        serialize_numericality(options)
      when :inclusion, :exclusion
        serialize_set(options)
      when :format
        RegexpTranslator.translate(options[:with])
      end
    end

    def self.serialize_length(options)
      opts = {}
      [:minimum, :maximum, :is].each do |k|
        opts[k.to_s] = options[k] if options[k].is_a?(Integer)
      end
      if (range = options[:in] || options[:within]).is_a?(Range)
        opts["minimum"] = range.min
        opts["maximum"] = range.max
      end
      opts.empty? ? nil : opts
    end

    def self.serialize_numericality(options)
      opts = {}
      opts["only_integer"] = true if options[:only_integer]
      [:greater_than, :greater_than_or_equal_to, :equal_to,
       :less_than, :less_than_or_equal_to, :other_than].each do |k|
        opts[k.to_s] = options[k] if options[k].is_a?(Numeric)
      end
      opts.empty? ? true : opts
    end

    def self.serialize_set(options)
      list = options[:in] || options[:within]
      list = list.to_a if list.is_a?(Range)
      return nil unless list.is_a?(Array)
      return nil unless list.all? { |v| json_scalar?(v) }
      { "in" => list }
    end

    def self.json_scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric) ||
        value == true || value == false || value.nil?
    end

    # Best-effort translation of a Ruby Regexp into a JS-RegExp-compatible
    # source. The client runs Regexp as a JS RegExp wrapper, so Ruby-only
    # constructs are either translated (\A, \z, \Z anchors) or, when they have
    # no safe JS equivalent, the validator is skipped with a warning.
    module RegexpTranslator
      # Substrings that JS RegExp cannot accept; presence means "skip".
      INCOMPATIBLE = ['[[:', '\\h', '\\H', '\\G', '(?>'].freeze

      def self.translate(regexp)
        return nil unless regexp.is_a?(Regexp)

        if (regexp.options & Regexp::EXTENDED) != 0
          return skip("extended (x) mode")
        end

        source = regexp.source
        if INCOMPATIBLE.any? { |token| source.include?(token) }
          return skip("uses a construct unsupported by JS RegExp")
        end

        js_source = source.gsub('\\A', '^').gsub('\\z', '$').gsub('\\Z', '$')

        flags = +''
        flags << 'i' if (regexp.options & Regexp::IGNORECASE) != 0
        flags << 'm' if (regexp.options & Regexp::MULTILINE) != 0

        { 'with' => js_source, 'flags' => flags }
      end

      def self.skip(reason)
        warn "[Funicular::Schema] skipping a format validator: #{reason}; " \
             "declare it directly in the Funicular::Model if needed"
        nil
      end
    end
  end
end
