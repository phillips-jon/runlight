# frozen_string_literal: true

module Runlight
  # A JSON-RPC error with its own code, such as -32602 for an unknown tool, answered with its message as it is.
  class McpError < RuntimeError
    attr_reader :code

    def initialize(message, code)
      super(message)
      @code = code
    end
  end
end
