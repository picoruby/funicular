# The unified REST callback contract (0.5.0, breaking vs <= 0.4):
# every callback is (result, error). On success `result` is the payload
# (all -> array, find/create -> instance, update -> the applied instance,
# destroy -> true) and `error` is nil; on failure `result` is nil.
#
# Funicular::HTTP is stubbed at the module level below. Each Picotest file
# runs in its own VM process, so the override cannot leak into other tests.
module Funicular
  module HTTP
    class << self
      def get(url, &block)
        $http_calls << ["GET", url, nil]
        block.call($http_response) if block
      end

      def post(url, body = nil, &block)
        $http_calls << ["POST", url, body]
        block.call($http_response) if block
      end

      def patch(url, body = nil, &block)
        $http_calls << ["PATCH", url, body]
        block.call($http_response) if block
      end

      def delete(url, &block)
        $http_calls << ["DELETE", url, nil]
        block.call($http_response) if block
      end
    end
  end
end

class ModelCallbackTest < Picotest::Test
  SCHEMA = {
    "attributes" => {
      "id" => { "readonly" => true, "type" => "integer" },
      "title" => { "type" => "string", "validations" => { "presence" => true } },
      "done" => { "type" => "boolean" },
    },
    "endpoints" => {
      "all" => { "path" => "/posts" },
      "find" => { "path" => "/posts/:id" },
      "create" => { "path" => "/posts" },
      "update" => { "path" => "/posts/:id" },
      "destroy" => { "path" => "/posts/:id" },
    },
  }

  def setup
    unless Object.const_defined?(:CallbackPost)
      Object.const_set(:CallbackPost, Class.new(Funicular::Model))
      CallbackPost.load_schema(SCHEMA)
    end
    $http_calls = []
    $http_response = nil
  end

  def ok_response(data)
    Funicular::HTTP::Response.new(200, data)
  end

  def error_response(message)
    Funicular::HTTP::Response.new(500, { "error" => message })
  end

  # ---- initialize ----

  def test_initialize_keeps_string_keyed_false
    post = CallbackPost.new({ "title" => "t", "done" => false })
    assert_equal(false, post.done)
  end

  def test_initialize_symbol_keys_still_work
    post = CallbackPost.new({ title: "sym", done: false })
    assert_equal("sym", post.title)
    assert_equal(false, post.done)
  end

  # ---- all ----

  def test_all_success_yields_instances_and_nil_error
    $http_response = ok_response([{ "id" => 1, "title" => "a", "done" => false }])
    result = nil
    error = :untouched
    CallbackPost.all do |r, e|
      result = r
      error = e
    end
    assert_equal(1, result.size)
    assert_equal("a", result[0].title)
    assert_equal(false, result[0].done)
    assert_nil(error)
  end

  def test_all_forwards_params_as_query_string
    $http_response = ok_response([])
    CallbackPost.all(page: 2, q: "hello world") { |r, e| }
    assert_equal([["GET", "/posts?page=2&q=hello+world", nil]], $http_calls)
  end

  def test_all_without_params_has_no_query_string
    $http_response = ok_response([])
    CallbackPost.all { |r, e| }
    assert_equal([["GET", "/posts", nil]], $http_calls)
  end

  def test_all_failure_yields_nil_result
    $http_response = error_response("boom")
    result = :untouched
    error = nil
    CallbackPost.all do |r, e|
      result = r
      error = e
    end
    assert_nil(result)
    assert_equal("boom", error)
  end

  # ---- find ----

  def test_find_success_yields_instance
    $http_response = ok_response({ "id" => 7, "title" => "found" })
    result = nil
    CallbackPost.find(7) { |r, e| result = r }
    assert_equal(7, result.id)
    assert_equal([["GET", "/posts/7", nil]], $http_calls)
  end

  # ---- create ----

  def test_create_success_yields_instance
    $http_response = ok_response({ "id" => 2, "title" => "made" })
    result = nil
    error = :untouched
    CallbackPost.create({ "title" => "made" }) do |r, e|
      result = r
      error = e
    end
    assert_equal(2, result.id)
    assert_nil(error)
  end

  def test_create_validation_failure_yields_nil_result_and_no_request
    result = :untouched
    error = nil
    CallbackPost.create({ "title" => "" }) do |r, e|
      result = r
      error = e
    end
    assert_nil(result)
    assert_not_nil(error)
    assert_equal([], $http_calls)
  end

  # ---- destroy ----

  def test_class_destroy_success_yields_true_and_nil_error
    $http_response = ok_response(nil)
    result = nil
    error = :untouched
    CallbackPost.destroy(3) do |r, e|
      result = r
      error = e
    end
    assert_equal(true, result)
    assert_nil(error)
    assert_equal([["DELETE", "/posts/3", nil]], $http_calls)
  end

  def test_class_destroy_failure_yields_nil_result
    $http_response = error_response("nope")
    result = :untouched
    error = nil
    CallbackPost.destroy(3) do |r, e|
      result = r
      error = e
    end
    assert_nil(result)
    assert_equal("nope", error)
  end

  # ---- update ----

  def test_update_success_yields_applied_instance
    post = CallbackPost.new({ "id" => 1, "title" => "before" })
    $http_response = ok_response({ "id" => 1, "title" => "after (server)" })
    result = nil
    error = :untouched
    post.update({ "title" => "after" }) do |r, e|
      result = r
      error = e
    end
    # The yielded result IS the receiver, with the server's authoritative
    # row already applied.
    assert_equal(post.__id__, result.__id__)
    assert_equal("after (server)", post.title)
    assert_nil(error)
    assert_equal([["PATCH", "/posts/1", { "title" => "after" }]], $http_calls)
  end

  def test_update_with_no_changes_is_a_successful_no_op
    post = CallbackPost.new({ "id" => 1, "title" => "same" })
    result = nil
    error = :untouched
    post.update do |r, e|
      result = r
      error = e
    end
    assert_equal(post.__id__, result.__id__)
    assert_nil(error)
    assert_equal([], $http_calls)
  end

  def test_update_validation_failure_yields_nil_result
    post = CallbackPost.new({ "id" => 1, "title" => "ok" })
    result = :untouched
    error = nil
    post.update({ "title" => "" }) do |r, e|
      result = r
      error = e
    end
    assert_nil(result)
    assert_not_nil(error)
    assert_equal([], $http_calls)
  end

  def test_update_http_failure_yields_nil_result
    post = CallbackPost.new({ "id" => 1, "title" => "ok" })
    $http_response = error_response("denied")
    result = :untouched
    error = nil
    post.update({ "title" => "changed" }) do |r, e|
      result = r
      error = e
    end
    assert_nil(result)
    assert_equal("denied", error)
  end
end
