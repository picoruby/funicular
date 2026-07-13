# frozen_string_literal: true

module Funicular
  module Helpers
    # View helpers exposed to ActionView through Funicular::Railtie.
    module PicorubyHelper
      CDN_URL_TEMPLATE = "https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@%<version>s/dist/init.iife.js"

      LOCAL_PATHS = {
        local_debug: "/picoruby/debug/init.iife.js",
        local_dist:  "/picoruby/dist/init.iife.js"
      }.freeze

      LOCAL_VARIANTS = {
        local_debug: "debug",
        local_dist:  "dist"
      }.freeze

      # Minimal CSS the gem ships for class names it emits itself (e.g.
      # FormBuilder error states). Read once; see assets/funicular.css.
      BASE_CSS_PATH = File.expand_path("../assets/funicular.css", __dir__)

      def self.base_css
        @base_css ||= File.read(BASE_CSS_PATH)
      end

      # Renders a <script> tag that bootstraps PicoRuby.wasm.
      #
      # The source is determined by Funicular.configuration based on the
      # current Rails environment, but can be overridden per call:
      #
      #   <%= picoruby_include_tag %>
      #   <%= picoruby_include_tag source: :cdn %>
      #   <%= picoruby_include_tag source: :local_dist, defer: true %>
      #
      # Also emits Funicular's small base stylesheet (so gem-emitted class names
      # such as form error states render without host-CSS setup); pass
      # base_styles: false to skip it. Any extra options become HTML attributes
      # on the <script> tag.
      def picoruby_include_tag(source: nil, base_styles: true, **options)
        resolved_source = source ? source.to_sym : Funicular.configuration.source_for(Rails.env)
        src = picoruby_src_for(resolved_source)
        script = tag.script("", src: src, **options)
        return script unless base_styles

        style = tag.style(PicorubyHelper.base_css.html_safe, "data-funicular-base": "")
        safe_join([style, script])
      end

      # Renders the SSR #app container with the server-rendered HTML inside.
      #
      #   <%= funicular_app_container(@ssr[:html]) %>
      #
      # On the client, Funicular hydrates this element instead of rebuilding
      # it. Pass an empty string (the default) to fall back to plain CSR.
      def funicular_app_container(html = "", id: "app", **options)
        content_tag(:div, raw(html.to_s), { id: id }.merge(options))
      end

      # Emits the initial state for client hydration as a global JS variable.
      #
      #   <%= funicular_state_tag(@ssr[:state]) %>
      #   # => <script>window.__FUNICULAR_STATE__ = {...};</script>
      #
      # The JSON is escaped so it cannot break out of the <script> element.
      def funicular_state_tag(state = {})
        json = JSON.generate(state || {})
        # Escape characters that could break out of the <script> element or
        # confuse the HTML parser, using JS unicode escapes that remain valid
        # JSON/JS string content.
        safe = json.gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
        raw("<script>window.__FUNICULAR_STATE__ = #{safe};</script>")
      end

      # Renders registered Funicular plugin browser assets.
      #
      # Plugins are gems in the Gemfile :funicular group. Their Ruby sources
      # are compiled into app.mrb before the application sources; this helper
      # emits browser assets such as CSS.
      def funicular_plugin_include_tags
        registry = Funicular::Plugin::Registry.new(Rails.root)
        tags = registry.asset_entries.map do |entry|
          logical_path = entry.fetch("logical_path")
          if entry["type"] == "css"
            stylesheet_link_tag(logical_path, "data-turbo-track": "reload")
          else
            tag.script("", type: "application/x-mrb", src: asset_path(logical_path), data: { funicular_plugin: true })
          end
        end
        safe_join(tags)
      rescue Funicular::Plugin::Error => e
        raise e if Rails.env.production?

        tag.comment("Funicular plugin assets skipped: #{e.message}")
      end

      private

      def picoruby_src_for(source)
        if source == :cdn
          version = Funicular.configuration.cdn_version
          if version.nil? || version.empty?
            raise ArgumentError,
                  "picoruby_include_tag source :cdn requires a version. " \
                  "Set Funicular.configuration.cdn_version or vendor the wasm artifacts via `rake funicular:vendor`."
          end
          format(CDN_URL_TEMPLATE, version: version)
        elsif (path = LOCAL_PATHS[source])
          local_picoruby_src(path, source)
        else
          raise ArgumentError,
                "Unknown picoruby source: #{source.inspect}. Expected one of #{Funicular::Configuration::SOURCES.inspect}"
        end
      end

      def local_picoruby_src(path, source)
        cache_key = local_picoruby_cache_key(source)
        return path if cache_key.nil?

        "#{path}?v=#{cache_key}"
      end

      def local_picoruby_cache_key(source)
        variant = LOCAL_VARIANTS.fetch(source)
        version = Funicular.vendored_wasm_version
        wasm = File.join(Funicular::VENDOR_PICORUBY_DIR, variant, "picoruby.wasm")
        mtime = File.mtime(wasm).to_i

        [version, mtime].compact.join("-")
      rescue Errno::ENOENT
        Funicular.vendored_wasm_version
      end
    end
  end
end
