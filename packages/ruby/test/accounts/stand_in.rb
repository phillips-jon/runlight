# frozen_string_literal: true

module AccountsSupport
  # The little of a Runlight that accounts on the web reach for: its store, its mail, and the client's address.
  # Mail is kept in a list instead of sent; `mail_fails` makes sending raise.
  class StandIn
    attr_reader :store, :sent
    attr_accessor :mail, :mail_fails

    def initialize(store)
      @store = store
      @sent = []
      @mail = nil
      @mail_fails = nil
    end

    def mail_settings
      @mail
    end

    def send_mail(message)
      raise @mail_fails unless @mail_fails.nil?

      @sent << message
    end

    # The last X-Forwarded-For entry, else the connection's address, as Runlight reads it by default.
    def client_ip(request, context = {})
      header = request.headers.get("x-forwarded-for")
      if header && !header.strip.empty?
        parts = header.split(",").map(&:strip).reject(&:empty?)
        return parts.last.to_s
      end
      context["ip"] || ""
    end
  end
end
