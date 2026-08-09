# frozen_string_literal: true

require_relative "session_epoch"

module Funicular
  # Controller mixin installed by the Railtie: when the local database is
  # enabled, it rotates the session epoch where the user_key lambda has its
  # controller, and leaves the value in the request env for the EpochHeader
  # middleware to write out (docs decision 13).
  #
  # The header itself is deliberately NOT set here: a controller-set
  # header dies with the controller's response when the action raises,
  # and the exception page ActionDispatch renders would go out
  # header-less -- which the client must treat as an epoch mismatch,
  # terminating a healthy page over a mere 500.
  #
  # The epoch is stamped TWICE around the action. Before it, so a
  # mid-action exception still sends a truthful value; and again in
  # the ensure, with the POST-action identity, because the very
  # actions that log a user in or out change the identity INSIDE the
  # action -- their own response must already carry the rotated epoch,
  # not leave the rotation to the next request (an old page would
  # apply the login response as a match).
  module EpochStamping
    # Lowercase per the Rack 3 spec (response header names MUST be
    # lowercase; Rack::Lint enforces it). HTTP header names are
    # case-insensitive on the wire, so the client contract is
    # unchanged.
    HEADER = "x-funicular-epoch"
    ENV_KEY = "funicular.epoch"

    def self.included(base)
      base.around_action :stamp_funicular_epoch if base.respond_to?(:around_action)
    end

    private

    # request.session, never the controller's session accessor: an
    # application action named "session" SHADOWS the accessor, and
    # calling it from here would invoke the action itself (rendering
    # twice). The ensure re-reads request.session instead of reusing
    # the pre-action object because reset_session (a logout) replaces
    # it mid-action.
    def stamp_funicular_epoch
      local_database = Funicular.configuration.local_database
      return yield unless local_database
      sess = request.session
      unless Funicular::SessionEpoch.session_available?(sess)
        # No session middleware (API-only Rails): there is no cookie
        # identity for the epoch to protect, so the feature stays off
        # instead of breaking every action with a disabled-session
        # error.
        return yield
      end
      request.env[ENV_KEY] = Funicular::SessionEpoch.stamp!(sess, self)
      yield
    ensure
      if local_database
        sess = request.session
        if Funicular::SessionEpoch.session_available?(sess)
          request.env[ENV_KEY] = Funicular::SessionEpoch.stamp!(sess, self)
        end
      end
    end
  end
end
