# frozen_string_literal: true

module Runlight
  # A link that cannot be made. `code` and `params` let the dashboard say it in its own language.
  # The code is text, as in TypeScript.
  class LinkError < RuntimeError
    attr_reader :code, :params

    def initialize(message, code, params = {})
      super(message)
      @code = code
      @params = params
    end
  end
end
