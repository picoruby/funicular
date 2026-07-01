# frozen_string_literal: true

require "test_helper"

# Exercises the top-level Funicular module: version constant, the
# configuration accessor/DSL, and the vendored wasm version reader.
class FunicularTest < Minitest::Test
  def test_VERSION
    assert ::Funicular.const_defined?(:VERSION)
    assert_match(/\A\d+\.\d+\.\d+/, Funicular::VERSION)
  end

  def test_configuration_is_memoized
    assert_instance_of Funicular::Configuration, Funicular.configuration
    assert_same Funicular.configuration, Funicular.configuration
  end

  def test_configure_yields_the_configuration
    yielded = nil
    Funicular.configure { |config| yielded = config }
    assert_same Funicular.configuration, yielded
  end

  def test_vendored_wasm_version_reads_version_file
    # The vendored artifacts are not present in a source checkout, so the
    # reader swallows Errno::ENOENT and returns nil. When they are present it
    # returns the trimmed VERSION file contents.
    version_file = File.join(Funicular::VENDOR_PICORUBY_DIR, "VERSION")
    Funicular.instance_variable_set(:@vendored_wasm_version, nil)

    if File.exist?(version_file)
      assert_equal File.read(version_file).strip, Funicular.vendored_wasm_version
    else
      assert_nil Funicular.vendored_wasm_version
    end
  ensure
    Funicular.instance_variable_set(:@vendored_wasm_version, nil)
  end
end
