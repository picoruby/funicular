# Rails Integration

This document describes CRubyGem funicular as a Rails plugin.

## Seamless Rails integration

- Automatic compilation of Ruby files to mruby bytecode (.mrb)
- Development mode with debug symbols (-g option)
- Production mode with optimized bytecode (no debug symbols)
- Auto-recompilation in development when source files change
- Rails-style routing with `link_to` helper and URL path helpers
- RESTful HTTP method support (GET, POST, PUT, PATCH, DELETE)
- Built-in CSRF protection for non-GET requests

## Prerequisites

Funicular bundles a WebAssembly build of the `picorbc` mruby compiler and
runs it through Node.js. Make sure Node.js is installed on any machine that
performs Funicular compilation (your development workstation, CI, and any
host that runs `assets:precompile`).

```bash
node --version
```

You do **not** need to install `@picoruby/picorbc` from npm; the gem ships
with the compiler already vendored.

## Installation

### 1. Add the gem

```ruby
# Gemfile
gem "funicular"
```

```bash
bundle install
```

### 2. Run the install task

```bash
bundle exec rake funicular:install
```

This runs two sub-tasks:

#### `funicular:install:wasm`

Copies the PicoRuby.wasm runtime (dist and debug builds) into your Rails app:

```
public/
  picoruby/
    dist/          # production build (smaller, no debug symbols)
      init.iife.js
      picoruby.js
      picoruby.wasm
    debug/         # development build (larger, with debug symbols)
      init.iife.js
      picoruby.js
      picoruby.wasm
```

The files in `public/picoruby/` should be added to `.gitignore` and
re-installed after gem updates.

#### `funicular:install:debug_assets`

Copies the component highlighter stylesheet and script for development use:

```
app/assets/
  javascripts/funicular_debug.js
  stylesheets/funicular_debug.css
config/initializers/funicular.rb
```

The generated `config/initializers/funicular.rb` is the place to configure
which PicoRuby.wasm source `picoruby_include_tag` uses (see below).

### 3. Add the script tag to your layout

Replace any hardcoded PicoRuby `<script>` tag with the view helper:

```erb
<%# app/views/layouts/application.html.erb %>
<head>
  ...
  <%= picoruby_include_tag %>
</head>
```

`picoruby_include_tag` chooses the right build automatically:

| Environment | Default source | Path served |
|---|---|---|
| development | `:local_debug` | `/picoruby/debug/init.iife.js` |
| test | `:local_debug` | `/picoruby/debug/init.iife.js` |
| production | `:local_dist` | `/picoruby/dist/init.iife.js` |

You can override the source per environment in `config/initializers/funicular.rb`:

```ruby
Funicular.configure do |config|
  # Use jsDelivr CDN in production instead of self-hosting:
  config.production_source = :cdn

  # The CDN version defaults to the @picoruby/wasm-wasi version vendored in
  # the gem. Override only if you need a specific version:
  # config.cdn_version = "4.0.0"
end
```

Available sources:

| Value | Description |
|---|---|
| `:local_debug` | `public/picoruby/debug/init.iife.js` |
| `:local_dist` | `public/picoruby/dist/init.iife.js` |
| `:cdn` | `https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@<version>/dist/init.iife.js` |

You can also override the source for a single tag:

```erb
<%= picoruby_include_tag source: :cdn %>
```

### 4. (Optional) Add debug assets to your layout

```erb
<% if Rails.env.development? %>
  <%= javascript_include_tag "funicular_debug", "data-turbo-track": "reload" %>
  <%= stylesheet_link_tag "funicular_debug", "data-turbo-track": "reload" %>
<% end %>
```

See [Component Debug Highlighter](#component-debug-highlighter) for details.

## Usage

### Directory Structure

Place your Funicular application files in the following structure:

```
app/funicular/
  models/              # UI models
    user.rb
    session.rb
  components/          # UI components
    login_component.rb
    chat_component.rb
  initializer.rb       # Application initialization (optional)
```

The `initializer.rb` file (or any file ending with `_initializer.rb`) is loaded last, after all models and components. Use it for application setup code like routing configuration.

### Compilation

#### Development Mode

In development mode, Funicular automatically recompiles your Ruby files when they change. The compiled bytecode includes debug symbols (-g option).

To manually compile:

```bash
bundle exec rake funicular:compile
```

Output:
- File: `app/assets/builds/app.mrb`
- Debug mode: enabled
- Size: ~19KB (with debug symbols)

The compiled file is placed in `app/assets/builds/` so that Rails asset pipeline (Propshaft) can process it and serve it from `public/assets/` with proper cache busting.

#### Production Mode

In production mode, compile without debug symbols for smaller file size:

```bash
RAILS_ENV=production bundle exec rake funicular:compile
```

Output:
- File: `app/assets/builds/app.mrb`
- Debug mode: disabled
- Size: ~16KB (optimized)

The compilation task is automatically run before `assets:precompile` in production deployments.

### Loading in Views

Include the compiled bytecode in your view using the `asset_path` helper. If you have an `initializer.rb` file, it will execute automatically when the mrb file loads:

```erb
<div id="app"></div>

<script type="application/x-mrb" src="<%= asset_path('app.mrb') %>"></script>
```

The `asset_path` helper ensures that:
- In development: The file is served from `app/assets/builds/` via Propshaft
- In production: The file is served from `public/assets/` with a digest hash for cache busting (e.g., `application-abc123.mrb`)

Example `app/funicular/initializer.rb`:

```ruby
puts "Funicular Chat App initializing..."

# Load all model schemas before starting the app
Funicular.load_schemas({ User => "user", Session => "session", Channel => "channel" }) do
  # Start the application after all schemas are loaded
  Funicular.start(container: 'app') do |router|
    router.get('/login', to: LoginComponent, as: 'login')
    router.get('/chat/:channel_id', to: ChatComponent, as: 'chat_channel')
    router.get('/settings', to: SettingsComponent, as: 'settings')
    router.delete('/logout', to: LogoutComponent, as: 'logout')
    router.set_default('/login')
  end
end
```

### File Concatenation Order

Funicular concatenates files in the following order:

1. `app/funicular/models/**/*.rb` (alphabetically)
2. `app/funicular/components/**/*.rb` (alphabetically)
3. `app/funicular/initializer.rb` and `app/funicular/*_initializer.rb`

This ensures that:
- Model classes are defined before components that depend on them
- Components are defined before initialization code that uses them

### Routing

Funicular provides Rails-style routing with automatic URL helper generation and RESTful HTTP method support.

#### Defining Routes

Use Rails-style DSL in your `initializer.rb`:

```ruby
Funicular.start(container: 'app') do |router|
  # GET routes with URL helpers
  router.get('/login', to: LoginComponent, as: 'login')
  router.get('/users/:id', to: UserComponent, as: 'user')
  router.get('/users/:id/edit', to: EditUserComponent, as: 'edit_user')

  # RESTful routes
  router.post('/users', to: CreateUserComponent, as: 'users')
  router.patch('/users/:id', to: UpdateUserComponent, as: 'update_user')
  router.delete('/users/:id', to: DeleteUserComponent, as: 'delete_user')

  # Set default route
  router.set_default('/login')
end
```

The `as` option automatically generates URL helper methods (e.g., `login_path`, `user_path`).

#### Using URL Helpers

URL helpers are automatically available in all components:

```ruby
class UserListComponent < Funicular::Component
  def render
    div do
      # Static path
      link_to login_path do
        span { "Login" }
      end

      # Path with parameter from state/props
      state.users.each do |user|
        link_to user_path(user.id) do
          span { user.name }
        end
      end

      # Or pass model object with id method
      link_to edit_user_path(state.current_user) do
        span { "Edit Profile" }
      end
    end
  end
end
```

#### Using link_to Helper

The `link_to` helper creates navigation links with automatic routing:

```ruby
# GET navigation (uses History API)
link_to settings_path, class: "button" do
  span { "Settings" }
end

# Path with dynamic data
link_to chat_channel_path(props[:channel]) do
  div(class: "channel-name") { "# #{props[:channel].name}" }
  div(class: "channel-desc") { props[:channel].description }
end

# RESTful actions (uses Fetch API)
link_to user_path(state.user), method: :delete, class: "danger" do
  span { "Delete Account" }
end

# Supported HTTP methods: :get, :post, :put, :patch, :delete
```

#### CSRF Protection

Non-GET requests automatically include CSRF tokens from Rails meta tags:

```erb
<!-- In your Rails layout -->
<head>
  <%= csrf_meta_tags %>
</head>
```

Funicular automatically reads the CSRF token and includes it in `X-CSRF-Token` header for POST, PUT, PATCH, and DELETE requests.

#### Viewing Routes

Display all defined routes with the Rake task:

```bash
rake funicular:routes
```

Output example:

```
Method   Path                Component         Helper
----------------------------------------------------------
GET      /login              LoginComponent    login_path
GET      /chat/:channel_id   ChatComponent     chat_channel_path
GET      /settings           SettingsComponent settings_path
DELETE   /logout             LogoutComponent   logout_path

Total: 4 routes
```

#### Backward Compatibility

The old `add_route` method is still supported:

```ruby
# Old style (still works)
router.add_route('/login', LoginComponent)

# With URL helper
router.add_route('/login', LoginComponent, as: 'login')
```

## Rails Asset Pipeline Integration

Funicular integrates with Rails' asset pipeline (Propshaft) following Rails best practices:

### Directory Structure

```
app/
  funicular/                    # Source files (version controlled)
    models/
    components/
    initializer.rb
  assets/
    builds/                     # Compiled output (gitignored)
      app.mrb                   # Generated by funicular:compile
      .keep                     # Keep directory in git
```

### Development vs Production

**Development:**
- Files in `app/assets/builds/` are served directly by Propshaft
- Middleware automatically recompiles when source files change
- Debug symbols included for better error messages

**Production:**
- `rake assets:precompile` runs `funicular:compile` first
- Propshaft copies files to `public/assets/` with digest hashes
- Example: `app.mrb` -> `app-abc123def456.mrb`
- Debug symbols excluded for smaller file size

### Cache Busting

Using `asset_path('app.mrb')` in views ensures:
- Correct path resolution in all environments
- Automatic cache busting when files change
- Standard Rails asset handling

## Development Tools

### Component Debug Highlighter

Funicular provides a debug tool that visually highlights components with `data-component` attributes in development mode.

`funicular:install` (or `funicular:install:debug_assets`) copies the
required files and adds them to your layout as shown in [Installation](#installation).

#### Features

In development mode, components automatically get `data-component` attributes with their class name. The debug tool:

- Highlights components with a green/yellow/pink/cyan outline
  ```ruby
  # in app/funicular/initializer.rb
  Funicular.debug_color = "pink"  # Options: "green", "yellow", "pink", "cyan", or nil to disable
  ```
- Shows a triangle indicator in the bottom-right corner
- Displays component name and id value (if exists) on hover
- Does not distort layout (uses `outline` instead of `border`)

This helps developers quickly identify which component class renders each part of the UI.

