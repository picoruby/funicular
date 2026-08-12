# frozen_string_literal: true

require "test_helper"

# The mrblib runtime is plain Ruby, so the CRuby suite can cover the
# Response#body alias and the handler error report format directly;
# the browser-side wiring ships with the next picoruby.wasm rebuild.
class CallbackErrorVisibilityTest < Minitest::Test
  def setup
    Funicular::SSR::Runtime.load_framework!
  end

  # Assigning the anonymous class to a constant names it, so the report
  # prints a real component name. Defined lazily: Funicular::Component
  # only exists after the framework loads.
  def probe_component
    unless defined?(::CheckoutProbeComponent)
      Object.const_set(:CheckoutProbeComponent, Class.new(Funicular::Component) do
        def render; end
      end)
    end
    ::CheckoutProbeComponent.new
  end

  def test_response_body_is_an_alias_of_data
    response = Funicular::HTTP::Response.new(200, { "id" => 1 })
    assert_equal response.data, response.body
    assert_equal({ "id" => 1 }, response.body)
  end

  def test_report_handler_error_names_component_handler_and_event
    error = ArgumentError.new("wrong number of arguments (given 1, expected 0)")

    out, _err = capture_io do
      probe_component.report_handler_error("click", "#handle_save", error)
    end

    assert_includes out, "CheckoutProbeComponent#handle_save"
    assert_includes out, "(onclick)"
    assert_includes out, "ArgumentError: wrong number of arguments"
  end

  def test_report_handler_error_never_raises
    capture_io do
      assert_nil probe_component.report_handler_error("click", "#x", RuntimeError.new("y"))
    end
  end
end
