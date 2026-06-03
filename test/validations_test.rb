# Client-side validation framework, mruby/PicoRuby side. The same code is
# tested under CRuby in minitest/validations_test.rb; this file confirms it
# runs on the real target VM, including FormatValidator against the JS RegExp
# engine. Models are built at runtime via Class.new so Funicular::Model is
# referenced only inside methods (load-time references resolve too early).
class ValidationsTest < Picotest::Test
  def model_with
    k = Class.new(Funicular::Model)
    k.load_schema(
      "attributes" => {
        "name" => { "type" => "string", "readonly" => false },
        "age" => { "type" => "string", "readonly" => false }
      },
      "endpoints" => {}
    )
    yield k
    k
  end

  def test_presence
    k = model_with { |c| c.validates :name, presence: true }
    blank = k.new("name" => "")
    assert_equal(false, blank.valid?)
    assert_equal(["can't be blank"], blank.errors[:name])
    assert_equal(true, k.new("name" => "Alice").valid?)
  end

  def test_length
    k = model_with { |c| c.validates :name, length: { minimum: 2, maximum: 5 } }
    short = k.new("name" => "a")
    assert_equal(false, short.valid?)
    assert_equal(["is too short (minimum is 2 characters)"], short.errors[:name])
    assert_equal(true, k.new("name" => "abc").valid?)
  end

  # FormatValidator runs the regexp through the JS RegExp engine. Patterns must
  # be written in JS syntax (^...$, not \A...\z).
  def test_format_with_js_regexp
    k = model_with { |c| c.validates :name, format: { with: /^[a-z]+$/ } }
    assert_equal(true, k.new("name" => "abc").valid?)
    bad = k.new("name" => "ABC")
    assert_equal(false, bad.valid?)
    assert_equal(["is invalid"], bad.errors[:name])
  end

  def test_numericality
    k = model_with { |c| c.validates :age, numericality: { only_integer: true, greater_than: 0 } }
    assert_equal(false, k.new("age" => "abc").valid?)
    assert_equal(true, k.new("age" => "10").valid?)
    low = k.new("age" => "0")
    assert_equal(false, low.valid?)
    assert_equal(["must be greater than 0"], low.errors[:age])
  end

  def test_inclusion
    k = model_with { |c| c.validates :name, inclusion: { in: ["a", "b"] } }
    assert_equal(true, k.new("name" => "a").valid?)
    assert_equal(false, k.new("name" => "z").valid?)
  end

  # Inline shape produced by Funicular::Schema.build: validations nested in
  # each attribute entry.
  def test_inline_schema_validations
    k = Class.new(Funicular::Model)
    k.load_schema(
      "attributes" => {
        "name" => {
          "type" => "string", "readonly" => false,
          "validations" => { "presence" => true, "length" => { "maximum" => 3 } }
        }
      },
      "endpoints" => {}
    )
    assert_equal(false, k.new("name" => "toolong").valid?)
    assert_equal(true, k.new("name" => "ok").valid?)
  end
end
