# frozen_string_literal: true

require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "tmpdir"

module Runlight
  # Counts tracker requests per address in fixed one-minute windows. Addresses
  # are hashed with a key made once per server, so the count never holds an IP,
  # and each window's counts are dropped when it ends.
  #
  # The counts live where every process of an app server can share them: one
  # small file per window in the system's temporary folder, or, where no file
  # can be written, in this process. Several servers behind a load balancer
  # each count on their own, as the TypeScript SDK's processes do.
  class RateLimit
    # per_minute: Integer; now: a callable giving milliseconds; dir: where the counts go, the system's temporary
    # folder when nil.
    def initialize(per_minute, now, dir = nil)
      @per_minute = per_minute
      @now = now
      @dir = dir
      # Counts kept in this process, used when no temporary folder works.
      @counts = {}
      @window = 0
      @lock = Mutex.new
    end

    # True while this address is under its limit for the current minute.
    def allow(ip)
      # No address cannot be told apart, so it is not limited.
      return true if ip == ""

      window = @now.call.div(60_000)
      id = OpenSSL::Digest::SHA256.hexdigest(self.class.key + ip)[0, 16]
      @lock.synchronize do
        count = count_in_file(window, id)
        return count <= @per_minute unless count.nil?

        if window != @window
          @window = window
          @counts = {}
        end
        @counts[id] = (@counts[id] || 0) + 1
        @counts[id] <= @per_minute
      end
    end
    alias allow? allow

    # A key made once and kept beside the counts, so the hashes cannot be turned back into addresses without it.
    def self.key
      @key ||= begin
        file = File.join(Dir.tmpdir, "runlight-rate", "key")
        stored = begin
          File.binread(file)
        rescue SystemCallError
          nil
        end
        if stored&.bytesize == 16
          stored
        else
          made = SecureRandom.random_bytes(16)
          begin
            FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
            File.open(file, File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) do |f|
              f.flock(File::LOCK_EX)
              f.write(made)
            end
          rescue SystemCallError
            # Kept for this process only.
          end
          made
        end
      end
    end

    private

    def count_in_file(window, id)
      dir = File.join(@dir || Dir.tmpdir, "runlight-rate")
      begin
        FileUtils.mkdir_p(dir, mode: 0o700)
      rescue SystemCallError
        return nil
      end
      file = File.join(dir, window.to_s)
      counts = nil
      begin
        File.open(file, File::RDWR | File::CREAT, 0o600) do |handle|
          handle.flock(File::LOCK_EX)
          counts = begin
            JSON.parse(handle.read)
          rescue JSON::ParserError
            nil
          end
          counts = {} unless counts.is_a?(Hash)
          counts[id] = counts[id].to_i + 1
          handle.rewind
          handle.truncate(0)
          handle.write(JSON.generate(counts))
          handle.flush
        end
      rescue SystemCallError, IOError
        return nil
      end
      # Earlier windows are no longer needed. Only windows: the key file beside them stays.
      Dir.glob(File.join(dir, "*")).each do |old|
        name = File.basename(old)
        next unless name.match?(/\A\d+\z/) && name.to_i < window - 1

        begin
          File.unlink(old)
        rescue SystemCallError
          nil
        end
      end
      counts[id]
    end
  end
end
