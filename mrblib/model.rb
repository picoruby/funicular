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

    def initialize(attributes = {})
      @changed_attributes = {}
      # Set attributes based on schema
      self.class.schema.each do |name, config|
        value = attributes[name] || attributes[name.to_sym]
        instance_variable_set("@#{name}", value)
      end
    end

    def self.all(params = {}, &block)
      endpoint = @endpoints["all"]
      return unless endpoint

      HTTP.get(endpoint["path"]) do |response|
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
          block.call(false, response.error_message) if block
        else
          block.call(true, response.data) if block
        end
      end
    end

    def update(attrs = nil, &block)
      if attrs
        attrs.each { |k, v| send("#{k}=", v) }
      end

      # Validate on the client before the request (mirrors ActiveRecord#save).
      unless valid?
        block.call(false, errors) if block
        return
      end

      return if @changed_attributes.empty?

      json_attrs = @changed_attributes.reject do |name, value|
        schema = self.class.schema[name]
        schema && schema["type"] == "binary"
      end

      return if json_attrs.empty?

      endpoint = self.class.endpoints["update"]
      path = endpoint["path"].gsub(":id", @id.to_s)

      HTTP.patch(path, json_attrs) do |response|
        if response.error?
          block.call(false, response.error_message) if block
        else
          # Update attributes with response data
          response.data.each do |key, value|
            instance_variable_set("@#{key}", value)
          end
          @changed_attributes = {}
          block.call(true, response.data) if block
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
