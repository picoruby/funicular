class FunicularTest < Picotest::Test
  def setup
  end

  def test_funicular_version
    assert_equal('0.3.0', Funicular::VERSION)
  end
end
