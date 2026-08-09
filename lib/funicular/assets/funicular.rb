# frozen_string_literal: true

# Exclude app/funicular from autoloading (PicoRuby.wasm code, not for CRuby)
Rails.autoloaders.main.ignore(Rails.root.join("app/funicular"))

# Choose where picoruby_include_tag loads PicoRuby.wasm from, per environment.
#
# Available sources:
#   :local_debug - public/picoruby/debug/init.iife.js (debug build, larger, with symbols)
#   :local_dist  - public/picoruby/dist/init.iife.js  (production build, smaller)
#   :cdn         - https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@<version>/dist/init.iife.js
#
# Defaults:
#   development -> :local_debug
#   test        -> :local_debug
#   production  -> :local_dist
#
# Funicular.configure do |config|
#   config.production_source = :cdn
#   # config.cdn_version = "4.0.0"  # defaults to the version vendored in the gem
# end

# Local database (SQLite in the browser, docs/local_database.md):
# disabled by default. Opting in also requires declaring how browser
# storage is namespaced -- a user_key resolver for apps with
# authentication, or anonymous_only for apps without users.
#
# Funicular.configure do |config|
#   config.local_database = true
#   config.user_key = ->(controller) {
#     controller.request.session[:user_id]&.to_s
#   }
#   # or, for apps that genuinely have no users:
#   # config.anonymous_only = true
# end
