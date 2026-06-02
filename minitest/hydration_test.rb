# frozen_string_literal: true

require "test_helper"

# Exercises the hydration mismatch guard under CRuby. The structural decision
# (`hydration_match?`) and the dev warning (`warn_hydration_mismatch`) are pure
# Ruby, so they are tested here without a DOM. The actual recovery swap done by
# `full_render_fallback` (Renderer + replaceChild) is JS-only and is covered by
# the browser/manual verification step, not here.
#
# A plain Hash stands in for the server DOM node: hydration_match? only reads
# `dom_element[:tagName]`, which a Hash answers the same way a JS::Element does.
class HydrationMatchTest < Minitest::Test
  def setup
    Funicular::SSR::Runtime.load_framework!
    Funicular.env = "development"
  end

  def teardown
    Funicular.env = "development"
  end

  # Builds the probe at runtime (Class.new) so the suite matches its picotest
  # twin and never references Funicular::Component at load time. render is never
  # invoked here (we feed vnodes directly); it only satisfies the abstract API.
  def probe
    klass = Class.new(Funicular::Component) do
      def render
        div { "x" }
      end

      def match?(vnode, dom)
        hydration_match?(vnode, dom)
      end

      def warn_for(vnode, dom)
        warn_hydration_mismatch(vnode, dom)
      end
    end
    klass.new
  end

  def el(tag)
    Funicular::VDOM::Element.new(tag, {}, ["x"])
  end

  # --- hydration_match? (the decision that drives the fallback) ---------

  def test_matches_when_root_tags_agree
    assert_equal true, probe.match?(el("div"), { tagName: "DIV" })
  end

  def test_detects_mismatched_root_tag
    assert_equal false, probe.match?(el("div"), { tagName: "SPAN" })
  end

  def test_tag_comparison_is_case_insensitive
    assert_equal true, probe.match?(el("h1"), { tagName: "H1" })
  end

  def test_non_element_vnode_is_treated_as_match
    assert_equal true, probe.match?(Funicular::VDOM::Text.new("hi"), { tagName: "DIV" })
  end

  def test_missing_dom_tag_name_is_treated_as_match
    assert_equal true, probe.match?(el("div"), {})
  end

  # --- warn_hydration_mismatch (dev-only diagnostics) -------------------

  def test_warning_fires_in_development
    out, _err = capture_io do
      probe.warn_for(el("div"), { tagName: "SPAN" })
    end
    assert_includes out, "Hydration mismatch"
    assert_includes out, "<div>"
    assert_includes out, "<span>"
  end

  def test_warning_is_silent_in_production
    Funicular.env = "production"
    out, _err = capture_io do
      probe.warn_for(el("div"), { tagName: "SPAN" })
    end
    assert_equal "", out
  end
end
