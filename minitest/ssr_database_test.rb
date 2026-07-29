# frozen_string_literal: true

require "test_helper"

# The SSR contract for the local database (docs decision 18): model
# class bodies evaluate under CRuby -- declarations are recorded, no
# SQLite is touched -- but booting the database or materializing a
# local query on the server fails loud with UnavailableError, never an
# empty result.
class SSRDatabaseTest < Minitest::Test
  def setup
    # Loads the mrblib runtime under CRuby and flips Funicular.server
    # to true, exactly like a Rails SSR render.
    Funicular::SSR::Runtime.load_framework!
  end

  def test_boot_refuses_on_the_server
    error = assert_raises(Funicular::DB::UnavailableError) do
      Funicular::DB.boot(models: [], metadata: {})
    end
    assert_includes error.message, "SSR"
    # The refusal is a clean raise, not a failed state: nothing to
    # tear down, nothing latched.
    assert_equal :unbooted, Funicular::DB.boot_state
  end

  def test_a_local_class_body_evaluates_but_materializing_raises
    model = Class.new(Funicular::Model) do
      table_name "ssr_drafts"
      storage :local do
        migrate 1 do |t|
          t.string :title
        end
      end
    end
    # The declaration side worked: storage recorded, no SQLite touched.
    assert_equal true, model.local?
    # Materializing is where the server says no.
    assert_raises(Funicular::DB::UnavailableError) { model.count }
    assert_raises(Funicular::DB::UnavailableError) { model.local.to_a }
    assert_raises(Funicular::DB::UnavailableError) do
      model.local_create(title: "nope")
    end
  end
end
