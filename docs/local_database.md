# Local Database

Funicular apps get a real relational database inside the browser: SQLite,
compiled to WebAssembly, queried from Ruby with an ActiveRecord-flavored API.

```ruby
Post.local.where(published: true).order(created_at: :desc).limit(10).each do |post|
  # instant, synchronous, no spinner -- this never touches the network
end
```

This document is the complete guide to the local database layer: what it is
for, how to declare models, how to query, how data flows in and out, and what
its durability guarantees are.

## Mental model

**The Rails server is the source of truth. The local database is a structured,
queryable replica plus a home for client-only data.**

Every piece of data in the local database belongs to one of two categories,
and the difference matters for everything else in this document:

- **Replica data** is a local copy of rows that live in your Rails database.
  It arrives via the REST API you already have. Losing it costs nothing but a
  refetch. It exists so that reads are instant and relational.
- **Client-only data** exists nowhere but this browser: drafts, local
  preferences, unsent form state. Losing it means losing user work, so it is
  persisted more aggressively and never dropped because of anything the
  server or the replica schema does. The only paths that discard it are the
  explicit resets (development auto-reset, a `reset: true` baseline,
  `reset_local`, `wipe`).

Physically these are two separate SQLite databases (`funicular_replica` and
`funicular_local`), each snapshotted independently to IndexedDB. You never
open or manage them yourself; model declarations decide where a model's table
lives.

### The source-of-truth contract

One lexical rule runs through the whole `Funicular::Model` API:

- **The bare class talks to the model's source of truth.** For replica and
  ephemeral models the truth is the Rails server, so the bare class speaks
  REST: `Post.all { }`, `Post.find(id) { }`, `Post.create(attrs) { }` --
  all network, all asynchronous, all reporting through an optional callback
  block with ONE shape: `(result, error)`. On success `result` is the
  payload and `error` is nil; on failure `result` is nil. Fire-and-forget
  (no block) is legal.

> **Breaking change vs Funicular <= 0.4**: `update` and `destroy` used to
> yield `(true/false, data_or_error)`. Every REST callback is now uniformly
> `(result, error)`: `all` yields the model array, `find`/`create` the
> instance, `update` the updated instance (as applied to the replica -- see
> write-through), `destroy` yields `true`. Existing callsites that read the
> first argument as a boolean must be updated.
- **`.local` is the local database view.** `Post.local.where(...)` reads the
  replica: instant and synchronous, but possibly stale -- writing `.local`
  is how you acknowledge "this may be a cache". Local reads return values;
  genuine bugs raise exceptions, with no error-handling ceremony.

```ruby
Post.all do |posts, error|                # network: block, (result, error)
  ...
end

posts = Post.local.where(published: true) # local: immediate return value
```

For `storage :local` models the local database IS the source of truth, so
the bare class and `.local` are interchangeable: `Draft.where(...)` is
`Draft.local.where(...)`; the prefix is optional there.

## Quick start

```ruby
# app/funicular/models/post.rb
class Post < Funicular::Model
  belongs_to :user
  has_many :comments
end

# app/funicular/models/draft.rb
class Draft < Funicular::Model
  storage :local do
    migrate 1 do |t|
      t.string  :title
      t.text    :body
      t.integer :post_id
      t.timestamps
    end
  end
end

# app/funicular/components/blog_index_component.rb
class BlogIndexComponent < Funicular::Component
  def initialize_state
    { posts: [] }
  end

  def component_mounted
    watch(:posts) { Post.local.where(published: true).order(created_at: :desc) }
    Post.all { |_posts, error| patch(error: error) if error }
  end

  def render
    div do
      state[:posts].each { |post| component PostRow, post: post }
    end
  end
end
```

What happens here:

1. `Post` is an ordinary schema-loaded model. By default it gets a replica
   table, auto-created from the schema your Rails server already delivers.
2. `Post.all { ... }` fetches from the REST endpoint as it always has; the
   framework additionally upserts every fetched row into the replica table
   (fetch-through).
3. `watch(:posts)` binds `state[:posts]` to a local query. Whenever the
   `posts` table changes -- because a fetch landed, or a write went through --
   the block re-runs and the component re-renders. You never wire this up
   manually.

## Declaring models

Two orthogonal declarations control a model's relationship with the local
database. Both have defaults chosen so that the common case needs no
declaration at all.

### `storage` -- where the model's data lives

```ruby
storage :replica     # default; you do not write this
storage :ephemeral
storage :local
```

- **`:replica`** (default). The model is backed by a local table derived from
  the server schema (`Funicular.load_schemas`). REST results flow into it
  automatically. The table is dropped and rebuilt whenever the server schema
  changes -- replicas are disposable by design.
- **`:ephemeral`**. No local table, nothing written to disk. The model
  behaves exactly like a classic Funicular model: REST only. Use this for
  sensitive models whose data must not rest in browser storage
  (authentication/session models are the canonical case). `.local` raises
  `Funicular::DB::NoTableError`.
- **`:local`**. Client-only table. No server schema, no REST integration;
  the table shape is declared with `migrate` blocks on the `storage`
  declaration itself (below). Writes are local and synchronous. The local
  table is the source of truth, so the `.local` prefix is optional:
  `Draft.where(...)` == `Draft.local.where(...)`. `storage :local` is the
  only variant that takes a block; passing one to `:replica` or `:ephemeral`
  raises.

#### How the databases boot

Database startup is one state machine (`Funicular::DB.boot`), driven by
`Funicular.start`, and it runs whether or not the app uses server schemas
at all -- an app with only `storage :local` models and no
`Funicular.load_schemas` call still gets namespace resolution, writer
election, snapshot restore, and local migrations. The order is fixed:

1. Model class bodies only record declarations; nothing touches SQLite.
2. The application/user namespace and session epoch are resolved from the
   page.
3. Writer election runs (Web Lock).
4. The local database is restored and its migrations applied.
5. Once ALL requested server schemas have arrived, the replica database is
   restored and its fingerprint validated -- DDL derivation and comparison
   run exactly once per boot, over the complete, canonically-ordered set.
6. Components mount/hydrate only after the databases they can reach are
   queryable; a `watch` can never observe a half-booted database.

If any schema request fails, startup fails loudly and precisely: the
`load_schemas` completion block is NOT invoked (so the app's
`Funicular.start` call inside it never runs), the replica database is not
initialized (a partial replica would be worse than none), and the failure
is always written to the console -- `config.on_boot_error` additionally
receives the aggregated errors naming each failed model, but leaving it
unset never means silence.

"Fails" is airtight by construction: the HTTP layer converts every outcome
-- success, HTTP error status, parse error, and fetch Promise rejection
(network down, CORS, aborted) -- into exactly one callback invocation per
request, so the barrier always settles; it cannot hang waiting for a
request whose Promise rejected. And an EMPTY schema set is only a valid
boot when no replica models are declared -- replica models with zero loaded
schemas would mean mounting components over nonexistent tables, so that is
a boot failure too.

The schema fingerprint covers only what affects SQLite DDL -- table names,
column names and types, and the id type. Endpoint or validation changes on
the server do NOT rebuild the replica. The fingerprint is the canonical
schema JSON itself, stored in a metadata table inside the replica database
and compared by plain string equality -- no hash algorithm, no extra
dependency, no collision to reason about (and no `PRAGMA user_version`,
which is a 32-bit integer and could not hold it anyway).

When the fingerprint mismatches, tables are dropped and recreated -- and the
rebuilt replica starts EMPTY. The framework still never issues implicit
HTTP: rows reappear at your app's next explicit fetch.

### `refresh` -- how replica data stays fresh

v1 ships exactly one policy, and it is the default, so you never write this
declaration: **manual**. The framework never issues an HTTP request on its
own. Replica tables change only when your code fetches
(`Post.all { ... }`, `Post.find(id) { ... }`) or writes through
(`create`/`update`/`destroy`). Predictable and boring, in the good sense --
and combined with `watch`, explicit fetching is already reactive: the fetch
lands, the table changes, every watching component re-renders.

The axis exists because it has a future: `refresh :auto`
(stale-while-revalidate against an authoritative index endpoint) and
`refresh :live` (ActionCable-pushed replication) are planned as drop-in
upgrades for models already written with `watch` -- app code will not
change. Declaring `:auto` or `:live` today raises "not yet supported" at
class-definition time, as does declaring `refresh` on `:ephemeral` or
`:local` models.

### Table names

Table names derive from the class name with naive pluralization: `Post` ->
`posts`, `Category` -> `categories`. There is no inflector dictionary in the
browser runtime, so irregular names must be declared:

```ruby
class Person < Funicular::Model
  table_name "people"
end
```

### Associations

```ruby
class Post < Funicular::Model
  belongs_to :user
  has_many :comments
end
```

Associations are local-query sugar over the `<name>_id` convention:

- `post.user` runs `User.local.find_by(id: post.user_id)` -- returns an
  instance or `nil`.
- `post.comments` returns `Comment.local.where(post_id: post.id)` -- a
  chainable Relation: `post.comments.order(:created_at).limit(5)`.

Instance-level association readers are unprefixed by design: an instance you
are holding already came out of the local database (or a fetch that passed
through it), so its neighborhood reads locally too. The `.local` marker
belongs at query entry points, where the cache-vs-server decision is made.

Options: `class_name:` and `foreign_key:` when the convention does not fit.
Not supported in v1: `through:`, `includes`/eager loading, polymorphic
associations. Note that the classic N+1 concern barely applies here -- each
"+1" is a microsecond query against local memory, not a network round trip.

Association targets are resolved lazily, at first use -- model files load in
sorted filename order, so `belongs_to :user` in `post.rb` must not demand
the `User` constant while `user.rb` is still unloaded. A typo in the target,
or a reference to a model the client does not carry, fails with a clear
error the first time the association is read.

Associations are declared on the client, deliberately. Your Rails models may
have dozens of associations; the client declares only the slice of the graph
it actually replicates, so the local association surface is exactly what the
app consciously chose to carry -- nothing auto-generated pointing at tables
that do not exist here.

### `storage :local do ... end` -- table shape and evolution

Client-only models define their table inside the `storage` declaration, as a
sequence of numbered `migrate` blocks:

```ruby
class Draft < Funicular::Model
  storage :local do
    migrate 1 do |t|
      t.string  :title
      t.text    :body
      t.integer :post_id
      t.boolean :pinned, default: false
      t.index   :post_id
      t.timestamps       # created_at / updated_at, maintained automatically
    end
  end
end
```

The table IS the fold of its `migrate` blocks: block 1 creates it, and every
later change -- additive or destructive -- is simply the next numbered block:

```ruby
storage :local do
  migrate 1 do |t|
    t.string :title
    t.string :body
    t.timestamps
  end
  migrate 2 do |t|
    t.rename :body, :content            # destructive steps are ordinary steps
    t.string :status, default: "draft"  # in later blocks this is ADD COLUMN
  end
end
```

There is no separate schema declaration to keep in sync: the blocks are the
schema, so declaration and migration can never disagree.

Builder vocabulary: `t.string` / `t.text` / `t.integer` / `t.float` /
`t.boolean` / `t.datetime` (options: `default:`, `null:`), `t.timestamps`,
`t.index` / `t.remove_index`, `t.rename :old, :new`, `t.remove :column`, and
`t.execute "..."` as the raw-SQL escape hatch for data transformations
(backfills, splitting a column, ...). Types map to SQLite affinities:
`string`/`text` -> TEXT, `integer` -> INTEGER, `float` -> REAL, `boolean` ->
INTEGER (0/1, converted at the Ruby boundary), `datetime` -> TEXT (ISO 8601
normalized to UTC at fixed precision by the codec -- that normalization is
what makes string order chronological). Every table gets an implicit
`id INTEGER PRIMARY KEY`.

How migrations run:

- Ordinarily the first block is version 1. The one exception: the first
  RETAINED block may carry any positive version when it is a `reset: true`
  baseline (see below) -- that is what makes deleting pre-baseline history
  legal. After the first retained block, versions must be contiguous; a gap
  raises at class-definition time.
- On boot, the framework compares each table's stored version (kept in a
  meta table inside the local database) with the declared blocks. A fresh
  database, or one stored below the baseline, is created/recreated from the
  baseline definition and then receives the later blocks; a database at or
  above the baseline receives only its missing later blocks. Application is
  per table, inside one transaction; failure rolls back and raises -- user
  data is never left half-migrated. Each `migrate` block is evaluated
  exactly once per migration run (the framework validates and applies the
  same recorded operations); it also runs when column metadata is first
  needed, so keep blocks deterministic and free of side effects.
- If any table's stored version is NEWER than the declared maximum (a
  rolled-back deploy), the WHOLE local database fails loud: every
  local-model operation -- read or write, any table -- raises
  `Funicular::DB::SchemaTooNewError`, and the database sits at
  `PRAGMA query_only = ON` so raw SQL cannot write either. (A newer deploy
  may have renamed or removed columns; old code cannot be trusted on that
  data, and v1 does not do per-table nuance.) Raw SELECTs against the
  actual on-disk schema remain possible for inspecting or exporting.
  Recovery: `reset_local` on the affected table (the framework internally
  lifts `query_only` for that rebuild; still `ReadOnlyTabError` on
  non-writer tabs) or a fixed-forward deploy.

#### Resetting a local table

Sometimes migrating is the wrong tool and "throw it away" is the right one.
Three mechanisms, for three situations:

- **Development auto-reset.** If applying migrations fails in the
  development environment, the framework drops the table and rebuilds it
  from the blocks, with a console warning -- iterate on your schema freely.
  This never happens in production.
- **Release-time reset: `reset: true`.** Mark a block as a new baseline:

  ```ruby
  migrate 4, reset: true do |t|
    t.string :title            # a complete table definition, not a diff
    t.text   :content
    t.timestamps
  end
  ```

  Clients below version 4 do not migrate: their table is dropped and
  recreated from this definition, discarding its data -- that is the point.
  Blocks older than a `reset: true` baseline may be deleted from the code;
  clients stranded below the baseline simply fall into the reset path. This
  doubles as the way to squash a long migration history.
- **Programmatic: `Draft.reset_local`.** Drops and rebuilds the table right
  now -- for a "clear local data" button or console debugging.
  `Funicular::DB.wipe` (below) remains the everything-nuke for logout.

## Querying

Local queries live under `.local` (see the source-of-truth contract) and
return immediately. `where`, `order`, `limit`, and `offset` build a lazy,
chainable Relation; SQL executes once, when you materialize it.

```ruby
rel = Post.local.where(published: true)   # no SQL yet
        .order(created_at: :desc)         # still no SQL
        .limit(10)
rel.each { |post| ... }                   # one SELECT, here
```

### Conditions

Four forms, covering the practical 95%:

```ruby
Post.local.where(done: false)                      # equality   ... WHERE done = ?
Post.local.where(id: [1, 2, 3])                    # array      ... WHERE id IN (?, ?, ?)
Post.local.where(created_at: t1..t2)               # range      ... WHERE created_at BETWEEN ? AND ?
Post.local.where("published_at < ?", now_iso8601)  # raw SQL fragment with placeholders
```

Edge semantics are pinned down, ActiveRecord-style:

- `where(deleted_at: nil)` generates `IS NULL`, never `= ?`.
- `where(id: [])` is an always-empty relation (`WHERE 1=0`), not invalid SQL.
- An inclusive Range (`1..10`) becomes `>= AND <=`; an exclusive Range
  (`1...10`) becomes `>= AND <`.
- Column names in hash conditions and `order` are validated against the
  model's schema and quoted; unknown columns raise instead of reaching SQL.
- `offset` without `limit` is legal (emitted as `LIMIT -1 OFFSET n`, which
  is how SQLite spells it).
- `count` on a limited/offset relation counts the window (a `COUNT(*)` over
  a subquery), matching ActiveRecord.
- `delete_all` raises if the relation carries `order`/`limit`/`offset` --
  say what you mean with a plain condition. It also exists ONLY for
  `storage :local` models: on a replica Relation it raises
  `Funicular::DB::ReplicaWriteError` (writer tab included) -- the server
  owns replica rows, and deletions reach the replica through write-through
  `destroy`, never through a local bulk delete.
- Boolean and datetime values cross the Ruby/SQLite boundary through one
  shared codec (`true`/`false` <-> 1/0, `Time` <-> ISO 8601 TEXT normalized
  to UTC at fixed precision -- arbitrary ISO 8601 offsets would not sort
  chronologically as strings) used identically by writes, reads, and
  condition binding. Datetime STRINGS handed to the typed side (a
  `datetime` column in a hash condition or a local write) are parsed and
  re-normalized to the same UTC fixed-precision form; malformed ones raise
  `ArgumentError` at bind time, not at query time. The SAME codec is
  applied when REST responses initialize model instances, so `Post.all`
  and `Post.local.find` return the same Ruby types for the same attribute.
  One boundary: binds on a RAW SQL fragment carry no column type, so they
  are encoded by value (`true`/`false` and `Time` instances converted;
  strings pass through untouched) -- format datetime strings there as UTC
  ISO 8601 yourself, as the examples do.

Multiple `where` calls AND together. `OR`, `JOIN`, `GROUP BY`, and anything
else SQL can do remain available through the raw-fragment form or, for full
control, `Funicular::DB.replica.execute(sql, binds)` /
`Funicular::DB.local.execute(sql, binds)`.

One rule comes with these guarded handles: framework writes all pass through a
single apply path that fires table change events (which drive `watch`) and
schedules snapshot persistence. A raw `execute` that WRITES bypasses both.
Reads need no ceremony, but after writing raw, tell the framework:

```ruby
Funicular::DB.local.execute("UPDATE drafts SET title = TRIM(title)")
Funicular::DB.notify_changed(Draft)     # fire watches + schedule persist
```

`notify_changed` takes the model class (preferred -- it knows both the
table and which database it lives in) or an explicit pair,
`notify_changed(:local, :drafts)`; a bare table name would be ambiguous
between the two databases. Called inside a raw transaction, the
notification and the persistence scheduling are deferred until commit and
discarded on rollback, like every framework-internal write.

### Ordering and slicing

```ruby
Post.local.order(:created_at)                # ASC
Post.local.order(created_at: :desc)
Post.local.order(:pinned, created_at: :desc) # multiple keys
Post.local.limit(20).offset(40)
```

### Materializers

```ruby
relation.each { |m| ... }   # enumerate model instances
relation.to_a               # array of model instances
relation.first              # instance or nil (adds LIMIT 1)
relation.count              # SELECT COUNT(*) -- no rows materialized
relation.exists?            # true/false      -- SELECT 1 LIMIT 1
```

`Post.local` itself is a Relation over the whole table, so everything hangs
off it directly:

```ruby
Post.local.find(42)         # instance, or raises Funicular::RecordNotFound
Post.local.find_by(id: 42)  # instance or nil
Post.local.count
Post.local.first
Post.local.to_a             # the whole table
```

Because the `.local` namespace has no REST methods in it, the ActiveRecord
names are all available with their ActiveRecord semantics -- including
`find`, which on the bare class remains the REST fetch (`Post.find(id) { }`)
it has always been.

Rows come back as instances of your model class -- the same class the REST
mapper returns -- with attribute readers, validations, and associations.

## Writing data

### Replica models: writes go through the server

The server owns replica data, so writes keep their existing REST form -- and
the local replica follows automatically:

```ruby
Post.create({ title: "Hello" }) do |post, error|
  # on success the server's authoritative row was upserted into the replica;
  # every watch on Post has already re-rendered
end

post.update(title: "Edited") do |post, error| ... end  # post = updated instance
post.destroy do |ok, error| ... end                    # ok = true on success
```

This is called write-through: the framework applies the server's response
(not your request) to the replica, so the local copy always reflects what the
server actually stored -- server-side defaults, callbacks, and normalizations
included. The replica is updated BEFORE your callback runs: inside the
callback, `Post.local.find(post.id)` already sees the applied row. There is
no local-write API for replica models in v1; optimistic local writes are a
possible future layer.

### Local models: writes are local, synchronous, validated

```ruby
draft = Draft.create(title: "untitled", body: "")   # returns the instance
draft.update(body: "...")                           # true/false (validations)
draft.errors                                        # standard validation errors
draft.destroy                                       # true
Draft.where("updated_at < ?", cutoff).delete_all    # bulk delete
```

No blocks -- these cannot fail like a network call can. Validation failures
report through `valid?`/`errors` exactly like the REST mapper does today.

Local record lifecycle, precisely: a new record is one whose `id` is nil;
`create` assigns the id from the inserted row. `created_at`/`updated_at`
(when declared via `t.timestamps`) are maintained automatically; an `update`
with no actual changes is a no-op that returns true and does not touch
`updated_at`. SQLite constraint violations (e.g. NOT NULL) escape as
`SQLite3::Exception` -- they are bugs, not user-facing validation. On
`storage :local` models the bare class is an alias for `.local`, so
`Draft.all` returns the whole-table Relation; passing a block to it raises
(there is no REST side to call).

`delete_all` is the only bulk writer. There is deliberately no `update_all`
(it would bypass validations); the rare true need is served by raw SQL plus
`Funicular::DB.notify_changed`.

## Reactivity: `watch`

`watch` is how components consume local data. It binds a state key to a
Relation:

```ruby
def component_mounted
  watch(:todos) { Todo.local.where(done: false).order(:id) }
end
```

Semantics -- deliberately simple in v1:

- The block must return a Relation (anything else raises with a helpful
  message). It runs once immediately; the framework materializes the
  Relation and places the array in `state[:todos]`.
- The framework subscribes to the Relation's table. Whenever that table
  changes -- fetch-through, write-through, local write, wipe -- the block
  re-runs (and is re-subscribed, in case a branchy block returns a
  different model's Relation this time) and the key is patched, triggering
  a re-render.
- Subscriptions die with the component; unmount cleans up automatically,
  even when a user lifecycle hook raises on the way out.
- Re-evaluation is cheap by design: these are microsecond local queries, so
  the framework can afford table-level (coarse) granularity.

Derived values -- counts, Hashes combining several queries, raw SQL -- use
the public primitive plus an ordinary `patch`:

```ruby
def component_mounted
  @todo_sub = Todo.on_change { patch(open_count: Todo.local.where(done: false).count) }
  patch(open_count: Todo.local.where(done: false).count)
end

def component_will_unmount
  Todo.off_change(@todo_sub)
end
```

Delivery guarantees (also for the `on_change` primitive below):

- Change events fire only after the surrounding SQLite transaction commits,
  and at most once per changed table per transaction -- a 50-row reconcile
  is one event, not fifty.
- Watcher updates are queued and coalesced, never delivered inside another
  component update: a notification arriving mid-`patch` is deferred to the
  next tick instead of being dropped.
- A subscriber that raises is isolated: it cannot prevent other subscribers,
  or the REST callback that triggered the write, from running.

`render` keeps its existing rule: **it reads `state`, nothing else.** `watch`
exists so that "state" and "live view of the local DB" are the same thing.

## Persistence and durability

SQLite runs in wasm memory; durability comes from snapshotting a whole
database into IndexedDB. The framework automates the snapshotting, with
different policies per database:

| | replica DB | local DB |
|---|---|---|
| Contains | server-recoverable copies | unrecoverable user data |
| Auto-persist after a write (`persistent_writer` state only; see Data isolation) | debounced, ~5 s quiet | debounced, ~500 ms quiet |
| Extra persist | on `visibilitychange` (tab hidden) | on `visibilitychange` |
| On schema mismatch | dropped and rebuilt | never dropped; migrated |

What this means in practice:

- **A page reload restores both databases from their last snapshot** (when
  persistence is available -- in the `volatile` state there is no snapshot
  to come back to). The
  replica gives you instant first paint from the previous session's data
  (stale until your fetches revalidate it -- design your
  screens knowing the first frame may be yesterday's data).
- **A crash or force-closed tab can lose the seconds since the last
  snapshot.** For the replica this is a non-event. For local data the
  window is small (sub-second debounce plus the tab-hidden backstop), but it
  is not zero: browser storage is best-effort, not a transaction log. Data
  the user must never lose should eventually reach the server through a REST
  endpoint; the local DB is not a substitute for that.
- Browsers may evict IndexedDB under storage pressure. When at least one
  `storage :local` model is declared -- that is, when data actually worth
  protecting exists -- the framework requests persistent storage
  (`navigator.storage.persist()`; note Firefox surfaces this as a user
  prompt). Replica-only apps never trigger the request. Opt out with
  `config.request_persistent_storage = false`. Either way, the final word
  belongs to the browser.

To force a snapshot right now (rarely needed):

```ruby
Funicular::DB.flush
```

Persistence runs in the background, and background work can fail (quota
exceeded, IndexedDB errors). Failures are never silent: they are logged
prominently, and apps that want to react -- warn the user, disable a form --
can register a hook:

```ruby
Funicular::DB.configure do
  config.on_persist_error = ->(error) { ... }
end
```

Snapshot I/O is owned by the framework, not by the SQLite layer: Funicular
opens the IndexedDB store itself with the automatic in-memory fallback
DISABLED, so a silently substituted empty store can never masquerade as
persistence -- unavailability is detected, classified, and announced as the
`volatile` state instead. Snapshots are stored Base64-encoded (a raw
SQLite image is a binary String, which does not survive the JS bridge
intact -- the same encoding the standalone sqlite3 gem uses).

Storage failure at boot has one simple philosophy in v1: **fail loud, fix,
reload**. There are exactly two behaviors:

- **The browser context has no storage BY DESIGN.** Availability errors on
  open (missing global, `SecurityError`, `InvalidStateError`) mean private
  mode or an exotic embedder: the page runs `volatile` (everything works,
  nothing persists -- see Data isolation).
- **Anything else fails the boot.** A store open error
  (`QuotaExceededError`, `UnknownError`, `VersionError`, a `BlockedError`
  timeout) or a snapshot read error (quota/data on GET) means storage
  exists but could not be used -- snapshots, including unrecoverable local
  data, may well be sitting there, so the framework refuses to start on
  top of them: components do not mount, the failure is written to the
  console, and `config.on_boot_error` receives it. For a corrupt snapshot
  (a GET failure -- the store handle exists), the hook may call
  `Funicular::DB.wipe` to discard it and then reload; for open failures,
  fix the browser state (quota, blocking tabs) and reload. There is no
  partial operation on top of unreadable storage.

## Data isolation: users, tabs, and windows

### One namespace per application and user

Snapshots are stored under a namespace built from two parts: an application
identifier and an opaque user storage key that the Rails server embeds in
the page (configured once, server-side, via the gem's existing
configuration API):

```ruby
# config/initializers/funicular.rb (Rails)
Funicular.configure do |config|
  config.application_id = "my_app"          # default: "funicular"
  config.user_key = ->(controller) {
    controller.current_user&.storage_key    # see below
  }
end
```

The user key should be a **stable, non-reusable** identifier -- a dedicated
UUID column is ideal. A raw sequential id works but is discouraged: if your
app ever deletes and re-issues ids, a new account could inherit an old
account's snapshot. The value is canonicalized with `to_s`; a signed-out
visitor gets the shared `anonymous` namespace (shared by every signed-out
visitor of that browser profile -- treat it as scratch space).

Internally the identity is never a naive string concatenation -- that would
let `application_id "a:b"` + user `"c"` collide with `"a"` + `"b:c"`, and a
real user key that happens to be the string `"anonymous"` collide with the
signed-out namespace. The framework encodes a typed, versioned tuple
(`["v1", app_id, "anonymous"]` / `["v1", app_id, "user", key]`) as
canonical JSON, and that ONE encoded identity is used everywhere it
matters: snapshot keys, the Web Lock name, the previous-identity value in
the Rails session, and the epoch-rotation comparison.

**Configuring `user_key` is mandatory for apps that use the local
database.** The gem cannot detect whether your app has authentication, and
a forgotten `user_key` would silently put every logged-in user into the
shared `anonymous` namespace AND stop the session epoch from rotating --
both isolation mechanisms broken at once. So the contract is explicit:
declare one or the other,

```ruby
Funicular.configure do |config|
  config.user_key = ->(controller) { ... }   # apps with authentication
  # or, for apps that genuinely have no users:
  config.anonymous_only = true
end
```

and an app that declares local-database models without doing either fails
loudly. The authoritative check runs client-side, in the database boot,
after every model declaration has been recorded -- the server cannot always
know at render time whether client-side local-DB models exist, so the
helper embeds "unconfigured" metadata as-is and the server raises only in
the cases it can detect reliably. Setting BOTH `user_key` and
`anonymous_only` is also a configuration error -- the framework never picks
one silently.

The namespace and epoch metadata reach the page through
`picoruby_include_tag` -- the helper every Funicular layout already has --
as HTML-escaped data attributes, so CSR-only and local-only apps need no
new helper and no template change.

At boot the client opens only the current namespace's databases. Table
names, SQL, and your model code are untouched by any of this -- isolation
happens entirely at the snapshot layer. When user B signs in on a machine
where user A never logged out (or the browser crashed), user B's boot opens
user B's namespace and never restores user A's replica or drafts. Cross-user
isolation does not depend on any logout code running. A pleasant side
effect on shared machines: when user A signs back in, their drafts are
still there. (Scope this correctly, though: namespacing stops the FRAMEWORK
from mixing users' data. It is not a security boundary against JavaScript
already running in the same origin -- browser storage never is.)

If more than one Funicular application shares an origin, give each a
distinct `application_id`.

### The session epoch: when the user changes under a running tab

All tabs of a profile share one cookie session, so a login/logout in tab B
silently changes who tab A's requests authenticate as -- and GET requests
carry no CSRF check, so they would keep succeeding as the new user. Left
alone, tab A would apply and persist user B's data into user A's namespace.

The framework prevents this with a session epoch, distinct from the storage
key: an opaque value that changes on every authentication transition. It is
managed entirely by the gem -- no application code: the Railtie keeps the
epoch in the Rails session and rotates it (SecureRandom) whenever the
computed `user_key` differs from the one the session was stamped with, so
login, logout, and direct user switches all rotate it. Every REST and
schema response carries the current epoch (an `X-Funicular-Epoch` header);
the client compares it against the epoch it booted with.

A response entering the apply path with a MISSING epoch header is treated
exactly like a mismatch -- fail closed, never fail open (a stale cached
response must not sneak through).

On mismatch the page enters a TERMINAL invalid-session state:

1. the offending response is discarded (never applied to any table),
2. from that moment on, replica applies, `storage :local` writes, raw
   writes, and snapshot persistence are ALL refused -- permanently, for the
   life of the page; a custom hook that chooses not to reload cannot
   re-enable them,
3. the `config.on_session_change` hook runs -- its default reloads the
   page, after which the tab boots cleanly in the new session's namespace.

The terminal flag is an irreversible latch, independent of the durability
state.

A WRITER tab entering terminal steps down completely: pending debounce
timers are cancelled, any persist already in flight is serialized with,
and then the lock-holding promise is resolved so the writer lock is
RELEASED -- a terminal tab that a custom hook chose not to reload must not
sit on the old namespace's lock forever, condemning that user's next tab to
permanent reader status. Its connections remain as a non-persistent read
view of the moment it died.

Override the hook to show a "you were signed out" dialog instead; what you
cannot do is keep operating, because the page's data and the session no
longer belong to the same user.

### One writer per namespace (multiple tabs)

Each tab holds its own in-memory SQLite image; two tabs snapshotting the
same name would silently overwrite each other ("last persist wins"). The
framework therefore elects a single writer per namespace using a Web Lock:

Every page runs in exactly one of three durability states:

- **`persistent_writer`** -- the tab holding the lock. Restores snapshots,
  persists, writes locally and to the replica. Exactly one per namespace.
- **`persistent_reader`** -- any additional tab, for the LIFE of the page.
  The replica works fully (restored from the latest snapshot; fetch-through
  still applies -- those are in-memory replica writes and are allowed) but
  is never persisted. Writes to `storage :local` models raise
  `Funicular::DB::ReadOnlyTabError`: unrecoverable data is never written
  where it would be silently lost. To write, reload after the writer tab
  has closed -- there is no in-page promotion in v1.
- **`volatile`** -- everything works, including `storage :local` writes,
  but NOTHING persists: no snapshot restore-to-disk path exists at all
  (persist, flush, and the auto-persist on close are disabled). This is
  the state when coordination or storage is unavailable (below) -- the app
  stays fully functional, durability is honestly zero, and a prominent
  error is logged (plus `config.on_persist_error` once at boot). (The name
  is deliberately NOT "ephemeral": `storage :ephemeral` is a model
  declaration, an unrelated concept.)

Which state a page gets -- decided instantly at boot, never by waiting:

- Web Locks available: boot requests the lock with `ifAvailable: true`,
  which returns immediately. Granted -> `persistent_writer` (the lock is
  held with a promise that resolves only on page teardown); not granted ->
  `persistent_reader`, permanently for this page.
- Web Locks API unavailable (very old browsers, some embedded WebViews) ->
  `volatile`; with no way to coordinate, running uncoordinated persistent
  writers is the one thing that must never happen.
- IndexedDB unavailable (blocking private modes) -> `volatile`.

Enforcement lives BELOW the model layer, not in politeness:
`Funicular::DB.local` / `.replica` hand out guarded proxy handles, never
the underlying `SQLite3::Database`. The proxy's surface is an explicit
allowlist, closed against leaking the raw connection: `transaction` is
implemented by the proxy and yields THE PROXY (never the raw database, as
the underlying gem's `transaction` would); `prepare` returns a guarded
statement subject to the same checks; batch execution, `deserialize`, and
manual `commit`/`rollback` are classified the same way. On a
`persistent_reader` tab the LOCAL connection runs with
`PRAGMA query_only = ON` (the replica connection stays writable in memory
for revalidation) and raw local writes fail. `persist` and `close` are not
on the proxy surface AT ALL, on any tab: the framework's databases are
unbound memory databases whose snapshots live in Funicular's own store, so
the SQLite-level `persist` has no valid target, and `close` would destroy
a framework-owned connection (the framework closes its connections
internally, without persisting). Persistence is exclusively
`Funicular::DB.flush` and the automatic debounce. On a non-writer tab,
`flush` / `wipe` / `reset_local` raise `ReadOnlyTabError`. There is no
sequence of public API calls by which a non-writer tab can overwrite the
snapshot.

And `query_only` itself is guarded -- SQLite's pragma is settable, so it is
not, by itself, a read-only guarantee. In any read-only state the proxy
checks every statement at EXECUTION time (not just preparation time) using
SQLite's own writes-or-not classification (`sqlite3_stmt_readonly`,
exposed as `Statement#readonly?`), converts write statements into the
appropriate framework exception, and separately rejects
connection-state-changing statements that SQLite classifies as "read-only"
(`PRAGMA query_only`, `ATTACH`, `DETACH`). Batch execution is refused
outright in read-only states.

Reader-to-writer promotion and cross-tab live synchronization
(BroadcastChannel) are post-v1 concerns. A reader tab that needs to write
reloads once the writer tab is gone -- one keypress, zero protocol.

### Private/incognito windows

An incognito window is a separate storage partition: separate cookies,
separate IndexedDB, separate Web Locks. A normal window and an incognito
window can therefore even be signed in as different users simultaneously
without seeing or clobbering each other. Within the incognito session
everything works normally (multiple incognito tabs share one partition and
one writer lock), but the partition's IndexedDB is ephemeral: snapshots --
including `storage :local` data -- vanish when the last incognito window
closes, which is exactly what private mode promises the user. Browsers that
block IndexedDB in private mode entirely are detected at open time: the
IndexedDB bridge preserves the DOMException name, and only the explicitly
listed availability errors (missing global, `SecurityError`,
`InvalidStateError` on open) drop the page to the `volatile` state -- the
app still runs, nothing persists. Quota and ordinary data errors do NOT
silently fall back: switching to an empty in-memory store would masquerade
as losing the user's previously persisted data, so those surface through
logging and `config.on_persist_error` instead. (`onblocked` is not an
availability failure either; it waits and times out with its own error.)

## Logout: wiping local data

Because namespaces already isolate users, `wipe` is a cleanup tool, not a
security requirement. Call it when the product wants no trace left on the
machine (shared terminals, "clear local data" policies):

```ruby
Funicular::DB.wipe
```

One call drops every table in both databases of the CURRENT namespace and
deletes its snapshots -- the two namespaced keys in Funicular's own
snapshot store. There is no per-model opt-out; a wipe is a wipe -- partial
wipes are how leftovers happen. (This is also the recovery path when a
local snapshot became unreadable; see Persistence.)

`wipe` runs on the writer tab (on a non-writer tab it raises
`ReadOnlyTabError`, like every destructive operation there). On the writer
it is safe to call at any moment, mid-flight included:

- REST responses that were already in flight when the wipe happened are
  discarded, not re-applied -- a logout can never resurrect the previous
  session's rows.
- Pending persistence timers are cancelled; an in-progress snapshot cannot
  overwrite the cleared state.
- Watches fire after the databases are rebuilt and queryable again, so
  components re-render onto empty tables rather than crashing onto missing
  ones.

## Server-side rendering

Local queries do not exist on the server. SSR pages are for SEO and first
paint; they render from server data passed via `state:`, exactly as before.

If a component's server-side render path reaches a local query, it raises
`Funicular::DB::UnavailableError` with a pointed message -- deliberately loud,
because silently rendering an empty list would defeat SSR and hide the bug.
The practical rule: components rendered through SSR read their data from
state seeded by the controller; `watch`-driven components belong on
client-rendered routes (or behind `Funicular.server?` guards in
`component_mounted`, which SSR never calls anyway).

## Configuration

Optional, in `app/funicular/initializer.rb`:

```ruby
Funicular::DB.configure do
  config.replica_debounce_ms         = 5000   # default
  config.local_debounce_ms           = 500    # default
  config.request_persistent_storage  = true   # default; see Persistence
  config.on_persist_error            = nil    # ->(error) { ... }
  config.on_boot_error               = nil    # ->(errors) { ... }; see boot
  config.on_session_change           = nil    # default behavior: reload page
end
```

The user/application namespace and session epoch are configured on the
Rails side (`Funicular.configure` -- see Data isolation), not here. Future
knobs (focus-time revalidation, for one) will land here rather than as new
method surface.

## Limitations and sharp edges (v1)

- **Whole-database snapshots.** Persistence cost scales with database size,
  not change size. Replicating tens of thousands of rows will make the
  5-second snapshot noticeable; replicate what your screens need, not your
  whole warehouse.
- **Memory-bound.** Both databases live in wasm memory. Same advice.
- **Binary attributes are not replicated.** This is wire-format reality, not
  a policy: binary attributes never ride the REST JSON in the first place
  (they travel through `Funicular::FileUpload`), so there is nothing to put
  in the replica. Assets that should live client-side (images, files) belong
  to Blob/object URLs or the Cache API, not a relational table.
- **Replica rows need an `id`.** Fetch-through upserts key on it. The
  local `id` column follows the type the
  server schema declares -- `INTEGER PRIMARY KEY` for integer ids,
  `TEXT PRIMARY KEY` for UUID-keyed models. A schema-loaded model whose
  schema has no `id` cannot be replicated: schema loading raises and the
  message tells you to declare `storage :ephemeral` on it.
- **A local query can yield.** Today queries never suspend, but the runtime
  reserves the right (a future VFS may perform I/O per statement). Do not
  assume the world cannot change between two separate queries; a single
  query is always internally consistent.
- **`JOIN`, `OR`, aggregates** beyond `count`: raw SQL escape hatch only.
- **No optimistic writes** for replica models: a `create`/`update` shows up
  locally when the server confirms it, not before.

## Relationship to `Funicular::Store`

The local database supersedes the Store layer (`Funicular::Store`,
`Store::Singleton`, `Store::Collection`). Store remains available and
unchanged for now, but no new features will build on it, and it will be
deprecated and removed once `refresh :live` ships. New code should use models
and `watch`.
