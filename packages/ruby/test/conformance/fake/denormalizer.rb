# frozen_string_literal: true

require "openssl"

module Conformance
  module Fake
    # Normalizing run backwards: each placeholder in an expected answer becomes a
    # fresh value of the shape that normalizes to it (24 hex digits for a whole
    # "<k>", 32 for "<hex>" in text, an rl_ key for "<key>", 40 hex digits for a
    # secret query value), so the runner's masking is exercised on values it has
    # never seen. Values are made from a counter, so a run is repeatable.
    class Denormalizer
      def initialize
        @made = 0
      end

      def value(value, key = "")
        case value
        when Array then value.map { |v| self.value(v, key) }
        when Hash then value.to_h { |k, v| [k, self.value(v, k.to_s)] }
        when String then text(value, key)
        else value
        end
      end

      def text(text, key = "")
        return hex(24) if text == "<#{key.empty? ? "value" : key}>"

        text = text.gsub(/([?&](?:code|ticket|secret|code_challenge)=)<value>/) { "#{Regexp.last_match(1)}#{hex(40)}" }
        text = text.gsub("<hex>") { hex(32) }
        text.gsub("<key>") { "rl_#{letters(24)}" }
      end

      # A Set-Cookie line with a fresh value where it says <value>.
      def cookie(line)
        line.sub(/\A([^=;]+)=<value>/) { "#{Regexp.last_match(1)}=#{letters(16)}" }
      end

      def hex(length)
        out = +""
        while out.length < length
          out << OpenSSL::Digest::SHA256.hexdigest("fake #{@made}")
          @made += 1
        end
        out[0, length]
      end

      # Letters that are never hex digits, so no run of them reads as hex.
      def letters(length)
        alphabet = "GHJKMNPQRSTVWXYZghjkmnpqrstvwxyz"
        hex(length).each_char.map { |c| alphabet[(c.hex * 2 % 32) + (@made % 2)] }.join
      end
    end
  end
end
