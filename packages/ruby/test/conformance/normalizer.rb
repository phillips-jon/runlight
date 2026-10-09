# frozen_string_literal: true

module Conformance
  # The masking http-conformance.ts applies to answers, ported line by line:
  # ids and other random values become placeholders, so answers compare across
  # runs and implementations. Values are as Json.decode gives them (Hashes and
  # Arrays, so {} and [] stay apart).
  #
  # The regexes are JavaScript's, written to read the same way in Ruby: `\A`
  # and `\z` for JavaScript's `^` and `$` without the m flag, and JavaScript's
  # `\s` spelled out, since it matches Unicode spaces that Ruby's `\s` does not.
  # Text that is not UTF-8 is read byte by byte, as the patterns only name ASCII.
  module Normalizer
    # Headers every implementation must send the same, where it sends them.
    HEADERS = %w[
      content-type
      cache-control
      location
      set-cookie
      www-authenticate
      allow
      content-disposition
      content-security-policy
      x-frame-options
      referrer-policy
      x-content-type-options
      x-robots-tag
      access-control-allow-origin
      access-control-allow-methods
      access-control-allow-headers
      access-control-max-age
    ].freeze

    # The version and the implementation differ between ports and releases, so they are placeholders too.
    RANDOM = %w[token secret hint version library language ticket recovery].freeze

    SECRET_PARAM = "([?&](?:code|ticket|secret|code_challenge)=)[^&#\"'<>%s]+"
    PATTERNS = {
      text: [
        Regexp.new(format(SECRET_PARAM, Runlight::Js::SPACE)),
        /(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])/,
        /(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])/,
      ],
      bytes: [
        Regexp.new(format(SECRET_PARAM, "\\t\\n\\v\\f\\r "), Regexp::NOENCODING),
        /(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])/n,
        /(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])/n,
      ],
    }.freeze
    WHOLE_KEY = /\Arlo?_[A-Za-z0-9]+\z/n
    WHOLE_HEX = /\A[a-f0-9]{24}\z/n
    COOKIE = /\A([^=;]+)=([^;]*)/

    module_function

    # Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and signatures.
    def scrub(text)
      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      param, hex, key = PATTERNS[utf8.valid_encoding? ? :text : :bytes]
      text = utf8.valid_encoding? ? utf8 : text.b
      text = text.gsub(param) { "#{Regexp.last_match(1)}<value>" }
      text = text.gsub(hex, "<hex>")
      text.gsub(key, "<key>")
    end

    # Ids and other random values become "<key>", so answers compare across runs and implementations.
    def normalize(value, key = "")
      case value
      when Array then value.map { |v| normalize(v, key) }
      when Hash then value.to_h { |k, v| [k, normalize(v, k.to_s)] }
      when String
        bytes = value.b
        if RANDOM.include?(key) || bytes.match?(WHOLE_KEY) || bytes.match?(WHOLE_HEX)
          return "<#{key.empty? ? "value" : key}>"
        end

        scrub(value)
      else value
      end
    end

    # A Set-Cookie header with its value as <value>, unless it clears the cookie.
    def cookie_shape(header)
      header = Runlight::Js.scrub(header)
      header.sub(COOKIE) { "#{Regexp.last_match(1)}=#{Regexp.last_match(2).empty? ? "" : "<value>"}" }
    end

    # Answers as one text to compare: object keys sorted, since JavaScript's deepEqual ignores their order,
    # and written as Json writes them, so 1.0 and 1 are the same number as they are in JavaScript.
    def canonical(value)
      Runlight::Json.encode(sorted(value), pretty: true)
    end

    def sorted(value)
      case value
      when Array then value.map { |v| sorted(v) }
      when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [k.to_s, sorted(v)] }
      else value
      end
    end

    private_class_method :sorted
  end
end
