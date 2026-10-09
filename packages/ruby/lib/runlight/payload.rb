# frozen_string_literal: true

require "json"

module Runlight
  # What the tracker sends, after validation. Anything malformed is dropped.
  #
  # A payload is a Hash {"kind" ("pageview", "event", or "engagement"), "site", "url" (an Http::Url),
  # "referrer", "title", "screenWidth", "screenHeight", "language", "name", "props", "pageviewId", "engagedMs",
  # "scroll"}, where nil stands for TypeScript's undefined. `props` is a Hash of String to String in
  # JavaScript's key order: keys that are array indexes first, in number order, then the rest as sent.
  module Payload
    MAX_BODY = 8 * 1024
    # One engagement ping covers at most the 30 minutes a session can idle.
    MAX_ENGAGED_MS = 30 * 60 * 1000
    MAX_PROPS = 30
    # A JSON escape, read left to right so an escaped backslash is never taken for the start of one: a
    # surrogate pair, a lone surrogate, or anything else escaped.
    ESCAPE = /\\(?:(?<pair>u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<lone>u[dD][89a-fA-F][0-9a-fA-F]{2})|.)/m
    private_constant :MAX_ENGAGED_MS, :MAX_PROPS, :ESCAPE

    module_function

    def str(value, max)
      value.is_a?(String) ? Js.slice(value, 0, max) : ""
    end

    def int(value, min, max)
      return nil unless value.is_a?(Integer) || value.is_a?(Float)

      value = value.to_f
      return nil if value.nan? || value.infinite?

      Js.round(value).clamp(min, max).to_i
    end

    def props(value)
      return nil unless value.is_a?(Hash)

      out = {}
      count = 0
      entries(value).each do |key, raw|
        break if count >= MAX_PROPS

        k = Js.slice(Js.trim(key), 0, 60)
        next if k.empty?

        if raw.is_a?(String)
          text = Js.slice(raw, 0, 500)
        elsif (raw.is_a?(Integer) || raw.is_a?(Float)) && raw.to_f.finite?
          # JSON.parse reads every number as a double, so a long integer is rounded as it is there.
          text = Js.string(raw.to_f)
        elsif raw == true || raw == false
          text = raw ? "true" : "false"
        else
          next
        end
        # Assigning out["__proto__"] in JavaScript sets the prototype, which a string cannot be, so
        # nothing is kept; it still counts.
        out[k] = text if k != "__proto__"
        count += 1
      end
      return nil if count.zero?

      entries(out).to_h
    end

    # An object's entries in JavaScript's order: keys that are array indexes first, ascending, then the
    # rest in the order they were added.
    def entries(object)
      indexes = []
      names = []
      object.each do |key, item|
        if key.match?(/\A(0|[1-9][0-9]{0,9})\z/) && key.to_i <= 4_294_967_294
          indexes << [key, item]
        else
          names << [key, item]
        end
      end
      indexes.sort_by { |key, _| key.to_i } + names
    end

    # Reads JSON as JSON.parse does where Ruby's parser differs: a lone surrogate escape reads as U+FFFD
    # (which is how the SDK stores it), a key given twice keeps its last value, and nesting has no
    # practical limit.
    def parse(text)
      text = text.gsub(ESCAPE) { |escape| Regexp.last_match(:lone) ? "�" : escape }
      ::JSON.parse(text, allow_nan: false, max_nesting: false, allow_duplicate_key: true)
    end

    def parse_payload(text)
      text = Js.scrub(text)
      return nil if Js.length(text) > MAX_BODY

      begin
        body = parse(text)
      rescue Json::ParseError
        return nil
      end
      return nil unless body.is_a?(Hash)

      get = ->(key) { body[key] }

      kind = get.call("k")
      return nil if kind != "pageview" && kind != "event" && kind != "engagement"

      url = Http::Url.parse(str(get.call("u"), 2048))
      return nil if url.nil? || (url.protocol != "http:" && url.protocol != "https:")

      name = Js.trim(str(get.call("n"), 120))
      return nil if kind == "event" && name.empty?

      pageview_id = str(get.call("i"), 32)
      return nil if !pageview_id.empty? && !pageview_id.match?(/\A[a-zA-Z0-9]+\z/)
      return nil if kind == "engagement" && pageview_id.empty?

      {
        "kind" => kind,
        "site" => str(get.call("s"), 64),
        "url" => url,
        "referrer" => str(get.call("r"), 2048),
        "title" => str(get.call("t"), 500),
        "screenWidth" => int(get.call("w"), 0, 20_000),
        "screenHeight" => int(get.call("h"), 0, 20_000),
        "language" => str(get.call("l"), 35),
        "name" => name,
        "props" => kind == "event" ? props(get.call("p")) : nil,
        "pageviewId" => pageview_id,
        "engagedMs" => kind == "engagement" ? int(get.call("e"), 0, MAX_ENGAGED_MS) || 0 : 0,
        "scroll" => int(get.call("d"), 0, 100),
      }
    end

    private_class_method :str, :int, :props, :entries, :parse
  end
end
