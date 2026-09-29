# Tests for the endpoint lookup and path expansion of the REST side:
# nested routes fill their :segments from params/attributes, the one
# segment left takes the record id whatever the route calls it, a
# missing endpoint or segment fails loud, and endpoint_name: reaches
# collection/member routes beyond the canonical five.

module Funicular
  module HTTP
    class << self
      def get(url, headers: nil, &block)
        $ep_calls << ["GET", url]
        block.call($ep_response) if block
      end

      def post(url, body = nil, &block)
        $ep_calls << ["POST", url, body]
        block.call($ep_response) if block
      end

      def patch(url, body = nil, &block)
        $ep_calls << ["PATCH", url, body]
        block.call($ep_response) if block
      end

      def delete(url, &block)
        $ep_calls << ["DELETE", url]
        block.call($ep_response) if block
      end
    end
  end
end

class RestEndpointTest < Picotest::Test
  COMMENT_SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "post_id" => { "type" => "integer" },
      "body" => { "type" => "string" },
    },
    "endpoints" => {
      "all" => { "method" => "GET", "path" => "/posts/:post_id/comments" },
      "find" => { "method" => "GET", "path" => "/posts/:post_id/comments/:id" },
      "create" => { "method" => "POST", "path" => "/posts/:post_id/comments" },
      "update" => { "method" => "PATCH", "path" => "/posts/:post_id/comments/:id" },
      "destroy" => { "method" => "DELETE", "path" => "/posts/:post_id/comments/:id" },
      "recent" => { "method" => "GET", "path" => "/comments/recent" },
    },
  }

  PAGE_SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "slug" => { "type" => "string" },
      "title" => { "type" => "string" },
    },
    "endpoints" => {
      "find" => { "method" => "GET", "path" => "/pages/:slug" },
      "update" => { "method" => "PATCH", "path" => "/pages/:slug" },
      "publish" => { "method" => "POST", "path" => "/pages/:slug/publish" },
    },
  }

  def setup
    unless Object.const_defined?(:EpComment)
      Object.const_set(:EpComment, Class.new(Funicular::Model))
      EpComment.class_eval { storage :ephemeral }
      EpComment.load_schema(COMMENT_SCHEMA)
      Object.const_set(:EpPage, Class.new(Funicular::Model))
      EpPage.class_eval { storage :ephemeral }
      EpPage.load_schema(PAGE_SCHEMA)
    end
    $ep_calls = []
    $ep_response = Funicular::HTTP::Response.new(200, { "id" => 1 })
  end

  # ---- nested paths ----

  def test_all_fills_the_path_and_queries_the_rest
    $ep_response = Funicular::HTTP::Response.new(200, [])
    EpComment.all(post_id: 3, page: 2) { |r, e| }
    assert_equal(["GET", "/posts/3/comments?page=2"], $ep_calls[0])
    EpComment.all("post_id" => 4) { |r, e| }
    assert_equal(["GET", "/posts/4/comments"], $ep_calls[1])
  end

  def test_find_takes_path_params_and_the_id
    EpComment.find(7, post_id: 3) { |r, e| }
    assert_equal(["GET", "/posts/3/comments/7"], $ep_calls[0])
  end

  def test_create_fills_the_path_from_attrs_and_sends_them_all
    EpComment.create(post_id: 3, body: "hi") { |r, e| }
    assert_equal("POST", $ep_calls[0][0])
    assert_equal("/posts/3/comments", $ep_calls[0][1])
    assert_equal({ post_id: 3, body: "hi" }, $ep_calls[0][2])
  end

  def test_instance_methods_fill_the_path_from_attributes
    comment = EpComment.new({ "id" => 7, "post_id" => 3, "body" => "old" })
    comment.body = "new"
    # The server's row is applied on success; keep the identity intact.
    $ep_response = Funicular::HTTP::Response.new(200, { "id" => 7, "post_id" => 3, "body" => "new" })
    comment.update { |r, e| }
    assert_equal(["PATCH", "/posts/3/comments/7", { "body" => "new" }], $ep_calls[0])
    comment.destroy { |r, e| }
    assert_equal(["DELETE", "/posts/3/comments/7"], $ep_calls[1])
    $ep_response = Funicular::HTTP::Response.new(200, { "id" => 7, "post_id" => 3, "body" => "x" })
    comment.reload { |r, e| }
    assert_equal(["GET", "/posts/3/comments/7"], $ep_calls[2])
  end

  def test_class_destroy_takes_path_params
    EpComment.destroy(7, post_id: 3) { |r, e| }
    assert_equal(["DELETE", "/posts/3/comments/7"], $ep_calls[0])
  end

  # ---- the identifier fills whatever segment the route names ----

  def test_find_fills_a_slug_segment_with_the_id_argument
    EpPage.find("hello-world") { |r, e| }
    assert_equal(["GET", "/pages/hello-world"], $ep_calls[0])
  end

  def test_instance_update_fills_a_slug_from_the_attribute
    page = EpPage.new({ "id" => 1, "slug" => "hello-world", "title" => "t" })
    page.title = "u"
    page.update { |r, e| }
    assert_equal(["PATCH", "/pages/hello-world", { "title" => "u" }], $ep_calls[0])
  end

  def test_segment_values_are_encoded
    EpPage.find("a b/c?d") { |r, e| }
    assert_equal(["GET", "/pages/a%20b%2Fc%3Fd"], $ep_calls[0])
  end

  # ---- beyond the canonical five ----

  def test_endpoint_name_reaches_collection_and_member_routes
    $ep_response = Funicular::HTTP::Response.new(200, [])
    EpComment.all(endpoint_name: "recent") { |r, e| }
    assert_equal(["GET", "/comments/recent"], $ep_calls[0])
    $ep_response = Funicular::HTTP::Response.new(200, { "id" => 1 })
    EpPage.create({ slug: "hello-world" }, endpoint_name: "publish") { |r, e| }
    assert_equal("/pages/hello-world/publish", $ep_calls[1][1])
  end

  # ---- failing loud ----

  def raised_message
    yield
    nil
  rescue => e
    "#{e.class}: #{e.message}"
  end

  def test_missing_endpoint_raises_with_the_available_names
    message = raised_message { EpPage.all { |r, e| } }
    assert_equal(true, message.include?("Funicular::Model::EndpointError"))
    assert_equal(true, message.include?("EpPage has no 'all' endpoint"))
    assert_equal(true, message.include?("find, update, publish"))
    assert_equal(true, message.include?("ep_pages#index"))
  end

  def test_missing_segment_raises_instead_of_sending_a_literal
    message = raised_message { EpComment.all { |r, e| } }
    assert_equal(true, message.include?("ArgumentError: missing :post_id for EpComment.all"))
    assert_raise(ArgumentError) { EpComment.find(7) { |r, e| } }
    assert_raise(ArgumentError) { EpComment.create(body: "no post") { |r, e| } }
    assert_equal(0, $ep_calls.size)
  end
end
