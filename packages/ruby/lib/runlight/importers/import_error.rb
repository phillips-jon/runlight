# frozen_string_literal: true

module Runlight
  module Importers
    # Why an import stopped, as a code the dashboard says in its own words.
    class ImportError < RuntimeError
      attr_reader :code, :params

      def initialize(message, code, params = {})
        super(message)
        @code = code
        @params = params
      end
    end
  end
end
