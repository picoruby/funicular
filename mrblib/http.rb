module Funicular
  module HTTP
    CACHE_DB_NAME = 'funicular_http_cache'.freeze
    CACHE_STORE = 'responses'.freeze

    @cache = nil

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

    # Open (or reuse) the response cache store. Idempotent and safe to call
    # multiple times. Falls back to the in-memory backing if browser
    # IndexedDB is unavailable.
    def self.cache_init!
      cache = @cache
      return cache if cache
      @cache = IndexedDB::KVS.open(CACHE_DB_NAME, store: CACHE_STORE)
    end

    # Drop a single cached entry by URL key. No-op if the cache is not
    # initialized.
    def self.cache_purge(url)
      cache = @cache
      return nil unless cache
      cache.delete(url)
      nil
    end

    # Drop every cached entry. No-op if the cache is not initialized.
    def self.cache_clear
      cache = @cache
      return nil unless cache
      cache.clear
      nil
    end

    # Internal: read the cache for *url*. Returns the parsed entry hash or
    # nil. Lazily initializes the cache on first use so callers can pass
    # `cache:` without booting the SPA shell first.
    def self.cache_lookup(url)
      cache_init! unless @cache
      cache = @cache
      return nil unless cache
      cache[url]
    end

    # Internal: write *entry* (a Hash with status/data/cached_at) to the
    # cache. Awaits one extra Promise so the next request reliably hits.
    def self.cache_write(url, entry)
      cache_init! unless @cache
      cache = @cache
      return nil unless cache
      cache[url] = entry
      nil
    end

    def self.get(url, cache: nil, &block)
      request("GET", url, nil, cache: cache, &block)
    end

    def self.post(url, body = nil, cache: nil, &block)
      warn_unsupported_cache("post") if cache
      request("POST", url, body, &block)
    end

    def self.patch(url, body = nil, cache: nil, &block)
      warn_unsupported_cache("patch") if cache
      request("PATCH", url, body, &block)
    end

    def self.delete(url, cache: nil, &block)
      warn_unsupported_cache("delete") if cache
      request("DELETE", url, nil, &block)
    end

    def self.put(url, body = nil, cache: nil, &block)
      warn_unsupported_cache("put") if cache
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

      def warn_unsupported_cache(verb)
        puts "[Funicular::HTTP] cache: option is GET-only; ignoring on #{verb.upcase}"
      end

      def now_seconds
        # JavaScript Date.now() returns ms since epoch
        ms = JS.global[:Date].now # steep:ignore
        (ms.to_i / 1000)
      end

      def cache_hit?(entry, ttl)
        return false unless entry.is_a?(Hash)
        cached_at = entry["cached_at"]
        return false unless cached_at.is_a?(Integer)
        (now_seconds - cached_at) <= ttl
      end

      def serve_from_cache(entry, &block)
        status = entry["status"].to_i
        data = entry["data"]
        block.call(Response.new(status, data)) if block
      end

      def parse_response_body(text)
        return nil if text.nil?

        body = text.to_s
        return nil if body.empty?

        JSON.parse(body)
      rescue
        body
      end

      def request(method, url, body, cache: nil, &block)
        if method == "GET" && cache.is_a?(Integer) && cache > 0
          entry = cache_lookup(url)
          if cache_hit?(entry, cache)
            serve_from_cache(entry, &block)
            return
          end
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

        JS.global.fetch(url, options) do |response|
          status = response.status.to_i
          json_text = response.to_binary
          data = parse_response_body(json_text)
          # @type var status: Integer
          http_response = Response.new(status, data)

          if method == "GET" && cache.is_a?(Integer) && cache > 0 && http_response.ok
            cache_write(url, {
              "status" => status,
              "data" => data,
              "cached_at" => now_seconds
            })
          end

          block.call(http_response) if block
        end
      end
    end
  end
end
