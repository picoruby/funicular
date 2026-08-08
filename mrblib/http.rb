module Funicular
  module HTTP
    class Response
      attr_reader :data, :status, :ok

      def initialize(status, data)
        @status = status
        @ok = @status >= 200 && @status < 300
        @data = data
      end

      def error?
        return true unless @ok
        return false unless @data.is_a?(Hash)
        @data["error"] || @data["errors"]
      end

      def error_message
        return nil unless @data.is_a?(Hash)
        @data["error"] || (@data["errors"].is_a?(Array) ? @data["errors"].join(", ") : @data["errors"])
      end
    end

    def self.get(url, &block)
      request("GET", url, nil, &block)
    end

    def self.post(url, body = nil, &block)
      request("POST", url, body, &block)
    end

    def self.patch(url, body = nil, &block)
      request("PATCH", url, body, &block)
    end

    def self.delete(url, &block)
      request("DELETE", url, nil, &block)
    end

    def self.put(url, body = nil, &block)
      request("PUT", url, body, &block)
    end

    # Get CSRF token from meta tag
    # Note: Don't cache the token - Rails may rotate it after each request
    def self.csrf_token
      meta = JS.document.querySelector('meta[name="csrf-token"]')
      if meta
        token_obj = meta.getAttribute('content')
        token_obj ? token_obj.to_s : nil
      else
        nil
      end
    end

    class << self
      private

      def parse_response_body(text)
        return nil if text.nil?

        body = text.to_s
        return nil if body.empty?

        JSON.parse(body)
      rescue
        body
      end

      def request(method, url, body, &block)
        # A terminal page must not TALK to the server either (docs
        # decision 13): discarding the response is not enough, because
        # the request itself would already have executed under the NEW
        # session's cookies -- an old screen's click could mutate
        # another user's data. Refused BEFORE the fetch; the callback
        # still settles exactly once.
        if Funicular::DB.session_terminated?
          block.call(session_changed_response) if block
          return nil
        end
        # @type var options: Hash[Symbol, String | Hash[String, String]]
        options = { method: method, credentials: "include" }

        headers = {} #: Hash[String, String]

        if body
          headers["Content-Type"] = "application/json"
          options[:body] = JSON.generate(body)
        end

        if method != "GET"
          token = csrf_token
          headers["X-CSRF-Token"] = token if token
        end

        options[:headers] = headers unless headers.empty?

        settled = false
        begin
          JS.global.fetch(url, options) do |response|
            # The epoch decides BEFORE the body is touched. fetch
            # resolves once the headers arrive -- which is all this
            # check needs -- but to_binary can still fail on an
            # interrupted body stream, and the rescue below would then
            # settle with a network error without ever processing the
            # mismatch: the page would stay non-terminal and free to
            # issue another request under the NEW session.
            if Funicular::DB.__session_epoch_ok?(response_epoch(response))
              # @type var status: Integer
              status = response.status.to_i
              json_text = response.to_binary
              data = parse_response_body(json_text)
              http_response = Response.new(status, data)
            else
              # The session changed under this page (docs decision 13):
              # the response is DISCARDED, and the caller settles with
              # an error instead of applying stale-session data.
              http_response = session_changed_response
            end
            settled = true
            block.call(http_response) if block
          end
        rescue => e
          # Exactly-once settle: a rejected fetch (network failure,
          # invalid URL) must still deliver a response -- a hanging
          # callback would hang the schema barrier and every REST
          # caller. An exception out of the caller's OWN block must
          # NOT settle a second time.
          raise e if settled
          settled = true
          if block
            block.call(Response.new(0,
              { "error" => "network error: #{e.class}: #{e.message}" }))
          end
        end
      end

      def session_changed_response
        Response.new(0,
          { "error" => "the session changed; this page is " \
                       "terminal (reload to continue)" })
      end

      # The X-Funicular-Epoch response header, nil when absent (no
      # headers surface, no such header, or a null value through the
      # JS bridge).
      def response_epoch(response)
        # @type var raw: untyped
        raw = response
        value = raw[:headers].get("X-Funicular-Epoch").to_s
        return nil if value.empty?
        return nil if value == "null" || value == "undefined"
        value
      rescue
        nil
      end
    end
  end
end
