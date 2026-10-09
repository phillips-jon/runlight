# frozen_string_literal: true

require "json"

module Runlight
  # Where a visitor is, from a hosting platform's headers or a database lookup.
  #
  # A location is a Hash {"country", "region", "city"}: the country ISO 3166-1 alpha-2 in upper case, the
  # region ISO 3166-2 such as "US-CA". A lookup is a callable taking an IP address and giving nil or a Hash
  # with any of those keys, such as one made by file_lookup from an MMDB file.
  #
  # Where the TypeScript would throw a TypeError on a value of the wrong type (a number for a city), this
  # raises one too, and the callers rescue it where the TypeScript catches it.
  module Geo
    EMPTY = { "country" => "", "region" => "", "city" => "" }.freeze
    # A city's trailing bracketed district.
    DISTRICT = /[#{Js::SPACE}]*\([^)]*\)[#{Js::SPACE}]*\z/
    private_constant :EMPTY, :DISTRICT

    module_function

    def decode(value)
      return "" if value.nil? || value == ""

      Js.trim(Js.decode_uri_component(value) || value)
    end

    def clean(location)
      country = Js.slice(Js.upper(text(location["country"])), 0, 2)
      country = "" if !country.match?(/\A[A-Z]{2}\z/) || country == "XX" || country == "T1"
      # A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
      # that has no codes ("California") is kept readable, as "US-California".
      raw = Js.trim(text(location["region"]))
      region = raw.match?(/\A([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}\z/) ? raw.upcase : Js.slice(raw, 0, 80)
      region = "#{country}-#{region}" if region != "" && !region.match?(/\A[A-Z]{2}-/) && country != ""
      region = "" if country == ""
      city = country == "" ? "" : Js.slice(text(location["city"]), 0, 100)
      { "country" => country, "region" => region, "city" => city }
    end

    # A String, or "" for nil, as `value ?? ""` gives; anything else has no string methods in JavaScript.
    def text(value)
      return "" if value.nil? || value.equal?(UNDEFINED)
      raise TypeError, "Not a string" unless value.is_a?(String)

      value
    end

    # Location from the headers a hosting platform adds, if any.
    def location_from_headers(headers)
      vercel = headers.get("x-vercel-ip-country")
      if !vercel.nil? && vercel != ""
        return clean({
                       "country" => vercel,
                       "region" => decode(headers.get("x-vercel-ip-country-region")),
                       "city" => decode(headers.get("x-vercel-ip-city")),
                     })
      end
      cloudflare = headers.get("cf-ipcountry")
      if !cloudflare.nil? && cloudflare != ""
        return clean({
                       "country" => cloudflare,
                       "region" => decode(headers.get("cf-region-code")),
                       "city" => decode(headers.get("cf-ipcity")),
                     })
      end
      netlify = headers.get("x-nf-geo")
      if !netlify.nil? && netlify != ""
        begin
          geo = ::JSON.parse(atob(netlify), allow_nan: false, max_nesting: false, allow_duplicate_key: true)
          # Reading a field of null is a TypeError.
          return nil if geo.nil?

          return clean({
                         "country" => field(field(geo, "country"), "code"),
                         "region" => field(field(geo, "subdivision"), "code"),
                         "city" => field(geo, "city"),
                       })
        rescue Json::ParseError, TypeError, ArgumentError, EncodingError
          return nil
        end
      end
      nil
    end

    # `value?.key`: a field of a JSON object, or nil (undefined) for anything else.
    def field(value, key)
      value.is_a?(Hash) && value.key?(key) ? value[key] : nil
    end

    # atob(): forgiving base64 to a binary string, each byte one character, which here is the bytes read as
    # ISO-8859-1 and written as UTF-8.
    def atob(text)
      text = text.gsub(/[\t\n\f\r ]/, "")
      text = text.sub(/={1,2}\z/, "") if (text.length % 4).zero?
      if text.length % 4 == 1 || text.match?(%r{[^A-Za-z0-9+/]})
        raise ArgumentError, "The string to be decoded is not correctly encoded."
      end

      padded = text.ljust((text.length / 4.0).ceil * 4, "=")
      padded.unpack1("m").force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
    end

    # The location of a request: the platform's headers when they name a country, else the lookup's answer
    # for the address, else nowhere.
    def locate(headers, ip, lookup = nil)
      from_headers = location_from_headers(headers)
      return from_headers if !from_headers.nil? && from_headers["country"] != ""

      if !lookup.nil? && ip != ""
        begin
          found = lookup.call(ip)
          return clean(found) if !found.nil? && found != false
        rescue StandardError
          # A broken lookup must never lose the event.
        end
      end
      EMPTY.dup
    end

    # A lookup answering from an MMDB reader. DB-IP's records follow MaxMind's city layout, with names but
    # no subdivision codes; a city loses the district DB-IP adds in brackets, as in "Toronto (Old Toronto)".
    # This is the TypeScript server's lookupFrom (packages/server/src/geo.ts).
    #
    # reader: an Mmdb, or anything with get(ip).
    def lookup_from(reader)
      lambda do |ip|
        begin
          found = reader.get(ip)
        rescue StandardError
          return nil
        end
        country = at(found, "country", "iso_code")
        return nil if country.nil? || country == "" || country == false || country == 0

        sub = at(found, "subdivisions", 0)
        city = at(found, "city", "names", "en")
        city = "" if city.nil?
        region = at(sub, "iso_code")
        region = at(sub, "names", "en") if region.nil?
        {
          "country" => country,
          "region" => region.nil? ? "" : region,
          "city" => city.is_a?(String) ? city_name(city) : city,
        }
      end
    end

    # A lookup from an MMDB file the owner supplies, such as MaxMind's GeoLite2 City.
    def file_lookup(file)
      lookup_from(Mmdb.open(file))
    end

    # A city as people say it, without a trailing bracketed district.
    def city_name(name)
      Js.trim(Js.scrub(name).sub(DISTRICT, ""))
    end

    # `value?.a?.b`, through Hashes and Arrays decoded from a database record.
    def at(value, *path)
      path.each do |key|
        if key.is_a?(Integer)
          return nil unless value.is_a?(Array) && key < value.length
        else
          return nil unless value.is_a?(Hash) && value.key?(key)
        end
        value = value[key]
      end
      value
    end

    private_class_method :decode, :clean, :text, :field, :atob, :at
  end
end
