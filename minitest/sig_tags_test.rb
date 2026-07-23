# frozen_string_literal: true

require "test_helper"

# The tag whitelist lives in mrblib/0_tags.rb (runtime) and is manually
# enumerated in sig/tags.rbs and sig/view_context.rbs (types). These drifted
# in the past; fail loudly when they do again.
class SigTagsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    Funicular::SSR::Runtime.load_framework!
  end

  def assert_sig_covers_all_tags(sig_path)
    sig = File.read(File.join(ROOT, sig_path))
    missing = Funicular::Tags::HTML_TAGS.reject do |tag|
      sig.include?("def #{tag}: ")
    end
    assert_empty missing, "#{sig_path} is missing tag signatures: #{missing.join(', ')}"
  end

  def test_sig_tags_rbs_covers_all_tags
    assert_sig_covers_all_tags("sig/tags.rbs")
  end

  def test_sig_view_context_rbs_covers_all_tags
    assert_sig_covers_all_tags("sig/view_context.rbs")
  end
end
