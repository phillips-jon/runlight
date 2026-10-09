# frozen_string_literal: true

module Runlight
  module Http
    # Query parameters as JavaScript's URLSearchParams reads and writes them:
    # pairs kept in order, `+` read as a space, and written back in the
    # application/x-www-form-urlencoded form. A name like `a[]` or `a.b` is
    # kept exactly as sent.
    class SearchParams
      include Enumerable

      # init: a query string (a leading "?" is dropped) or a Hash of name to value.
      def initialize(init = "")
        @pairs = []
        if init.is_a?(Hash)
          init.each { |name, value| @pairs << [name.to_s, value.to_s] }
          return
        end
        text = init.to_s.delete_prefix("?")
        text.split("&").each do |part|
          next if part.empty?

          name, value = part.split("=", 2)
          @pairs << [self.class.decode(name), self.class.decode(value || "")]
        end
      end

      def get(name)
        pair = @pairs.find { |key, _| key == name }
        pair && pair[1]
      end
      alias [] get

      def get_all(name)
        @pairs.select { |key, _| key == name }.map { |_, value| value }
      end

      def has?(name)
        @pairs.any? { |key, _| key == name }
      end
      alias has has?

      def set(name, value)
        found = false
        pairs = []
        @pairs.each do |pair|
          if pair[0] != name
            pairs << pair
          elsif !found
            pairs << [name, value.to_s]
            found = true
          end
        end
        pairs << [name, value.to_s] unless found
        @pairs = pairs
      end

      def append(name, value)
        @pairs << [name.to_s, value.to_s]
      end

      def delete(name)
        @pairs.reject! { |key, _| key == name }
      end

      def keys
        @pairs.map(&:first)
      end

      def each(&block)
        return enum_for(:each) unless block

        @pairs.each { |name, value| block.call(name, value) }
      end

      def size
        @pairs.size
      end

      def to_s
        @pairs.map { |name, value| "#{self.class.encode(name)}=#{self.class.encode(value)}" }.join("&")
      end

      def self.decode(text)
        bytes = text.tr("+", " ").b.gsub(/%([0-9A-Fa-f]{2})/n) { Regexp.last_match(1).hex.chr }
        # Bytes that are not UTF-8 become U+FFFD, as URLSearchParams decodes them.
        Js.scrub(bytes)
      end

      # The form encoding: letters, digits, and *-._ as they are, spaces as +, the rest escaped.
      def self.encode(text)
        Js.scrub(text).b.gsub(/[^A-Za-z0-9*\-._ ]/n) { |c| format("%%%02X", c.ord) }.tr(" ", "+").force_encoding(Encoding::UTF_8)
      end
    end
  end
end
