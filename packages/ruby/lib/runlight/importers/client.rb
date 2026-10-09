# frozen_string_literal: true

require "time"

module Runlight
  module Importers
    # JSON over HTTPS with a timeout and a few retries on rate limits and server
    # errors, plus the few pieces of JavaScript the importers lean on (Date.parse,
    # String(), truthiness, and fields that may be missing). An importer takes one,
    # so tests can pass a fake fetcher and a sleep that does not wait.
    class Client
      ISO_DATE = /\A([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:\d{2})?)?\z/i
      private_constant :ISO_DATE

      # sleep: a callable that waits this many milliseconds.
      def initialize(fetcher = nil, sleep = nil)
        @fetcher = fetcher || Http::NetFetcher.new
        @sleep = sleep || ->(ms) { Kernel.sleep(ms / 1000.0) if ms.positive? }
      end

      def pause(ms)
        @sleep.call(ms)
      end

      # Fetches JSON, decoded. `init` may hold "headers", "method", and "body".
      def get_json(url, init = {})
        attempt = 1
        loop do
          options = { "headers" => { "accept" => "application/json" }.merge(init["headers"] || {}), "timeoutMs" => 20_000 }
          options["method"] = init["method"] unless init["method"].nil?
          options["body"] = init["body"] unless init["body"].nil?
          begin
            response = @fetcher.fetch(url, options)
          rescue Http::FetchError
            if attempt < 3
              attempt += 1
              next
            end
            host = Http::Url.new(url).host
            raise ImportError.new("Could not reach #{host}", "unreachable", { "host" => host })
          end
          return Json.decode(response.text) if response.ok?
          raise HttpError.new("The key or sign-in was refused", 401, "import_refused") if response.status == 401

          if (response.status == 429 || response.status >= 500) && attempt < 4
            wait = Client.number(response.headers.get("retry-after")) * 1000
            wait = 800 * attempt if (wait.is_a?(Float) && wait.nan?) || wait.zero?
            pause(whole([wait, 10_000].min))
            attempt += 1
            next
          end
          host = Http::Url.new(url).host
          raise HttpError.new("#{host} answered #{response.status}", response.status, "import_status",
                              { "host" => host, "status" => response.status.to_s })
        end
      end

      # JavaScript's Number() of a header or other text: 0 for none or blank, NaN for anything not a number.
      def self.number(text)
        Js.number(text)
      end

      # JavaScript's String.prototype.trim.
      def self.trim(text)
        Js.trim(text)
      end

      # JavaScript's encodeURIComponent.
      def self.encode_uri_component(text)
        Js.encode_uri_component(text)
      end

      # Whether JavaScript counts a value as true.
      def self.truthy?(value)
        Js.truthy?(value)
      end

      # JavaScript's String() of a value, as a template literal writes it.
      def self.str(value)
        Js.string(value)
      end

      # `object?.key`: the field, or UNDEFINED when the object or the field is missing. A nil field stays nil.
      def self.field(object, key)
        if object.is_a?(Hash)
          object.key?(key) ? object[key] : UNDEFINED
        elsif object.is_a?(Array) && key.is_a?(Integer)
          key >= 0 && key < object.length ? object[key] : UNDEFINED
        else
          UNDEFINED
        end
      end

      # `a ?? b`: b when a is nil or missing.
      def self.coalesce(value, fallback)
        value.nil? || value.equal?(UNDEFINED) ? fallback : value
      end

      # An object as JSON.stringify would keep it: the fields holding UNDEFINED left out.
      def self.defined(fields)
        fields.reject { |_, v| v.equal?(UNDEFINED) }
      end

      # Date.parse: milliseconds, or NaN for text that is not a date. The ISO
      # forms are read as JavaScript reads them (a date alone is UTC, a date and
      # time without an offset is local time); other forms go to Ruby's parser,
      # which takes what V8's fallback parser takes in the formats services send.
      def self.parse_date(text)
        return Float::NAN unless text.is_a?(String)

        text = Js.trim(text)
        if (m = ISO_DATE.match(text))
          year = m[1].to_i
          month = m[2].nil? ? 1 : m[2].to_i
          day = m[3].nil? ? 1 : m[3].to_i
          timed = !m[4].nil?
          hour = timed ? m[4].to_i : 0
          minute = timed ? m[5].to_i : 0
          second = m[6].nil? ? 0 : m[6].to_i
          ms = m[7].nil? ? 0 : m[7].ljust(3, "0")[0, 3].to_i
          if m[1] == "-000000" || month < 1 || month > 12 || day < 1 || day > days_in(year, month) || hour > 24 ||
             minute > 59 || second > 59 || (hour == 24 && (minute.positive? || second.positive? || ms.positive?))
            return Float::NAN
          end

          zone = m[8].to_s
          utc = utc_ms(year, month, day, hour, minute, second, ms)
          return utc if zone.upcase == "Z" || (!timed && zone.empty?)

          unless zone.empty?
            sign = zone[0] == "-" ? -1 : 1
            return utc - (sign * ((zone[1, 2].to_i * 60) + zone[4, 2].to_i) * 60_000)
          end
          # Local time, in the process's zone, as JavaScript reads it.
          return utc - (Time.at(utc.div(1000)).utc_offset * 1000)
        end
        return Float::NAN if text.empty? || !text.match?(/\d/)

        begin
          date = Time.parse(text)
        rescue ArgumentError, RangeError
          return Float::NAN
        end
        (date.to_r * 1000).floor
      end

      # `new Date(ms).toISOString()`; a RangeError where JavaScript throws one.
      def self.iso_string(ms)
        raise RangeError, "Invalid time value" if ms.is_a?(Float) && (ms.nan? || ms.infinite?)

        # TimeClip truncates toward zero.
        ms = ms.to_i
        raise RangeError, "Invalid time value" if ms.abs > 8_640_000_000_000_000

        seconds = ms.div(1000)
        millis = ms - (seconds * 1000)
        date = Time.at(seconds).utc
        year = date.year
        prefix = year >= 0 && year <= 9999 ? format("%04d", year) : format("%s%06d", year.negative? ? "-" : "+", year.abs)
        prefix + date.strftime("-%m-%dT%H:%M:%S") + format(".%03dZ", millis)
      end

      def self.utc_ms(year, month, day, hour, minute, second, ms)
        days = Time.utc(year, month, day).to_i
        ((days + (hour * 3600) + (minute * 60) + second) * 1000) + ms
      end

      # Days in a month of the proleptic Gregorian calendar.
      def self.days_in(year, month)
        case month
        when 2 then (year % 4).zero? && (year % 100 != 0 || (year % 400).zero?) ? 29 : 28
        when 4, 6, 9, 11 then 30
        else 31
        end
      end

      private_class_method :utc_ms, :days_in

      private

      # A float that is whole as an Integer, so it reads as JavaScript's number would.
      def whole(n)
        n.is_a?(Float) && n.finite? && n == n.floor ? n.to_i : n
      end
    end
  end
end
