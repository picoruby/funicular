# Hydration mismatch guard, mruby/PicoRuby side. The structural decision
# (`hydration_match?`) is pure Ruby and shared between server and client, so it
# is tested under both VMs (see minitest/hydration_test.rb for the CRuby twin)
# to guard against divergence. The DOM swap performed on mismatch
# (`full_render_fallback`) is JS-only and is verified in the browser, not here.
#
# A plain Hash stands in for the server DOM node: hydration_match? only reads
# `dom_element[:tagName]`, which a Hash answers like a JS::Element does.
#
# The probe subclass is built at runtime via Class.new so that
# Funicular::Component is referenced only inside a method (matching the other
# picotests); referencing it in a class body resolves at load time and fails.
class HydrationTest < Picotest::Test
  def probe
    klass = Class.new(Funicular::Component) do
      def render
        div { "x" }
      end

      def match?(vnode, dom)
        hydration_match?(vnode, dom)
      end
    end
    klass.new
  end

  def el(tag)
    Funicular::VDOM::Element.new(tag, {}, ['x'])
  end

  def test_matches_when_root_tags_agree
    assert_equal(true, probe.match?(el('div'), {tagName: 'DIV'}))
  end

  def test_detects_mismatched_root_tag
    assert_equal(false, probe.match?(el('div'), {tagName: 'SPAN'}))
  end

  def test_tag_comparison_is_case_insensitive
    assert_equal(true, probe.match?(el('h1'), {tagName: 'H1'}))
  end

  def test_non_element_vnode_is_treated_as_match
    assert_equal(true, probe.match?(Funicular::VDOM::Text.new('hi'), {tagName: 'DIV'}))
  end

  def test_missing_dom_tag_name_is_treated_as_match
    assert_equal(true, probe.match?(el('div'), {}))
  end
end
