# Funicular

> 🎵Funicu-lì, Funicu-là!🚊🚊🚊
>
> 🎵Funicu-lì, Funicu-là!🚞🚞🚞

**Funicular** is a single-page application (SPA) framework powered by PicoRuby.wasm.

## Features

- Write client-side code in Ruby instead of JavaScript
- Seamless Rails integration

## Combined Gem

This repository consists of three relevant projects:

- PicoGem "picoruby-funicular" ... Core implementation
- CRubyGem "funicular" ... Rails integration
- Chrome extension "PicoRuby Debugger"

### PicoGem "picoruby-funicular"

```console
.
├── mrbgem.rake
├── mrblib/
└── test/
```

### CRubyGem "funicular"

```console
.
├── bin/
├── exe/
├── funicular.gemspec
├── Gemfile
├── Gemfile.lock
├── lib/
├── minitest/
└── Rakefile
```

### Chrome extention "PicoRuby.wasm debugger"

```console
.
└── debugger/
```

----

The others are common resources.

## Documentation

User documentation is hosted on **picoruby.org**:

- [Getting Started with Funicular](https://picoruby.org/funicular) — a standalone, no-Rails tutorial
- [Funicular on Rails](https://picoruby.org/funicular-on-rails-quick-chat) — quick tutorial, installation, the asset pipeline, and a feature-by-feature tutorial plus reference (components, routing, forms and validation, data fetching, stores, SSR, styling, debugging)

For contributors working on the gem itself, see [docs/architecture.md](docs/architecture.md).

## Development

This repository is a submodule of [picoruby/picoruby](https://github.com/picoruby/picoruby).
Do not check it out as a standalone. Instead, clone the parent repository and work from there:

```console
git clone --recurse-submodules https://github.com/picoruby/picoruby.git
cd picoruby/mrbgems/picoruby-funicular
```

The CRubyGem side (`lib/`, `funicular.gemspec`, etc.) can be developed and tested independently inside that directory, but `rake copy_wasm` — which vendors the PicoRuby.wasm and mrbc wasm artifacts into the gem — relies on sibling directories within the picoruby repository (`mrbgems/picoruby-wasm/npm/`).
Running it from a standalone checkout will fail.

## Testing

- CRubygem (Rails integration) test: `rake test` in this repository
- PicoGem Funicular test: `rake test:gems:wasm[picoruby-funicular]` in picoruby where mrbgems/picoruby-funicular exists as a submodule

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/picoruby/funicular.

## License

Copyright © 2025- HASUMI Hitoshi. See MIT-LICENSE for further details.
