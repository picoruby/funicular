# frozen_string_literal: true

require "test_helper"
require "active_model"

# Exercises Funicular::Schema.validations_for: deriving client validation rules
# from an ActiveModel class, honoring the attribute allowlist and the per-kind
# denylist, skipping unsupported/conditional validators, and translating the
# `format` regexp for the JS RegExp engine.
class SchemaDerivationTest < Minitest::Test
  class Account
    include ActiveModel::Validations
    attr_accessor :name, :email, :age, :role, :code, :score

    # Custom validator (kind :even) stands in for any non-standard validator
    # the client has no counterpart for; it must be skipped during derivation.
    class EvenValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value); end
    end

    validates :name, presence: true, length: { maximum: 30 }
    validates :email, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
    validates :age, numericality: { only_integer: true, greater_than: 0 }
    validates :role, inclusion: { in: %w[admin user] }
    validates :code, presence: true, if: -> { false }      # conditional -> skipped
    validates :score, even: true                           # unsupported kind -> skipped
  end

  def derive(attrs, except: {})
    Funicular::Schema.validations_for(Account, attrs, except: except)
  end

  def test_presence_and_length
    result = derive(["name"])
    assert_equal({ "presence" => true, "length" => { "maximum" => 30 } }, result["name"])
  end

  def test_only_listed_attributes_are_introspected
    result = derive(["name"])
    assert_equal ["name"], result.keys
  end

  def test_numericality_and_inclusion
    result = derive(["age", "role"])
    assert_equal({ "only_integer" => true, "greater_than" => 0 }, result["age"]["numericality"])
    assert_equal({ "in" => %w[admin user] }, result["role"]["inclusion"])
  end

  def test_format_translates_ruby_anchors
    result = derive(["email"])
    fmt = result["email"]["format"]
    # \A and \z become ^ and $ for JS RegExp.
    assert_equal "^[^@\\s]+@[^@\\s]+$", fmt["with"]
  end

  def test_denylist_suppresses_a_kind
    result = derive(["name"], except: { name: [:length] })
    assert_equal({ "presence" => true }, result["name"])
  end

  def test_conditional_validator_is_skipped
    result = derive(["code"])
    assert_nil result["code"]
  end

  def test_unsupported_kind_is_skipped
    result = derive(["score"])
    assert_nil result["score"]
  end

  def test_build_inlines_validations_into_attributes
    schema = Funicular::Schema.build(
      Account,
      attributes: {
        "display_name" => { type: "string", readonly: false },
        "name" => { type: "string", readonly: false }
      },
      endpoints: { "update" => { method: "PATCH", path: "/x/:id" } },
      except: { name: [:length] }
    )
    # Attribute with no validators is untouched.
    assert_equal({ type: "string", readonly: false }, schema[:attributes]["display_name"])
    # Validators are merged inline; denylist drops :length here.
    assert_equal(
      { type: "string", readonly: false, validations: { "presence" => true } },
      schema[:attributes]["name"]
    )
    assert_equal({ "update" => { method: "PATCH", path: "/x/:id" } }, schema[:endpoints])
  end

  def test_extended_regexp_is_skipped
    klass = Class.new do
      include ActiveModel::Validations
      def self.name; "Extended"; end
      attr_accessor :token
      validates :token, format: { with: /
        \A \d+ \z   # an integer, written with x-mode whitespace
      /x }
    end
    result = nil
    capture_io do  # silence the skip warning
      result = Funicular::Schema.validations_for(klass, ["token"])
    end
    assert_nil result["token"]
  end
end
