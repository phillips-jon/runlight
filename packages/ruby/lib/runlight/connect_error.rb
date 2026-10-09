# frozen_string_literal: true

module Runlight
  # Why connecting failed, as a code the dashboard says in its own words. The first four (expired, denied,
  # refused, token) come back from the consent page, the rest (url, unreachable, not_runlight, endpoints, old,
  # register) from starting.
  # The code is text, as in TypeScript.
  class ConnectError < RangeError
    attr_reader :code, :params

    def initialize(message, code, params = {})
      super(message)
      @code = code
      @params = params
    end
  end
end
