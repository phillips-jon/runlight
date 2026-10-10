# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Runlight
  module Server
    # The standalone server's settings, as the Rack app (config.ru, or `runlight serve`) and the command line
    # (exe/runlight) both read them: environment variables first, then a config.rb in the project folder that
    # returns the same names as a Hash.
    #
    #   PORT                  where `runlight serve` listens (3000)
    #   HOST                  which address it listens on (0.0.0.0)
    #   DATA_DIR              the SQLite file, the secret, the setup code, and location data (./runlight-data)
    #   DATABASE_URL          a postgres://, mysql://, or mariadb:// URL, to use that database instead of SQLite
    #   RUNLIGHT_SECRET       signs sessions and encrypts saved keys (made and kept in DATA_DIR if unset)
    #   RUNLIGHT_TOKEN        also accepted as a bearer token on the API, and makes the first account
    #   RUNLIGHT_URL          the dashboard's public address, which can never become a link domain
    #   TRUST_PROXY           "false" when no proxy sits in front, so forwarded addresses are ignored
    #   RUNLIGHT_GEO          city (the default), country, off, or the path to an MMDB file
    #   CRON_SECRET           lets a scheduler run the check over HTTP, at POST /api/check
    #   RUNLIGHT_OBSERVE_KEY  one key for every site's AI agent reports
    #
    # Relative paths are read from the project folder.
    class Config
      attr_reader :root

      # root: the project folder, which holds config.rb. file: a config.rb elsewhere; RUNLIGHT_CONFIG names one too.
      def initialize(root, file = nil)
        @root = root
        @file = {}
        @secret = nil
        @store = nil
        file ||= Env.get("RUNLIGHT_CONFIG")
        file = file.nil? ? "#{root}/config.rb" : path(file)
        if File.file?(file)
          values = Object.new.instance_eval(File.read(file), file)
          unless values.is_a?(Hash)
            raise RuntimeError, "Runlight: #{file} must return a Hash of settings, such as " \
                                "{ \"RUNLIGHT_URL\" => \"https://stats.example.com\" }"
          end

          @file = values.transform_keys(&:to_s)
        elsif file != "#{root}/config.rb"
          raise RuntimeError, "Runlight: there is no config file at #{file}"
        end
      end

      # A setting: the environment's, else config.rb's, trimmed, with nothing for an empty one.
      def get(name)
        value = Env.get(name)
        return value unless value.nil?

        given = @file[name]
        return given ? "true" : "false" if [true, false].include?(given)
        return nil unless given.is_a?(String) || given.is_a?(Numeric) || given.is_a?(Symbol)

        given = given.to_s.strip
        given.empty? ? nil : given
      end

      # The data folder, made on first use and readable only by this user.
      def data_dir
        dir = data_path
        unless File.directory?(dir)
          begin
            FileUtils.mkdir_p(dir, mode: 0o700)
          rescue SystemCallError
            nil
          end
          unless File.directory?(dir)
            raise RuntimeError, "Runlight: could not make the data folder #{dir}. Make it, writable by the server, " \
                                "or set DATA_DIR."
          end
        end
        dir
      end

      # Where the data lives, for messages.
      def where
        url = get("DATABASE_URL") || ""
        if url.match?(%r{\Apostgres(ql)?://}i) then "Postgres"
        elsif url.match?(%r{\Amysql://}i) then "MySQL"
        elsif url.match?(%r{\Amariadb://}i) then "MariaDB"
        elsif url != "" then url
        else "#{data_path}/runlight.db"
        end
      end

      def store
        @store ||= begin
          url = get("DATABASE_URL")
          url.nil? ? Stores.sqlite("#{data_dir}/runlight.db") : Stores.url(url)
        end
      end

      # RUNLIGHT_SECRET, or one made on first use and kept beside the data, readable only by this user.
      def secret
        return @secret unless @secret.nil?

        given = get("RUNLIGHT_SECRET")
        return @secret = given unless given.nil?

        file = "#{data_dir}/secret"
        saved = read(file)
        return @secret = saved if saved != ""

        made = SecureRandom.hex(32)
        # Made once: whoever writes the file first wins, and everyone else reads theirs.
        begin
          File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |out| out.write("#{made}\n") }
        rescue SystemCallError
          sleep(0.05)
          saved = read(file)
          if saved == ""
            raise RuntimeError, "Runlight: could not write #{file}. Make the data folder writable, or set RUNLIGHT_SECRET."
          end

          return @secret = saved
        end
        File.chmod(0o600, file)
        @secret = made
      end

      # The dashboard's public address, such as https://stats.example.com, or nil.
      def url
        url = get("RUNLIGHT_URL")
        if !url.nil? && !url.match?(%r{\Ahttps?://[^/?#]+/?\z})
          raise RuntimeError, "Runlight: set RUNLIGHT_URL to the dashboard's address only, such as https://stats.example.com"
        end

        url
      end

      # false with nothing in front, or the one header your proxy sets, such as cf-connecting-ip behind Cloudflare.
      # Unset stays nil, so the library's default applies and it can warn when nothing sits in front.
      def trust_proxy
        value = (get("TRUST_PROXY") || "").downcase
        return nil if value == ""
        return false if value == "false"

        %w[x-forwarded-for x-real-ip cf-connecting-ip].include?(value) ? value : true
      end

      # DB-IP's monthly download, for RUNLIGHT_GEO city (the default) or country, or nil. The same one each time,
      # so a running server's lookups see what its schedule downloads.
      def db_ip
        return @db_ip if defined?(@db_ip)

        mode = (get("RUNLIGHT_GEO") || "city").downcase
        @db_ip = mode == "city" || mode == "country" ? DbIp.new("#{data_path}/geo", mode) : nil
      end

      # The location lookup: DB-IP's newest release, an MMDB file of the owner's, or nil when it is off.
      def geo
        setting = get("RUNLIGHT_GEO") || "city"
        db_ip = self.db_ip
        return db_ip.load_newest.current unless db_ip.nil?
        return nil if setting.downcase == "off"

        file = path(setting)
        lookup = nil
        lambda do |ip|
          lookup ||= Geo.file_lookup(file)
          lookup.call(ip)
        end
      end

      # The file that holds the setup link while there is no account.
      def setup_file
        "#{data_dir}/setup.txt"
      end

      # The one-time code that unlocks /setup, made the first time it is asked for and written to setup.txt in the
      # data folder with the link that carries it. With RUNLIGHT_TOKEN set there is none: setup asks for the token.
      def setup_code
        return nil unless get("RUNLIGHT_TOKEN").nil?

        file = setup_file
        found = read(file, strip: false).match(%r{/setup\?code=([A-Za-z0-9_-]+)})
        return found[1] unless found.nil?

        code = Accounts::Web.setup_code
        link = "#{url.nil? ? "https://your-runlight-address" : url.sub(%r{/+\z}, "")}/setup?code=#{code}"
        begin
          File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |out|
            out.write("Open this link to create the first Runlight account. It works only while Runlight has no account.\n#{link}\n")
          end
        rescue SystemCallError
          # Someone else wrote it first.
          sleep(0.05)
          found = read(file, strip: false).match(%r{/setup\?code=([A-Za-z0-9_-]+)})
          return found[1] unless found.nil?

          raise RuntimeError, "Runlight: could not write #{file}. Make the data folder writable, or set RUNLIGHT_TOKEN."
        end
        File.chmod(0o600, file)
        code
      end

      # The standalone server these settings describe. options: more of Standalone's options, such as now or
      # fetcher, for tests. setup: whether to make the setup code when there is none, as the web pages need.
      def standalone(options = {}, setup = true)
        db_ip = self.db_ip
        geo = self.geo
        code = setup ? setup_code : nil
        settings = {
          "store" => store,
          "secret" => secret,
          "token" => get("RUNLIGHT_TOKEN"),
          "url" => url,
          "trustProxy" => trust_proxy,
          "geoCredit" => !db_ip.nil?,
          "cronSecret" => get("CRON_SECRET"),
          "observeKey" => get("RUNLIGHT_OBSERVE_KEY"),
        }
        settings["geo"] = geo unless geo.nil?
        unless code.nil?
          settings["setupCode"] = code
          settings["setupWhere"] = "in the file setup.txt in Runlight's data folder (<code>runlight setup</code> prints it too)"
        end
        Standalone.new(settings.merge(Options.normalize(options)))
      end

      private

      # A path from a setting, read from the project folder when it is relative.
      def path(value)
        value.match?(%r{\A(/|\\|[A-Za-z]:[\\/])}) ? value : "#{@root}/#{value}"
      end

      def data_path
        path(get("DATA_DIR") || "runlight-data")
      end

      # A file's text, trimmed unless asked not to, or "" when there is none.
      def read(file, strip: true)
        text = File.file?(file) ? File.read(file) : ""
        strip ? text.strip : text
      rescue SystemCallError
        ""
      end
    end
  end
end
