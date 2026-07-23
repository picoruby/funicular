# Architecture (contributor guide)

This document is for people working **on** Funicular itself. User-facing
documentation -- how to build apps with Funicular -- lives at
[picoruby.org/wasm](https://picoruby.org/funicular-getting-started).

Funicular is a unidirectional, Virtual DOM-based SPA framework for
PicoRuby.wasm. State flows down to the DOM; events flow up through `patch()` to
update state and trigger a re-render. There is no global store, no auto-tracking
reactivity, and no separate build tool -- compilation rides on the Rails asset
pipeline.

## Two sides of one repository

Funicular ships as two cooperating pieces (plus a Chrome extension):

- **PicoGem `picoruby-funicular`** (`mrblib/`) -- the runtime that executes in
  the browser under PicoRuby.wasm. This is the framework proper.
- **CRubyGem `funicular`** (`lib/`) -- the Rails integration: the compiler
  wrapper, middleware, railtie, view helpers, and the server-side rendering
  runtime.

The same `mrblib/` code also runs under CRuby during SSR (see below), so it must
stay free of browser-only calls on any server code path
(`Funicular.server?` is true there).

## `mrblib/` runtime: responsibilities

| File(s)                                                 | Responsibility                                                                                  |
|---------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `funicular.rb`                                          | Top-level module: `start`, `router`, `server?`, `debug_color` export                            |
| `runtime.rb`                                            | Per-app runtime context propagated through render/SSR/hydration                                 |
| `0_tags.rb`                                             | Bareword tag DSL mixed into `Component`; reserved-name list and collision errors                |
| `view_context.rb`                                       | Internal element factory shared by the tag DSL, FormBuilder, and framework helpers              |
| `component.rb`                                          | `Funicular::Component` base: state, props, lifecycle, suspense loading, refs                    |
| `vdom.rb`                                               | Virtual DOM nodes, including component vnodes with ordinary `children`                          |
| `differ.rb`                                             | `Differ.diff(old, new)` -- minimal patch set, key-based list reconciliation                     |
| `patcher.rb`                                            | `Patcher.apply(dom, patches)` -- apply patches to the real DOM                                  |
| `html_serializer.rb`                                    | `VDOM::HTMLSerializer` -- VDOM to HTML string (used by SSR)                                     |
| `router.rb`                                             | Client-side router, route DSL, per-runtime route helper object, History API                     |
| `model.rb`                                              | Object-REST Mapper (`all`/`find`/`create`/`update`/`destroy`)                                   |
| `http.rb`                                               | Low-level fetch wrapper, CSRF, IndexedDB response cache                                         |
| `cable.rb`                                              | ActionCable-compatible consumer/subscription client                                             |
| `store.rb`, `store_singleton.rb`, `store_collection.rb` | IndexedDB-backed stores, scope API, `subscribes_to`, event dispatch                             |
| `form_builder.rb`                                       | `form_for` field helpers with inline error rendering                                            |
| `0_validations.rb`, `1_validators.rb`                   | ActiveModel-style validators and `errors`                                                       |
| `styles.rb`                                             | CSS-in-Ruby bareword `styles do ... end` builder and generated `styles.name` accessors          |
| `error_boundary.rb`                                     | `ErrorBoundary` component                                                                       |
| `file_upload.rb`                                        | File / FormData upload helper                                                                   |
| `debug.rb`                                              | Development-only component/error registry for the DevTools extension                            |
| `environment_inquirer.rb`                               | Environment detection (`server?`, `development?`)                                               |

The render cycle: a state change calls `patch()`, which rebuilds the component's
VDOM by calling `render`, diffs it against the previous VDOM with `Differ`,
and applies the result with `Patcher`. Event handlers are native DOM listeners,
re-bound on each render.

Inside `render` (zero-arity as of 0.4.0), `self` is the component, so the
DSL is bareword: HTML is authored as `div`, custom elements as
`tag(:custom_element)`, child components as `component`, forms as `form_for`,
styles as `styles.name(variant)` or `styles[:name]`, resources as
`resources[:name]`, and routes as `routes.user_path(id)`. Component state is
explicitly read with `state[:name]` or `state.fetch(:name)`.

Tag and helper names (~46 words) are reserved inside component classes:
defining one raises `DSLCollisionError` at class-definition time
(`method_added`) or at first mount (`validate_dsl_conflicts!`, which also
covers `attr_*` on mruby and included modules). `allow_dsl_override :name`
opts out per class; the shadowed element stays reachable via `tag(:name)`.
Two caveats are inherent to barewords: `p` builds a `<p>` element (use
`puts x.inspect` for debugging; non-Hash arguments raise with a hint), and
a local variable named after a tag shadows the zero-paren call form (write
`option()` or rename the local). Procs handed to ANOTHER component --
ErrorBoundary's `fallback:` -- run under that component's cursor and
therefore receive an explicit view context instead of barewords.

Style definitions are bareword too: the class-level `styles do ... end`
block runs on a BasicObject cleanroom builder, so any name (including
`display`, `hash`, ...) defines a style identically on mruby and CRuby.
Computed values need the explicit form `styles { |css| css.define(...) }`.
Unknown style lookups raise instead of returning an empty class string.

Component children are ordinary VDOM children stored on
`VDOM::Component#children`; there is no delayed `children_block` prop. This keeps
SSR, diffing, ErrorBoundary rendering, and hydration on the same data model.

## `lib/` Rails integration

- `compiler.rb` -- runs the vendored `mrbc` (WebAssembly, via Node.js) to
  compile `app/funicular/**/*.rb` (models, then stores, then components, then
  initializers) into a single `app/assets/builds/app.mrb`. `-g` is added in
  development for debug symbols.
- `middleware.rb` -- development only; watches `app/funicular/` and recompiles on
  change, then invalidates the Propshaft asset cache.
- `railtie.rb` -- inserts the middleware, exposes view helpers, loads the rake
  tasks.
- `helpers/picoruby_helper.rb` -- `picoruby_include_tag`,
  `funicular_app_container`, `funicular_state_tag`.
- `configuration.rb` -- per-environment runtime source selection
  (`:local_debug` / `:local_dist` / `:cdn`).
- `ssr.rb`, `ssr/runtime.rb` -- load the `mrblib/` runtime into the Rails process
  and render a route's VDOM to HTML, injecting state for client hydration.
- `schema.rb` -- introspect an ActiveRecord model's `validators_on` and emit
  client-side validators inline with the schema.

## Vendored artifacts

`rake copy_wasm` (run by `rake build`) copies the PicoRuby.wasm runtime and the
`mrbc` compiler from the sibling `mrbgems/picoruby-wasm/npm/` directory into
`lib/funicular/vendor/`:

- `vendor/picoruby/dist/` -- production runtime build
- `vendor/picoruby/debug/` -- development runtime build (debug symbols)
- `vendor/mrbc/` -- the mruby compiler (run through Node.js)

Because `copy_wasm` reads sibling directories inside the picoruby repository, it
only works from within that checkout -- see Development below.

## JavaScript interop contract

As of picoruby commit 9e69333f, `JS::Object` inherits `BasicObject` instead of
`Object`. Consequences for framework code:

- Dot access on JS values is reliable for names Kernel used to shadow
  (`hash`, `send`, `open`, `class`, `method`, ...): they now reach the JS side
  via `method_missing`.
- The Ruby protocol predicates `nil?`, `is_a?`, `kind_of?`, `instance_of?`, and
  `respond_to?` are defined in C on `JS::Object` (a `?` suffix is illegal in a
  JS identifier, so they can never shadow a JS property). `respond_to?` does a
  real method-table lookup only; it does not report JS properties.
- Any other name ending in `?` or `!` raises `NoMethodError` instead of being
  forwarded to JS, so typos fail loudly rather than silently returning nil.
- `==`, `to_s`, `inspect`, `[]`, `[]=`, `to_a`, and `typeof` are defined
  directly on `JS::Object` and behave as before.

## Server-side rendering, briefly

For SSR the `mrblib/` framework is loaded into the Rails process under CRuby.
`Funicular::SSR.render(path:, state:)` resolves the path against the routes in
`app/funicular/initializer.rb`, builds a `Runtime` around that router, builds the
component's VDOM, and serializes it with `HTMLSerializer`. The state is also
embedded as `window.__FUNICULAR_STATE__` so the browser can hydrate the markup
rather than rebuild it. Keep `render` deterministic and free of browser-only
calls so the same code is safe on both sides.

## Development

This repository is a submodule of
[picoruby/picoruby](https://github.com/picoruby/picoruby). Do not check it out
standalone; clone the parent and work from there:

```console
git clone --recurse-submodules https://github.com/picoruby/picoruby.git
cd picoruby/mrbgems/picoruby-funicular
```

The CRubyGem side (`lib/`, `funicular.gemspec`) can be developed and tested
independently inside that directory, but `rake copy_wasm` relies on sibling
directories within the picoruby repository and fails from a standalone checkout.

PicoGem dependencies are declared in `mrbgem.rake` (picoruby-wasm,
picoruby-indexeddb, picoruby-json, and the mruby `*-ext` gems).

## Testing

- CRubyGem (Rails integration): `rake test` in this repository.
- PicoGem runtime: `rake test:gems:picoruby[picoruby-funicular]` in the parent
  picoruby repository, where `mrbgems/picoruby-funicular` exists as a submodule.
