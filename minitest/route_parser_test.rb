# frozen_string_literal: true

require "tempfile"

require "test_helper"
require "funicular/route_parser"

# Exercises Funicular::RouteParser, the line-based scanner that extracts route
# definitions from an app's app/funicular/initializer.rb (used by the
# `funicular:routes` command). It is deliberately regex-free string slicing, so
# the tests cover the quoting, `to:`/`as:` and legacy `add_route` shapes.
class RouteParserTest < Minitest::Test
  def parse(source)
    Tempfile.create(["initializer", ".rb"]) do |f|
      f.write(source)
      f.flush
      Funicular::RouteParser.new(f.path).parse
    end
  end

  def test_missing_file_returns_empty
    assert_equal [], Funicular::RouteParser.new("/no/such/file.rb").parse
  end

  def test_parses_get_with_to_and_as
    routes = parse(<<~RUBY)
      router.get("/channels", to: ChannelsComponent, as: "channels")
    RUBY

    assert_equal 1, routes.size
    assert_equal(
      { method: "GET", path: "/channels", component: "ChannelsComponent", helper: "channels_path" },
      routes.first
    )
  end

  def test_upcases_each_http_method
    routes = parse(<<~RUBY)
      router.get("/a", to: A)
      router.post("/b", to: B)
      router.put("/c", to: C)
      router.patch("/d", to: D)
      router.delete("/e", to: E)
    RUBY

    assert_equal %w[GET POST PUT PATCH DELETE], routes.map { |r| r[:method] }
  end

  def test_legacy_add_route_uses_second_argument_and_get_method
    routes = parse(<<~RUBY)
      router.add_route('/legacy', LegacyComponent)
    RUBY

    assert_equal(
      { method: "GET", path: "/legacy", component: "LegacyComponent", helper: nil },
      routes.first
    )
  end

  def test_helper_is_nil_without_as_option
    routes = parse(<<~RUBY)
      router.get("/plain", to: PlainComponent)
    RUBY

    assert_nil routes.first[:helper]
  end

  def test_single_and_double_quotes_are_both_accepted
    routes = parse(<<~RUBY)
      router.get('/single', to: Single)
      router.get("/double", to: Double)
    RUBY

    assert_equal ["/single", "/double"], routes.map { |r| r[:path] }
  end

  def test_comments_and_blank_lines_are_skipped
    routes = parse(<<~RUBY)
      # router.get("/commented", to: Commented)

        # indented comment
      router.get("/real", to: Real)
    RUBY

    assert_equal ["/real"], routes.map { |r| r[:path] }
  end

  def test_non_router_lines_are_ignored
    routes = parse(<<~RUBY)
      Funicular.configure do |config|
        config.something = true
      end
      router.get("/only", to: Only)
    RUBY

    assert_equal 1, routes.size
    assert_equal "/only", routes.first[:path]
  end

  def test_line_without_path_is_skipped
    routes = parse(<<~RUBY)
      router.get(to: NoPath)
    RUBY

    assert_equal [], routes
  end

  def test_line_without_component_is_skipped
    routes = parse(<<~RUBY)
      router.get("/orphan")
    RUBY

    assert_equal [], routes
  end

  def test_component_before_trailing_options_is_isolated
    routes = parse(<<~RUBY)
      router.get("/x", to: XComponent, as: "x", extra: :ignored)
    RUBY

    assert_equal "XComponent", routes.first[:component]
    assert_equal "x_path", routes.first[:helper]
  end

  def test_component_at_end_of_line_without_trailing_delimiter
    routes = parse("router.get \"/y\", to: YComponent")

    assert_equal "YComponent", routes.first[:component]
  end

  def test_as_option_without_a_quoted_value_yields_nil_helper
    routes = parse(<<~RUBY)
      router.get("/z", to: ZComponent, as: some_variable)
    RUBY

    assert_equal "ZComponent", routes.first[:component]
    assert_nil routes.first[:helper]
  end
end
