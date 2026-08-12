class NavigationGuardTest < Picotest::Test
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
    @container = stub(Object.new) # JS::Object
    @router = Funicular::Router.new(@container)
  end

  def teardown
    Funicular.confirm_handler = nil
  end

  def test_leave_allowed_without_component
    assert_equal(true, @router.leave_allowed?)
  end

  def test_leave_allowed_with_nil_guard
    @router.instance_variable_set(:@current_component, FreeComponent.new)
    assert_equal(true, @router.leave_allowed?)
  end

  def test_denied_confirmation_blocks_leaving
    @router.instance_variable_set(:@current_component, GuardedComponent.new)
    asked = []
    Funicular.confirm_handler = ->(message) { asked << message; false }

    assert_equal(false, @router.leave_allowed?)
    assert_equal(["Unsaved changes will be lost. Leave?"], asked)
  end

  def test_accepted_confirmation_allows_leaving
    @router.instance_variable_set(:@current_component, GuardedComponent.new)
    Funicular.confirm_handler = ->(_message) { true }

    assert_equal(true, @router.leave_allowed?)
  end

  def test_component_guard_defaults_to_nil
    assert_equal(nil, Funicular::Component.new.navigation_guard)
  end
end
