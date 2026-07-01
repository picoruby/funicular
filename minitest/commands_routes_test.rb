# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "test_helper"
require_relative "support/rails_stub"
require "funicular/commands/routes"

# Exercises the `funicular:routes` CLI command: its guard clauses (not a Rails
# app / no initializer / no routes) and the aligned routes table it prints.
class CommandsRoutesTest < Minitest::Test
  def setup
    Rails.reset_stub!
  end

  def teardown
    Rails.reset_stub!
  end

  # Runs Routes#execute inside a throwaway app dir, capturing stdout and the
  # SystemExit status (nil when the command runs to completion).
  def run_in_app(files: {})
    Dir.mktmpdir do |dir|
      files.each do |rel, contents|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end
      Rails.root = Pathname(dir)

      status = nil
      out = +""
      Dir.chdir(dir) do
        out, = capture_io do
          begin
            Funicular::Commands::Routes.new.execute
          rescue SystemExit => e
            status = e.status
          end
        end
      end
      yield out, status
    end
  end

  def test_errors_when_not_in_a_rails_app
    run_in_app(files: {}) do |out, status|
      assert_equal 1, status
      assert_includes out, "Not in a Rails application"
    end
  end

  def test_reports_when_initializer_is_missing
    run_in_app(files: { "config/application.rb" => "# app\n" }) do |out, status|
      assert_equal 0, status
      assert_includes out, "No Funicular routes found"
    end
  end

  def test_reports_when_initializer_defines_no_routes
    run_in_app(files: {
      "config/application.rb" => "# app\n",
      "app/funicular/initializer.rb" => "# nothing here\n"
    }) do |out, status|
      assert_equal 0, status
      assert_includes out, "No routes defined"
    end
  end

  def test_prints_aligned_table_with_totals
    initializer = <<~RUBY
      router.get("/", to: HomeComponent, as: "home")
      router.get("/channels/:id", to: ChannelComponent)
    RUBY

    run_in_app(files: {
      "config/application.rb" => "# app\n",
      "app/funicular/initializer.rb" => initializer
    }) do |out, status|
      assert_nil status # ran to completion, no exit
      assert_includes out, "Method"
      assert_includes out, "Component"
      assert_includes out, "HomeComponent"
      assert_includes out, "home_path"
      assert_includes out, "/channels/:id"
      assert_includes out, "Total: 2 routes"
    end
  end

  def test_total_is_singular_for_one_route
    routes = [{ method: "GET", path: "/", component: "HomeComponent", helper: nil }]
    out, = capture_io { Funicular::Commands::Routes.new.send(:print_routes_table, routes) }
    assert_includes out, "Total: 1 route"
    refute_includes out, "1 routes"
  end
end
