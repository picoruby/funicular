# frozen_string_literal: true

require "test_helper"

Funicular::SSR::Runtime.load_framework!

# Router-side navigation guard: a component may veto navigation with a
# confirmation message (mrblib logic exercised under CRuby; the browser
# integration is covered by test/navigation_guard_test.rb and the
# beforeunload listener).
class NavigationGuardTest < Minitest::Test
  class FreeComponent
    def navigation_guard
      nil
    end
  end

  class GuardedComponent
    def navigation_guard
      "Unsaved changes will be lost. Leave?"
    end
  end

  def setup
    @router = Funicular::Router.new(nil)
  end

  def teardown
    Funicular.confirm_handler = nil
  end

  def test_leaving_is_allowed_without_a_current_component
    assert_equal true, @router.leave_allowed?
  end

  def test_leaving_is_allowed_when_the_guard_returns_nil
    @router.instance_variable_set(:@current_component, FreeComponent.new)
    assert_equal true, @router.leave_allowed?
  end

  def test_guard_message_is_prompted_and_denial_blocks_leaving
    @router.instance_variable_set(:@current_component, GuardedComponent.new)
    asked = []
    Funicular.confirm_handler = ->(message) { asked << message; false }

    assert_equal false, @router.leave_allowed?
    assert_equal [ "Unsaved changes will be lost. Leave?" ], asked
  end

  def test_confirmation_allows_leaving
    @router.instance_variable_set(:@current_component, GuardedComponent.new)
    Funicular.confirm_handler = ->(_message) { true }

    assert_equal true, @router.leave_allowed?
  end

  def test_confirm_defaults_to_true_on_the_server
    # SSR must never block: without a handler, server mode allows leaving.
    assert_equal true, Funicular.confirm("anything")
  end

  def test_component_guard_defaults_to_nil
    assert_nil Funicular::Component.new.navigation_guard
  end
end
