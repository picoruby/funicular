# Tests for the namespace identity (docs decisions 12/13): the typed,
# versioned tuple every durable name hangs off, and the declaration
# rules resolved authoritatively on the client.

class NamespaceTest < Picotest::Test
  def db
    Funicular::DB
  end

  # ---- identity structure ----

  def test_anonymous_differs_from_a_user_literally_named_anonymous
    anon = db.namespace_identity("app1", nil, true)
    tricky = db.namespace_identity("app1", "anonymous", false)
    assert_equal(false, anon == tricky)
  end

  def test_identity_is_canonical_and_stable
    assert_equal("[\"v1\",\"app1\",\"user\",\"u1\"]",
                 db.namespace_identity("app1", "u1", false))
    assert_equal("[\"v1\",\"app1\",\"anonymous\"]",
                 db.namespace_identity("app1", nil, true))
    assert_equal(db.namespace_identity("app1", "u1", false),
                 db.namespace_identity("app1", "u1", false))
  end

  def test_structure_beats_delimiter_tricks
    # A naive "app:user" concatenation would collide these two.
    assert_equal(false,
      db.namespace_identity("a:b", "c", false) ==
        db.namespace_identity("a", "b:c", false))
  end

  def test_identities_differ_between_users_and_apps
    base = db.namespace_identity("a", "u1", false)
    assert_equal(false, base == db.namespace_identity("a", "u2", false))
    assert_equal(false, base == db.namespace_identity("b", "u1", false))
  end

  def test_empty_values_fail_loud
    assert_raise(Funicular::DB::ConfigError) do
      db.namespace_identity("", "u", false)
    end
    assert_raise(Funicular::DB::ConfigError) do
      db.namespace_identity("app", "", false)
    end
    assert_raise(Funicular::DB::ConfigError) do
      db.namespace_identity("app", nil, false)
    end
  end

  # ---- declaration rules ----
  # Configuration errors key off user_key_configured (is a SOURCE
  # declared?); the anonymous/user choice keys off the resolved value.

  def test_user_key_and_anonymous_only_are_mutually_exclusive
    assert_raise(Funicular::DB::ConfigError) do
      db.resolve_namespace(application_id: "a", user_key: "u",
                           user_key_configured: true,
                           anonymous_only: true, local_models: false)
    end
    # Detected even while the configured lambda currently resolves nil.
    assert_raise(Funicular::DB::ConfigError) do
      db.resolve_namespace(application_id: "a", user_key: nil,
                           user_key_configured: true,
                           anonymous_only: true, local_models: false)
    end
  end

  def test_local_models_require_a_configured_user_key
    assert_raise(Funicular::DB::ConfigError) do
      db.resolve_namespace(application_id: "a", user_key: nil,
                           user_key_configured: false,
                           anonymous_only: false, local_models: true)
    end
  end

  def test_signed_out_visit_boots_into_the_anonymous_namespace
    # user_key IS configured; it just resolves to nil right now.
    assert_equal("[\"v1\",\"a\",\"anonymous\"]",
      db.resolve_namespace(application_id: "a", user_key: nil,
                           user_key_configured: true,
                           anonymous_only: false, local_models: true))
  end

  def test_empty_resolved_user_key_is_a_config_error
    # Only nil means signed out: an empty string is a broken user_key
    # source, and folding it into anonymous would mix users' data.
    assert_raise(Funicular::DB::ConfigError) do
      db.resolve_namespace(application_id: "a", user_key: "",
                           user_key_configured: true,
                           anonymous_only: false, local_models: true)
    end
  end

  def test_anonymous_only_is_the_explicit_opt_out
    assert_equal("[\"v1\",\"a\",\"anonymous\"]",
      db.resolve_namespace(application_id: "a", user_key: nil,
                           user_key_configured: false,
                           anonymous_only: true, local_models: true))
  end

  def test_replica_only_apps_default_to_anonymous
    assert_equal("[\"v1\",\"a\",\"anonymous\"]",
      db.resolve_namespace(application_id: "a", user_key: nil,
                           user_key_configured: false,
                           anonymous_only: false, local_models: false))
  end

  def test_user_key_resolves_to_the_user_identity
    assert_equal("[\"v1\",\"a\",\"user\",\"u\"]",
      db.resolve_namespace(application_id: "a", user_key: "u",
                           user_key_configured: true,
                           anonymous_only: false, local_models: true))
  end

  # ---- derived names ----

  def test_derived_names_are_distinct_and_carry_the_identity
    identity = db.namespace_identity("a", "u", false)
    replica_key = db.snapshot_key(identity, :replica)
    local_key = db.snapshot_key(identity, :local)
    lock = db.lock_name(identity)
    assert_equal(false, replica_key == local_key)
    assert_equal(false, lock == replica_key)
    assert_equal(true, replica_key.include?(identity))
    assert_equal(true, local_key.include?(identity))
    assert_equal(true, lock.include?(identity))
    assert_raise(ArgumentError) { db.snapshot_key(identity, :other) }
  end

  def test_derived_names_differ_between_identities
    a = db.namespace_identity("a", "u1", false)
    b = db.namespace_identity("a", "u2", false)
    assert_equal(false, db.snapshot_key(a, :local) == db.snapshot_key(b, :local))
    assert_equal(false, db.lock_name(a) == db.lock_name(b))
  end
end
