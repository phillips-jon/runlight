# frozen_string_literal: true

module Runlight
  # A setting refused, such as a site's domain or the assistant's service, as a code the dashboard says
  # in its own words.
  # The code is text, as in TypeScript.
  class SettingsError < RangeError
    attr_reader :code, :params

    def initialize(message, code, params = {})
      super(message)
      @code = code
      @params = params
    end
  end
end
