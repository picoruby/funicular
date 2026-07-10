class FunicularTest < Picotest::Test
  def setup
  end

  def test_funicular_version
    assert_equal('0.1.0', Funicular::VERSION)
  end

  def test_start_accepts_gc_scheduler_driven_in_server_mode
    original_server = Funicular.server?
    Funicular.server = true

    assert_equal(nil, Funicular.start(gc_scheduler_driven: true))
  ensure
    Funicular.server = original_server
  end
end
