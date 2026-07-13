## [Unreleased]

### Added

- 0.3.0 rendering architecture: `render(h)` now receives a `ViewContext`
  facade for elements, components, forms, styles, resources, and routes.
- Per-app `Runtime` context for route helpers and renderer/serializer
  propagation, enabling isolated route helper sets across multiple apps.

### Breaking Changes

- **0.3.0 is a deliberate breaking DSL redesign. Existing Funicular
  components written for 0.2.x require source changes.**
- Component render methods must now accept a view context:
  `def render(h)`. The former implicit component-level DSL methods for HTML
  tags, `component`, `form_for`, `link_to`, `button_to`, `suspense`, styles,
  resources, and route helpers have been removed.
- HTML and framework helpers are now called through `h`, for example
  `h.div`, `h.component(...)`, `h.form_for(...)`, `h.link_to(...)`,
  `h.suspense(...)`, `h.styles[...]`, `h.resources[...]`, and `h.routes`.
- Component state reads are explicit: use `state[:key]`, `state.fetch(:key)`,
  or `h.state[:key]`. The old `state.key_name` method-style access has been
  removed.
- Style definitions are explicit: use `styles { |css| css.define(...) }`.
  The old dynamic style definition DSL has been removed.
- Component children are stored as `VDOM::Component#children`. The old
  `children_block` prop path has been removed and no compatibility shim is
  provided.
- Route helpers are scoped by `Funicular::Runtime`; global
  `Funicular::RouteHelpers` injection has been removed. Code that depends on
  route helpers should use `h.routes`.
- `FormBuilder`, `ErrorBoundary`, SSR, hydration, renderer, patcher, and HTML
  serialization now operate through the same `ViewContext` / `Runtime`
  architecture.

### Changed

- Since mruby-compiler-prism, which used to be mruby-compiler2 producing
  picorbc, has become the default compiler for mruby, we changed the name
  from picorbc to mrbc.

### Fixed

- Harden VDOM rendering against HTML and script injection in both SSR and
  browser rendering: validate tag and attribute names, reject `script`
  elements, and consistently block case-obfuscated event handlers, `srcdoc`,
  and unsafe URL schemes including control-character variants.

## [0.2.1] - 2026-06-15

### Added

- **Funicular::Component**: Add `name` field to form to find state changed.

## [0.2.0] - 2026-06-11

### Added

- **Funicular::Store DSL**: Declarative client-side stores backed by
  IndexedDB. Subclass `Funicular::Store::Singleton` (one value per scope)
  or `Funicular::Store::Collection` (ordered list per scope) and use
  class-level DSL (`database`, `scope`, `limit`, `key`, `expires_in`,
  `cleared_on`, `subscribes_to`) to wire up persistence, TTL, event-based
  clearing, and ActionCable integration.
- `Funicular::Store.dispatch(:event)` for coordinated store clearing
  (e.g., logout wipes all stores registered with `cleared_on :logout`)
- `subscribes_to` DSL for embedding Cable message handling directly in
  store classes; scopes gain `subscribe!` / `unsubscribe!` / `subscribed?`
- Lazy KVS initialization: stores open IndexedDB on first access, removing
  the need for explicit `init!` calls in application initializers
- `Funicular::Store::Scope#on_change` / `off_change` for reactive UI
  updates when store data changes

### Changed

- `Funicular::Cable::Consumer` now automatically resubscribes all active
  subscriptions after WebSocket reconnect (`resubscribe_all`)

## [0.1.0] - 2026-04-20

### Added

- Consolidated with picoruby-funicular: merged the full PicoRuby frontend
  framework into this gem, including Component, Cable, VDOM, Router,
  FormBuilder, Model, HTTP, FileUpload, ErrorBoundary, Styles, Differ,
  Patcher, Debug, and EnvironmentInquirer, along with RBS signatures and
  comprehensive test suite
- Bundle PicoRuby.wasm and picorbc WASM artifacts into the gem via a
  `rake copy_wasm` task; artifacts are vendored at build time so no
  runtime npm lookup is required
- `Funicular::Configuration` with per-environment PicoRuby.wasm source
  selection (`:local_debug`, `:local_dist`, `:cdn`) and optional
  `cdn_version` override
- `picoruby_include_tag` view helper (auto-registered via Railtie) that
  serves the appropriate PicoRuby.wasm build per environment
- `funicular:install:wasm` rake sub-task to copy dist/debug WASM builds
  into `public/picoruby/`
- Rails Asset Pipeline integration: Rack middleware, compiler, and
  `funicular:compile` / `funicular:install` rake tasks
- `funicular routes` CLI command and `Funicular::RouteParser` to inspect
  Rails routes from the command line
- Component Debug Highlighter: CSS/JS assets (`funicular_debug.css`,
  `funicular_debug.js`) that highlight the selected component in the
  browser
- `ENV['FUNICULAR_ENV']` is now set from `Rails.env` in generated
  `application.rb`

### Changed

- picorbc is now resolved from a vendored WASM artifact; removed
  npm-based picorbc lookup and all `PICORBC_VERSION` environment variable
  logic
- Upgraded picorbc to the latest version
- Switched test framework from test/unit to minitest

### Fixed

- Asset pipeline: middleware now detects whether `app.mrb` has actually
  changed before recompiling, preventing unnecessary rebuilds
- XSS vulnerabilities in VDOM attribute handling: expanded
  `URL_ATTRIBUTES` constant, applied case-insensitive `javascript:` URI
  blocking, and added the same URL validation to `Patcher#update_props`
  and `Patcher#create_element`
- XSS vulnerability in Debug module: replaced manual JSON string
  concatenation with `JSON.generate` to eliminate escaping gaps
- `funicular:compile` rake task
- `funicular:install` rake task
- Rack middleware
- RBS type signatures

### Removed

- Debugger Chrome extension (`debugger/` directory)
- `.ruby-version` file

## [0.0.1] - 2025-11-27

- Initial release
