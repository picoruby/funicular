module Funicular
  module HTTP
    class Response
      attr_reader :data, :status, :ok, :etag

      # Every mainstream HTTP client calls the payload `body`; keep
      # that name working alongside `data`.
      alias body data

      # etag and cache_control are the raw response header values (nil
      # when absent). A 304 carries no body: data is nil there.
      def initialize(status, data, etag = nil, cache_control = nil)
        @status = status
        @ok = @status >= 200 && @status < 300
        @data = data
        @etag = etag
        @cache_control = cache_control
      end

      # 304 Not Modified: the representation the client already holds
      # is current. Not an error, and not a body either.
      def not_modified?
        @status == 304
      end

      # The server asked that this representation not be stored
      # (Cache-Control: no-store): the caller must not remember its
      # ETag.
      def no_store?
        cc = @cache_control
        return false unless cc
        cc.to_s.downcase.include?("no-store")
      end

      def error?
        return false if not_modified?
        return true unless @ok
        return false unless @data.is_a?(Hash)
        @data["error"] || @data["errors"]
      end

      # errors may be a String, an Array of messages, or -- the
      # ActiveModel::Errors#as_json shape -- a Hash of attribute name
      # to messages. Every shape flattens to one String here; Model
      # keeps the Hash shape as a Funicular::Model::Errors.
      def error_message
        return nil unless @data.is_a?(Hash)
        return @data["error"] if @data["error"]
        errors = @data["errors"]
        if errors.is_a?(Array)
          errors.join(", ")
        elsif errors.is_a?(Hash)
          parts = [] #: Array[String]
          errors.each do |attribute, messages|
            list = messages.is_a?(Array) ? messages.join(", ") : messages.to_s
            parts << "#{attribute} #{list}"
          end
          parts.join("; ")
        else
          errors
        end
      end
    end

    # headers: extra request headers (e.g. "If-None-Match" for a
    # conditional GET); nil sends none.
    def self.get(url, headers: nil, &block)
      request("GET", url, nil, headers, &block)
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

      def request(method, url, body, extra_headers = nil, &block)
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

        if extra_headers
          extra_headers.each { |name, value| headers[name.to_s] = value.to_s }
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
              http_response = Response.new(status, data,
                response_header(response, "ETag"),
                response_header(response, "Cache-Control"))
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
          # NOT settle a second time. It is re-raised into the JS
          # bridge, where it can vanish silently, so name the culprit
          # on the console first: a swallowed typo in a response
          # handler otherwise just freezes the page in its loading
          # state.
          if settled
            puts "[Funicular::HTTP] #{method} #{url} callback raised " \
                 "#{e.class}: #{e.message}"
            raise e
          end
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
        response_header(response, "X-Funicular-Epoch")
      end

      # One response header as a String, nil when absent (no headers
      # surface, no such header, or a null value through the JS bridge).
      def response_header(response, name)
        # @type var raw: untyped
        raw = response
        value = raw[:headers].get(name).to_s
        return nil if value.empty?
        return nil if value == "null" || value == "undefined"
        value
      rescue
        nil
      end
    end
  end
end
