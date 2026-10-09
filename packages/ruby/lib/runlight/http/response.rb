# frozen_string_literal: true

require "stringio"

module Runlight
  module Http
    # An answer, shaped like the Fetch API's Response. The body is text, or a
    # Proc that writes its parts to the writer it is given (anything with <<),
    # for answers too long to hold at once.
    class Response
      attr_reader :status, :headers

      def initialize(body = "", status: 200, headers: {})
        @body = body.is_a?(Proc) ? body : body.to_s
        @status = status
        @headers = headers.is_a?(Headers) ? headers : Headers.new(headers)
      end

      def self.json(data, status: 200, headers: {})
        new(Json.encode(data), status: status, headers: { "content-type" => "application/json" }.merge(headers))
      end

      def self.redirect(location, status: 302)
        new("", status: status, headers: { "location" => location })
      end

      def ok?
        @status >= 200 && @status < 300
      end

      # The whole body as text; a streamed body is run and captured.
      def text
        return @body if @body.is_a?(String)

        out = StringIO.new(+"")
        @body.call(out)
        @body = out.string
      end

      # The body as JSON. Raises Runlight::Json::ParseError when it is not.
      def json
        Json.decode(text)
      end

      def streamed?
        !@body.is_a?(String)
      end

      # Calls the block with each part of the body, as a Rack body's each does.
      def each_chunk(&block)
        return block.call(@body) if @body.is_a?(String)

        @body.call(Writer.new(block))
      end

      # [status, headers, body] for Rack. Header names are lowercase, as Rack 3 asks; Set-Cookie values are
      # one per line.
      def to_rack
        headers = {}
        @headers.all.each do |name, values|
          headers[name] = name == "set-cookie" ? values.join("\n") : values.join(", ")
        end
        [@status, headers, RackBody.new(self)]
      end

      # What a streamed body writes to: each part goes straight to the block.
      class Writer
        def initialize(block)
          @block = block
        end

        def <<(chunk)
          @block.call(chunk.to_s)
          self
        end

        def write(chunk)
          @block.call(chunk.to_s)
          chunk.to_s.bytesize
        end
      end

      # A Rack body that writes a Response's parts.
      class RackBody
        def initialize(response)
          @response = response
        end

        def each(&block)
          @response.each_chunk(&block)
        end
      end
    end
  end
end
