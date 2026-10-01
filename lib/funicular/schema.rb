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
    #     except:     { username: [:format] })
    #   # => { attributes: { "display_name" => { type:, readonly:,
    #   #        validations: { "presence" => true, "length" => {...} } } },
    #   #      endpoints: { "find" => { method: "GET", path: "/users/:id" },
    #   #                   "update" => { method: "PATCH", path: "/users/:id" } } }
    #
    # Only the attributes you declare are introspected (allowlist); `except`
    # drops specific kinds per attribute (denylist).
    #
    # Endpoints derive from the Rails routes to the model's controller
    # (`resources :users` -> users#show is "find", users#update is
    # "update"; see Endpoints). Every keyword is an escape hatch:
    #
    #   controller: "api/users"   # the routes' controller when it is not
    #                             # model_class.model_name.collection
    #   endpoints:  { "current" => "sessions#show",             # alias a route
    #                 "create"  => { method: "POST", path: "/login" }, # by hand
    #                 "destroy" => nil }                        # hide one
    #   routes:     false         # no derivation: endpoints: only
    #
    # model_class may be nil for a schema with no ActiveModel behind it
    # (a session, say); pass controller: then, and no validations derive.
    #
    # Associations derive from the ActiveRecord reflections: a belongs_to
    # whose foreign key is one of the declared attributes travels with
    # the schema, and the client defines `comment.post` (and the inverse
    # `post.comments`) from it. See Associations for the rules, and:
    #
    #   associations: false                 # no derivation
    #   associations: { "author" => nil }   # hide a derived one
    #   associations: { "author" => { kind: "belongs_to",
    #                                 class_name: "User",
    #                                 foreign_key: "author_id" } }  # by hand
    def self.build(model_class, attributes:, endpoints: nil, except: {},
                   controller: nil, routes: nil, associations: nil)
      merged = {}
      derive_validations = model_class.respond_to?(:validators_on)
      attributes.each do |name, definition|
        # Readonly attributes are server-managed: the client never
        # submits them, so validating their (nil) client-side value
        # against e.g. a presence validator would reject every create.
        # Skip validator introspection for them entirely.
        if readonly?(definition) || !derive_validations
          merged[name] = definition
          next
        end
        rules = rules_for(model_class, name, except_kinds(except, name))
        merged[name] = rules.empty? ? definition : definition.merge(validations: rules)
      end
      {
        attributes: merged,
        endpoints: Endpoints.resolve(model_class, endpoints, controller, routes),
        associations: Associations.resolve(model_class, attributes, associations)
      }
    end

    # The associations of a schema, derived from the model's ActiveRecord
    # reflections.
    #
    # Only belongs_to derives, and only when its foreign key is one of
    # the declared attributes: the key is public already, so the schema
    # reveals nothing new but the class it points at. The client turns
    # each entry into a belongs_to reader and, when the foreign key
    # follows the convention (post_id -> Post), into the inverse
    # has_many on the target (`post.comments`). Both appear only when
    # the client carries both models. A polymorphic belongs_to and a
    # composite foreign key do not derive.
    module Associations
      # explicit: the associations: keyword (nil to derive, false for
      # none, or a Hash whose values are a hand-written
      # { kind:, class_name:, foreign_key: } entry or nil to hide a
      # derived one).
      def self.resolve(model_class, attributes, explicit)
        return {} if explicit == false
        result = derive(model_class, attributes)
        (explicit || {}).each do |name, value|
          name = name.to_s
          if value.nil?
            result.delete(name)
          else
            result[name] = entry_for(name, value)
          end
        end
        result
      end

      KINDS = %w[belongs_to has_many].freeze

      # A hand-written entry, checked here: the client would only skip a
      # malformed one, far from the line that wrote it.
      def self.entry_for(name, value)
        unless value.is_a?(Hash)
          raise ArgumentError,
                "associations: #{name.inspect} must be nil or a " \
                "{ kind:, class_name:, foreign_key: } Hash, got #{value.inspect}"
        end
        entry = value.transform_keys(&:to_sym)
        kind = entry[:kind].to_s
        unless KINDS.include?(kind)
          raise ArgumentError,
                "associations: #{name.inspect} has kind #{entry[:kind].inspect}; " \
                "expected one of #{KINDS.join(', ')}"
        end
        class_name = entry[:class_name].to_s
        foreign_key = entry[:foreign_key].to_s
        if class_name.empty? || foreign_key.empty?
          raise ArgumentError,
                "associations: #{name.inspect} needs class_name: and foreign_key:"
        end
        { kind: kind, class_name: class_name, foreign_key: foreign_key }
      end

      def self.derive(model_class, attributes)
        result = {}
        return result unless model_class.respond_to?(:reflect_on_all_associations)
        exposed = attributes.keys.map(&:to_s)
        model_class.reflect_on_all_associations(:belongs_to).each do |reflection|
          next if reflection.polymorphic?
          foreign_key = reflection.foreign_key
          next unless foreign_key.is_a?(String) || foreign_key.is_a?(Symbol)
          next unless exposed.include?(foreign_key.to_s)
          result[reflection.name.to_s] = {
            kind: "belongs_to",
            # ActiveRecord keeps a leading "::" (class_name: "::Post").
            class_name: reflection.class_name.to_s.delete_prefix("::"),
            foreign_key: foreign_key.to_s
          }
        end
        result
      end
    end

    # The endpoint table of a schema, derived from the Rails routes.
    #
    # ActiveRecord maps a class to a table by convention; this maps a
    # model to its resource the same way. Every route whose controller
    # is the model's becomes an endpoint: the five RESTful actions get
    # the names Funicular::Model calls them by, any other action keeps
    # its own name (`get :avatar, on: :member` -> "avatar", reached with
    # `find(id, endpoint_name: "avatar")`). Where two routes lead to the
    # same action, the first one in routes.rb wins, as in Rails' own
    # matching; `endpoints:` picks another with a "controller#action"
    # reference.
    module Endpoints
      CANONICAL = {
        "index" => "all",
        "show" => "find",
        "create" => "create",
        "update" => "update",
        "destroy" => "destroy"
      }.freeze

      # explicit: the endpoints: keyword (nil, or a Hash whose values are
      # a { method:, path: } Hash, a "controller#action" String, or nil
      # to hide a derived endpoint). routes: nil for the application's,
      # false for none, or a RouteSet.
      def self.resolve(model_class, explicit, controller, routes)
        route_set = routes.nil? ? application_routes : routes
        route_set = nil if route_set == false
        name = controller || default_controller(model_class)
        result = route_set && name ? derive(name, route_set) : {}
        (explicit || {}).each do |key, value|
          key = key.to_s
          if value.nil?
            result.delete(key)
          elsif value.is_a?(String) || value.is_a?(Symbol)
            result[key] = lookup(value.to_s, route_set, key)
          else
            result[key] = value
          end
        end
        # An explicit endpoints: (even {}) declares the REST side, so an
        # empty table is what the caller asked for.
        if result.empty? && route_set && explicit.nil?
          raise ArgumentError,
                "no endpoints for #{model_class || name}: routes.rb has no " \
                "route to #{name || '(no controller)'}, and none were " \
                "declared with endpoints:"
        end
        result
      end

      def self.application_routes
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:application)
        app = ::Rails.application
        return nil unless app && app.respond_to?(:routes)
        app.routes
      end

      # Post -> "posts", Admin::Post -> "admin/posts": the controller
      # `resources` declares for the model.
      def self.default_controller(model_class)
        return nil unless model_class.respond_to?(:model_name)
        model_class.model_name.collection
      end

      def self.derive(controller, route_set)
        result = {}
        route_set.routes.each do |route|
          next unless route.defaults[:controller].to_s == controller
          action = route.defaults[:action].to_s
          next if action.empty?
          name = CANONICAL[action] || action
          next if result.key?(name)
          entry = entry_for(route)
          result[name] = entry if entry
        end
        result
      end

      def self.lookup(reference, route_set, key)
        unless route_set
          raise ArgumentError,
                "endpoints: #{key.inspect} refers to #{reference.inspect}, " \
                "but no routes are available to resolve it"
        end
        controller, action = reference.split("#", 2)
        if controller.nil? || controller.empty? || action.nil? || action.empty?
          raise ArgumentError,
                "endpoints: #{key.inspect} must be a { method:, path: } Hash " \
                "or a \"controller#action\" reference, got #{reference.inspect}"
        end
        route_set.routes.each do |route|
          next unless route.defaults[:controller].to_s == controller
          next unless route.defaults[:action].to_s == action
          entry = entry_for(route)
          return entry if entry
        end
        raise ArgumentError,
              "endpoints: #{key.inspect} refers to #{reference}, but " \
              "routes.rb has no such route"
      end

      # { method:, path: } for one route; nil for a route without an
      # HTTP verb (a mounted engine, say) or with a glob (*path), which
      # no placeholder can fill. Optional groups ("(/:locale)",
      # "(.:format)") are dropped: Rails matches the short form too.
      def self.entry_for(route)
        verb = route.verb.to_s.split("|").first.to_s
        return nil if verb.empty?
        path = +route.path.spec.to_s
        nil while path.sub!(/\([^()]*\)/, "")
        return nil if path.include?("*")
        { method: verb, path: path.empty? ? "/" : path }
      end
    end

    def self.readonly?(definition)
      definition.is_a?(Hash) && !!(definition[:readonly] || definition["readonly"])
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
      serialized =
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
      attach_shared_options(serialized, options)
    end

    # allow_nil / allow_blank change what the client may skip; without them
    # a format validator on an optional attribute rejects the blank value
    # that the server happily accepts. Kinds that serialize to a bare true
    # (presence, or numericality without constraints) upgrade to a Hash so
    # the flags survive for them too.
    def self.attach_shared_options(serialized, options)
      return serialized unless options[:allow_nil] || options[:allow_blank]
      serialized = {} if serialized == true
      return serialized unless serialized.is_a?(Hash)
      serialized["allow_nil"] = true if options[:allow_nil]
      serialized["allow_blank"] = true if options[:allow_blank]
      serialized
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
        # Ruby regexp literals escape "#" to suppress interpolation and the
        # escape survives in Regexp#source, but "\#" is an invalid identity
        # escape for a JS RegExp under the u flag. "#" never needs escaping
        # in JS source (x mode is already rejected above), so unescape it.
        js_source = js_source.gsub('\\#', '#')

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
