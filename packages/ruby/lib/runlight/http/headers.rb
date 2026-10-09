# frozen_string_literal: true

module Runlight
  module Http
    # Header names are matched without regard to case, as the Fetch API's
    # Headers are. get joins repeated values with ", "; Set-Cookie is kept
    # apart, since its values may hold commas, and read back with get_set_cookie.
    class Headers
      include Enumerable

      # init: a Hash of name to a String or an Array of Strings, or another Headers.
      def initialize(init = {})
        @values = {}
        if init.is_a?(Headers)
          init.all.each { |name, values| @values[name] = values.dup }
          return
        end
        (init || {}).each do |name, value|
          Array(value).each { |one| append(name.to_s, one.to_s) }
        end
      end

      def get(name)
        values = @values[name.to_s.downcase]
        values&.join(", ")
      end
      alias [] get

      def has?(name)
        @values.key?(name.to_s.downcase)
      end
      alias has has?

      def set(name, value)
        @values[name.to_s.downcase] = [clean(value)]
      end
      alias []= set

      def append(name, value)
        (@values[name.to_s.downcase] ||= []) << clean(value)
      end

      def delete(name)
        @values.delete(name.to_s.downcase)
      end

      def get_set_cookie
        (@values["set-cookie"] || []).dup
      end

      # Lowercase name to its values, in the order they were first set.
      def all
        @values
      end

      # Name and joined value pairs in name order, as iterating Fetch Headers gives them.
      def each
        return enum_for(:each) unless block_given?

        @values.keys.sort.each do |name|
          if name == "set-cookie"
            @values[name].each { |value| yield name, value }
          else
            yield name, @values[name].join(", ")
          end
        end
      end

      # The pairs as a Hash in name order, Set-Cookie joined.
      def to_h
        each.each_with_object({}) { |(name, value), out| out[name] = out.key?(name) ? "#{out[name]}, #{value}" : value }
      end

      def dup
        Headers.new(self)
      end

      private

      # Header values never carry a line break, so nothing a caller passes can add a header of its own.
      def clean(value)
        value.to_s.delete("\r\n\0").strip
      end
    end
  end
end
