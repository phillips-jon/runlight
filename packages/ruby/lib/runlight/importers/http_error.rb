# frozen_string_literal: true

module Runlight
  module Importers
    # A service answered with a status that is not success.
    class HttpError < ImportError
      attr_reader :status

      def initialize(message, status, code, params = {})
        super(message, code, params)
        @status = status
      end
    end
  end
end
