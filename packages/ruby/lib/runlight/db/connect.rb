# frozen_string_literal: true

require "uri"
require "fileutils"

module Runlight
  module Db
    # Pools Runlight opens itself, each an abstract ActiveRecord class of its own, so they never touch the
    # app's ActiveRecord::Base connection.
    module Pools
      @count = 0
      @lock = Mutex.new

      def self.make(config)
        @lock.synchronize do
          @count += 1
          klass = Class.new(::ActiveRecord::Base) { self.abstract_class = true }
          const_set("Pool#{@count}", klass)
          klass.establish_connection(config)
          klass
        end
      end
    end

    # Opens the database a store keeps its tables in, set up per connection as the TypeScript drivers set up
    # theirs. Tables are prefixed `rl_`, so the database can be the app's own.
    module Connect
      module_function

      # A SQLite file, or ":memory:", in WAL mode with a five second busy timeout, as better-sqlite3 opens it.
      def sqlite(path)
        path = path.to_s
        memory = path == ":memory:" || path.empty?
        # A file in a folder that is not there yet gets the folder, as a fresh app's data/ often is.
        FileUtils.mkdir_p(File.dirname(path)) if !memory && !path.start_with?("file:") && !File.directory?(File.dirname(path))
        config = { adapter: "sqlite3", database: memory ? ":memory:" : path, timeout: 5000,
                   # One connection for a database in memory, which every connection would otherwise make anew.
                   pool: memory ? 1 : 5 }
        Database.new(Pools.make(config), owned: true, dialect: "sqlite")
      end

      # Postgres from a URL like postgres://user:pass@host:5432/db?sslmode=require. statement_timeout stops any
      # one statement after that many milliseconds; 0 turns it off. It is set when the connection starts, as
      # pg's `statement_timeout` option sets it, so `RESET statement_timeout` comes back to it. schema, when
      # given, is the search path.
      def postgres(url, statement_timeout: 120_000, schema: nil)
        parts = parts(url)
        options = []
        options << parts[:query]["options"] if parts[:query]["options"]
        options << "-c statement_timeout=#{statement_timeout.to_i}" if statement_timeout.to_i.positive?
        options << "-c search_path=#{option(schema)}" if schema
        config = { adapter: "postgresql", host: parts[:host], port: parts[:port] || 5432, database: parts[:database],
                   username: parts[:user], password: parts[:password], connect_timeout: 10 }
        config[:sslmode] = parts[:query]["sslmode"] if parts[:query]["sslmode"]
        config[:options] = options.join(" ") unless options.empty?
        config[:schema_search_path] = schema if schema
        Database.new(Pools.make(config.compact), owned: true, dialect: "postgres")
      end

      # MySQL 8.4 or MariaDB 11.4 and later from a URL like mysql://user:pass@host:3306/db (or mariadb://),
      # through the trilogy gem when it is installed, else mysql2. The session is utf8mb4 with the server's own
      # SQL mode plus IGNORE_SPACE, as mysql2 opens it for the TypeScript driver (its connect flags ask for
      # that, which neither Ruby driver can, so it is set as the session's mode). Runlight's tables carry their
      # own binary collation, so text compares and sorts by code point. statement_timeout is set per
      # connection as stores/mysql.ts sets it; 0 turns it off.
      def mysql(url, statement_timeout: 120_000)
        parts = parts(url.to_s.sub(/\Amariadb:/i, "mysql:"))
        config = { adapter: mysql_adapter, host: parts[:host], port: parts[:port] || 3306, database: parts[:database],
                   username: parts[:user], password: parts[:password], encoding: "utf8mb4", strict: :default,
                   connect_timeout: 10 }
        db = Database.new(Pools.make(config.compact), owned: true, statement_timeout: statement_timeout.to_i, dialect: "mysql")
        version, mode = db.connection_class.connection_pool.with_connection { |c| c.select_rows("SELECT VERSION(), @@GLOBAL.sql_mode")[0] }
        db.connection_class.connection_pool.disconnect!
        variables = { sql_mode: (mode.to_s.split(",") | ["IGNORE_SPACE"]).join(",") }
        if statement_timeout.to_i.positive?
          variables.merge!(version.to_s.match?(/mariadb/i) ? { max_statement_time: statement_timeout.to_i / 1000.0 } : { max_execution_time: statement_timeout.to_i })
        end
        db.connection_class.establish_connection(config.compact.merge(variables: variables))
        db
      end

      # Picks the database from a URL's scheme: sqlite:, file:, postgres:, postgresql:, mysql:, or mariadb:.
      def url(url)
        scheme = url.to_s[/\A([a-z][a-z0-9+.-]*):/i, 1].to_s.downcase
        case scheme
        when "postgres", "postgresql" then postgres(url)
        when "mysql", "mariadb" then mysql(url)
        when "sqlite", "file" then sqlite(url.to_s.sub(%r{\A(sqlite|file):(//)?}i, ""))
        else raise ArgumentError, "Runlight: DATABASE_URL must start with postgres://, mysql://, mariadb://, or sqlite:"
        end
      end

      def quote_name(name, quote)
        "#{quote}#{name.to_s.gsub(quote, quote * 2)}#{quote}"
      end

      # trilogy when it can be loaded, else mysql2.
      def mysql_adapter
        require "trilogy"
        "trilogy"
      rescue LoadError
        "mysql2"
      end

      # A value inside libpq's `options`, where a space or backslash is escaped with a backslash.
      def option(value)
        value.to_s.gsub(/([\\\s'])/) { "\\#{Regexp.last_match(1)}" }
      end

      def parts(url)
        uri = URI.parse(url.to_s)
        raise ArgumentError, "Runlight: the database URL could not be read" if uri.host.nil?

        query = URI.decode_www_form(uri.query.to_s).to_h
        { host: uri.host.delete_prefix("[").delete_suffix("]"), port: uri.port,
          user: uri.user && URI.decode_uri_component(uri.user),
          password: uri.password && URI.decode_uri_component(uri.password),
          database: URI.decode_uri_component(uri.path.to_s.delete_prefix("/")), query: query }
      rescue URI::InvalidURIError
        raise ArgumentError, "Runlight: the database URL could not be read"
      end
    end
  end
end
