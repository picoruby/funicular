## [0.5.0] - Unreleased

The local database release: an ActiveRecord-like, reactive local store on
in-browser SQLite (picoruby-sqlite3), with the Rails server as the source
of truth. Entries below accumulate as the feature lands.

### Added

- Navigation guard: a component can veto leaving by overriding
  `navigation_guard` to return a confirmation message (nil allows).
  The router consults it before `navigate` (including `link_to
  navigate: true`), on browser back/forward (restoring the history
  entry when the user stays), and through a synchronous `beforeunload`
  listener for reload / tab close via the browser's native dialog.
  `Funicular.confirm_handler=` injects the dialog for tests or custom
  UIs; SSR never blocks. The guard must not suspend.

- The SQLite local-database subsystem is now globally opt-in through
  `config.local_database = true` and defaults off. REST-only applications do
  not start SQLite, IndexedDB, Web Locks, replica write-through, or session
  epochs. Opted-in applications must also declare `config.user_key` or
  `config.anonymous_only = true`; existing snapshots are retained while the
  feature is disabled.

- Design documentation for the local database layer:
  `docs/local_database.md` is the user-facing API contract (source-of-truth
  contract, `storage`/`refresh` declarations, `migrate` blocks, `.local`
  Relations, `watch`, persistence/durability, namespaces and tabs, session
  epoch, SSR constraints); `docs/architecture.md` gains the
  contributor-facing invariants.
- `Model.all(params)` now forwards `params` as a percent-encoded query
  string (`Post.all(page: 2)` -> `GET /posts?page=2`) via the new
  picoruby-uri gem's CRuby-compatible `URI.encode_www_form`. The argument
  existed before but was silently ignored.
- The local-query foundation (`mrblib/db.rb`, `mrblib/relation.rb`):
  `Funicular::Relation`, the lazy chainable query builder behind `.local`
  (where/order/limit/offset; hash, IN, BETWEEN, IS NULL, and raw-fragment
  conditions; each/to_a/first/count/exists?/find/find_by/delete_all), the
  `Funicular::DB` error vocabulary, and the shared boolean/datetime codec
  (`true`/`false` <-> 1/0, `Time` <-> UTC ISO 8601 TEXT) used on both the
  SQLite and REST boundaries. The model-layer wiring (`storage`, `.local`)
  arrives in a following change; the gem now depends on picoruby-sqlite3.
- The model declaration DSL: `storage :replica (default) | :ephemeral |
  :local do ... end` (with `migrate N [, reset: true] do |t| ... end`
  blocks recorded at class eval and version rules -- baseline and
  contiguity -- validated there), `refresh :manual` (`:auto`/`:live`
  raise "not yet supported"), `table_name` (naive pluralization +
  override), and the `.local` entry point returning a whole-table
  `Funicular::Relation` (NoTableError on ephemeral models). Replica
  column metadata derives from the server schema (binary attributes
  excluded); materializing a query before `Funicular::DB.boot` (a later
  change) raises `Funicular::DB::UnavailableError`.
- Associations: `belongs_to :user` and `has_many :comments` as local-query
  sugar over the `<name>_id` convention -- `post.user` reads
  `User.local.find_by(id: post.user_id)`, `post.comments` returns the
  chainable `Comment.local.where(post_id: post.id)` Relation (usable in
  `watch`). `class_name:` and `foreign_key:` override the conventions;
  `through:`, eager loading, and polymorphic associations raise as
  unsupported in v1. Targets resolve lazily at first read, so model files
  may load in any order, and a declaration whose name collides with a
  column, a REST attribute, another declaration, or a `Funicular::Model`
  instance method is refused instead of silently shadowing it.
- The client-only-table migration machinery: `Funicular::DB::TableBuilder`
  (the `t` in migrate blocks -- string/text/integer/float/boolean/datetime
  columns with `default:`/`null:`, `timestamps`, `index`/`remove_index`,
  `rename`, `remove`, raw `execute`) and the per-table runner
  (`Funicular::DB.apply_local_migrations`): fresh and below-baseline
  tables rebuild from the baseline -- the newest `reset: true` block, or
  the first block; superseded pre-reset history may stay in the code and
  is never folded or applied -- upgrades apply exactly
  the missing blocks in one transaction (rolled back on failure; in
  development a failed upgrade auto-resets the table instead), applied
  versions live in the `funicular_meta` table, and a table newer than
  the declarations raises `Funicular::DB::SchemaTooNewError`. The column
  fold is validated before any DDL runs, so declarations SQLite would
  accept as plain DDL (renaming or removing the implicit `id`) are
  rejected while the database is still intact. Local
  models' `local_columns` now fold their migrate blocks (implicit
  `id INTEGER PRIMARY KEY` included), replacing the interim
  UnavailableError.
- The change-event bus (`mrblib/db.rb`): `Funicular::DB.subscribe`/
  `unsubscribe` per [database role, table], and the raw-SQL protocol
  `Funicular::DB.notify_changed(Model)` (or `(:local | :replica,
  table)`; ephemeral models raise NoTableError). Events fire
  post-commit only: inside a guarded transaction block they coalesce to
  one event per [role, table] and flush after COMMIT, or vanish with
  the rollback. Delivery is deferred to the NEXT tick (JS
  `setTimeout(0)` by default; the scheduler is pluggable and CRuby
  drains immediately, where no component can be mid-update), coalescing
  per [role, table] within the tick; an event raised by a subscriber
  belongs to the following tick -- never nested, never dropped -- and a
  raising subscriber is isolated. `Model.local_table_changed` now feeds
  this bus, so every framework write (local CRUD, delete_all, replica
  write-through) announces itself.
- The writer election (`mrblib/db.rb`, docs decision 14): one tab per
  namespace persists. `Funicular::DB.elect_writer` runs once at boot
  with Web Locks' `ifAvailable` -- granted makes the tab the
  `persistent_writer` (the lock is held by a promise resolved only at
  `release_writer_lock`, the terminal step-down seam), not granted
  makes it a `persistent_reader` for the life of the page (no
  promotion in v1; reload to write), and a missing or failing Web
  Locks API drops the page to `volatile` (everything works, nothing
  persists). `Funicular::DB.durability` reports the state; the JS shim
  accepts an injectable Locks API for tests.
- The persistence core (`mrblib/db.rb`, docs decisions 11/16):
  whole-database snapshots (serialize -> Base64) in Funicular's OWN
  IndexedDB store, opened with the in-memory fallback disabled --
  availability errors (private mode) classify as the `volatile` state,
  every other storage error stays loud for the boot to fail on.
  Auto-persist rides the post-commit change-event funnel with a
  per-role debounce (replica ~5 s, local ~500 ms; a rollback schedules
  nothing), `Funicular::DB.flush` snapshots immediately (writer only;
  `ReadOnlyTabError` on a reader, honest no-op on volatile), and a
  `visibilitychange` backstop persists when the tab hides. A persist
  landing while that database has an open transaction (a stale timer,
  the backstop, an in-block flush) refuses to serialize uncommitted
  pages and defers itself to the commit/rollback settle. Failures are
  never silent: always logged, plus `config.on_persist_error`.
  `Funicular::DB.configure` arrives with the persistence knobs
  (`replica_debounce_ms`/`local_debounce_ms`/
  `request_persistent_storage` -- `navigator.storage.persist()` is
  asked only when local data exists -- and the
  `on_persist_error`/`on_boot_error`/`on_session_change` hooks).
- `Funicular::DB.boot` (docs decision 19), the client-side boot that
  wires everything in order: page metadata -> namespace resolution
  (+ session epoch held for the HTTP layer) -> writer election ->
  snapshot store (availability errors -> volatile) -> the two
  `:memory:` connections -> local snapshot restore + migrations ->
  replica restore + schema-derived DDL -> guarded handles installed
  (`Funicular::DB.local`/`.replica`, and `Model.local_db`/`replica_db`
  now consult the boot; reader tabs get `PRAGMA query_only=ON` plus a
  read-only local proxy) -> `navigator.storage.persist()` when a
  local model exists -> the visibilitychange backstop. One-shot;
  raises `UnavailableError` under SSR. The handles gate on
  `boot_state == :ready`, not on their existence: mid-boot (another
  Task running during a boot await) and after a failed boot the
  database is equally unreachable -- and the raw-database paths that
  bypass the handles carry the gate too: `Model.reset_local` requires
  `:ready`, `wipe` allows `:ready` or `:failed` (wiping from
  `on_boot_error` is the official corrupt-snapshot recovery), and
  `persist_snapshot` -- the final persistence entry that flush and
  the debounce funnel through -- refuses during `:booting`, so a
  mid-boot flush cannot overwrite stored snapshots with unrestored
  databases. Any failure is decision 16's
  fail loud: `boot_state` becomes `:failed`, the handles are torn
  back out, the errors hit the console and `config.on_boot_error`,
  nothing mounts (wired with `Funicular.start` in a following
  change), and once the hook has had its recovery chance the writer
  lock is released -- a failed page must not deny the writer slot to
  every other tab. SchemaTooNew instead
  completes the boot LOCKED DOWN (docs decision 7): every model-level
  local operation raises `SchemaTooNewError`, raw SELECT export
  through `DB.local` survives, writes are refused by SQLite itself.
  `Model.reset_local` arrives with it: writer-only baseline rebuild of
  one client-only table that lifts the lockdown once the whole
  declared set passes again -- and the lift is provisional: a reset
  that fails mid-rebuild puts SQLite's own write refusal
  (`query_only`) back up before re-raising.
- The schema boot barrier and the start gate (docs decision 19,
  wiring half). `Funicular.load_schemas` is now a real barrier: every
  request settles its slot exactly once -- success, HTTP error, or a
  schema that arrived but cannot be applied -- so it always
  completes. All green boots the local database (declared models come
  from a new Model registry filled at subclass definition; namespace,
  epoch, and user-key metadata come from the include tag's
  HTML-escaped `data-funicular-*` attributes) and only then runs the
  completion block; any failure never invokes the block, reports
  through the console and `config.on_boot_error`, and marks the boot
  failed. `Funicular.start` gates on the boot before touching the
  DOM: replica apps boot inside the barrier, local-only apps boot
  right in start, and nothing mounts on top of a failed boot. An
  empty schema set with a schema-less replica model declared fails
  the boot loud instead of running on missing tables.
- The session-epoch terminal latch (docs decision 13, client half)
  and HTTP's exactly-once settle. Every `Funicular::HTTP` request now
  settles its callback exactly once: a rejected fetch (network
  failure, invalid URL) delivers a status-0 error response instead of
  hanging the schema barrier and every REST caller, and an exception
  out of the caller's own block never settles twice. When the page
  carried a session epoch, every response's `X-Funicular-Epoch` is
  checked -- a rotated value OR a missing header means this page
  belongs to a session that no longer exists: the response is
  discarded (the caller settles with an error, nothing is applied)
  and the page goes TERMINAL, irreversibly. From then on the page
  refuses to ISSUE requests as well -- every verb settles immediately
  with the same session-changed error before any fetch, since a
  request executed under the new session's cookies could mutate
  another user's data. A terminal writer steps
  down completely: pending persist timers are cancelled, the final
  persistence entry refuses forever, the writer lock frees the slot
  for a fresh tab -- but only after an in-flight snapshot write has
  landed, so a new writer can never race the old session's image --
  and both database handles become a non-persistent read view. The
  latch is independent of durability: `wipe` and `Model.reset_local`
  -- the raw paths that bypass the read-only proxies -- refuse on ANY
  terminated page, including a volatile one, which never steps down
  to reader. A mismatch landing MID-BOOT (the boot suspends at the
  writer election and at every storage read, with nothing to tear
  down yet) aborts the boot through the ordinary failure funnel,
  releasing a writer lock the election acquired after the
  termination; as defense in depth, handles installed on a terminal
  page come up read-only. `config.on_session_change` runs
  once (default: `location.reload()`). The schema barrier arms the
  page's epoch BEFORE its first request leaves, and the check itself
  latches lazily off the page otherwise -- pre-boot HTTP (an
  ephemeral model's REST call, a direct `HTTP.get` at app init) is
  covered too, not only traffic after `DB.boot`, which alone would
  latch too late. Pages without an epoch (no Rails integration yet)
  are unaffected.
- The Rails half of data isolation and the session epoch (docs
  decisions 12/13). `Funicular.configure` gains `application_id`
  (default `"funicular"`; give each app sharing an origin its own),
  `user_key` (a lambda receiving the controller and returning a
  stable identifier, nil when signed out), and `anonymous_only` (the
  explicit opt-out for apps without users) -- setting both is a
  configuration error raised straight from the initializer. The
  Railtie now stamps `X-Funicular-Epoch` on every response (emitted
  lowercase, as the Rack 3 spec requires; HTTP header names are
  case-insensitive on the wire): the epoch
  lives in the Rails session PER application_id
  (`session["funicular_epochs"]`) and rotates whenever the computed
  user key changes, so login, logout, and direct user switches all
  rotate it with no application code. Rotation runs in a controller
  around_action (the user_key lambda needs its controller) that
  stamps BEFORE the action and re-stamps in its ensure with the
  post-action identity -- the login/logout actions flip the identity
  mid-request, and their own response must already carry the rotated
  epoch. The header itself is written by a Rack middleware sitting
  ABOVE ActionDispatch's exception renderer: a controller-set header
  dies with the controller's response when the action raises, and a
  header-less 500 would read as an epoch mismatch client-side,
  terminating a healthy page over a mere server error. Both the
  concern and the include-tag helper read the session through
  `request.session`, never the controller/view `session` accessor: an
  application action named "session" shadows that accessor, and
  calling it would invoke the action itself. Session-less
  Rails API apps stay unbroken: a disabled session leaves the epoch
  feature off (no cookie identity exists to protect) instead of
  raising on every action. `picoruby_include_tag` embeds
  the namespace + epoch metadata as HTML-escaped `data-funicular-*`
  attributes on the bootstrap script tag -- exactly the contract
  `DB.read_page_metadata` reads client-side -- with the user-key
  attribute omitted for signed-out visitors and the epoch drawn from
  the same session entry the response header uses; the user-key
  attribute and the epoch identity come from ONE resolver evaluation,
  so a racy `current_user` cannot embed one user's namespace with
  another user's epoch. A `user_key` that resolves to an empty string
  fails loud server-side.
- `Funicular::DB.wipe` and the mutation generation (docs decision 17):
  one call drops every table in both databases of the current
  namespace, deletes its two snapshot keys, rebuilds the replica DDL +
  fingerprint and the local migration state from scratch, and notifies
  watchers only once the tables are queryable again AND the stale
  snapshots are really gone (components re-render onto empty tables,
  never onto missing ones; a failing snapshot delete raises out of
  wipe before any watcher is told). Writer-only
  (`ReadOnlyTabError` on a reader; fine on volatile, where there are
  no snapshots to delete). The wipe is safe mid-flight: it advances
  the mutation generation FIRST, so REST responses issued before it
  are discarded -- the callback gets `(nil, Funicular::DB::Error)`
  instead of resurrecting the previous session's rows -- pending
  persistence timers are cancelled, and an in-progress snapshot
  cannot overwrite the cleared state. While either database has an
  open transaction, wipe refuses loudly BEFORE any side effect: the
  rebuild would otherwise nest into (or be rolled back with) that
  transaction. The check cannot be raced, either: wipe never suspends
  its Task between the check and the end of the rebuild -- the
  snapshot deletes, the only awaiting operations, come last.
- The reactivity layer on top of the bus: `Component#watch(:key)` binds
  a state key to a `storage :local`/`.local` Relation -- the block runs
  once, materializes into `state[:key]`, and re-runs (re-subscribing,
  so branchy blocks may switch relations) after every change event on
  the relation's table; anything that is not a Relation raises, pointing
  at `Model.on_change`/`off_change`, the public primitive for hashes,
  counts, and raw-SQL-derived state. Watch subscriptions die with the
  component even when a lifecycle hook raises.
- The guarded database handles (`mrblib/db.rb`,
  `Funicular::DB::GuardedDatabase`/`GuardedStatement`/
  `GuardedResultSet`): the proxies `Funicular::DB.local`/`.replica`
  will hand out instead of raw connections. The allowlist is closed --
  persist/close/serialize/deserialize/backup do not exist in any state,
  `transaction` yields the proxy itself, and `query` returns a wrapped
  result set. Read-only handles enforce at EVERY execution entry
  (execute, step, ResultSet next/reset) via `Statement#readonly?` (a
  write prepared while writable is still refused after the handle went
  read-only, one-way), raising
  `Funicular::DB::ReadOnlyTabError`; ATTACH/DETACH and
  `PRAGMA query_only` are rejected in every state, comment prefixes
  included, while read pragmas stay available.
- The namespace identity (`mrblib/db.rb`): a typed, versioned tuple
  (`["v1", app, "anonymous"]` / `["v1", app, "user", key]`) encoded as
  canonical JSON, which every durable name -- the two snapshot keys and
  the Web Lock name -- derives from. Structure, not delimiters,
  separates the fields, so a user_key of "anonymous" or one containing
  separators cannot collide. `resolve_namespace` enforces the
  declaration rules client-side (`Funicular::DB::ConfigError`):
  user_key and anonymous_only are mutually exclusive, and every opted-in
  application requires a user_key unless anonymous_only explicitly accepts
  one shared anonymous namespace.
- REST is wired to the local database layer: response values decode
  through the shared codec when instances initialize and when `update`
  applies the server row (ISO 8601 strings become `Time`, 1/0 become
  booleans -- `Post.all` and `Post.local.find` now return the same Ruby
  types), and every successful REST call mirrors its result into the
  replica through the single apply entry point BEFORE user callbacks
  run (`all`/`find`/`create` upsert, `update` upserts the applied
  server row, `destroy` deletes). Write-through stays inert until
  `Funicular::DB.boot` installs the replica handle, so REST keeps
  working standalone.
- The replica-table plumbing (`mrblib/db.rb`): CREATE TABLE derived from
  the server schema (id type follows the server -- INTEGER or TEXT; a
  schema without id raises pointing at `storage :ephemeral`; binary
  attributes never reach the replica), the canonical-JSON schema
  fingerprint stored in `funicular_meta` (string equality; a mismatch
  drops and recreates ALL replica tables empty, refilled by the app's
  next explicit fetch), and the single write-through entry points
  `replica_upsert` (whole-row INSERT OR REPLACE through the codec) and
  `replica_delete` (RETURNING-based), both firing the model's change
  hook. Boot wiring and the REST call sites arrive next.
- Local CRUD and the bare-class alias on `storage :local` models:
  synchronous, validated `create` (id from the inserted row; omitted
  attributes take the SQL DEFAULT while an explicit nil binds NULL; the
  row is read back, so defaults and codec normalization land in the
  instance; auto `created_at`/`updated_at`), `#update`
  (true/false; an update with no actual changes is a no-op that does
  not touch `updated_at`), `#destroy`, `#reload`, `#new_record?`;
  `Draft.all` is the whole-table Relation (blocks and params raise --
  there is no REST side), and `where`/`order`/`limit`/`offset`/`count`/
  `first`/`exists?`/`find_by`/`delete_all` hang off the bare class,
  which on other storage kinds points you at `.local`. All local writes
  fire the `local_table_changed` hook and let SQLite constraint
  violations escape as `SQLite3::Exception`. `Model.create` now also
  accepts bare keywords (`Draft.create(title: "x")`) on every storage
  kind.

### Changed (BREAKING)

- Every `Funicular::Model` REST callback is now uniformly
  `(result, error)`: on success `result` is the payload (`all` -> array,
  `find`/`create` -> instance, `update` -> the applied instance, `destroy`
  -> `true`) and `error` is nil; on failure `result` is nil. `update` and
  `destroy` used to yield boolean-first `(true/false, data_or_error)`;
  callsites reading the first argument as a boolean must be updated.
  `update` with nothing to send (no changes, or binary-only changes) now
  reports a successful no-op instead of silently not calling the block.

### Fixed

- `Model#initialize` uses key-presence lookups instead of `||`, so a
  string-keyed `false` (boolean columns) no longer collapses to nil.

### Removed

- The IndexedDB-backed HTTP response cache (`Funicular::HTTP` `cache:`
  option, `cache_purge`, `cache_clear`). It was dead code -- no caller
  anywhere passed `cache:` -- and the local database layer is this
  release's answer to caching. Structured data belongs in replica tables,
  not keyed response bodies.

## [0.4.0] - 2026-07-23

### Added

- 0.4.0 bareword component DSL: `render` (zero-arity) runs with `self` as
  the component, so HTML tags, `component`, `form_for`, `link_to`,
  `button_to`, `suspense`, `state`, `props`, `styles`, `resources`, and
  `routes` are all called bareword, without the 0.3.0 `h.` receiver.
- DSL collision detection: tag and helper names are reserved inside
  component classes. Defining one raises `Funicular::DSLCollisionError` at
  class-definition time (`method_added`) or at first mount
  (`validate_dsl_conflicts!`, covering `attr_*` on mruby and included
  modules). `allow_dsl_override :name` opts out per class; the shadowed
  element stays reachable via `tag(:name, ...)`.
- Bareword style definitions: the class-level `styles do ... end` block
  runs on a `BasicObject` cleanroom builder, so any name (including
  `display`, `hash`, ...) defines a style identically on mruby and CRuby.
  The explicit `styles { |css| css.define(...) }` form remains for
  computed values.
- Generated style accessors: each declared style name becomes a real
  method on a per-component accessor, e.g. `styles.button(:disabled)`;
  the `styles[:name, variant]` form is kept.

### Breaking Changes

- **0.4.0 is a breaking DSL change against 0.3.0. Components written for
  0.3.0 migrate mechanically: delete the `render(h)` parameter, drop the
  `h.` receivers, convert `css.define :name, "..."` to bareword
  `name "..."`, and `h.styles[:name, variant]` to
  `styles.name(variant)`.**
- `p` inside a component builds a `<p>` element. Debug with
  `puts x.inspect`; a non-Hash argument to any tag raises `ArgumentError`
  with a hint.
- A local variable named after a tag shadows the zero-paren call form
  (plain Ruby scoping); write `option()` or rename the local.
- Tag and helper names (RESERVED_DSL) can no longer be defined as
  component methods without `allow_dsl_override`.
- Style lookups of unknown names raise (`NoMethodError` for
  `styles.typo`, `ArgumentError` for `styles[:typo]`) instead of
  silently returning an empty class string. Style definition values are
  validated (String / Hash / keyword options; unknown option keys raise).
- Tag helpers called while the component is not rendering raise
  `Funicular::RenderContextError` instead of being silently dropped.
- `ErrorBoundary` `fallback:`/`error:` procs keep an explicit view
  context (`->(h, error) { h.div { ... } }`): they are created in the
  parent's scope but run during the boundary's render, so barewords
  cannot work there by design.
- `Component#render_suspense` no longer takes a view context; suspense
  `fallback:`/`error:`/content procs run bareword in their own component
  (`fallback: -> { div { "Loading" } }`).

### Changed

- Requires picoruby-wasm with `JS::Object < BasicObject` (picoruby
  9e69333f): Kernel names (`hash`, `send`, `open`, ...) no longer shadow
  JS property access, and unknown `?`/`!` methods on JS values raise.

## [0.3.0] - 2026-07-13

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
