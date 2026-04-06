# frozen_string_literal: true

require_relative "lib/funicular/version"

Gem::Specification.new do |spec|
  spec.name = "funicular"
  spec.version = Funicular::VERSION
  spec.authors = ["HASUMI Hitoshi"]
  spec.email = ["hasumikin@gmail.com"]

  spec.summary = "Rails plugin for client-side Ruby development with mruby"
  spec.description = "Funicular enables you to write client-side UI components in Ruby, powered by PicoRuby.wasm"
  spec.homepage = "https://github.com/picoruby/funicular"
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
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "rails", "~> 8.0"

  # Post-install message
  spec.post_install_message = <<~MSG

    Thank you for installing Funicular!

    IMPORTANT: Funicular requires picorbc compiler (version #{Funicular::PICORBC_VERSION})

    Please add it to your project dependencies:
      npm install --save-dev @picoruby/picorbc@#{Funicular::PICORBC_VERSION}

    For more information: https://www.npmjs.com/package/@picoruby/picorbc

  MSG

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
