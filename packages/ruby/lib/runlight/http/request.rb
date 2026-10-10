# frozen_string_literal: true

module Runlight
  module Http
    # An incoming request, shaped like the Fetch API's Request so the routes read
    # the same as the TypeScript SDK's: an absolute URL, a method, headers, and a
    # body read as text or JSON.
    class Request
      # The collect endpoint's limit; its payloads are under 8 KB.
      MAX_COLLECT_BODY = 16 * 1024

      # Everything else, such as a link import of 5,000 rows.
      MAX_BODY = 10 * 1024 * 1024

      # A body past its limit, for an answer of 413 rather than reading on.
      class TooLarge < StandardError; end

      attr_reader :url, :method, :headers, :remote_address

      # remote_address: the address the request came from, before any proxy header is read.
      def initialize(url, method: "GET", headers: {}, body: "", remote_address: "")
        @url = url.to_s
        @method = method.to_s.upcase
        @headers = headers.is_a?(Headers) ? headers : Headers.new(headers)
        @body = body.to_s
        @remote_address = remote_address.to_s
      end

      # A request from a Rack env: the scheme and host Rack reports, the path and query as sent, headers from
      # the HTTP_ keys, and the body read once. The client's address is REMOTE_ADDR; proxy headers are read
      # later, only when trusted. With read_body false the body is left for whoever reads it next. A body past
      # the path's limit raises TooLarge once one byte past it has been read.
      def self.from_rack(env, read_body: true)
        scheme = env["rack.url_scheme"] || "http"
        host = env["HTTP_HOST"]
        if host.nil? || host.empty?
          port = env["SERVER_PORT"].to_s
          default = (scheme == "https" && port == "443") || (scheme == "http" && port == "80") || port.empty?
          host = "#{env["SERVER_NAME"] || "localhost"}#{default ? "" : ":#{port}"}"
        end
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        path = "/#{path}" unless path.start_with?("/")
        query = env["QUERY_STRING"].to_s
        headers = Headers.new
        env.each do |key, value|
          next unless key.start_with?("HTTP_") && value.is_a?(String)

          headers.append(key.delete_prefix("HTTP_").downcase.tr("_", "-"), value)
        end
        type = env["CONTENT_TYPE"].to_s
        headers.set("content-type", type) unless type.empty?
        length = env["CONTENT_LENGTH"].to_s
        headers.set("content-length", length) unless length.empty?
        method = env["REQUEST_METHOD"].to_s.upcase
        body = +""
        input = env["rack.input"]
        if read_body && !%w[GET HEAD].include?(method) && input
          body = read_capped(env, limit_for(path))
          raise TooLarge, "Body over the limit" if body.nil?

          input.rewind if input.respond_to?(:rewind)
        end
        url = "#{scheme}://#{host}#{path}#{query.empty? ? "" : "?#{query}"}"
        new(url, method: method, headers: headers, body: body, remote_address: env["REMOTE_ADDR"].to_s)
      end

      # The most a body may hold at this path: little for the collect endpoint, more for everything else.
      def self.limit_for(path)
        path.end_with?("/e") ? MAX_COLLECT_BODY : MAX_BODY
      end

      # A Rack env's body, or nil when it is longer than limit. A Content-Length past the limit is refused
      # unread, and one under it is not trusted: at most limit and one more byte are ever read.
      def self.read_capped(env, limit)
        length = env["CONTENT_LENGTH"].to_s
        return nil if length.match?(/\A\d+\z/) && length.to_i > limit

        input = env["rack.input"]
        return "".b if input.nil?

        input.rewind if input.respond_to?(:rewind)
        body = "".b
        while body.bytesize <= limit && (chunk = input.read([64 * 1024, limit + 1 - body.bytesize].min))
          body << chunk
        end
        body.bytesize > limit ? nil : body
      end

      def text
        @body
      end

      # The body as JSON. Raises Runlight::Json::ParseError when it is not.
      def json
        Json.decode(@body)
      end

      def parsed_url
        Url.new(@url)
      end

      # The same request with other parts, as `new Request(request, init)` makes one.
      def with(url: nil, method: nil, headers: nil, body: nil)
        Request.new(url || @url, method: method || @method, headers: headers || @headers, body: body || @body,
                                 remote_address: @remote_address)
      end
    end
  end
end
