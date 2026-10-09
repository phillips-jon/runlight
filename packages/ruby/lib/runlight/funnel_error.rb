# frozen_string_literal: true

module Runlight
  # Why a funnel was refused, as a code the dashboard says in its own words.
  # The code is text, as in TypeScript.
  class FunnelError < RuntimeError
    attr_reader :code, :params

    def initialize(message, code, params = {})
      super(message)
      @code = code
      @params = params
    end
  end
end
