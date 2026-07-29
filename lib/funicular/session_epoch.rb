# frozen_string_literal: true

require "json"
require "securerandom"

module Funicular
  # The server half of the session epoch (docs: local_database.md, "The
  # session epoch"). The epoch is an opaque value that changes on every
  # authentication transition; every response carries it in the
  # X-Funicular-Epoch header, and the client goes terminal on a mismatch
  # so a tab can never keep applying data that now belongs to somebody
  # else's cookie session.
  #
  # State lives in the Rails session PER application_id, so several
  # Funicular apps sharing one cookie session cannot rotate each other's
  # epochs:
  #
  #   session["funicular_epochs"][app_id] = {
  #     "identity" => <canonical identity JSON>,
  #     "epoch"    => <opaque hex>,
  #   }
  #
  # String keys throughout: cookie sessions round-trip through JSON.
  module SessionEpoch
    SESSION_KEY = "funicular_epochs"

    class << self
      # A Rails API-only app usually runs WITHOUT a session middleware:
      # request.session is a disabled stub whose every read and write
      # raises. Loading Funicular must not break such an app, so both
      # the controller concern and the include-tag helper check here
      # and leave the epoch feature OFF -- with no cookie session there
      # is no shared identity for the epoch to protect in the first
      # place. Plain hashes (tests, exotic stores) count as enabled.
      def session_available?(session)
        return false if session.nil?
        return true unless session.respond_to?(:enabled?)
        session.enabled?
      end

      # The signed-in user's storage key, resolved through the
      # configured lambda; nil when signed out or when no user_key is
      # configured (anonymous_only apps included). An empty resolved
      # key is a broken source and fails loud -- it would fold every
      # user into one namespace.
      def user_key(controller)
        resolver = Funicular.configuration.user_key
        return nil unless resolver
        value = resolver.call(controller)
        return nil if value.nil?
        key = value.to_s
        if key.empty?
          raise Funicular::Error,
                "Funicular user_key resolved to an empty string; " \
                "return nil for signed-out visitors instead"
        end
        key
      end

      # The identity for an ALREADY-resolved user key (nil = signed
      # out), encoded exactly like the client's namespace tuple (docs
      # decision 12): ["v1", app, "anonymous"] or
      # ["v1", app, "user", key] as canonical JSON. STRUCTURE separates
      # the fields, so no delimiter or "anonymous"-as-a-user-key
      # collisions. Callers that also DISPLAY the key (the include-tag
      # helper) resolve it once and pass that same value here -- two
      # resolver evaluations could disagree mid-transition and stamp
      # one user's epoch onto another user's page namespace.
      def identity_for(user_key)
        app_id = Funicular.configuration.application_id
        if user_key.nil?
          JSON.generate(["v1", app_id, "anonymous"])
        else
          JSON.generate(["v1", app_id, "user", user_key])
        end
      end

      # The current identity, resolving the user key through the
      # configured lambda.
      def identity(controller)
        identity_for(user_key(controller))
      end

      # Returns the application's current epoch, rotating it first
      # whenever the stored identity differs from the computed one --
      # login, logout, and a direct user switch are all just "the
      # identity changed". Writes the session entry on rotation.
      def stamp!(session, controller)
        stamp_identity!(session, identity(controller))
      end

      # The rotation core against a pre-computed identity.
      def stamp_identity!(session, current)
        stored = session[SESSION_KEY]
        epochs = stored.is_a?(Hash) ? stored : {}
        app_id = Funicular.configuration.application_id
        entry = epochs[app_id]
        if entry.is_a?(Hash) && entry["identity"] == current
          epoch = entry["epoch"].to_s
          return epoch unless epoch.empty?
        end
        epoch = SecureRandom.hex(16)
        epochs[app_id] = { "identity" => current, "epoch" => epoch }
        session[SESSION_KEY] = epochs
        epoch
      end
    end
  end
end
