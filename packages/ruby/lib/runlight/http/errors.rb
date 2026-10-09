# frozen_string_literal: true

module Runlight
  module Http
    # No answer came back: the connection was refused, timed out, or failed TLS. fetch() rejects with a
    # TypeError then.
    class FetchError < StandardError
      attr_reader :timed_out

      def initialize(message = "fetch failed", timed_out: false)
        super(message)
        @timed_out = timed_out
      end

      def timed_out?
        @timed_out
      end
    end

    # A body longer than the reader allows.
    class BodyTooLong < StandardError; end
  end
end
