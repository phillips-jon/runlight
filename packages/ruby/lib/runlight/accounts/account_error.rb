# frozen_string_literal: true

module Runlight
  module Accounts
    # A problem with an account change, to show the person making it. A RangeError in TypeScript, and here,
    # with a `code` and `params` the dashboard words in its own language.
    class AccountError < RangeError
      attr_reader :code, :params

      def initialize(message, code, params = {})
        super(message)
        @code = code
        @params = params
      end
    end
  end
end
