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

| File(s)                                          | Responsibility                                                            |
|--------------------------------------------------|---------------------------------------------------------------------------|
| `funicular.rb`                                   | Top-level module: `start`, `router`, `server?`, `debug_color` export      |
| `component.rb`                                   | `Funicular::Component` base: state, props, lifecycle, suspense, refs, styles |
| `vdom.rb`                                         | Virtual DOM nodes and the element-factory DSL (`div`, `button`, ...)      |
| `differ.rb`                                       | `Differ.diff(old, new)` -- minimal patch set, key-based list reconciliation |
| `patcher.rb`                                      | `Patcher.apply(dom, patches)` -- apply patches to the real DOM            |
| `html_serializer.rb`                             | `VDOM::HTMLSerializer` -- VDOM to HTML string (used by SSR)               |
| `router.rb`                                       | Client-side router, route DSL, `RouteHelpers` generation, History API     |
| `model.rb`                                        | Object-REST Mapper (`all`/`find`/`create`/`update`/`destroy`)            |
| `http.rb`                                         | Low-level fetch wrapper, CSRF, IndexedDB response cache                    |
| `cable.rb`                                        | ActionCable-compatible consumer/subscription client                       |
| `store.rb`, `store_singleton.rb`, `store_collection.rb` | IndexedDB-backed stores, scope API, `subscribes_to`, event dispatch |
| `form_builder.rb`                                | `form_for` and field helpers with inline error rendering                  |
| `0_validations.rb`, `1_validators.rb`            | ActiveModel-style validators and `errors`                                 |
| `styles.rb`                                       | CSS-in-Ruby `styles` DSL and the `s` helper                              |
| `error_boundary.rb`                              | `ErrorBoundary` component                                                 |
| `file_upload.rb`                                 | File / FormData upload helper                                              |
| `debug.rb`                                        | Development-only component/error registry for the DevTools extension      |
| `environment_inquirer.rb`                        | Environment detection (`server?`, `development?`)                         |

The render cycle: a state change calls `patch()`, which rebuilds the component's
VDOM, diffs it against the previous VDOM with `Differ`, and applies the result
with `Patcher`. Event handlers are native DOM listeners, re-bound on each render.

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

## Server-side rendering, briefly

For SSR the `mrblib/` framework is loaded into the Rails process under CRuby.
`Funicular::SSR.render(path:, state:)` resolves the path against the routes in
`app/funicular/initializer.rb`, builds the component's VDOM, and serializes it
with `HTMLSerializer`. The state is also embedded as `window.__FUNICULAR_STATE__`
so the browser can hydrate the markup rather than rebuild it. Keep `render`
deterministic and free of browser-only calls so the same code is safe on both
sides.

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
