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
| `model.rb`                                              | Object-REST Mapper (`all`/`find`/`create`/`update`/`destroy`) + local query API (`storage`/`refresh`, associations, `migrate` blocks) |
| `db.rb`                                                 | `Funicular::DB`: local SQLite databases, DDL derivation, snapshot persistence, change events, `wipe` |
| `relation.rb`                                           | Lazy chainable Relation and SQL builder for local queries                                       |
| `http.rb`                                               | Low-level fetch wrapper, CSRF                                                                   |
| `cable.rb`                                              | ActionCable-compatible consumer/subscription client                                             |
| `store.rb`, `store_singleton.rb`, `store_collection.rb` | IndexedDB-backed stores (superseded by the local database; see below)                           |
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

## Local database (sqlite3)

`Funicular::Model` is backed by an in-browser SQLite database
(picoruby-sqlite3 on wasm: `:memory:` database + IndexedDB snapshot
persistence). The user-facing contract is documented in
[local_database.md](local_database.md); the contributor-relevant invariants
are:

- The entire subsystem is optional and defaults off. Rails emits an explicit
  page opt-in only for `config.local_database = true`; without it schema and
  REST traffic continue normally, while DB boot, SQLite, IndexedDB, Web Locks,
  replica write-through, and session-epoch handling do not run. Disabled
  `storage :local` declarations fail at the pre-DOM start gate, and runtime
  local APIs raise `UnavailableError`. Disabling does not delete snapshots.

- Two databases split by durability class: `funicular_replica`
  (server-recoverable, dropped and rebuilt on schema mismatch) and
  `funicular_local` (client-only data, evolved via numbered `migrate` blocks
  with per-table versions in a meta table; never dropped in production --
  dev auto-resets on migration failure, `reset: true` baselines and
  `Model.reset_local` are the explicit reset paths). Both auto-persist,
  in the `persistent_writer` state only, via debounce plus a
  `visibilitychange` backstop.
- One apply entry point: every FRAMEWORK-CONTROLLED replica write
  (fetch-through, write-through, and, in the future, Cable-pushed
  replication) funnels through the same upsert/delete path in
  `Funicular::DB`, which is also where per-table change events fire. The
  sanctioned exception is app-level raw SQL through the guarded handles,
  whose contract is to call `notify_changed` afterwards. Relation#delete_all
  exists only for `storage :local`; on replica Relations it raises
  ReplicaWriteError even on the writer tab.
- The source-of-truth contract on `Funicular::Model`: the bare class targets
  the model's source of truth -- REST verbs with optional callbacks of ONE
  shape, `(result, error)`, for replica/ephemeral models (BREAKING vs <=0.4:
  update/destroy were boolean-first), the local table for `storage :local`
  models (there the `.local` prefix is an optional alias). `.local` is the
  explicitly-marked local/cache view: it returns immediate values and raises
  on genuine bugs; on ephemeral models it raises
  `Funicular::DB::NoTableError`.
- Boot barrier: all schemas are collected before replica DDL/fingerprint
  work runs (exactly once per boot); any schema failure fails startup with
  aggregated errors. The fingerprint covers DDL-affecting data only and IS
  the canonical schema JSON, stored in a replica metadata table and
  compared by string equality (no digest dependency; never user_version).
- Isolation: namespace identity is a typed, versioned tuple
  (["v1", app_id, "anonymous"] / ["v1", app_id, "user", key]) encoded as
  canonical JSON -- never naive concatenation (collision-free even for a
  literal "anonymous" user key or delimiter-containing values); the same
  encoded identity is used for snapshot keys, the Web Lock name, the
  previous-identity value in the Rails session, and epoch rotation.
  (Configuration contract for user_key/anonymous_only: see the dedicated
  bullet below.) When the subsystem is enabled, a separate SESSION EPOCH is
  managed by the Railtie with no app code: kept in the Rails session, rotated (SecureRandom)
  whenever the computed user_key changes, stamped on all REST/schema
  responses (X-Funicular-Epoch). A mismatching OR MISSING epoch on an
  apply-path response moves the page to a TERMINAL invalid-session state:
  the response is discarded and replica applies, local writes, raw writes,
  and persistence are refused for the life of the page (a non-reloading
  on_session_change hook cannot re-enable them; default hook reloads). The
  terminal flag is an irreversible latch independent of durability state;
  a terminal WRITER steps down -- debounce cancelled, in-flight persist
  serialized, lock-holding promise resolved so the lock releases,
  connections kept only as a non-persistent read view.
- Durability is a three-state machine per page: persistent_writer (holds
  the Web Lock; restores, persists, writes), persistent_reader (replica
  fully functional incl. in-memory revalidation writes, never persisted;
  LOCAL connection PRAGMA query_only=ON; local writes and
  flush/wipe/reset_local raise ReadOnlyTabError; persist/close are not
  on the proxy surface at all, on any tab), and
  volatile (everything works including local writes, nothing persists;
  entered when Web Locks or IndexedDB are unavailable; named distinctly
  from the `storage :ephemeral` model declaration). Lock protocol: boot
  decides instantly via `ifAvailable: true`; a reader stays reader for the
  life of the page (no promotion in v1 -- reload to write); the writer
  parks the lock on a promise resolved at teardown. DB handles
  are guarded proxies with a closed allowlist, never raw SQLite3::Database:
  proxy `transaction` yields the proxy (the gem's own transaction yields
  the raw db), `prepare` returns a guarded statement, batch/deserialize/
  commit/rollback are classified; pending notify_changed state is tied to
  raw-transaction commit/rollback. Read-only states are enforced per
  STATEMENT at execution time via sqlite3_stmt_readonly
  (Statement#readonly?, new sqlite3 API): write statements -> framework
  exception; PRAGMA query_only/ATTACH/DETACH rejected separately (SQLite
  classifies them read-only; query_only alone is not a guarantee -- it can
  be switched OFF); execute_batch refused outright in read-only states;
  EVERY execution entry point re-checks the current latch/state when run
  (execute, step, ResultSet#next, get_first_* alike).
- `wipe` (writer-only) advances the MUTATION GENERATION (deliberately not
  called "epoch" -- the session epoch is a different mechanism): stale
  in-flight applies are rejected, debounce timers cancelled, watchers
  notified only after DBs are queryable again. If ANY local table's stored
  migration version exceeds the declared maximum, the WHOLE local DB fails
  loud: every local-model operation (read or write, any table) raises
  SchemaTooNewError and the DB sits at query_only=ON; raw SELECT export and
  reset_local (which internally lifts query_only for the rebuild; still
  ReadOnlyTabError on non-writer tabs) are the only doors. No per-table
  nuance in v1.
- When opted in, boot is one state machine (`Funicular::DB.boot`, driven by
  Funicular.start, independent of load_schemas usage): declarations ->
  namespace+epoch -> writer election -> local restore+migrations -> replica
  restore+fingerprint (after ALL schemas collected) -> components mount.
  Schema failure: completion block not invoked, console.error always,
  on_boot_error(errors) when set. The HTTP layer settles every schema
  request exactly once (success / HTTP error / parse error / Promise
  rejection), so the barrier cannot hang; an empty schema set is valid only
  when no replica models are declared.
- picoruby-indexeddb error classification cannot ride the generic JS
  Promise bridge (it carries only error.message; JS::Promise#await raises a
  string): the gem's own EM_JS promises resolve a TAGGED result -- success
  as { ok:, value: }, failure as { ok:, name:, message: } -- converted to
  values/typed Ruby exceptions; the same shape applies to the request and
  transaction helpers, not just open. Only listed availability errors
  (SecurityError, InvalidStateError, missing global) fall back to the
  in-memory store (-> volatile state); quota and data errors surface;
  onblocked is not availability failure -- it waits with a fixed timeout
  (default 5000ms), raises a typed BlockedError on expiry, and a late open
  success after the timeout closes that connection immediately; open cleans
  up its callback registry in ensure.
- picoruby-sqlite3 gains official primitives instead of Funicular poking
  internals: open a memory DB without snapshot binding (no restore/no
  persist -- plain `close` on an unbound DB persists nothing, so no
  `close(persist: false)` variant is needed) and `Statement#readonly?`. (No
  named-snapshot-deletion API: it would target the gem's built-in store,
  which Funicular does not use -- `wipe` deletes the two namespaced keys
  directly from Funicular's own KVS.) Snapshots are stored Base64-encoded
  (binary Strings do not survive the JS bridge). The proxy exposes NO
  `persist`/`close` on any tab: the framework's DBs are unbound memory DBs
  (SQLite-level persist has no valid target; close would destroy a
  framework-owned connection). Snapshot I/O itself is OWNED BY FUNICULAR:
  `Funicular::DB` opens its IndexedDB store with `fallback: false` and does
  its own serialize/deserialize round trips -- the sqlite3 gem's built-in
  STORE_NAME persistence (whose KVS defaults to fallback: true and would
  hide unavailability) is not used by Funicular. Storage failure at boot,
  v1: availability errors on open -> volatile (backend absent by design);
  ANY other storage failure -- open errors
  (QuotaExceeded/Unknown/Version/Blocked-timeout) or snapshot GET errors
  (quota/data) -- FAILS THE BOOT: components do not mount, console.error +
  on_boot_error. Recovery: corrupt snapshot (GET failure, handle exists) ->
  the hook may call wipe then reload; open failure -> fix browser state,
  reload. No latches, no partial boot, no in-page recovery (deferred).
- watch, v1: the block must return a Relation (else a helpful raise); the
  framework materializes it and subscribes to that Relation's table,
  re-subscribing each evaluation. Hashes/scalars/raw SQL: use Model.on_change
  + patch. (The dependency collector, tables: option, and refresh :auto's
  barrier-time all-endpoint validation are deferred with :auto itself.)
- Every opted-in application requires `user_key`, or `anonymous_only = true`
  as the explicit choice for an auth-less app (both set = config error), even
  when it has only replica models. Rails validates after initialization and
  before helper output; DB.boot validates the emitted contract defensively.
  The opt-in flag plus namespace and epoch metadata are emitted by
  `picoruby_include_tag` as HTML-escaped data attributes (no new helper;
  CSR-only apps covered). No metadata means disabled, never an implicit
  anonymous `"funicular"` namespace.
  Session epoch state is stored PER application_id
  (session[:funicular_epochs][app_id] = { identity:, epoch: }) so multiple
  Funicular apps sharing one Rails session cannot rotate each other's
  epochs.
- notify_changed takes a model class or (role, table) pair -- change
  identity is [database_role, table_name]; inside a raw transaction the
  event and persist scheduling defer to commit and vanish on rollback.
- Event bus: change events fire post-commit, coalesced to one per table per
  transaction; watcher delivery is queued (never nested inside a component
  update) and subscriber exceptions are isolated.
- SSR: all SQLite3 access is deferred inside methods so class bodies still
  evaluate under CRuby; materializing a local query during SSR raises
  `Funicular::DB::UnavailableError` (fail loud, never an empty result).

The Store layer (`store.rb`, `store_singleton.rb`, `store_collection.rb`) is
superseded by this: every Store feature has a local-database counterpart
(scopes -> tables/where, `expires_in` -> `refresh :auto`, `on_change` ->
table change events + `watch`, `subscribes_to` -> future `refresh :live`,
`cleared_on`/`dispatch` -> `Funicular::DB.wipe`). Store stays in the tree
untouched for now -- its `subscribes_to` implementation is the design
reference for `refresh :live` -- but nothing new builds on it, and it will be
deprecated and removed once `refresh :live` ships.

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
