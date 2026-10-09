# frozen_string_literal: true

require "socket"

module Runlight
  # Fetches from addresses that other people's input names, such as the icon
  # links on a site's home page or a link domain, and only from the public
  # internet. Only https is fetched, never a private, loopback, link-local,
  # or metadata address, and redirects are followed by hand under the same
  # rules. The name is resolved and every address it gives is checked before
  # each hop, and the request is pinned to the checked addresses (the fetcher's
  # "resolve"), so a name that answers differently a moment later gets nowhere.
  module Safefetch
    module_function

    def v4(text)
      parts = text.split(".", -1)
      return nil if parts.length != 4
      return nil unless parts.all? { |p| p.match?(/\A\d{1,3}\z/) && p.to_i <= 255 }

      parts.map(&:to_i)
    end

    def public_v4?(four)
      a, b, c = four
      return false if a.zero? || a == 10 || a == 127 || a >= 224
      return false if a == 100 && b >= 64 && b < 128
      return false if a == 169 && b == 254
      return false if a == 172 && b >= 16 && b < 32
      return false if a == 192 && b == 168
      return false if a == 192 && b.zero? && (c.zero? || c == 2)
      return false if a == 198 && [18, 19].include?(b)
      return false if a == 198 && b == 51 && c == 100
      return false if a == 203 && b.zero? && c == 113

      true
    end

    # An IPv6 address as eight 16-bit groups, or nil when it is not one.
    def v6(text)
      address = text.sub(/\A\[/, "").sub(/\]\z/, "").split("%", 2).first.to_s.downcase
      # A trailing IPv4 address becomes the last two groups.
      if (tail = address.match(/(\d{1,3}(?:\.\d{1,3}){3})\z/))
        four = v4(tail[1])
        return nil if four.nil?

        address = "#{address[0, address.length - tail[1].length]}#{((four[0] << 8) | four[1]).to_s(16)}:#{((four[2] << 8) | four[3]).to_s(16)}"
      end
      halves = address.split("::", -1)
      halves = [""] if halves.empty?
      return nil if halves.length > 2

      head = halves[0] == "" ? [] : halves[0].split(":", -1)
      rest = halves.length == 2 && halves[1] != "" ? halves[1].split(":", -1) : []
      missing = 8 - head.length - rest.length
      return nil if halves.length == 1 ? missing != 0 : missing < 1

      groups = [*head, *Array.new(halves.length == 2 ? missing : 0, "0"), *rest]
      return nil unless groups.all? { |g| g.match?(/\A[0-9a-f]{1,4}\z/) }

      groups.map { |g| g.to_i(16) }
    end

    # Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is not.
    def public_address?(ip)
      four = v4(ip)
      return public_v4?(four) unless four.nil?

      g = v6(ip)
      return false if g.nil?

      embedded = ->(hi, lo) { [hi >> 8, hi & 255, lo >> 8, lo & 255] }
      zero = ->(groups) { groups.all?(&:zero?) }
      # IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
      if zero.call(g[0, 5]) && (g[5] == 0xffff || g[5].zero?)
        return g[5].zero? && g[6].zero? && g[7] <= 1 ? false : public_v4?(embedded.call(g[6], g[7]))
      end
      return public_v4?(embedded.call(g[6], g[7])) if g[0] == 0x64 && g[1] == 0xff9b && zero.call(g[2, 4])
      # 6to4 carries an IPv4 address in its second and third groups.
      return public_v4?(embedded.call(g[1], g[2])) if g[0] == 0x2002
      return false if (g[0] & 0xfe00) == 0xfc00 || (g[0] & 0xffc0) == 0xfe80 || (g[0] & 0xff00) == 0xff00
      # Teredo, documentation, and discard prefixes.
      return false if g[0] == 0x2001 && (g[1].zero? || g[1] == 0xdb8)
      return false if g[0] == 0x100 && zero.call(g[1, 3])

      true
    end

    # Every address a name resolves to, v4 and v6, as getaddrinfo() gives them (the hosts file included).
    # Empty when it does not resolve.
    def lookup(name)
      bare = name.sub(/\A\[/, "").sub(/\]\z/, "")
      return [bare] if !v4(bare).nil? || !v6(bare).nil?

      Addrinfo.getaddrinfo(bare, nil, nil, :STREAM).map(&:ip_address).uniq
    rescue SocketError, SystemCallError
      []
    end

    # The public addresses a name resolves to, for setting up DNS records. None where it does not resolve.
    # lookup: a callable standing in for DNS in tests.
    def public_addresses(name, lookup = nil)
      addresses = begin
        lookup.nil? ? lookup(name) : lookup.call(name)
      rescue StandardError
        return []
      end
      addresses.select { |address| public_address?(address) }.uniq
    end

    # Whether a name resolves to an address off the public internet. False when it does not resolve.
    # lookup: a callable standing in for DNS in tests.
    def resolves_privately?(name, lookup = nil)
      addresses = begin
        lookup.nil? ? lookup(name) : lookup.call(name)
      rescue StandardError
        return false
      end
      addresses.any? { |address| !public_address?(address) }
    end

    # GETs an https URL on the public internet, following up to "redirects"
    # redirects that stay on it, within "timeoutMs" in all. Raises a
    # PrivateAddressError for an address off it, and an Http::FetchError that
    # is timed_out? when time runs out. A redirect past the last one comes back
    # as it is. "maxBytes" and "truncate" go to the fetcher, for a capped read.
    # "lookup" stands in for DNS in tests.
    #
    # init: a Hash with "timeoutMs", and optionally "headers", "redirects", "maxBytes", "truncate", and "lookup".
    def public_fetch(target, init, fetcher = nil)
      fetcher ||= Http::NetFetcher.new
      lookup = init["lookup"] || method(:lookup)
      until_ns = monotonic + (init["timeoutMs"] * 1_000_000)
      url = Http::Url.new(target)
      hop = 0
      loop do
        raise PrivateAddressError, url.href if url.protocol != "https:"

        host = url.hostname.sub(/\A\[/, "").sub(/\]\z/, "").downcase
        literal = !v4(host).nil? || !v6(host).nil?
        raise PrivateAddressError, host if literal && !public_address?(host)
        raise PrivateAddressError, host if host == "localhost" || host.end_with?(".localhost")

        pin = []
        unless literal
          # The address checked is the address used: every one the name gives must be public, and the
          # connection is pinned to them, so a second lookup cannot hand back another.
          addresses = lookup.call(host)
          raise Http::FetchError, "getaddrinfo ENOTFOUND #{host}" if addresses.empty?

          addresses.each { |address| raise PrivateAddressError, host unless public_address?(address) }
          port = url.port == "" ? "443" : url.port
          pin = ["#{host}:#{port}:#{addresses.map { |a| a.include?(":") ? "[#{a}]" : a }.join(",")}"]
        end
        left = (until_ns - monotonic).div(1_000_000)
        raise timed_out if left <= 0

        options = { "headers" => init["headers"] || {}, "redirect" => "manual", "timeoutMs" => left }
        %w[maxBytes truncate].each { |key| options[key] = init[key] unless init[key].nil? }
        options["resolve"] = pin unless pin.empty?
        begin
          answer = fetcher.fetch(url.href, options)
        rescue Http::FetchError => e
          # Whichever way the request gave up, the caller hears that time ran out.
          raise timed_out if e.timed_out? || monotonic >= until_ns

          raise
        end
        location = answer.headers.get("location")
        if answer.status < 300 || answer.status >= 400 || location.nil? || location == "" || hop >= (init["redirects"] || 0)
          return answer
        end

        url = Http::Url.new(location, url.href)
        hop += 1
      end
    end

    def timed_out
      Http::FetchError.new("The operation was aborted due to timeout", timed_out: true)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    private_class_method :v4, :public_v4?, :v6, :timed_out, :monotonic
  end
end
