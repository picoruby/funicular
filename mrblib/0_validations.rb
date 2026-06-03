# Attribute validations for Funicular::Model, modeled on ActiveModel.
#
# This file is named with a "0_" prefix on purpose: the mruby build
# concatenates mrblib/**/*.rb in alphabetical order, so this loads before
# model.rb (which does `include Validations`) and before 1_validators.rb
# (the concrete validators). Keep this file free of Ruby-only regexp features
# (\A, \z, $1, ...): on the client, Regexp is a thin JS RegExp wrapper.
module Funicular
  class Model
    # A small slice of ActiveModel::Errors: messages keyed by attribute.
    # Consumed by FormBuilder, which reads errors[:field].
    class Errors
      def initialize
        @messages = {}
      end

      def add(attribute, message)
        key = attribute.to_sym
        (@messages[key] ||= []) << message
        message
      end

      # Always returns an array (possibly empty) for the attribute.
      def [](attribute)
        @messages[attribute.to_sym] || []
      end

      def added?(attribute)
        !self[attribute].empty?
      end

      # { attribute_symbol => ["message", ...] }
      def messages
        @messages
      end

      def full_messages
        result = [] #: Array[String]
        @messages.each do |attribute, msgs|
          human = humanize(attribute)
          msgs.each { |m| result << "#{human} #{m}" }
        end
        result
      end

      def clear
        @messages = {}
      end

      def empty?
        @messages.all? { |_attr, msgs| msgs.empty? }
      end

      def any?
        !empty?
      end

      private

      def humanize(attribute)
        words = attribute.to_s.split("_")
        first = words[0].to_s
        first = first[0].to_s.upcase + first[1..-1].to_s
        ([first] + words[1..-1].to_a).join(" ")
      end
    end

    module Validations
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Base class for attribute validators, mirroring
      # ActiveModel::Validations::EachValidator.
      class EachValidator
        attr_reader :attributes, :options

        def initialize(attributes:, **options)
          @attributes = attributes
          @options = options
        end

        # PresenceValidator -> :presence. Validator names are single words,
        # so a plain downcase is enough (no regexp needed).
        def kind
          name = self.class.to_s.split("::").last.to_s
          name = name[0...-9] if name.end_with?("Validator")
          name.to_s.downcase.to_sym
        end

        def validate(record)
          attributes.each do |attribute|
            value = record.read_attribute_for_validation(attribute)
            next if options[:allow_nil] && value.nil?
            next if options[:allow_blank] && blank?(value)
            validate_each(record, attribute, value)
          end
        end

        def validate_each(record, attribute, value)
          raise "#{self.class} must implement validate_each"
        end

        private

        def blank?(value)
          return true if value.nil?
          return value.strip.empty? if value.is_a?(String)
          return value.empty? if value.respond_to?(:empty?)
          false
        end

        def present?(value)
          !blank?(value)
        end
      end

      module ClassMethods
        # Validators declared on this model class.
        def validators
          @validators ||= []
        end

        def validators_on(attribute)
          attr = attribute.to_sym
          validators.select { |v| v.attributes.include?(attr) }
        end

        # Options that configure every validator in a `validates` call rather
        # than naming a validator of their own (mirrors ActiveModel).
        SHARED_OPTIONS = [:allow_nil, :allow_blank, :if, :unless, :on, :strict]

        # validates :a, :b, presence: true, length: { maximum: 30 }, allow_blank: true
        def validates(*attributes, **options)
          return if attributes.empty?
          attrs = attributes.map { |a| a.to_sym }

          shared = {} #: Hash[Symbol, untyped]
          SHARED_OPTIONS.each { |k| shared[k] = options[k] if options.key?(k) }

          options.each do |key, opts|
            next if SHARED_OPTIONS.include?(key)
            klass = validator_class_for(key)
            next unless klass
            base = {} #: Hash[Symbol, untyped]
            base = opts unless opts == true
            validator_options = shared.merge(base) # per-validator options win
            validators << klass.new(attributes: attrs, **validator_options)
          end
        end

        # Append a single schema-derived validator (from load_schema), unless a
        # validator of the same kind is already declared for the attribute in
        # the subclass body. Frontend declarations win, avoiding duplicates.
        def add_schema_validator(attribute, kind, opts)
          attr = attribute.to_sym
          k = kind.to_sym
          return if validators.any? { |v| v.attributes.include?(attr) && v.kind == k }
          klass = validator_class_for(kind)
          return unless klass
          validator_options = {} #: Hash[Symbol, untyped]
          validator_options = symbolize_keys(opts) unless opts == true
          validators << klass.new(attributes: [attr], **validator_options)
        end

        private

        def validator_class_for(key)
          class_name = "#{key.to_s.capitalize}Validator"
          return nil unless Funicular::Model::Validations.const_defined?(class_name)
          Funicular::Model::Validations.const_get(class_name)
        end

        def symbolize_keys(hash)
          return hash unless hash.is_a?(Hash)
          out = {} #: Hash[Symbol, untyped]
          hash.each { |k, v| out[k.to_sym] = v }
          out
        end
      end

      # --- instance API ---

      def errors
        @errors ||= Funicular::Model::Errors.new
      end

      def read_attribute_for_validation(attribute)
        send(attribute)
      end

      def valid?
        errors.clear
        # Steep does not know whether `self.class` extends ClassMethods
        # @type var cls: untyped
        cls = self.class
        cls.validators.each { |validator| validator.validate(self) }
        errors.empty?
      end

      def invalid?
        !valid?
      end
    end
  end
end
