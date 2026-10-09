# frozen_string_literal: true

module Runlight
  module Mail
    # A mail problem to show the person setting it up. `code` and `params` let the dashboard say it in
    # its own language; a service's own words, which only it can give, travel in `params["detail"]`.
    class MailError < StandardError
      attr_reader :code, :params

      # params: nil means `{ detail: message }`, as the TS default.
      def initialize(message, code = "mail_failed", params = nil)
        super(message)
        @code = code
        @params = params.nil? ? { "detail" => message } : params
      end
    end
  end
end
