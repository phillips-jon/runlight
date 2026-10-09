# frozen_string_literal: true

require "openssl"

module Runlight
  module Mail
    # Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
    # AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
    module Ses
      module_function

      # Signs a request; public for its test against AWS's published example.
      #
      # input: "method", "url" (a String or Http::Url), "body", "region", "service", "accessKeyId",
      # "secretAccessKey", "now" (milliseconds), and "headers" (name to value).
      def sign_v4(input)
        url = input["url"].is_a?(Http::Url) ? input["url"] : Http::Url.new(input["url"])
        amz_date = Time.at(input["now"].div(1000)).utc.strftime("%Y%m%dT%H%M%SZ")
        day = amz_date[0, 8]
        payload_hash = OpenSSL::Digest::SHA256.hexdigest(input["body"])
        headers = input["headers"].merge("host" => url.host, "x-amz-date" => amz_date)
        names = headers.keys.map { |h| h.to_s.downcase }.sort
        lower = {}
        headers.each { |k, v| lower[k.to_s.downcase] = Js.trim(v).gsub(/[#{Js::SPACE}]+/o, " ") }
        path = url.pathname.split("/", -1).map { |p| Transports.encode_uri_component(raw_url_decode(p)) }.join("/")
        # A stable sort on the name alone, as Array.prototype.sort is.
        pairs = url.search_params.each.to_a.each_with_index.sort do |(a, i), (b, j)|
          order = Js.compare(a[0], b[0])
          order.zero? ? i <=> j : order
        end.map(&:first)
        canonical = [
          input["method"],
          path.empty? ? "/" : path,
          pairs.map { |k, v| "#{Transports.encode_uri_component(k)}=#{Transports.encode_uri_component(v)}" }.join("&"),
          names.map { |n| "#{n}:#{lower[n]}\n" }.join,
          names.join(";"),
          payload_hash,
        ].join("\n")
        scope = "#{day}/#{input["region"]}/#{input["service"]}/aws4_request"
        to_sign = ["AWS4-HMAC-SHA256", amz_date, scope, OpenSSL::Digest::SHA256.hexdigest(canonical)].join("\n")
        key = OpenSSL::HMAC.digest("SHA256", "AWS4#{input["secretAccessKey"]}", day)
        key = OpenSSL::HMAC.digest("SHA256", key, input["region"])
        key = OpenSSL::HMAC.digest("SHA256", key, input["service"])
        key = OpenSSL::HMAC.digest("SHA256", key, "aws4_request")
        signature = OpenSSL::HMAC.hexdigest("SHA256", key, to_sign)
        headers.merge(
          "authorization" => "AWS4-HMAC-SHA256 Credential=#{input["accessKeyId"]}/#{scope}, SignedHeaders=#{names.join(";")}, Signature=#{signature}",
        )
      end

      # Sends one message. now: milliseconds; the clock when nil.
      def deliver(config, m, from, fetcher = nil, now = nil)
        region = Transports.trim(config["region"].to_s)
        raise MailError.new("That is not an AWS region, like us-east-1", "mail_region", {}) unless region.match?(/\A[a-z]{2}(-[a-z]+)+-\d\z/)

        url = Http::Url.new("https://email.#{region}.amazonaws.com/v2/email/outbound-emails")
        header_list = (m["headers"] || {}).map { |name, value| { "Name" => name.to_s, "Value" => value } }
        body = Json.encode({
          "FromEmailAddress" => from,
          "Destination" => { "ToAddresses" => [m["to"]] },
          "Content" => {
            "Simple" => {
              "Subject" => { "Data" => m["subject"], "Charset" => "UTF-8" },
              "Body" => { "Html" => { "Data" => m["html"], "Charset" => "UTF-8" }, "Text" => { "Data" => m["text"], "Charset" => "UTF-8" } },
              "Headers" => header_list,
            },
          },
        })
        headers = sign_v4({
          "method" => "POST",
          "url" => url,
          "body" => body,
          "region" => region,
          "service" => "ses",
          "accessKeyId" => Transports.trim(config["accessKeyId"].to_s),
          "secretAccessKey" => Transports.trim(config["secretAccessKey"].to_s),
          "now" => now || (Time.now.to_r * 1000).floor,
          "headers" => { "content-type" => "application/json" },
        })
        headers.delete("host")
        begin
          response = (fetcher || Http::NetFetcher.new).fetch(url.href, { "method" => "POST", "headers" => headers, "body" => body, "timeoutMs" => 20_000 })
        rescue Http::FetchError => e
          raise MailError.new("Could not reach Amazon SES: #{e.message}", "mail_unreachable", { "host" => "Amazon SES", "detail" => e.message })
        end
        return if response.ok?

        message = Transports.service_message(response.text)
        raise MailError.new("Amazon SES answered #{response.status}#{message.empty? ? "" : ": #{message}"}", "mail_refused",
                            { "host" => "Amazon SES", "detail" => "#{response.status}#{message.empty? ? "" : " #{message}"}" })
      end

      # rawurldecode: each %XX becomes its byte, and anything else stays as it is.
      def raw_url_decode(text)
        Js.scrub(text.b.gsub(/%([0-9A-Fa-f]{2})/n) { Regexp.last_match(1).hex.chr })
      end

      private_class_method :raw_url_decode
    end
  end
end
