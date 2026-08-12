# The 'js' gem (picoruby-wasm) provides JavaScript interop and is only
# available in wasm builds. During test builds, picoruby-wasm is excluded
# from dependencies (see mrbgem.rake), so `require 'js'` raises LoadError.
#
# Additionally, gem init order is not guaranteed to be stable. A dummy
# `require` in picoruby-mruby/mrblib/require.rb exists to suppress
# LoadError during picogem_init, but if picoruby-require initializes
# before this gem, the real `require` (which raises LoadError) will
# already be active. Rescuing LoadError here makes the code robust
# regardless of init order.
begin
  require 'js'
rescue LoadError
  # not available outside wasm environment
end

module Funicular
  # Guard against redefinition: when the mrblib runtime is loaded into a
  # CRuby/Rails process for SSR, lib/funicular/version.rb has already defined
  # VERSION for the CRuby gem. In the wasm build VERSION is undefined here.
  VERSION = '0.5.0' unless Funicular.const_defined?(:VERSION)

  def self.version
    VERSION
  end

  # True when the runtime is loaded under CRuby on the server (SSR) rather
  # than running as PicoRuby.wasm in the browser. JS-dependent entry points
  # become no-ops in this mode. Defaults to false (browser).
  @server = false

  def self.server?
    @server
  end

  def self.server=(value)
    @server = value ? true : false
  end

  def self.env
    @env ||= EnvironmentInquirer.new(ENV['FUNICULAR_ENV'] || ENV['RAILS_ENV'] || 'development')
  end

  def self.env=(environment)
    case environment
    when EnvironmentInquirer
      @env = environment
    when nil
      @env = nil
    else
      @env = EnvironmentInquirer.new(environment)
    end
    # @type ivar @env: EnvironmentInquirer?
    @env
  end

  @router = nil

  def self.router
    @router
  end

  # Confirmation dialog used by the router's navigation guard. The
  # default asks through window.confirm; tests (and apps wanting a
  # custom dialog) can replace it with a proc taking the message and
  # returning true to leave, false to stay.
  @confirm_handler = nil

  def self.confirm_handler=(handler)
    @confirm_handler = handler
  end

  def self.confirm(message)
    handler = @confirm_handler
    return !!handler.call(message) if handler
    return true if server?
    !!JS.global.confirm(message)
  end

  # Read the SSR state embedded by the server (funicular_state_tag) as a
  # Ruby Hash with string keys. Returns {} when absent or on the server.
  # Goes through JSON.stringify/parse for a reliable JS->Ruby conversion.
  def self.window_state
    return {} if server?
    win = JS.global[:window]
    # @type var win: JS::Object?
    return {} unless win
    raw = win[:__FUNICULAR_STATE__]
    return {} if raw.nil?
    json = JS.global[:JSON]
    # @type var json: untyped
    json_str = json.stringify(raw)
    JSON.parse(json_str.to_s)
  rescue => e
    puts "[Funicular] Failed to read window state: #{e.message}"
    {}
  end

  # True when the server embedded hydration state on the page.
  def self.has_ssr_state?
    return false if server?
    win = JS.global[:window]
    # @type var win: JS::Object?
    return false unless win
    !win[:__FUNICULAR_STATE__].nil?
  rescue
    false
  end

  # The first element child of a container, or nil. Used to find the
  # server-rendered root for hydration.
  def self.first_element_child(container_element)
    child = container_element[:firstElementChild]
    child.is_a?(JS::Element) ? child : nil
  end

  # The schema boot barrier (docs decisions 6/19).
  # Usage:
  #   Funicular.load_schemas({ User => "user", Session => "session" }) do
  #     Funicular.start(container: 'app') { |router| ... }
  #   end
  # EVERY request settles its slot exactly once -- success, HTTP
  # error, or a schema that fails to apply -- so the barrier always
  # completes. All green: an opted-in local database boots before the
  # completion block; a REST-only app runs the block directly. Any failure:
  # the block is NEVER invoked and the errors reach the console and
  # config.on_boot_error. Only an active DB lifecycle is marked failed.
  def self.load_schemas(models, &block)
    # On the server there is no fetch and no need for client-side schemas:
    # SSR injects plain data into component state directly. Just run the
    # block so route registration (Funicular.start) still happens.
    if server?
      block.call if block
      return
    end

    # Arm the page's epoch before the first request leaves: schema
    # responses are epoch-checked too (docs decision 13). The response
    # gate latches lazily on its own; the explicit call keeps the
    # whole barrier deterministically armed at issue time.
    local_database = Funicular::DB.local_database_enabled?
    Funicular::DB.__latch_page_epoch if local_database

    total = models.size
    settled = 0
    # @type var errors: Array[untyped]
    errors = []
    completed = false

    settle = -> {
      settled += 1
      # Exactly once, and only with every slot settled.
      next if completed
      next if settled < total
      completed = true
      __settle_boot_barrier(errors, &block)
    }

    if total == 0
      __settle_boot_barrier(errors, &block)
      return
    end

    entries = models.to_a
    entries_size = entries.size
    i = 0
    while i < entries_size
      entry = entries[i]
      # One request per method call: the response block must capture
      # ITS model and name, and a while loop's shared locals would all
      # resolve to the last pair by response time.
      __request_schema(entry[0], entry[1], errors, settle)
      i += 1
    end
  end

  def self.__request_schema(model_class, schema_name, errors, settle)
    HTTP.get("/api/schema/#{schema_name}") do |response|
      if response.error?
        # Status and model always; the body's message only when the
        # server actually sent one (an empty or HTML error body has
        # no error_message).
        message = "schema #{schema_name} (#{model_class.to_s}): " \
                  "HTTP #{response.status}"
        detail = response.error_message
        message = "#{message}: #{detail}" if detail
        errors << Funicular::DB::Error.new(message)
      else
        begin
          model_class.load_schema(response.data)
          puts "[Schema] #{schema_name} model initialized"
        rescue => e
          # A schema that arrived but cannot be applied settles as a
          # failure -- the barrier must never hang on it. Wrapped so
          # on_boot_error can tell WHICH model broke among several.
          errors << Funicular::DB::Error.new(
            "schema #{schema_name} (#{model_class.to_s}): " \
            "#{e.class}: #{e.message}")
        end
      end
      settle.call
    end
    nil
  end

  # The barrier settled: boot on all-green (the completion block runs
  # only when the boot itself succeeded too), fail loud otherwise.
  def self.__settle_boot_barrier(errors, &block)
    if errors.empty?
      if Funicular::DB.local_database_enabled?
        block.call if Funicular::DB.boot && block
      else
        block.call if block
      end
    else
      if Funicular::DB.local_database_enabled?
        Funicular::DB.__fail_boot(errors)
      else
        Funicular::DB.__report_boot_errors(errors)
      end
    end
    nil
  end

  # Funicular.start's client-side gate (docs decision 19): apps with
  # opted-in replica models boot inside the schema barrier above; opted-in
  # local-only apps (no load_schemas call) boot right here. REST-only apps
  # bypass DB boot, except that an explicit storage :local declaration fails.
  def self.__boot_for_start
    unless Funicular::DB.local_database_enabled?
      models = Funicular::Model.__registered_models
      i = 0
      models_size = models.size
      while i < models_size
        if models[i].local?
          raise Funicular::DB::ConfigError,
            "storage :local requires config.local_database = true"
        end
        i += 1
      end
      return true
    end
    state = Funicular::DB.boot_state
    return true if state == :ready
    return false unless state == :unbooted
    Funicular::DB.boot
  end

  # Start Funicular application
  # Usage:
  #   Funicular.start(MyComponent, container: 'app')
  #   Funicular.start(MyComponent, container: 'app', props: { name: 'John' })
  def self.start(component_class = nil, container: 'app', props: {}, hydrate: false, &block)
    # On the server we only need route registration so SSR can resolve a
    # path to a component. Skip all DOM/JS work (container lookup, popstate
    # listener, debug export).
    if server?
      if block
        router = Router.new(nil)
        @router = router
        block.call(router)
        return router
      end
      return nil
    end

    # An opted-in local database comes up before anything mounts. A failed
    # boot already reported itself, so start quietly refuses to mount on it;
    # a REST-only application passes this gate without touching the DB.
    unless __boot_for_start
      puts "[Funicular] start aborted: the local database did not boot"
      return nil
    end

    # Export debug configuration to JavaScript
    export_debug_config

    # Initialize debug module in development mode
    Funicular::Debug.expose_to_global if Funicular.env.development?

    container_element = if container.is_a?(String)
      JS.document.getElementById(container)
    else
      container
    end

    unless container_element.is_a?(JS::Element)
      raise "Container element not found: #{container}"
    end

    # Hydrate automatically when the server embedded state, unless the caller
    # explicitly opted out.
    hydrate = true if hydrate == false && has_ssr_state?

    # If block is given, use router mode
    if block
      router = Router.new(container_element)
      @router = router
      block.call(router)
      router.start(hydrate: hydrate)
      return router
    end

    # Otherwise, mount single component (backward compatible)
    if component_class
      instance = component_class.new(props)
      instance.runtime = Funicular::Runtime.new(nil)
      server_root = hydrate ? first_element_child(container_element) : nil
      if server_root
        instance.seed_state(window_state)
        instance.hydrate(server_root)
      else
        instance.mount(container_element)
      end
      return instance
    end

    raise "Either component_class or block must be provided"
  rescue => e
    puts "Exception in Funicular.start: #{e.message}"
    puts e.backtrace
    raise e
  end

  # Form builder configuration
  class << self
    attr_accessor :form_builder_config

    def configure_forms
      # Defaults are semantic class names whose CSS the gem ships and injects
      # via picoruby_include_tag (see assets/funicular.css).
      @form_builder_config ||= {
        error_class: "funicular-error",
        field_error_class: "funicular-field-error"
      }
      config = @form_builder_config
      # @type var config: Hash[Symbol, String]
      yield config if block_given?
    end
  end

  # Initialize default form configuration
  configure_forms

  # Debug highlighter configuration
  class << self
    attr_accessor :debug_color

    def configure_debug
      @debug_color = 'green'
      yield self if block_given?
    end
  end

  # Initialize default debug configuration
  configure_debug

  # Export debug_color to JavaScript global variable
  def self.export_debug_config
    return if server?
    if JS.global[:window]
      JS.global[:window][:FUNICULAR_DEBUG_COLOR] = @debug_color # steep:ignore
    end
  end
end
