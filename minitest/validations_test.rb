# frozen_string_literal: true

require "test_helper"

# Load the mrblib runtime before defining model subclasses below, since their
# class bodies reference Funicular::Model and call `validates` at load time.
Funicular::SSR::Runtime.load_framework!

# Exercises the client-side validation framework under CRuby (the same code
# runs in the browser under PicoRuby; see test/validations_test.rb).
class ValidationsTest < Minitest::Test
  # A fresh, isolated model class with the given schema so validators declared
  # in one test never leak into another.
  def model_class(attributes = { "name" => false, "age" => false }, endpoints = {})
    klass = Class.new(Funicular::Model)
    attrs = {}
    attributes.each { |name, readonly| attrs[name] = { "type" => "string", "readonly" => readonly } }
    klass.load_schema("attributes" => attrs, "endpoints" => endpoints)
    klass
  end

  # --- individual validators -------------------------------------------

  def test_presence
    k = model_class
    k.class_eval { validates :name, presence: true }
    blank = k.new("name" => "")
    assert_equal false, blank.valid?
    assert_equal ["can't be blank"], blank.errors[:name]
    assert_equal true, k.new("name" => "Alice").valid?
  end

  def test_length_maximum_and_minimum
    k = model_class
    k.class_eval { validates :name, length: { minimum: 2, maximum: 5 } }

    short = k.new("name" => "a"); short.valid?
    assert_equal ["is too short (minimum is 2 characters)"], short.errors[:name]

    long = k.new("name" => "abcdef"); long.valid?
    assert_equal ["is too long (maximum is 5 characters)"], long.errors[:name]

    assert_equal true, k.new("name" => "abc").valid?
  end

  def test_format
    k = model_class
    k.class_eval { validates :name, format: { with: /^[a-z]+$/ } }
    assert_equal true, k.new("name" => "abc").valid?
    bad = k.new("name" => "ABC"); bad.valid?
    assert_equal ["is invalid"], bad.errors[:name]
  end

  def test_numericality
    k = model_class
    k.class_eval { validates :age, numericality: { only_integer: true, greater_than: 0 } }
    nan = k.new("age" => "abc"); nan.valid?
    assert_equal ["is not a number"], nan.errors[:age]
    assert_equal true, k.new("age" => "10").valid?
    low = k.new("age" => "0"); low.valid?
    assert_equal ["must be greater than 0"], low.errors[:age]
    frac = k.new("age" => "1.5"); frac.valid?
    assert_equal ["must be an integer"], frac.errors[:age]
  end

  def test_inclusion_and_exclusion
    inc = model_class
    inc.class_eval { validates :name, inclusion: { in: ["a", "b"] } }
    assert_equal true, inc.new("name" => "a").valid?
    assert_equal false, inc.new("name" => "z").valid?

    exc = model_class
    exc.class_eval { validates :name, exclusion: { in: ["admin"] } }
    assert_equal false, exc.new("name" => "admin").valid?
    assert_equal true, exc.new("name" => "alice").valid?
  end

  def test_allow_blank_skips_validation
    k = model_class
    k.class_eval { validates :name, length: { minimum: 3 }, allow_blank: true }
    assert_equal true, k.new("name" => "").valid?
    assert_equal false, k.new("name" => "ab").valid?
  end

  def test_valid_clears_previous_errors
    k = model_class
    k.class_eval { validates :name, presence: true }
    m = k.new("name" => "")
    m.valid?
    m.instance_variable_set("@name", "now set")
    assert_equal true, m.valid?
    assert_equal [], m.errors[:name]
  end

  # --- schema-derived validators + merge -------------------------------

  def test_load_schema_merges_and_dedupes
    k = Class.new(Funicular::Model)
    k.class_eval { validates :name, presence: true } # client-declared
    k.load_schema(
      "attributes" => {
        "name" => { "type" => "string", "readonly" => false },
        "age" => { "type" => "string", "readonly" => false }
      },
      "endpoints" => {},
      "validations" => {
        "name" => { "presence" => true, "length" => { "maximum" => 3 } },
        "age" => { "presence" => true }
      }
    )

    name_kinds = k.validators_on(:name).map(&:kind).sort
    # presence appears once (client wins, schema presence deduped) + length merged
    assert_equal [:length, :presence], name_kinds
    assert_equal [:presence], k.validators_on(:age).map(&:kind)
  end

  def test_inline_attribute_validations_are_registered
    # The shape produced by Funicular::Schema.build: validations nested inside
    # each attribute entry.
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
    assert_equal [:length, :presence], k.validators_on(:name).map(&:kind).sort
    assert_equal false, k.new("name" => "toolong").valid?
    assert_equal true, k.new("name" => "ok").valid?
  end

  def test_format_from_schema_rebuilds_regexp
    k = Class.new(Funicular::Model)
    k.load_schema(
      "attributes" => { "name" => { "type" => "string", "readonly" => false } },
      "endpoints" => {},
      "validations" => { "name" => { "format" => { "with" => "^[a-z]+$", "flags" => "i" } } }
    )
    assert_equal true, k.new("name" => "ABC").valid? # 'i' flag honored
    assert_equal false, k.new("name" => "123").valid?
  end

  # --- create/update auto-validation -----------------------------------

  def test_create_short_circuits_when_invalid
    k = model_class({ "name" => false }, "create" => { "method" => "POST", "path" => "/things" })
    k.class_eval { validates :name, presence: true }

    got_instance = :unset
    got_error = :unset
    # Invalid -> returns before any HTTP call, yields the errors.
    k.create({ "name" => "" }) do |instance, error|
      got_instance = instance
      got_error = error
    end

    assert_nil got_instance
    assert_instance_of Funicular::Model::Errors, got_error
    assert_equal ["can't be blank"], got_error[:name]
  end

  def test_update_short_circuits_when_invalid
    k = model_class({ "name" => false }, "update" => { "method" => "PATCH", "path" => "/things/:id" })
    k.class_eval { validates :name, presence: true }

    m = k.new("name" => "ok")
    m.instance_variable_set("@id", 1)

    got_success = :unset
    got_result = :unset
    m.update("name" => "") do |success, result|
      got_success = success
      got_result = result
    end

    assert_equal false, got_success
    assert_equal ["can't be blank"], got_result[:name]
  end
end
