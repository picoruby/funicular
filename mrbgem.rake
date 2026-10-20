MRuby::Gem::Specification.new('picoruby-funicular') do |spec|
  spec.license = 'MIT'
  spec.author  = 'HASUMI Hitoshi'
  spec.summary = 'Browser application framework with VDOM for PicoRuby.wasm'

  # picoruby-aot compiles the typed defs, and the widened ones too (the
  # VDOM path takes Hash[Symbol, untyped] props): on a build with conf.aot
  spec.aot = true
  spec.aot_include_widened = true

  unless ENV['TEST_TASK']
    spec.add_dependency 'picoruby-wasm'
  end
  spec.add_dependency 'picoruby-indexeddb'
  spec.add_dependency 'picoruby-sqlite3'
  spec.add_dependency 'picoruby-json'
  spec.add_dependency 'picoruby-uri'
  spec.add_dependency 'mruby-object-ext', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-object-ext"
  spec.add_dependency 'mruby-hash-ext', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-hash-ext"
  spec.add_dependency 'mruby-array-ext', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-array-ext"
  spec.add_dependency 'mruby-string-ext', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-string-ext"
  spec.add_dependency 'mruby-metaprog', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-metaprog"
  # VDOM::Patch is a Data: each member is a C method, which the AOT
  # compiler and the type inference read as a typed slot
  spec.add_dependency 'mruby-data', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-data"
end
