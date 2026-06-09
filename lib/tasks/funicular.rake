# frozen_string_literal: true

namespace :funicular do
  desc "Compile Funicular Ruby files to .mrb format"
  task compile: :environment do
    require "funicular/compiler"
    require "funicular/plugin"

    source_dir = Rails.root.join("app", "funicular")
    output_file = Rails.root.join("app", "assets", "builds", "app.mrb")
    debug_mode = !Rails.env.production?

    unless Dir.exist?(source_dir)
      puts "Skipping Funicular compilation: #{source_dir} does not exist"
      next
    end

    begin
      plugin_registry = Funicular::Plugin::Registry.new(Rails.root)
      plugin_registry.validate!
      plugin_registry.sync_assets
      compiler = Funicular::Compiler.new(
        source_dir: source_dir,
        output_file: output_file,
        debug_mode: debug_mode,
        prepend_source_files: plugin_registry.local_source_files
      )
      compiler.compile
    rescue Funicular::Plugin::Error => e
      puts "ERROR: #{e.message}"
      exit 1
    rescue Funicular::Compiler::PicorbcMissingError => e
      puts "ERROR: #{e.message}"
      exit 1
    rescue => e
      puts "ERROR: Failed to compile Funicular application"
      puts e.message
      puts e.backtrace.join("\n")
      exit 1
    end
  end

  desc "Show all Funicular routes"
  task routes: :environment do
    require "funicular/commands/routes"

    begin
      Funicular::Commands::Routes.new.execute
    rescue => e
      puts "ERROR: Failed to display routes"
      puts e.message
      puts e.backtrace.join("\n")
      exit 1
    end
  end

  desc "Install Funicular debug assets, PicoRuby.wasm artifacts, and test support into a Rails app"
  task install: ["install:debug_assets", "install:wasm", "install:test"] do
    puts ""
    puts "All Funicular assets installed."
    puts ""
    puts "Next steps:"
    puts "  1. In your layout, replace any hardcoded PicoRuby <script> tag with:"
    puts '       <%= picoruby_include_tag %>'
    puts ""
    puts "  2. (Optional) Edit config/initializers/funicular.rb to choose the source"
    puts "     for each environment (:local_debug, :local_dist, :cdn)."
    puts ""
    puts "  3. (Optional, development only) Add to your layout to enable"
    puts "     the component highlighter:"
    puts '       <% if Rails.env.development? %>'
    puts '         <%= javascript_include_tag "funicular_debug", "data-turbo-track": "reload" %>'
    puts '         <%= stylesheet_link_tag "funicular_debug", "data-turbo-track": "reload" %>'
    puts '       <% end %>'
    puts ""
    puts "  4. Run `npm install` if package.json was created or updated."
    puts "     Client-side Funicular tests live under test/funicular/client/**/*_picotest.rb"
    puts "     and run through `bin/rails test`."
  end

  namespace :install do
    desc "Install Funicular debug JS/CSS assets and the gem initializer"
    task :debug_assets do
      require "fileutils"

      javascripts_dir  = Rails.root.join("app", "assets", "javascripts")
      stylesheets_dir  = Rails.root.join("app", "assets", "stylesheets")
      initializers_dir = Rails.root.join("config", "initializers")

      FileUtils.mkdir_p(javascripts_dir)
      FileUtils.mkdir_p(stylesheets_dir)
      FileUtils.mkdir_p(initializers_dir)

      source_js          = File.expand_path("../funicular/assets/funicular_debug.js", __dir__)
      source_css         = File.expand_path("../funicular/assets/funicular_debug.css", __dir__)
      source_initializer = File.expand_path("../funicular/assets/funicular.rb", __dir__)

      dest_js          = javascripts_dir.join("funicular_debug.js")
      dest_css         = stylesheets_dir.join("funicular_debug.css")
      dest_initializer = initializers_dir.join("funicular.rb")

      FileUtils.cp(source_js,          dest_js)
      FileUtils.cp(source_css,         dest_css)
      FileUtils.cp(source_initializer, dest_initializer)

      puts "Installed Funicular debug assets:"
      puts "  - #{dest_js}"
      puts "  - #{dest_css}"
      puts "  - #{dest_initializer}"
    end

    desc "Install vendored PicoRuby.wasm artifacts (dist + debug) into public/picoruby/"
    task :wasm do
      require "fileutils"

      vendor_root = File.expand_path("../funicular/vendor/picoruby", __dir__)
      unless Dir.exist?(vendor_root)
        abort "Vendored PicoRuby artifacts not found at #{vendor_root}. " \
              "Reinstall the funicular gem or run `rake funicular:vendor` from a checkout."
      end

      dest_root = Rails.root.join("public", "picoruby")
      FileUtils.mkdir_p(dest_root)

      %w[dist debug].each do |variant|
        src = File.join(vendor_root, variant)
        dst = dest_root.join(variant)

        unless Dir.exist?(src)
          warn "Skipping #{variant}: #{src} not found"
          next
        end

        FileUtils.rm_rf(dst)
        FileUtils.mkdir_p(dst)
        FileUtils.cp_r(File.join(src, "."), dst)

        puts "Installed PicoRuby #{variant} build to #{dst}"
      end
    end


    desc "Install Funicular client test support"
    task :test do
      require "fileutils"
      require "json"

      test_dir = Rails.root.join("test")
      funicular_test_dir = test_dir.join("funicular")
      client_test_dir = funicular_test_dir.join("client")
      FileUtils.mkdir_p(client_test_dir)

      test_helper = test_dir.join("test_helper.rb")
      unless File.exist?(test_helper)
        File.write(test_helper, <<~TEST_HELPER)
          ENV["RAILS_ENV"] ||= "test"

          require_relative "../config/environment"
          require "rails/test_help"
        TEST_HELPER
        puts "Installed #{test_helper}"
      end

      application_test = funicular_test_dir.join("application_test.rb")
      unless File.exist?(application_test)
        File.write(application_test, <<~APPLICATION_TEST)
          require_relative "../test_helper"
          require "funicular/testing"

          class FunicularApplicationTest < ActiveSupport::TestCase
            test "client-side Funicular tests" do
              result = Funicular::Testing.run!(timeout_ms: 10_000)
              Funicular::Testing.assert_picotests(self, result)
            end
          end
        APPLICATION_TEST
        puts "Installed #{application_test}"
      end

      keep_file = client_test_dir.join(".keep")
      FileUtils.touch(keep_file) unless File.exist?(keep_file)

      package_json = Rails.root.join("package.json")
      package = if File.exist?(package_json)
                  JSON.parse(File.read(package_json))
                else
                  { "private" => true }
                end
      package["devDependencies"] ||= {}
      package["devDependencies"]["jsdom"] ||= "^26.1.0"
      File.write(package_json, JSON.pretty_generate(package) + "\n")
      puts "Updated #{package_json}"

      gitignore = Rails.root.join(".gitignore")
      if File.exist?(gitignore)
        content = File.read(gitignore)
        unless content.lines.any? { |line| line.chomp == "/node_modules" }
          File.open(gitignore, "a") do |f|
            f.puts
            f.puts "# Ignore Node dependencies."
            f.puts "/node_modules"
          end
          puts "Updated #{gitignore}"
        end
      end

      puts "Installed Funicular test support:"
      puts "  - #{application_test}"
      puts "  - #{client_test_dir}"
      puts "  - jsdom dev dependency in #{package_json}"
    end
  end
end

# Hook into assets:precompile for production deployment
if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance(["funicular:compile"])
end
