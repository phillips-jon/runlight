# frozen_string_literal: true

module Runlight
  # Options as Ruby callers write them (symbols in snake_case, `rate_limit: 60`) read as the TypeScript option
  # names the port uses inside (`"rateLimit"`). String keys pass through as they are, so `"rateLimit" => 60`
  # works too.
  module Options
    module_function

    # The hash with each key in camelCase as a String. Nested Hashes listed in `deep` (by their camelCase
    # name) are converted too, and so are the Hashes inside an Array there.
    def normalize(options, deep: [])
      return {} if options.nil?

      options.each_with_object({}) do |(key, value), out|
        name = camel(key)
        out[name] = if deep.include?(name) && value.is_a?(Hash)
                      normalize(value)
                    elsif deep.include?(name) && value.is_a?(Array)
                      value.map { |item| item.is_a?(Hash) ? normalize(item) : item }
                    else
                      value
                    end
      end
    end

    def camel(key)
      return key if key.is_a?(String)

      key.to_s.gsub(/_([a-z0-9])/) { Regexp.last_match(1).upcase }
    end
  end
end
