# Concrete validators for Funicular::Model, mirroring the standard Rails set.
#
# Named "1_" so the mruby build loads it after 0_validations.rb (which defines
# EachValidator) but before model.rb. Keep this free of Ruby-only regexp
# features: on the client, Regexp is a JS RegExp wrapper.
module Funicular
  class Model
    module Validations
      class PresenceValidator < EachValidator
        def validate_each(record, attribute, value)
          record.errors.add(attribute, options[:message] || "can't be blank") if blank?(value)
        end
      end

      class AbsenceValidator < EachValidator
        def validate_each(record, attribute, value)
          record.errors.add(attribute, options[:message] || "must be blank") if present?(value)
        end
      end

      class LengthValidator < EachValidator
        def validate_each(record, attribute, value)
          length = value.nil? ? 0 : value.to_s.length

          if (min = options[:minimum]) && length < min
            record.errors.add(attribute, options[:message] ||
              "is too short (minimum is #{min} characters)")
          end
          if (max = options[:maximum]) && length > max
            record.errors.add(attribute, options[:message] ||
              "is too long (maximum is #{max} characters)")
          end
          if (exact = options[:is]) && length != exact
            record.errors.add(attribute, options[:message] ||
              "is the wrong length (should be #{exact} characters)")
          end
          if (range = options[:in] || options[:within]) && !range_include?(range, length)
            record.errors.add(attribute, options[:message] || "is the wrong length")
          end
        end

        private

        def range_include?(range, length)
          if range.respond_to?(:include?)
            range.include?(length)
          else
            false
          end
        end
      end

      class FormatValidator < EachValidator
        def validate_each(record, attribute, value)
          str = value.to_s
          if (with = options[:with]) && !str.match?(with)
            record.errors.add(attribute, options[:message] || "is invalid")
          end
          if (without = options[:without]) && str.match?(without)
            record.errors.add(attribute, options[:message] || "is invalid")
          end
        end
      end

      class NumericalityValidator < EachValidator
        CHECKS = {
          greater_than: ">",
          greater_than_or_equal_to: ">=",
          equal_to: "==",
          less_than: "<",
          less_than_or_equal_to: "<=",
          other_than: "!="
        }

        def validate_each(record, attribute, value)
          number = to_number(value)
          if number.nil?
            record.errors.add(attribute, options[:message] || "is not a number")
            return
          end

          if options[:only_integer] && !number.is_a?(Integer)
            record.errors.add(attribute, options[:message] || "must be an integer")
            return
          end

          CHECKS.each do |option, _operator|
            next unless options.key?(option)
            unless compare(number, option, options[option])
              record.errors.add(attribute, options[:message] || message_for(option, options[option]))
            end
          end
        end

        private

        def compare(number, option, target)
          case option
          when :greater_than then number > target
          when :greater_than_or_equal_to then number >= target
          when :equal_to then number == target
          when :less_than then number < target
          when :less_than_or_equal_to then number <= target
          when :other_than then number != target
          else true
          end
        end

        def message_for(option, target)
          case option
          when :greater_than then "must be greater than #{target}"
          when :greater_than_or_equal_to then "must be greater than or equal to #{target}"
          when :equal_to then "must be equal to #{target}"
          when :less_than then "must be less than #{target}"
          when :less_than_or_equal_to then "must be less than or equal to #{target}"
          when :other_than then "must be other than #{target}"
          else "is invalid"
          end
        end

        def to_number(value)
          return value if value.is_a?(Numeric)
          str = value.to_s.strip
          return nil if str.empty?
          begin
            Integer(str)
          rescue
            begin
              Float(str)
            rescue
              nil
            end
          end
        end
      end

      class InclusionValidator < EachValidator
        def validate_each(record, attribute, value)
          list = options[:in] || options[:within]
          return unless list.respond_to?(:include?)
          unless list.include?(value)
            record.errors.add(attribute, options[:message] || "is not included in the list")
          end
        end
      end

      class ExclusionValidator < EachValidator
        def validate_each(record, attribute, value)
          list = options[:in] || options[:within]
          return unless list.respond_to?(:include?)
          if list.include?(value)
            record.errors.add(attribute, options[:message] || "is reserved")
          end
        end
      end

      class AcceptanceValidator < EachValidator
        def validate_each(record, attribute, value)
          accepted = options[:accept] || ["1", "true", true]
          accepted = [accepted] unless accepted.is_a?(Array)
          unless accepted.include?(value)
            record.errors.add(attribute, options[:message] || "must be accepted")
          end
        end
      end

      class ConfirmationValidator < EachValidator
        def validate_each(record, attribute, value)
          confirmation_attr = "#{attribute}_confirmation"
          return unless record.respond_to?(confirmation_attr)
          confirmation = record.send(confirmation_attr)
          return if confirmation.nil?
          if value != confirmation
            record.errors.add(attribute, options[:message] || "doesn't match confirmation")
          end
        end
      end
    end
  end
end
