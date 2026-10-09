# frozen_string_literal: true

module Runlight
  # The few JavaScript string and number rules the port has to keep exactly:
  # lengths and slices counted in UTF-16 units, trim() with JavaScript's idea of
  # white space, decodeURIComponent's strictness, String(value), Number(value),
  # Math.round, truthiness, property reads, and comparing text with `<`.
  #
  # Text that is not valid UTF-8 is first made valid as a browser's TextDecoder
  # would make it, each broken sequence becoming one U+FFFD (String#scrub does
  # exactly that). A slice that cuts a surrogate pair in two leaves U+FFFD in
  # place of the lone half, which is what the TypeScript SDK stores once it
  # writes the text out as UTF-8.
  module Js
    # The characters JavaScript's \s and trim() treat as white space, for a character class.
    SPACE = "\\t\\n\\v\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"

    TRIM = /\A[#{SPACE}]+|[#{SPACE}]+\z/
    private_constant :TRIM

    REPLACEMENT = "�"

    module_function

    # Text as valid UTF-8, each ill-formed sequence replaced by U+FFFD as the WHATWG decoder does.
    def scrub(text)
      text = text.to_s
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text.valid_encoding? ? text : text.scrub(REPLACEMENT)
    end

    # The length JavaScript gives a string: UTF-16 code units.
    def length(text)
      text = scrub(text)
      return text.bytesize if text.ascii_only?

      text.length + text.each_char.count { |c| c.ord > 0xFFFF }
    end

    # String.prototype.slice, counting UTF-16 code units.
    def slice(text, start, finish = nil)
      text = scrub(text)
      return text.dup if start.zero? && !finish.nil? && finish >= 0 && text.bytesize <= finish

      if text.ascii_only?
        count = text.bytesize
        from = start.negative? ? [0, count + start].max : [start, count].min
        to = if finish.nil? then count
             elsif finish.negative? then [0, count + finish].max
             else [finish, count].min
             end
        return to <= from ? +"" : text.byteslice(from, to - from)
      end
      units = text.encode(Encoding::UTF_16BE).unpack("n*")
      count = units.length
      from = start.negative? ? [0, count + start].max : [start, count].min
      to = if finish.nil? then count
           elsif finish.negative? then [0, count + finish].max
           else [finish, count].min
           end
      return +"" if to <= from

      part = units[from...to]
      part[0] = 0xFFFD if part[0].between?(0xDC00, 0xDFFF)
      part[-1] = 0xFFFD if part[-1].between?(0xD800, 0xDBFF)
      part.pack("n*").force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8, invalid: :replace, replace: REPLACEMENT)
    end

    # String.prototype.trim: JavaScript's white space and line terminators, at both ends.
    def trim(text)
      scrub(text).gsub(TRIM, "")
    end

    def lower(text)
      scrub(text).downcase
    end

    def upper(text)
      scrub(text).upcase
    end

    # decodeURIComponent, or nil where it would throw: a broken escape or bytes that are not UTF-8.
    def decode_uri_component(text)
      text = text.to_s
      return nil if text.match?(/%(?![0-9A-Fa-f]{2})/)

      decoded = text.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
      decoded.valid_encoding? ? decoded : nil
    end

    # encodeURIComponent(text).
    def encode_uri_component(text)
      scrub(text).b.gsub(/[^A-Za-z0-9\-_.!~*'()]/n) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::UTF_8)
    end

    # String(value) for the values the SDK passes it.
    def string(value)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      when Integer then value.to_s
      when Float
        if value.nan? then "NaN"
        elsif value.infinite? then value.positive? ? "Infinity" : "-Infinity"
        else Json.number(value)
        end
      when String then value
      when Symbol then value.to_s
      # An array is its items joined with commas, null and undefined as nothing.
      when Array then value.map { |v| v.nil? || v.equal?(UNDEFINED) ? "" : string(v) }.join(",")
      when Hash then "[object Object]"
      else value.equal?(UNDEFINED) ? "undefined" : value.to_s
      end
    end

    # Math.round: halves go up, toward positive infinity, so -2.5 becomes -2.
    def round(value)
      value = value.to_f
      return value if value.nan? || value.infinite?

      floor = value.floor.to_f
      # A double's distance from its floor is exact, so 0.49999999999999994 stays 0.
      value - floor >= 0.5 ? floor + 1 : floor
    end

    # Number(value).
    def number(value)
      return 0 if value.nil? || value == false
      return 1 if value == true
      return value if value.is_a?(Integer) || value.is_a?(Float)
      return number(string(value)) if value.is_a?(Array)
      return Float::NAN unless value.is_a?(String)

      text = trim(value)
      return 0 if text.empty?

      if (m = text.match(/\A0([xob])([0-9a-f]+)\z/i))
        kind = m[1].downcase
        digits = m[2].downcase
        valid = { "x" => /\A[0-9a-f]+\z/, "o" => /\A[0-7]+\z/, "b" => /\A[01]+\z/ }[kind]
        return Float::NAN unless digits.match?(valid)

        base = { "x" => 16, "o" => 8, "b" => 2 }[kind]
        return whole(digits.to_i(base).to_f)
      end
      return text.start_with?("-") ? -Float::INFINITY : Float::INFINITY if text.match?(/\A[+-]?Infinity\z/)
      return Float::NAN unless text.match?(/\A[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?\z/i)

      whole(Float(text.sub(/\A([+-]?)\./, '\10.').sub(/\.(?=e|\z)/i, "")))
    end

    # value[key]: UNDEFINED when there is no such property, and a TypeError for a property of null or
    # undefined, as JavaScript throws then.
    def get(value, key)
      if value.nil? || value.equal?(UNDEFINED)
        raise TypeError, "Cannot read properties of #{value.nil? ? "null" : "undefined"} (reading '#{key}')"
      end

      case value
      when Hash then value.key?(key.to_s) ? value[key.to_s] : UNDEFINED
      when Array
        return value.length if key == "length"

        index = key.is_a?(Integer) ? key : (key.to_s.match?(/\A(0|[1-9]\d*)\z/) ? key.to_i : nil)
        index && index < value.length ? value[index] : UNDEFINED
      when String then key == "length" ? length(value) : UNDEFINED
      else UNDEFINED
      end
    end

    # Whether JavaScript reads a value as true.
    def truthy?(value)
      return false if value.nil? || value.equal?(UNDEFINED) || value == false || value == ""
      return !value.zero? if value.is_a?(Integer)
      return !value.zero? && !value.nan? if value.is_a?(Float)

      true
    end

    # Whether typeof value is "object" and it is not null: an array or an object.
    def object?(value)
      value.is_a?(Hash) || value.is_a?(Array)
    end

    # JSON.parse of a body as Response.json() reads it: a byte order mark is skipped and bytes that are not
    # UTF-8 read as U+FFFD. Returns [whether it parsed, the value].
    def parse_json(text)
      text = scrub(text)
      text = text.delete_prefix("﻿")
      [true, Json.decode(text)]
    rescue Json::ParseError, EncodingError
      [false, nil]
    end

    # Orders two strings as JavaScript's `<` does, by UTF-16 code units: -1, 0, or 1.
    def compare(a, b)
      return 0 if a == b
      return a < b ? -1 : 1 if a.ascii_only? && b.ascii_only?

      utf16(a) < utf16(b) ? -1 : 1
    end

    # text.slice(0, length), counting UTF-16 code units. Where JavaScript would cut a pair in two and keep half
    # of a character, this leaves the whole character out, since Ruby text cannot hold half of one.
    def cut(text, limit)
      text = scrub(text)
      return text if text.bytesize <= limit

      units = 0
      text.each_char.with_index do |c, i|
        width = c.ord > 0xFFFF ? 2 : 1
        return text[0, i] if units + width > limit

        units += width
      end
      text
    end

    def utf16(text)
      scrub(text).encode(Encoding::UTF_16BE).b
    end

    def whole(n)
      n.finite? && n == n.floor && n.abs <= 2**62 ? n.to_i : n
    end

    private_class_method :utf16, :whole
  end
end
