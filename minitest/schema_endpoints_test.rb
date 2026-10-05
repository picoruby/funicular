# frozen_string_literal: true

require "test_helper"
require "active_model"
require "action_dispatch"
# resources with a nested block singularizes the parent's param name.
require "active_support/core_ext/string/inflections"

# Exercises Funicular::Schema::Endpoints: deriving a model's endpoint
# table from a Rails RouteSet by convention, and every escape hatch for
# routes that do not follow it.
class SchemaEndpointsTest < Minitest::Test
  # model_name derives from the class name; drop the test namespace.
  class Post
    def self.model_name = ActiveModel::Name.new(self, nil, "Post")
  end

  module Admin
    class Post
      def self.model_name = ActiveModel::Name.new(self, nil, "Admin::Post")
    end
  end

  ROUTES = ActionDispatch::Routing::RouteSet.new
  ROUTES.draw do
    resources :posts, only: [:index, :show] do
      resources :comments, only: [:index, :create]
    end
    resources :users, only: [:show, :update] do
      member { get :avatar }
      collection { get :online }
    end
    resources :pages, param: :slug, only: [:show, :update]
    resource :profile, only: [:show]
    post "login", to: "sessions#create"
    delete "logout", to: "sessions#destroy"
    get "current_user", to: "sessions#show"
    namespace :admin do
      resources :posts, only: [:index]
    end
    # A second route to comments#create: the nested one above wins.
    resources :comments, only: [:create]
    # Optional segments and globs: the client cannot send them as text.
    scope "(:locale)" do
      resources :articles, only: [:index, :show]
    end
    get "archive(/:year(/:month))", to: "archive#index"
    get "files/*path", to: "files#show"
  end

  def build(model_class, **options)
    Funicular::Schema.build(model_class, attributes: {}, routes: ROUTES, **options)[:endpoints]
  end

  def test_resources_derive_the_canonical_names
    assert_equal(
      {
        "all" => { method: "GET", path: "/posts" },
        "find" => { method: "GET", path: "/posts/:id" }
      },
      build(Post)
    )
  end

  def test_update_takes_patch_and_other_actions_keep_their_names
    endpoints = build(nil, controller: "users")
    assert_equal({ method: "PATCH", path: "/users/:id" }, endpoints["update"])
    assert_equal({ method: "GET", path: "/users/:id/avatar" }, endpoints["avatar"])
    assert_equal({ method: "GET", path: "/users/online" }, endpoints["online"])
    assert_equal(%w[online find update avatar].sort, endpoints.keys.sort)
  end

  def test_nested_resources_keep_their_parent_segment_and_the_first_route_wins
    endpoints = build(nil, controller: "comments")
    assert_equal({ method: "GET", path: "/posts/:post_id/comments" }, endpoints["all"])
    assert_equal({ method: "POST", path: "/posts/:post_id/comments" }, endpoints["create"])
  end

  def test_a_namespaced_model_names_its_namespaced_controller
    assert_equal({ "all" => { method: "GET", path: "/admin/posts" } }, build(Admin::Post))
  end

  def test_custom_param_and_singular_resources
    assert_equal({ method: "GET", path: "/pages/:slug" }, build(nil, controller: "pages")["find"])
    assert_equal({ "find" => { method: "GET", path: "/profile" } }, build(nil, controller: "profiles"))
  end

  def test_plain_routes_derive_too
    assert_equal(
      {
        "create" => { method: "POST", path: "/login" },
        "destroy" => { method: "DELETE", path: "/logout" },
        "find" => { method: "GET", path: "/current_user" }
      },
      build(nil, controller: "sessions")
    )
  end

  def test_explicit_endpoints_alias_override_and_hide
    endpoints = build(nil, controller: "sessions", endpoints: {
      "current" => "sessions#show",
      "create" => { method: "POST", path: "/sign_in" },
      "destroy" => nil
    })
    assert_equal({ method: "GET", path: "/current_user" }, endpoints["current"])
    assert_equal({ method: "POST", path: "/sign_in" }, endpoints["create"])
    assert_nil endpoints["destroy"]
    assert_equal({ method: "GET", path: "/current_user" }, endpoints["find"])
  end

  def test_a_reference_may_point_at_another_controller
    endpoints = build(Post, endpoints: { "comment" => "comments#create" })
    assert_equal({ method: "POST", path: "/posts/:post_id/comments" }, endpoints["comment"])
  end

  def test_routes_false_uses_explicit_endpoints_only
    endpoints = build(Post, routes: false, endpoints: { "all" => { method: "GET", path: "/x" } })
    assert_equal({ "all" => { method: "GET", path: "/x" } }, endpoints)
  end

  def test_no_routes_and_no_endpoints_is_an_error
    error = assert_raises(ArgumentError) { build(nil, controller: "nothing") }
    assert_includes error.message, "no route to nothing"
  end

  def test_explicit_empty_endpoints_mean_no_rest_side
    assert_equal({}, build(nil, controller: "nothing", endpoints: {}))
  end

  def test_optional_segments_derive_in_their_short_form
    endpoints = build(nil, controller: "articles")
    assert_equal({ method: "GET", path: "/articles" }, endpoints["all"])
    assert_equal({ method: "GET", path: "/articles/:id" }, endpoints["find"])
    assert_equal({ method: "GET", path: "/archive" }, build(nil, controller: "archive")["all"])
  end

  def test_a_glob_route_derives_no_endpoint
    assert_equal({}, build(nil, controller: "files", endpoints: {}))
    error = assert_raises(ArgumentError) { build(nil, controller: "files") }
    assert_includes error.message, "no route to files"
  end

  def test_a_dangling_reference_is_an_error
    error = assert_raises(ArgumentError) { build(Post, endpoints: { "x" => "posts#nope" }) }
    assert_includes error.message, "no such route"
    error = assert_raises(ArgumentError) { build(Post, endpoints: { "x" => "posts" }) }
    assert_includes error.message, "controller#action"
    error = assert_raises(ArgumentError) do
      build(Post, routes: false, endpoints: { "x" => "posts#index" })
    end
    assert_includes error.message, "no routes are available"
  end

  def test_without_a_rails_application_only_explicit_endpoints_apply
    # Rails.application is nil under the stub: no derivation, no error.
    endpoints = Funicular::Schema.build(Post, attributes: {})[:endpoints]
    assert_equal({}, endpoints)
  end
end
