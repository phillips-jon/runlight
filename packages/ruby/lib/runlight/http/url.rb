# frozen_string_literal: true

module Runlight
  module Http
    # An absolute http or https URL, parsed the way browsers and JavaScript's URL
    # do for those schemes: the host lowercased, backslashes read as slashes, dot
    # segments resolved, and the path and query percent-encoded with the WHATWG
    # sets, so a path recorded here matches what the tracker sent and what the
    # TypeScript SDK stores.
    class Url
      # Raised by Url.new for text that is not a URL, as `new URL()` throws a TypeError.
      class Invalid < ArgumentError; end

      attr_accessor :protocol, :username, :password, :hostname, :port, :pathname, :search, :hash

      DEFAULT_PORTS = { "http:" => "80", "https:" => "443", "ws:" => "80", "wss:" => "443", "ftp:" => "21" }.freeze

      PATH = " \"#<>?`{}"
      QUERY = " \"#<>'"
      FRAGMENT = " \"<>`"
      USERINFO = " \"#<>?`{}/:;=@[\\]^|"

      def self.parse(input, base = nil)
        new(input, base)
      rescue Invalid
        nil
      end

      def self.can_parse?(input, base = nil)
        !parse(input, base).nil?
      end

      def initialize(input, base = nil)
        @username = +""
        @password = +""
        @has_authority = false
        input = Js.scrub(input.to_s).gsub(/\A[\x00-\x20]+|[\x00-\x20]+\z/, "").delete("\t\n\r")
        m = input.match(/\A([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)\z/m)
        unless m
          raise Invalid, "Invalid URL: #{input}" if base.nil?

          resolve(input, base.is_a?(Url) ? base : Url.new(base))
          return
        end
        @protocol = "#{m[1].downcase}:"
        rest = m[2]
        unless special?
          # Not a special scheme (mailto:, data:, javascript:): kept as it came.
          @hostname = +""
          @port = +""
          if rest.start_with?("//")
            # An authority after the scheme (android-app://com.google.android.gm/) is an opaque host, kept in its case.
            rest = rest[2..]
            finish = rest.index(%r{[/?#]}) || rest.length
            opaque_authority(rest[0, finish])
            @has_authority = true
            tail(rest[finish..], "")
            return
          end
          rest, @hash = cut(rest, "#")
          @pathname, @search = cut(rest, "?")
          return
        end
        rest = rest.tr("\\", "/").sub(%r{\A/+}, "")
        finish = rest.index(%r{[/?#]}) || rest.length
        authority(rest[0, finish])
        tail(rest[finish..], "/")
      end

      def host
        @port.empty? ? @hostname : "#{@hostname}:#{@port}"
      end

      def origin
        special? ? "#{@protocol}//#{host}" : "null"
      end

      def href
        return "#{@protocol}#{@pathname}#{@search}#{@hash}" if !special? && !@has_authority

        auth = @username.empty? && @password.empty? ? "" : "#{@username}#{@password.empty? ? "" : ":#{@password}"}@"
        "#{@protocol}//#{auth}#{host}#{@pathname}#{@search}#{@hash}"
      end
      alias to_s href

      def search_params
        SearchParams.new(@search)
      end

      # Replaces the query with these parameters, as assigning url.search does.
      def search_params=(params)
        text = params.to_s
        @search = text.empty? ? "" : "?#{text}"
      end

      # Replaces the path, as assigning url.pathname does: tabs and newlines dropped, and for http and https a
      # backslash read as a slash.
      def set_pathname(path)
        path = path.to_s.delete("\t\n\r")
        path = path.tr("\\", "/") if special?
        @pathname = self.class.path(path.start_with?("/") ? path : "/#{path}")
      end

      # Replaces the query, as assigning url.search does for http and https: one leading "?" is dropped and the
      # rest percent-encoded, and an empty value removes the query. A lone "?" leaves an empty query, which href
      # still writes, as JavaScript does.
      def set_search(search)
        search = search.to_s
        if search.empty?
          @search = +""
          return
        end
        search = search.delete("\t\n\r")
        @search = "?#{self.class.encode(search.delete_prefix("?"), QUERY)}"
      end

      # Percent-encodes C0 controls, DEL, bytes past ASCII, and `extra`; existing escapes stay as written.
      def self.encode(text, extra)
        pattern = extra.empty? ? /[^\x21-\x7e]/n : /[^\x21-\x7e]|[#{Regexp.escape(extra)}]/n
        Js.scrub(text).b.gsub(pattern) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::UTF_8)
      end

      def self.path(path)
        out = []
        segments = path.split("/", -1)
        segments.shift
        count = segments.length
        segments.each_with_index do |segment, i|
          lower = segment.downcase
          last = i == count - 1
          if ["..", ".%2e", "%2e.", "%2e%2e"].include?(lower)
            out.pop
            out << "" if last
          elsif [".", "%2e"].include?(lower)
            out << "" if last
          else
            out << encode(segment, PATH)
          end
        end
        "/#{out.join("/")}"
      end

      private

      def special?
        DEFAULT_PORTS.key?(@protocol)
      end

      def resolve(input, base)
        @protocol = base.protocol
        input = input.tr("\\", "/") if special?
        if input.start_with?("//")
          # A special scheme skips any further slashes before the host: ///x is the host x.
          rest = special? ? input.sub(%r{\A/+}, "") : input[2..]
          finish = rest.index(%r{[/?#]}) || rest.length
          authority(rest[0, finish])
          tail(rest[finish..], "/")
          return
        end
        @username = base.username
        @password = base.password
        @hostname = base.hostname
        @port = base.port
        if input.empty?
          @pathname = base.pathname
          @search = base.search
          @hash = +""
          return
        end
        if input.start_with?("#")
          @pathname = base.pathname
          @search = base.search
          @hash = input.length > 1 ? "##{self.class.encode(input[1..], FRAGMENT)}" : +""
          return
        end
        if input.start_with?("?")
          @pathname = base.pathname
          query, hash = cut(input[1..], "#")
          @search = query.empty? ? +"" : "?#{self.class.encode(query, QUERY)}"
          @hash = hash.empty? ? +"" : "##{self.class.encode(hash[1..], FRAGMENT)}"
          return
        end
        if input.start_with?("/")
          tail(input, "/")
          return
        end
        dir = base.pathname[0, (base.pathname.rindex("/") || -1) + 1]
        tail(dir + input, "/")
      end

      def authority(authority)
        at = authority.rindex("@")
        if at
          user = authority[0, at]
          authority = authority[(at + 1)..]
          name, pass = cut(user, ":")
          @username = self.class.encode(name, USERINFO)
          @password = pass.empty? ? +"" : self.class.encode(pass[1..], USERINFO)
        end
        port = +""
        if authority.start_with?("[")
          close = authority.index("]")
          raise Invalid, "Invalid URL" if close.nil?

          host = authority[0, close + 1].downcase
          after = authority[(close + 1)..]
          unless after.empty?
            raise Invalid, "Invalid URL" unless after.start_with?(":")

            port = after[1..]
          end
        else
          colon = authority.rindex(":")
          host = colon.nil? ? authority : authority[0, colon]
          port = colon.nil? ? +"" : authority[(colon + 1)..]
          host = domain(host)
        end
        raise Invalid, "Invalid URL" if host.empty?

        unless port.empty?
          raise Invalid, "Invalid URL" if !port.match?(/\A\d+\z/) || port.to_i > 65_535

          port = port.to_i.to_s
          port = +"" if port == DEFAULT_PORTS[@protocol]
        end
        @hostname = host
        @port = port
      end

      def opaque_authority(authority)
        at = authority.rindex("@")
        if at
          name, pass = cut(authority[0, at], ":")
          @username = self.class.encode(name, USERINFO)
          @password = pass.empty? ? +"" : self.class.encode(pass[1..], USERINFO)
          authority = authority[(at + 1)..]
        end
        colon = authority.rindex(":")
        host = colon.nil? ? authority : authority[0, colon]
        port = colon.nil? ? "" : authority[(colon + 1)..]
        if host.match?(%r{[\x00 #/:<>?@\[\\\]^|]}) || (!port.empty? && (!port.match?(/\A\d+\z/) || port.to_i > 65_535))
          raise Invalid, "Invalid URL"
        end

        @hostname = self.class.encode(host, "")
        @port = port.empty? ? +"" : port.to_i.to_s
      end

      def tail(rest, empty)
        rest, hash = cut(rest, "#")
        path, query = cut(rest, "?")
        @pathname = path.empty? && empty.empty? ? +"" : self.class.path(path.empty? ? empty : path)
        @search = query.length > 1 ? "?#{self.class.encode(query[1..], QUERY)}" : +""
        @hash = hash.length > 1 ? "##{self.class.encode(hash[1..], FRAGMENT)}" : +""
      end

      # The part before `mark`, and the rest starting with it.
      def cut(text, mark)
        at = text.index(mark)
        at.nil? ? [text, +""] : [text[0, at], text[at..]]
      end

      def domain(host)
        host = Js.scrub(host.b.gsub(/%([0-9A-Fa-f]{2})/n) { Regexp.last_match(1).hex.chr })
        raise Invalid, "Invalid URL" if host.match?(%r{[\x00-\x20#%/:<>?@\[\\\]^|]})

        lower = host.downcase
        lower = Idna.to_ascii(lower) unless lower.ascii_only?
        ipv4(lower) || lower
      end

      # A host written as an IPv4 address in any form browsers accept, normalised to dotted decimal.
      def ipv4(host)
        parts = host.split(".", -1)
        parts.pop if parts.last == ""
        return nil if parts.empty? || parts.length > 4
        return nil unless parts.last.match?(/\A(0x[0-9a-f]*|[0-9]+)\z/)

        numbers = parts.map do |part|
          if (m = part.match(/\A0x([0-9a-f]*)\z/)) then m[1].empty? ? 0 : m[1].to_i(16)
          elsif part.match?(/\A0[0-7]+\z/) then part.to_i(8)
          elsif part.match?(/\A[0-9]+\z/) then part.to_i
          else raise Invalid, "Invalid URL"
          end
        end
        value = numbers.pop
        raise Invalid, "Invalid URL" if numbers.any? { |n| n > 255 }
        raise Invalid, "Invalid URL" if value >= 256**(5 - parts.length)

        numbers.each_with_index { |n, i| value += n * (256**(3 - i)) }
        [(value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255].join(".")
      end
    end

    # Hostnames past ASCII to their xn-- form, as URL's domain to ASCII does: mapped (lowercased and NFKC
    # normalised, as UTS 46 maps the usual characters) then Punycode encoded label by label.
    module Idna
      BASE = 36
      TMIN = 1
      TMAX = 26
      SKEW = 38
      DAMP = 700
      INITIAL_BIAS = 72
      INITIAL_N = 128

      module_function

      def to_ascii(host)
        mapped = host.unicode_normalize(:nfkc).downcase.tr("。．｡", "...")
        labels = mapped.split(".", -1).map do |label|
          next label if label.ascii_only?

          "xn--#{punycode(label)}"
        end
        out = labels.join(".")
        raise Url::Invalid, "Invalid URL" if out.match?(%r{[\x00-\x20#%/:<>?@\[\\\]^|]})

        out
      rescue ArgumentError, Encoding::CompatibilityError
        raise Url::Invalid, "Invalid URL"
      end

      def punycode(label)
        input = label.codepoints
        output = input.select { |c| c < 0x80 }.map(&:chr)
        basic = output.length
        handled = basic
        output << "-" if basic.positive?
        n = INITIAL_N
        delta = 0
        bias = INITIAL_BIAS
        while handled < input.length
          m = input.select { |c| c >= n }.min
          delta += (m - n) * (handled + 1)
          n = m
          input.each do |c|
            delta += 1 if c < n
            next unless c == n

            q = delta
            k = BASE
            loop do
              t = if k <= bias then TMIN
                  elsif k >= bias + TMAX then TMAX
                  else k - bias
                  end
              break if q < t

              output << digit(t + ((q - t) % (BASE - t)))
              q = (q - t) / (BASE - t)
              k += BASE
            end
            output << digit(q)
            bias = adapt(delta, handled + 1, handled == basic)
            delta = 0
            handled += 1
          end
          delta += 1
          n += 1
        end
        output.join
      end

      def digit(d)
        (d < 26 ? d + 97 : d + 22).chr
      end

      def adapt(delta, points, first)
        delta = first ? delta / DAMP : delta / 2
        delta += delta / points
        k = 0
        while delta > ((BASE - TMIN) * TMAX) / 2
          delta /= BASE - TMIN
          k += BASE
        end
        k + (((BASE - TMIN + 1) * delta) / (delta + SKEW))
      end
    end
  end
end
