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

  # Read-side accessor. One subclass is generated per component class with a
  # real method per declared style name (see accessor_for), so lookups never
  # go through method_missing at render time and a typo raises loudly.
  # BasicObject keeps Object/Kernel names (display, hash, ...) usable as
  # style names on both mruby and CRuby.
  class StyleAccessor < BasicObject
    def self.accessor_for(definitions)
      klass = ::Class.new(self) #: singleton(StyleAccessor)
      definitions.each_key do |name|
        klass.__send__(:define_method, name) do |variant = nil|
          self[name, variant] # steep:ignore
        end
      end
      klass
    end

    def initialize(definitions)
      @definitions = definitions
    end

    def [](name, variant = nil)
      style = @definitions[name]
      unless style
        ::Kernel.raise ::ArgumentError,
          "unknown style :#{name} (declared: #{@definitions.keys.map { |k| ":#{k}" }.join(', ')})"
      end

      if variant.nil?
        # No arguments: return base or value
        StyleValue.new(style[:base] || style[:value] || "")
      elsif variant == true || variant == false
        # Boolean argument: base + active (if true)
        base = style[:base] || ""
        active_class = (variant == true) ? (style[:active] || "") : ""
        StyleValue.new("#{base} #{active_class}".strip)
      elsif ::Symbol === variant
        # Symbol argument: base + variants[symbol]
        base = style[:base] || ""
        variant_class = style[:variants] ? (style[:variants][variant] || "") : ""
        StyleValue.new("#{base} #{variant_class}".strip)
      else
        # Other types: just return base
        StyleValue.new(style[:base] || style[:value] || "")
      end
    end

    def method_missing(name, *_args)
      ::Kernel.raise ::NoMethodError,
        "unknown style '#{name}' (declared: #{@definitions.keys.map { |k| ":#{k}" }.join(', ')})"
    end

    def respond_to_missing?(name, _include_private = false)
      @definitions.key?(name)
    end
  end

  # Definition-side builder. The class-level `styles do ... end` block is
  # instance_exec'd on an instance, so barewords define styles:
  #
  #   styles do
  #     shell "app-shell"
  #     button base: "btn", variants: { primary: "btn--primary" }
  #   end
  #
  # BasicObject keeps the bareword namespace clean on both VMs; the block
  # also receives the builder as an argument for the explicit form
  # `styles { |css| css.define(:name, ...) }`, needed when a value is
  # computed (a bareword helper call inside the block would be captured as
  # a style definition, and its nil return raises via validation below).
  class StyleBuilder < BasicObject
    # Style names that would clobber the builder/accessor internals.
    RESERVED_NAMES = %i[
      initialize method_missing respond_to_missing? define to_definitions
      validate_options
      == != ! [] equal? __send__ __id__ instance_eval instance_exec
    ]

    def initialize
      @definitions = {} #: Hash[Symbol, untyped]
    end

    def define(name, value = nil, **options)
      if RESERVED_NAMES.include?(name)
        ::Kernel.raise ::ArgumentError, "style name :#{name} is reserved"
      end
      if @definitions.key?(name)
        ::Kernel.raise ::ArgumentError, "style :#{name} is already defined"
      end

      if ::String === value
        @definitions[name] = { value: value }
      elsif ::Hash === value
        @definitions[name] = validate_options(name, value)
      elsif (::NilClass === value) && !options.empty?
        @definitions[name] = validate_options(name, options)
      else
        ::Kernel.raise ::ArgumentError,
          "invalid style definition for :#{name}; expected a String, a " \
          "Hash, or keyword options. Note: helper methods cannot be called " \
          "bareword inside a styles block; use " \
          "`styles { |css| css.define(...) }` for computed values."
      end
      self
    end

    def validate_options(name, options)
      options.each do |key, val|
        case key
        when :value, :base, :active
          unless ::String === val
            ::Kernel.raise ::ArgumentError,
              "style :#{name} option #{key}: must be a String. Note: helper " \
              "methods cannot be called bareword inside a styles block; use " \
              "`styles { |css| css.define(...) }` for computed values."
          end
        when :variants
          unless (::Hash === val) && val.all? { |_k, v| ::String === v }
            ::Kernel.raise ::ArgumentError,
              "style :#{name} option variants: must be a Hash of Symbol => String"
          end
        else
          ::Kernel.raise ::ArgumentError,
            "style :#{name} has unknown option #{key.inspect} " \
            "(allowed: value, base, active, variants)"
        end
      end
      options
    end

    def to_definitions
      @definitions
    end

    def method_missing(name, value = nil, **options)
      define(name, value, **options)
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end
end
