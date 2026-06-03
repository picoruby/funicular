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
  VERSION = '0.1.0' unless Funicular.const_defined?(:VERSION)

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

  # Read the SSR state embedded by the server (funicular_state_tag) as a
  # Ruby Hash with string keys. Returns {} when absent or on the server.
  # Goes through JSON.stringify/parse for a reliable JS->Ruby conversion.
  def self.window_state
    return {} if server?
    win = JS.global[:window]
    return {} unless win
    raw = win[:__FUNICULAR_STATE__]
    return {} if raw.nil?
    json_str = JS.global[:JSON].stringify(raw)
    JSON.parse(json_str.to_s)
  rescue => e
    puts "[Funicular] Failed to read window state: #{e.message}"
    {}
  end

  # True when the server embedded hydration state on the page.
  def self.has_ssr_state?
    return false if server?
    win = JS.global[:window]
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

  # Load schemas for models
  # Usage:
  #   Funicular.load_schemas({ User => "user", Session => "session" }) do
  #     Funicular.start(container: 'app') { |router| ... }
  #   end
  def self.load_schemas(models, &block)
    # On the server there is no fetch and no need for client-side schemas:
    # SSR injects plain data into component state directly. Just run the
    # block so route registration (Funicular.start) still happens.
    if server?
      block.call if block
      return
    end

    schemas_loaded = 0
    total_schemas = models.size

    check_completion = -> {
      if schemas_loaded >= total_schemas
        puts "[Funicular] All schemas loaded (#{schemas_loaded}/#{total_schemas})"
        block.call if block
      end
    }

    models.each do |model_class, schema_name|
      HTTP.get("/api/schema/#{schema_name}") do |response|
        if response.error?
          puts "[Schema] Failed to load #{schema_name} schema: #{response.error_message}"
        else
          model_class.load_schema(response.data)
          puts "[Schema] #{schema_name} model initialized"
          schemas_loaded += 1
          check_completion.call
        end
      end
    end
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
      yield @form_builder_config if block_given?
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
