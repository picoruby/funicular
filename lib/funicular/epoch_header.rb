# frozen_string_literal: true

require_relative "session_epoch"
require_relative "epoch_stamping"

module Funicular
  # With the local database enabled, this Rack middleware writes the
  # X-Funicular-Epoch header onto EVERY response -- the exception pages
  # ActionDispatch renders included. Disabled responses are returned untouched.
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
    # Every spelling of the header this middleware owns.
    OWNED_HEADERS = [EpochStamping::HEADER, "X-Funicular-Epoch"].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [status, headers, body] unless Funicular.configuration.local_database
      # This header is the framework's to write, so an inner layer's
      # value is dropped FIRST and unconditionally: a stale one
      # (stamped before a login/logout rotated the epoch) would let an
      # old page read the post-transition response as a match --
      # exactly the boundary decision 13 exists to keep closed. Leaving
      # it in place when no authoritative epoch is available would be
      # the same hole with none of the excuses. Both spellings go:
      # plain header hashes are case-sensitive, so a legacy-cased
      # duplicate would otherwise ride out alongside our lowercase
      # (Rack 3) name.
      OWNED_HEADERS.each { |name| headers.delete(name) }
      epoch = env[EpochStamping::ENV_KEY] || stored_epoch(env)
      headers[EpochStamping::HEADER] = epoch if epoch
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
