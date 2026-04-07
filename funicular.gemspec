# frozen_string_literal: true

require_relative "lib/funicular/version"

Gem::Specification.new do |spec|
  spec.name = "funicular"
  spec.version = Funicular::VERSION
  spec.authors = ["HASUMI Hitoshi"]
  spec.email = ["hasumikin@gmail.com"]

  spec.summary = "Rails plugin for client-side Ruby development with mruby"
  spec.description = "Funicular enables you to write client-side UI components in Ruby, powered by PicoRuby.wasm"
  spec.homepage = "https://github.com/hasumikin/funicular"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end

  # Vendored PicoRuby.wasm and picorbc artifacts are populated by
  # `rake funicular:vendor` (which `rake build` depends on) and are
  # intentionally not tracked in git. Add them to the gem file list so
  # they ship with releases.
  vendor_root = File.join(__dir__, "lib", "funicular", "vendor")
  if Dir.exist?(vendor_root)
    vendored = Dir.glob(File.join(vendor_root, "**", "*")).reject { |f| File.directory?(f) }
    vendored.map! { |f| f.sub("#{__dir__}/", "") }
    spec.files = (spec.files + vendored).uniq.sort
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "rails", "~> 8.0"

  # Post-install message
  spec.post_install_message = <<~MSG

    Thank you for installing Funicular!

    Funicular bundles a WebAssembly build of picorbc, which compiles your
    Ruby code to .mrb at request time (development) and at asset:precompile
    time (production). Make sure Node.js is installed on machines that run
    the compilation.

    To install Funicular into a Rails app:
      bin/rails funicular:install

    For more information: https://github.com/hasumikin/funicular

  MSG

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
