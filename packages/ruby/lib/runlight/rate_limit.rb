# frozen_string_literal: true

require "openssl"
require "securerandom"

module Runlight
  # Counts tracker requests per address in fixed one-minute windows, in memory.
  # Addresses are hashed with a key made at start, so the map never holds an IP,
  # and the whole map is dropped at the end of each window. Nothing is written
  # to disk.
  #
  # Each process counts on its own, as the TypeScript SDK's do: several workers
  # of an app server, or several servers behind a load balancer, each allow the
  # limit.
  class RateLimit
    # per_minute: Integer; now: a callable giving milliseconds.
    def initialize(per_minute, now)
      @per_minute = per_minute
      @now = now
      @key = SecureRandom.random_bytes(16)
      @counts = {}
      @window = 0
      # App servers such as Puma call in from several threads.
      @lock = Mutex.new
    end

    # True while this address is under its limit for the current minute.
    def allow(ip)
      # No address cannot be told apart, so it is not limited.
      return true if ip == ""

      window = @now.call.div(60_000)
      id = OpenSSL::Digest::SHA256.digest(@key + ip.b)[0, 8]
      @lock.synchronize do
        if window != @window
          @window = window
          @counts = {}
        end
        @counts[id] = (@counts[id] || 0) + 1
        @counts[id] <= @per_minute
      end
    end
    alias allow? allow
  end
end
