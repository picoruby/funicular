module Funicular
  class StyleValue
    attr_reader :value

    def initialize(value)
      @value = value.to_s
    end

    def |(other)
      case other
      when StyleValue
        StyleValue.new("#{@value} #{other.value}".strip)
      when String
        StyleValue.new("#{@value} #{other}".strip)
      when nil
        self
      else
        other = other #: untyped
        StyleValue.new("#{@value} #{other.to_s}".strip)
      end
    end

    def to_s
      @value
    end
  end

  class StyleAccessor
    def initialize(definitions)
      @definitions = definitions
    end

    def [](name, variant = nil)
      style = @definitions[name]
      return StyleValue.new("") unless style

      if variant.nil?
        # No arguments: return base or value
        StyleValue.new(style[:base] || style[:value] || "")
      elsif variant == true || variant == false
        # Boolean argument: base + active (if true)
        # JS::Object#== now supports direct comparison with Ruby true/false
        base = style[:base] || ""
        active_class = (variant == true) ? (style[:active] || "") : ""
        StyleValue.new("#{base} #{active_class}".strip)
      elsif variant.is_a?(Symbol)
        # Symbol argument: base + variants[symbol]
        base = style[:base] || ""
        variant_class = style[:variants] ? (style[:variants][variant] || "") : ""
        StyleValue.new("#{base} #{variant_class}".strip)
      else
        # Other types: just return base
        StyleValue.new(style[:base] || style[:value] || "")
      end
    end
  end

  class StyleBuilder
    def initialize
      @definitions = {}
    end

    def define(name, value = nil, **options)
      if value.is_a?(String)
        @definitions[name] = { value: value }
      elsif value.is_a?(Hash)
        @definitions[name] = value
      elsif !options.empty?
        @definitions[name] = options
      else
        raise ArgumentError, "Invalid style definition for #{name}"
      end
    end

    def to_definitions
      @definitions
    end
  end
end
