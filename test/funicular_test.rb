class FunicularTest < Picotest::Test
  def setup
  end

  def test_funicular_version
    # The exact value lives in mrblib/version.rb; only check the shape so
    # that bumping the version does not require touching this test.
    # Regexp is not available in the PicoRuby test build, so check the
    # "MAJOR.MINOR.PATCH" shape with plain string operations.
    assert(Funicular::VERSION.is_a?(String))
    parts = Funicular::VERSION.split('.')
    assert_equal(3, parts.size)
    parts.each do |part|
      assert(part.size > 0)
      assert_equal(part, part.to_i.to_s)
    end
    assert_equal(Funicular::VERSION, Funicular.version)
  end
end
