# frozen_string_literal: true

require "fileutils"
require "net/http"
require "uri"
require "zlib"

module Runlight
  module Server
    # Location for servers with no platform headers (Cloudflare, Vercel, and Netlify send their own, and those always
    # win), from DB-IP's free databases (CC BY 4.0, https://db-ip.com). This is the port of the Geo class in
    # packages/server/src/geo.ts: `runlight cron` and the server's own schedule download each month's release with
    # refresh(), and lookups read the newest file on disk. lookup() opens it at the first lookup, as each PHP
    # request does; a server that keeps running reads through current() instead, which load_newest() points at the
    # newest release whenever the schedule runs, as the Node server's Geo does.
    class DbIp
      # dir: the folder the releases live in. mode: "city" or "country". download: a callable taking the URL and a
      # file, that writes the gzipped file at the URL to the file and says whether it got one (Net::HTTP by
      # default). log: a callable taking a line.
      def initialize(dir, mode, download = nil, log = nil)
        @dir = dir
        @mode = mode
        @download = download || method(:fetch_to)
        @log = log || ->(line) { warn(line) }
        @loaded = nil
        @lookup = nil
        @lock = Mutex.new
      end

      # "2026-10", the month DB-IP names each release after.
      def self.month(ms)
        Time.at(ms.div(1000)).utc.strftime("%Y-%m")
      end

      # The newest release on disk, or nil before the first download.
      def newest
        Dir.glob("#{@dir}/dbip-#{@mode}-lite-*.mmdb").max
      end

      # A lookup answering from the newest release on disk, opened at the first lookup, or nil when there is none
      # yet. Lookups that fail answer nothing, as they do before the first download in TypeScript.
      def lookup
        file = newest
        return nil if file.nil?

        found = nil
        lambda do |ip|
          begin
            found ||= Geo.lookup_from(Mmdb.open(file))
          rescue StandardError
            next nil
          end
          found.call(ip)
        end
      end

      # A lookup that always answers, from the release load_newest() last opened, and with nothing before there
      # is one.
      def current
        ->(ip) { @lookup&.call(ip) }
      end

      # Opens the newest release on disk when it is not the one open already. Safe to call often: it reads only
      # the folder when nothing changed.
      def load_newest
        file = newest
        return self if file.nil? || file == @loaded

        @lock.synchronize do
          next if file == @loaded

          begin
            @lookup = Geo.lookup_from(Mmdb.open(file))
            @loaded = file
          rescue StandardError => e
            @log.call("Runlight: could not open location data in #{file}: #{e.message}")
          end
        end
        self
      end

      # Fetches this month's release when it is missing. A new month's file appears a day or so after the month
      # starts, so until then last month's is fetched when that is missing too. Older releases go once a new
      # one is ready. Safe to call often: once this month's file is there it reads only the folder.
      def refresh(now)
        current = self.class.month(now)
        return if File.file?(file(current))

        begin
          FileUtils.mkdir_p(@dir, mode: 0o755)
        rescue SystemCallError
          @log.call("Runlight: could not make the folder for location data, #{@dir}")
          return
        end
        at = Time.at(now.div(1000)).utc
        year = at.month == 1 ? at.year - 1 : at.year
        previous = format("%<year>04d-%<month>02d", year: year, month: at.month == 1 ? 12 : at.month - 1)
        [current, previous].each do |release|
          return if File.file?(file(release))

          url = "https://download.db-ip.com/free/dbip-#{@mode}-lite-#{release}.mmdb.gz"
          gz = "#{file(release)}.gz.partial"
          partial = "#{file(release)}.partial"
          begin
            next unless @download.call(url, gz)

            self.class.gunzip(gz, partial)
            # A file that does not open as a database is never kept.
            Mmdb.open(partial)
            File.rename(partial, file(release))
            Dir.glob("#{@dir}/dbip-#{@mode}-lite-*").each do |old|
              File.unlink(old) if old != file(release)
            rescue SystemCallError
              nil
            end
            @log.call("Runlight: location data from DB-IP (#{release}) is ready.")
            return
          rescue StandardError => e
            @log.call("Runlight: could not download location data from #{url}: #{e.message}")
          ensure
            FileUtils.rm_f(gz)
            FileUtils.rm_f(partial)
          end
        end
      end

      def self.gunzip(from, to)
        Zlib::GzipReader.open(from) do |input|
          File.open(to, "wb") { |output| IO.copy_stream(input, output) }
        end
      rescue Zlib::Error
        raise RuntimeError, "could not unpack #{from}"
      end

      private

      def file(release)
        "#{@dir}/dbip-#{@mode}-lite-#{release}.mmdb"
      end

      # Downloads a file straight to disk, since a city database is too big to hold in memory. This is the one
      # download that does not go through a fetcher, which keeps whole answers in memory. Redirects are followed
      # on https only.
      def fetch_to(url, file, redirects = 5)
        uri = URI(url)
        raise RuntimeError, "not https: #{url}" unless uri.scheme == "https"

        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 600) do |http|
          http.request(Net::HTTP::Get.new(uri)) do |answer|
            if answer.is_a?(Net::HTTPRedirection) && redirects.positive? && answer["location"]
              return fetch_to(URI.join(url, answer["location"]).to_s, file, redirects - 1)
            end
            return false unless answer.code == "200"

            File.open(file, "wb") do |out|
              answer.read_body { |chunk| out.write(chunk) }
            end
            return true
          end
        end
        false
      end
    end
  end
end
