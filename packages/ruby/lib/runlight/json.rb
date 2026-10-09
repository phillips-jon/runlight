# frozen_string_literal: true

require "json"

module Runlight
  # JSON written exactly as JavaScript's JSON.stringify writes it, so answers
  # match the TypeScript SDK byte for byte: slashes and Unicode as they are,
  # whole floats without a decimal point, numbers in JavaScript's own form,
  # and NaN or infinity as null.
  #
  # A Hash becomes an object (keys written with to_s, a value of
  # Runlight::UNDEFINED left out) and an Array an array (UNDEFINED written as
  # null). Symbols are written as strings. Anything else that responds to
  # `json_value` is written as what that returns. Decoding gives Hashes with
  # String keys, so {} and [] stay apart; a whole number past 2**53 reads as
  # a Float, as JSON.parse reads it.
  module Json
    ParseError = ::JSON::ParserError

    ESCAPES = {
      '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t",
    }.freeze
    private_constant :ESCAPES

    SAFE = 2**53
    private_constant :SAFE

    module_function

    def encode(value, pretty: false)
      out = +""
      pretty ? write_pretty(out, value, "") : write(out, value)
      out
    end

    # Parses JSON text. Raises Runlight::Json::ParseError when it is not JSON.
    def decode(text)
      value = ::JSON.parse(text.to_s, allow_nan: false, max_nesting: 512)
      text.to_s.match?(/\d{16}/) ? unsafe_to_float(value) : value
    end

    # Decodes, or gives nil for text that is not JSON.
    def try_decode(text)
      decode(text)
    rescue ParseError, EncodingError
      nil
    end

    # A number as JavaScript's String(number) writes it, "null" for NaN and infinity.
    def number(n)
      return n.to_s if n.is_a?(Integer)
      return "null" if n.nan? || n.infinite?
      return "0" if n.zero?

      negative = n.negative?
      text = n.abs.to_s
      mantissa, exponent = text.split("e")
      whole, fraction = mantissa.split(".")
      fraction = "" if fraction.nil? || fraction == "0"
      digits = whole + fraction
      point = whole.length + exponent.to_i
      stripped = digits.sub(/\A0+/, "")
      point -= digits.length - stripped.length
      digits = stripped.sub(/0+\z/, "")
      k = digits.length
      body =
        if k <= point && point <= 21
          digits + ("0" * (point - k))
        elsif point.positive? && point <= 21
          "#{digits[0, point]}.#{digits[point..]}"
        elsif point > -6 && point <= 0
          "0.#{"0" * -point}#{digits}"
        else
          e = point - 1
          sign = e.negative? ? "-" : "+"
          head = k == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
          "#{head}e#{sign}#{e.abs}"
        end
      negative ? "-#{body}" : body
    end

    # A string as JSON.stringify writes it.
    def string(text)
      text = text.to_s
      text = Js.scrub(text) unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
      escaped = text.gsub(/["\\\x00-\x1f]/) { |c| ESCAPES[c] || format("\\u%04x", c.ord) }
      "\"#{escaped}\""
    end

    def write(out, value)
      case value
      when nil then out << "null"
      when true then out << "true"
      when false then out << "false"
      when Integer, Float then out << number(value)
      when String then out << string(value)
      when Symbol then out << string(value.to_s)
      when Hash
        out << "{"
        first = true
        value.each do |key, item|
          next if item.equal?(UNDEFINED)

          out << "," unless first
          first = false
          out << string(key.to_s) << ":"
          write(out, item)
        end
        out << "}"
      when Array
        out << "["
        value.each_with_index do |item, i|
          out << "," if i.positive?
          write(out, item.equal?(UNDEFINED) ? nil : item)
        end
        out << "]"
      else
        if value.respond_to?(:json_value)
          write(out, value.json_value)
        elsif value.equal?(UNDEFINED)
          out << "null"
        else
          out << string(value.to_s)
        end
      end
    end

    def write_pretty(out, value, indent)
      value = value.json_value if !value.is_a?(Hash) && !value.is_a?(Array) && value.respond_to?(:json_value)
      inner = "#{indent}  "
      case value
      when Array
        return out << "[]" if value.empty?

        out << "[\n"
        value.each_with_index do |item, i|
          out << ",\n" if i.positive?
          out << inner
          write_pretty(out, item.equal?(UNDEFINED) ? nil : item, inner)
        end
        out << "\n" << indent << "]"
      when Hash
        items = value.reject { |_, item| item.equal?(UNDEFINED) }
        return out << "{}" if items.empty?

        out << "{\n"
        items.each_with_index do |(key, item), i|
          out << ",\n" if i.positive?
          out << inner << string(key.to_s) << ": "
          write_pretty(out, item, inner)
        end
        out << "\n" << indent << "}"
      else
        write(out, value)
      end
    end

    def unsafe_to_float(value)
      case value
      when Integer then value.abs >= SAFE ? value.to_f : value
      when Array then value.map { |item| unsafe_to_float(item) }
      when Hash then value.transform_values { |item| unsafe_to_float(item) }
      else value
      end
    end

    private_class_method :write, :write_pretty, :unsafe_to_float
  end
end
