# frozen_string_literal: true

require "json"
require_relative "../compiler"

module Funicular
  module SSR
    # Loads the PicoRuby (mrblib) framework runtime and the application's
    # component classes into the CRuby process so the server can build VDOM
    # and serialize it to HTML.
    #
    # The mrblib runtime is plain Ruby; the only JS access happens inside
    # methods that SSR never calls (mount, patcher, fetch, history, ...).
    # `Funicular.server = true` makes the few JS-touching entry points
    # (Funicular.start, Router#start, FileUpload.mount, Debug) no-ops.
    module Runtime
      MRBLIB_DIR = File.expand_path("../../../mrblib", __dir__)

      # Load order is by dependency at *class-body* evaluation time. Most
      # files reference JS / other classes only inside methods, so only a
      # few real dependencies exist (vdom before html_serializer; styles and
      # vdom before component; component before error_boundary).
      LOAD_ORDER = %w[
        0_tags
        environment_inquirer
        vdom
        html_serializer
        differ
        patcher
        styles
        runtime
        view_context
        debug
        component
        error_boundary
        router
        0_validations
        1_validators
        db
        relation
        model
        store
        store_singleton
        store_collection
        form_builder
        http
        cable
        file_upload
        funicular
      ].freeze

      class << self
        # Load the framework runtime once. Idempotent.
        def load_framework!
          return if @framework_loaded

          LOAD_ORDER.each do |name|
            require File.join(MRBLIB_DIR, "#{name}.rb")
          end
          Funicular.server = true
          @framework_loaded = true
        end

        # Load the application's component/model/store/initializer files in the
        # canonical order. Running the initializer registers routes into
        # Funicular.router (server-safe: Funicular.start skips all DOM work).
        #
        # Funicular model files are loaded so that the constants they define
        # (e.g. Channel, Session) are available when the initializer evaluates
        # `load_schemas({ Channel => "channel", ... })`. If a Funicular model
        # shares a name with a same-named ActiveRecord model that Rails has
        # already auto-loaded, Ruby raises TypeError (superclass mismatch).
        # In that case we rescue and continue: the AR constant is already defined
        # and is all that load_schemas needs (it ignores the hash on the server).
        #
        # Loaded once per process. With auto_reload (the railtie enables
        # it in development), edited sources are picked up on the next
        # render: reloading re-runs the initializer, and the server-side
        # Funicular.start builds a fresh router, so routes refresh too.
        # Without it, restart the server to pick up changes.
        def boot!(source_dir)
          load_framework!
          if @app_loaded
            return unless auto_reload && sources_changed?(source_dir)
          end

          files = Funicular::Compiler.source_files(source_dir.to_s)
          files.each do |file|
            begin
              Kernel.load(file)
            rescue TypeError => e
              # Funicular model name conflicts with an already-loaded AR model.
              # The constant is already defined; safe to skip.
              warn "[Funicular SSR] Skipped #{File.basename(file)}: #{e.message}"
            end
          end
          @app_loaded = true
          @sources_snapshot = sources_snapshot(source_dir)
        end

        # Reload edited app sources on the next boot! instead of
        # requiring a server restart (meant for development).
        attr_accessor :auto_reload

        def sources_changed?(source_dir)
          @sources_snapshot != sources_snapshot(source_dir)
        end

        def sources_snapshot(source_dir)
          Funicular::Compiler.source_files(source_dir.to_s).map do |file|
            [ file, File.exist?(file) ? File.mtime(file).to_f : nil ]
          end
        end

        # Test/escape hatch: forget loaded application state so a different
        # app (or a reload) can be booted. Does not unload the framework.
        def reset_app!
          @app_loaded = false
        end

        def framework_loaded?
          !!@framework_loaded
        end
      end
    end
  end
end
