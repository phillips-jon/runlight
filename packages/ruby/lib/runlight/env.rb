# frozen_string_literal: true

module Runlight
  # Environment variables, trimmed, with an empty value read as unset.
  module Env
    module_function

    def get(name)
      value = ENV.fetch(name.to_s, nil)
      return nil unless value.is_a?(String)

      value = value.strip
      value.empty? ? nil : value
    end
  end
end
