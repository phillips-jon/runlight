# frozen_string_literal: true

module Conformance
  # The servers a scenario stands in for, as the fake fetch in http-conformance.ts
  # plays them: a request goes to the first upstream whose url its URL starts with
  # (and whose method matches, when one is given); a request none matches fails as
  # a network error does. Every request is recorded, matched or not.
  class UpstreamFetcher
    # upstream: the scenario's upstream entries, as Json.decode gives them.
    def initialize(upstream)
      @upstream = upstream
      @fetched = []
    end

    def fetch(url, init = {})
      url = url.to_s
      method = (init["method"] || "GET").to_s.upcase
      given = {}
      Runlight::Http::Headers.new(init["headers"] || {}).each { |name, value| given[name] = value }
      given = given.sort.to_h
      text = init["body"].to_s
      seen = { "method" => method, "url" => url }
      seen["headers"] = given unless given.empty?
      seen["body"] = self.class.sent_body(text, given["content-type"] || "") unless text.empty?
      @fetched << { "seen" => seen, "text" => text }

      match = @upstream.find do |u|
        url.start_with?(u["url"].to_s) && (!Runlight::Js.truthy?(u["method"]) || u["method"] == method)
      end
      raise Runlight::Http::FetchError, "fetch failed" if match.nil?

      has_body = match.key?("body")
      sent = match["body"]
      body = if !has_body then ""
             elsif sent.is_a?(String) then sent
             else Runlight::Json.encode(sent)
             end
      # typeof null is "object" too, so a null body is sent as JSON.
      json = has_body && !sent.is_a?(String) && !sent.is_a?(Numeric) && sent != true && sent != false
      headers = json ? { "content-type" => "application/json" } : {}
      (match["headers"] || {}).each { |name, value| headers[name] = Runlight::Js.string(value) }
      # The cap a real fetcher keeps, so code that reads only the start of a page sees what it would.
      max_bytes = init["maxBytes"].nil? ? nil : Integer(init["maxBytes"])
      if !max_bytes.nil? && body.bytesize > max_bytes
        raise Runlight::Http::BodyTooLong, "Body over #{max_bytes} bytes" unless Runlight::Js.truthy?(init["truncate"])

        body = body.byteslice(0, max_bytes)
      end
      Runlight::Http::Response.new(body, status: Integer(match["status"] || 200), headers: headers)
    end

    # The requests made since the last take ([{"seen" =>, "text" =>}, ...]), and forgets them.
    def take
      out = @fetched
      @fetched = []
      out
    end

    # A body another server was sent, as JSON or form fields when it is one of those, else its text.
    def self.sent_body(text, type)
      if type.start_with?("application/x-www-form-urlencoded")
        fields = {}
        Runlight::Http::SearchParams.new(text).each { |name, value| fields[name] = value }
        return fields
      end
      Runlight::Json.decode(text)
    rescue Runlight::Json::ParseError, EncodingError
      text
    end
  end
end
