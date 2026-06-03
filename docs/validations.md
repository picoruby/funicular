# Model Validations

`Funicular::Model` has an ActiveModel-style validation API, so a model can validate itself in the browser (under PicoRuby) with no server round-trip. Validations can be declared directly on the client model, derived from the matching ActiveRecord model on the server, or both at once.

## Declaring validators

Declare validations in a `Funicular::Model` subclass exactly as you would in Rails:

```ruby
class User < Funicular::Model
  validates :display_name, presence: true, length: { maximum: 30 }
  validates :age, numericality: { only_integer: true, greater_than: 0 }, allow_blank: true
end
```

The standard validators are provided as `Funicular::Model::Validations::PresenceValidator` and friends: `presence`, `absence`, `length` (`minimum`/`maximum`/`is`/`in`), `format` (`with:`/`without:`), `numericality` (`only_integer`, `greater_than`, `less_than`, `equal_to`, ...), `inclusion` (`in:`), `exclusion` (`in:`), `acceptance`, and `confirmation`. The shared options `allow_nil` and `allow_blank` are honored for every validator in a `validates` call.

## Running validations

`valid?` runs every validator and populates `errors`; `invalid?` is its inverse. `errors` is a small `Funicular::Model::Errors`: `errors[:attr]` returns an array of messages, `errors.messages` returns the `{ attribute => [messages] }` hash, and `errors.full_messages` returns human-readable strings.

`Model.create` and `Model#update` validate first and behave like `ActiveRecord#save`: when the instance is invalid they skip the HTTP request and hand the errors to your callback, so you can show them without a network trip:

```ruby
user.update(display_name: name) do |success, result|
  if success
    # saved
  elsif result.respond_to?(:messages)
    patch(errors: result.messages)   # client-side validation errors, shown inline
  else
    patch(message: "Error: #{result}", is_error: true)  # server error
  end
end
```

`form_for` reads `state.errors[:field]` and renders the message beside each field, so `patch(errors: model.errors.messages)` is all a form needs to display inline errors. The server still validates and may return a 422; client validation is an additive pre-flight layer.

## Reusing ActiveRecord validations

Most apps already declare `validates` on their ActiveRecord models. Rather than restating those rules on the client, build the schema with `Funicular::Schema.build`: it introspects the AR model via `validators_on` and merges the derived rules inline into each attribute entry, which `load_schema` then turns into client validators.

```ruby
class Api::SchemaController < ApplicationController
  def user
    render json: Funicular::Schema.build(
      User,
      attributes: {
        "display_name" => { type: "string", readonly: false },
        "username"     => { type: "string", readonly: true }
      },
      endpoints: { "update" => { method: "PATCH", path: "/users/:id" } },
      except: { username: [:format] }
    )
  end
end
```

The emitted `display_name` entry becomes `{ type: "string", readonly: false, validations: { "presence" => true, "length" => { "maximum" => 30 } } }` — the validators ride along with the attribute, so there is nothing extra to declare or keep in sync.

The exposure policy is an attribute allowlist plus a per-kind denylist. Validations are derived only for the attributes you declare (already public in `attributes`), so nothing outside the schema is ever introspected. `except:` suppresses specific kinds for specific attributes. Validators that cannot run on the client are skipped automatically: `uniqueness` (database-only), any custom validator, and conditional/context validators (`if:`, `unless:`, `on:`).

(`Funicular::Schema.validations_for(model, names, except:)` is also available if you prefer to emit a separate top-level `validations:` block instead of the inline form; `load_schema` accepts either.)

Client-declared validators and schema-derived ones merge. If the same kind is declared for an attribute on both sides, the client declaration wins and the schema-derived duplicate is dropped, so frontend-only validations always keep working.

## The `format` regexp caveat

On the client, `Regexp` is a thin wrapper over the JavaScript `RegExp` engine, not Ruby's Onigmo, so a few Ruby-only constructs differ. Write client `format` patterns in JavaScript syntax: use `^...$` rather than `\A...\z`, and avoid extended (`/x`) mode, POSIX classes like `[[:alpha:]]`, and `\h`/`\H`.

When deriving a `format` validator from ActiveRecord, `Funicular::Schema` translates the common anchors (`\A` to `^`, `\z`/`\Z` to `$`) and carries the `i`/`m` flags, but it skips (with a warning) any pattern using a construct JavaScript cannot accept. `format` is therefore the prime candidate for the `except:` denylist; declare such a validator directly on the `Funicular::Model` in JS-compatible syntax instead.
