# frozen_string_literal: true

require_relative "session_epoch"
require_relative "epoch_stamping"

module Funicular
  # Rack middleware writing the X-Funicular-Epoch header onto EVERY
  # response -- the exception pages ActionDispatch renders included.
  # A controller-level after_action cannot guarantee that: it never
  # runs when the action raises, and a header-less 500 reads as an
  # epoch mismatch client-side, terminating a healthy page over a mere
  # server error. The Railtie inserts this above
  # ActionDispatch::ShowExceptions, so the freshly-built exception
  # response passes through here too.
  #
  # The controller concern (EpochStamping) owns the ROTATION -- the
  # user_key lambda needs its controller -- and leaves the epoch in the
  # request env; this middleware only writes the header. When the
  # request died before the concern ran, the stored session epoch
  # (read without rotating) is the best truthful answer; with no
  # session and no env value the header is simply absent, exactly as
  # before the request.
  class EpochHeader
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      epoch = env[EpochStamping::ENV_KEY] || stored_epoch(env)
      if epoch
        # The framework's epoch is AUTHORITATIVE and overwrites
        # whatever an inner layer set: a stale value there (stamped
        # before a login/logout rotated the epoch) would let an old
        # page apply the post-transition response as a match --
        # exactly the boundary decision 13 exists to keep closed. The
        # capitalized spelling goes too: plain header hashes are
        # case-sensitive, and a legacy-cased duplicate would otherwise
        # ride out alongside our lowercase (Rack 3) name.
        headers.delete("X-Funicular-Epoch")
        headers[EpochStamping::HEADER] = epoch
      end
      [status, headers, body]
    end

    private

    def stored_epoch(env)
      session = env["rack.session"]
      return nil unless session
      epochs = session[SessionEpoch::SESSION_KEY]
      return nil unless epochs.is_a?(Hash)
      entry = epochs[Funicular.configuration.application_id]
      return nil unless entry.is_a?(Hash)
      epoch = entry["epoch"].to_s
      epoch.empty? ? nil : epoch
    rescue StandardError
      # Best effort on the exception path: masking the original error
      # with a session-read failure would be worse than a missing
      # header.
      nil
    end
  end
end
