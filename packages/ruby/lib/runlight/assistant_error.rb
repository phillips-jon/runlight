# frozen_string_literal: true

module Runlight
  # What went wrong with the assistant, as a code the dashboard says in its own words; a service's own
  # text goes in `params["detail"]`.
  # The code is text, as in TypeScript.
  class AssistantError < RuntimeError
    attr_reader :code, :params

    def initialize(message, code, params = {})
      super(message)
      @code = code
      @params = params
    end
  end
end
