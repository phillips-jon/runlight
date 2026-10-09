# frozen_string_literal: true

module Runlight
  module Mail
    # Sends mail through the service a site picked. A message is a Hash shaped as TS's Message:
    # "to", "from", "fromName" (optional), "subject", "html", "text", and "headers" (optional extra
    # headers, such as List-Unsubscribe). A config is "service" plus its fields, every value a String,
    # as typed in the dashboard.
    module Transports
      # Every service Runlight can send through, and what each needs.
      SERVICES = [
        { "id" => "ses", "name" => "Amazon SES", "fields" => [
          { "name" => "region", "label" => "Region", "placeholder" => "us-east-1" },
          { "name" => "accessKeyId", "label" => "Access key ID" },
          { "name" => "secretAccessKey", "label" => "Secret access key", "secret" => true },
        ] },
        { "id" => "resend", "name" => "Resend", "fields" => [{ "name" => "apiKey", "label" => "API key", "secret" => true, "placeholder" => "re_..." }] },
        { "id" => "postmark", "name" => "Postmark", "fields" => [
          { "name" => "serverToken", "label" => "Server API token", "secret" => true },
          { "name" => "stream", "label" => "Message stream", "optional" => true, "placeholder" => "outbound" },
        ] },
        { "id" => "sendgrid", "name" => "SendGrid", "fields" => [{ "name" => "apiKey", "label" => "API key", "secret" => true, "placeholder" => "SG...." }] },
        { "id" => "mailgun", "name" => "Mailgun", "fields" => [
          { "name" => "domain", "label" => "Sending domain", "placeholder" => "mg.example.com" },
          { "name" => "apiKey", "label" => "API key", "secret" => true },
          { "name" => "region", "label" => "Region", "options" => %w[us eu] },
        ] },
        { "id" => "brevo", "name" => "Brevo", "fields" => [{ "name" => "apiKey", "label" => "API key", "secret" => true, "placeholder" => "xkeysib-..." }] },
        { "id" => "mailjet", "name" => "Mailjet", "fields" => [
          { "name" => "apiKey", "label" => "API key" },
          { "name" => "secretKey", "label" => "Secret key", "secret" => true },
        ] },
        { "id" => "mailersend", "name" => "MailerSend", "fields" => [{ "name" => "apiKey", "label" => "API token", "secret" => true, "placeholder" => "mlsn...." }] },
        { "id" => "sparkpost", "name" => "SparkPost", "fields" => [
          { "name" => "apiKey", "label" => "API key", "secret" => true },
          { "name" => "region", "label" => "Region", "options" => %w[us eu] },
        ] },
        { "id" => "smtp", "name" => "SMTP", "fields" => [
          { "name" => "host", "label" => "Host", "placeholder" => "smtp.example.com" },
          { "name" => "port", "label" => "Port", "placeholder" => "587" },
          { "name" => "security", "label" => "Security", "options" => %w[starttls tls none] },
          { "name" => "username", "label" => "Username", "optional" => true },
          { "name" => "password", "label" => "Password", "secret" => true, "optional" => true },
        ] },
        { "id" => "webhook", "name" => "Webhook", "fields" => [
          { "name" => "url", "label" => "URL", "placeholder" => "https://example.com/hooks/mail" },
          { "name" => "secret", "label" => "Signing secret", "secret" => true, "optional" => true },
        ] },
      ].freeze

      module_function

      def address(m)
        name = m["fromName"].to_s
        name.empty? ? m["from"].to_s : "#{name.gsub(/["\\\r\n]/, "")} <#{m["from"]}>"
      end

      # The error a mail service explains itself with, from its JSON or XML reply,
      # and never the raw body: a reply is shown to the dashboard, so an address
      # that is not a mail service must not be able to put its page there.
      def service_message(reply)
        reply = Js.scrub(reply)
        parsed = Json.try_decode(reply)
        # JSON.parse fails, or reading a field of null does, and either way the XML form is tried.
        if parsed.nil?
          m = reply.match(%r{<Message>([^<]{1,200})</Message>})
          return m ? trim(m[1]) : ""
        end
        first = lambda do |v|
          case v
          when String then v
          when Array then first.call(v[0])
          when Hash then first.call(v["message"])
          else ""
          end
        end
        %w[message Message error errors ErrorMessage].each do |name|
          text = first.call(parsed.is_a?(Hash) ? parsed[name] : nil)
          return slice16(text, 200) unless text.empty?
        end
        ""
      end

      # POSTs to a service, with the errors the dashboard shows. init: "headers" and "body".
      def post(fetcher, url, init, explains = true)
        begin
          response = fetcher.fetch(url, { "method" => "POST", "headers" => init["headers"], "body" => init["body"], "timeoutMs" => 20_000 })
        rescue Http::FetchError => e
          host = Http::Url.new(url).host
          raise MailError.new("Could not reach #{host}: #{e.message}", "mail_unreachable", { "host" => host, "detail" => e.message })
        end
        return if response.ok?

        message = explains ? service_message(response.text) : ""
        host = Http::Url.new(url).host
        raise MailError.new("#{host} answered #{response.status}#{message.empty? ? "" : ": #{message}"}", "mail_refused",
                            { "host" => host, "detail" => "#{response.status}#{message.empty? ? "" : " #{message}"}" })
      end

      def json(headers = {})
        { "content-type" => "application/json" }.merge(headers)
      end

      # Basic auth over the UTF-8 bytes, so a key with any character is sent.
      def basic(user, pass)
        "Basic #{[Js.scrub("#{user}:#{pass}").b].pack("m0")}"
      end

      # Checks a config has what its service needs, before anything is saved or sent.
      def check_config(config)
        service = nil
        SERVICES.each { |s| service = s if s["id"] == config["service"] }
        raise MailError.new("Pick a mail service", "mail_service", {}) if service.nil?

        service["fields"].each do |f|
          value = config[f["name"]].nil? ? nil : config[f["name"]].to_s
          if !f["optional"] && (value.nil? || trim(value).empty?)
            raise MailError.new("Enter the #{Js.lower(f["label"])}", "mail_field", { "field" => f["name"] })
          end
          next unless f["options"] && !value.nil? && !value.empty? && !f["options"].include?(value)

          options = f["options"].join(", ")
          raise MailError.new("#{f["label"]} must be one of #{options}", "mail_option", { "field" => f["name"], "options" => options })
        end
        url = config["url"].to_s
        if config["service"] == "webhook" && !url.match?(%r{\Ahttps://}) && !url.match?(%r{\Ahttp://(localhost|127\.0\.0\.1)(:\d+)?(/|\z)})
          raise MailError.new("The webhook URL must use https", "mail_https", {})
        end
        if config["service"] == "webhook" && Http::Url.parse(url).nil?
          raise MailError.new("Enter the webhook's whole URL, like https://example.com/hooks/mail", "mail_url", {})
        end
        # A port a socket can connect to, read with Number() as the SMTP client reads it.
        port = Smtp.port_number(config["port"].to_s)
        if config["service"] == "smtp" && !(port.finite? && port == port.floor && port >= 1 && port <= 65_535)
          raise MailError.new("The port must be a whole number from 1 to 65535", "mail_port", {})
        end
      end

      # Sends one message through the configured service. now: milliseconds, for SES's signature; the
      # clock when nil.
      def deliver(config, m, fetcher = nil, now = nil)
        check_config(config)
        fetcher ||= Http::NetFetcher.new
        headers = m["headers"] || {}
        has_name = !m["fromName"].to_s.empty?
        case config["service"]
        when "resend"
          post(fetcher, "https://api.resend.com/emails", {
            "headers" => json("authorization" => "Bearer #{config["apiKey"]}"),
            "body" => Json.encode({ "from" => address(m), "to" => [m["to"]], "subject" => m["subject"], "html" => m["html"], "text" => m["text"], "headers" => headers }),
          })
          return
        when "postmark"
          list = headers.map { |name, value| { "Name" => name.to_s, "Value" => value } }
          post(fetcher, "https://api.postmarkapp.com/email", {
            "headers" => json("accept" => "application/json", "x-postmark-server-token" => config["serverToken"]),
            "body" => Json.encode({
              "From" => address(m), "To" => m["to"], "Subject" => m["subject"], "HtmlBody" => m["html"], "TextBody" => m["text"],
              "MessageStream" => config["stream"].to_s.empty? ? "outbound" : config["stream"],
              "Headers" => list,
            }),
          })
          return
        when "sendgrid"
          post(fetcher, "https://api.sendgrid.com/v3/mail/send", {
            "headers" => json("authorization" => "Bearer #{config["apiKey"]}"),
            "body" => Json.encode({
              "personalizations" => [{ "to" => [{ "email" => m["to"] }] }],
              "from" => { "email" => m["from"] }.merge(has_name ? { "name" => m["fromName"] } : {}),
              "subject" => m["subject"],
              "content" => [{ "type" => "text/plain", "value" => m["text"] }, { "type" => "text/html", "value" => m["html"] }],
              "headers" => headers,
            }),
          })
          return
        when "mailgun"
          form = Http::SearchParams.new({ "from" => address(m), "to" => m["to"], "subject" => m["subject"], "html" => m["html"], "text" => m["text"] })
          headers.each { |k, v| form.set("h:#{k}", v) }
          host = config["region"] == "eu" ? "api.eu.mailgun.net" : "api.mailgun.net"
          post(fetcher, "https://#{host}/v3/#{encode_uri_component(config["domain"].to_s)}/messages", {
            "headers" => { "authorization" => basic("api", config["apiKey"]), "content-type" => "application/x-www-form-urlencoded" },
            "body" => form.to_s,
          })
          return
        when "brevo"
          post(fetcher, "https://api.brevo.com/v3/smtp/email", {
            "headers" => json("api-key" => config["apiKey"], "accept" => "application/json"),
            "body" => Json.encode({ "sender" => { "email" => m["from"] }.merge(has_name ? { "name" => m["fromName"] } : {}), "to" => [{ "email" => m["to"] }], "subject" => m["subject"],
                                    "htmlContent" => m["html"], "textContent" => m["text"], "headers" => headers }),
          })
          return
        when "mailjet"
          post(fetcher, "https://api.mailjet.com/v3.1/send", {
            "headers" => json("authorization" => basic(config["apiKey"], config["secretKey"])),
            "body" => Json.encode({
              "Messages" => [{ "From" => { "Email" => m["from"] }.merge(has_name ? { "Name" => m["fromName"] } : {}), "To" => [{ "Email" => m["to"] }], "Subject" => m["subject"],
                               "TextPart" => m["text"], "HTMLPart" => m["html"], "Headers" => headers }],
            }),
          })
          return
        when "mailersend"
          list = headers.map { |name, value| { "name" => name.to_s, "value" => value } }
          post(fetcher, "https://api.mailersend.com/v1/email", {
            "headers" => json("authorization" => "Bearer #{config["apiKey"]}"),
            "body" => Json.encode({
              "from" => { "email" => m["from"] }.merge(has_name ? { "name" => m["fromName"] } : {}), "to" => [{ "email" => m["to"] }], "subject" => m["subject"], "html" => m["html"], "text" => m["text"],
            }.merge(list.empty? ? {} : { "headers" => list })),
          })
          return
        when "sparkpost"
          post(fetcher, "https://#{config["region"] == "eu" ? "api.eu.sparkpost.com" : "api.sparkpost.com"}/api/v1/transmissions", {
            "headers" => json("authorization" => config["apiKey"]),
            "body" => Json.encode({
              "recipients" => [{ "address" => { "email" => m["to"] } }],
              "content" => { "from" => has_name ? { "email" => m["from"], "name" => m["fromName"] } : m["from"], "subject" => m["subject"], "html" => m["html"], "text" => m["text"], "headers" => headers },
            }),
          })
          return
        when "ses"
          Ses.deliver(config, m, address(m), fetcher, now)
          return
        when "smtp"
          Smtp.deliver(config, m, address(m))
          return
        when "webhook"
          body = Json.encode({ "to" => m["to"], "from" => m["from"], "fromName" => m["fromName"] || "", "subject" => m["subject"], "html" => m["html"], "text" => m["text"], "headers" => headers })
          secret = config["secret"].to_s
          signature = secret.empty? ? {} : { "x-runlight-signature" => "sha256=#{Hashing.hmac(secret, body)}" }
          # A webhook can be any address, so only its status comes back.
          post(fetcher, config["url"], { "headers" => json(signature), "body" => body }, false)
          return
        end
        raise MailError.new("Unknown mail service \"#{config["service"]}\"", "mail_service", {})
      end

      # JavaScript's encodeURIComponent.
      def encode_uri_component(text)
        Js.encode_uri_component(text)
      end

      # JavaScript's String.prototype.trim, which also takes Unicode spaces.
      def trim(text)
        Js.trim(text)
      end

      # The first `units` UTF-16 code units, as String.prototype.slice counts them. A pair cut in half keeps
      # no half; JavaScript would keep a lone surrogate, which Ruby text cannot hold.
      def slice16(text, units)
        Js.cut(text, units)
      end

      private_class_method :post, :json, :basic
    end
  end
end
