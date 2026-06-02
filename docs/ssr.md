# Server-Side Rendering (SSR) and Hydration

Funicular can render your components to HTML on the Rails server and then hydrate that markup in the browser. The same component classes run on both sides: on the server under CRuby, and in the browser under PicoRuby.wasm.

This gives you a fast first paint and SEO-friendly, data-filled HTML for public pages, while keeping the full single-page application experience after the page loads.

## How it works

1. The Funicular runtime (the `mrblib/` framework code) is loaded into your Rails process. It is plain Ruby; the few methods that touch the browser (DOM patching, `fetch`, History API, IndexedDB) are never called on the server because `Funicular.server?` is true there.
2. `Funicular::SSR.render` resolves the request path to a component using the routes you defined in `app/funicular/initializer.rb`, builds its VDOM, and serializes it to an HTML string with `Funicular::VDOM::HTMLSerializer`.
3. The server injects data into the component's state and also embeds the same state as `window.__FUNICULAR_STATE__`.
4. In the browser, `Funicular.start` detects the embedded state and hydrates the server HTML: it rebuilds the VDOM from the same state, attaches event listeners and refs to the existing DOM nodes, and then behaves like a normal SPA. No DOM is rebuilt.

Event handlers (`onclick`, `oninput`, ...) are not serialized; they are Procs that are re-bound during hydration.

## Writing an isomorphic component

A component that supports SSR should render from its `state`, and only fetch data on mount when that state is missing:

```ruby
class ChannelIndexComponent < Funicular::Component
  def initialize_state
    { channels: [] }
  end

  def component_mounted
    # Client-only fallback: if the server did not inject channels, fetch them.
    Channel.all { |channels, _| patch(channels: channels.map(&:as_json)) } if state.channels.empty?
  end

  def render
    div do
      state.channels.each do |ch|
        link_to "/chat/#{ch["id"]}", navigate: true, key: ch["id"] do
          div { "# #{ch["name"]}" }
        end
      end
    end
  end
end
```

The top routed component owns the data in its state and passes it to children as `props`. Nested components are rendered in the same server pass, so they do not need their own serialized state.

## Server side (Rails)

In a controller, call `Funicular::SSR.render` and pass the data you want to inject as `state`:

```ruby
class HomeController < ApplicationController
  def index
    if request.path == "/explore"
      @ssr = Funicular::SSR.render(
        path: "/explore",
        state: { channels: explore_channels }
      )
    end
  end

  private

  def explore_channels
    Channel.order(:name).map do |c|
      { "id" => c.id, "name" => c.name, "description" => c.description }
    end
  end
end
```

In the view, place the rendered HTML inside the `#app` container and embed the state. When `@ssr` is absent, the container is empty and the client renders from scratch (plain CSR):

```erb
<%= funicular_app_container(@ssr ? @ssr[:html] : "") %>
<% if @ssr %>
  <%= funicular_state_tag(@ssr[:state]) %>
<% end %>

<script type="application/x-mrb" src="<%= asset_path('app.mrb') %>"></script>
```

`Funicular::SSR.render` returns `{ html:, state:, component: }`. When no route matches the path, `html` is `""` so the page falls back to client-side rendering.

## Client side

No extra code is needed. `Funicular.start` automatically hydrates when `window.__FUNICULAR_STATE__` is present; otherwise it mounts normally. If the server and client markup disagree (for example, a nondeterministic render), a warning is logged and Funicular falls back to a full client render.

For determinism, avoid `Time.now`, randomness, or any value that differs between server and client inside `render`.

## Current limitations (v1)

- A single state payload is serialized, for the top routed component. Child components derive their data from props or fetch it on mount.
- Server-side data is injected as plain hashes; the `Model` layer is not used to fetch data on the server.
- Suspense renders its resolved/empty branch on the server (no timers).
