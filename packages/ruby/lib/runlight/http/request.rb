# frozen_string_literal: true

module Runlight
  module Http
    # An incoming request, shaped like the Fetch API's Request so the routes read
    # the same as the TypeScript SDK's: an absolute URL, a method, headers, and a
    # body read as text or JSON.
    class Request
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
      # later, only when trusted.
      def self.from_rack(env)
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
        if !%w[GET HEAD].include?(method) && input
          input.rewind if input.respond_to?(:rewind)
          body = input.read.to_s
          input.rewind if input.respond_to?(:rewind)
        end
        url = "#{scheme}://#{host}#{path}#{query.empty? ? "" : "?#{query}"}"
        new(url, method: method, headers: headers, body: body, remote_address: env["REMOTE_ADDR"].to_s)
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
