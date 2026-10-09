# frozen_string_literal: true

module Runlight
  # The stores stores/sqlite.ts, stores/postgres.ts, and stores/mysql.ts make, over ActiveRecord. Tables are
  # prefixed `rl_`, so the database can be the app's own, and a database made by the TypeScript SDK opens here.
  module Stores
    module_function

    # Runlight's tables in a SQLite file (or ":memory:"), in WAL mode, as better-sqlite3 opens it there.
    def sqlite(path)
      Store::SqlStore.new(Db::Connect.sqlite(path))
    end

    # Runlight's tables in Postgres, from a connection string. statement_timeout is the longest one statement
    # may run, in milliseconds (default 120000, 0 for no limit); schema is the search path.
    def postgres(url, statement_timeout: 120_000, schema: nil)
      raise ArgumentError, "Runlight: postgres() needs a url" if url.to_s.empty?

      Store::SqlStore.new(Db::Connect.postgres(url, statement_timeout: statement_timeout, schema: schema))
    end

    # Runlight's tables in MySQL 8.4 or MariaDB 11.4 and later, from a mysql:// or mariadb:// URL. Text is
    # utf8mb4 with a binary collation, so it compares and sorts by code point, case and trailing spaces
    # included, as SQLite and Postgres do. statement_timeout is in milliseconds (default 120000, 0 for no
    # limit), which MySQL applies to reads only and MariaDB to every statement.
    def mysql(url, statement_timeout: 120_000)
      raise ArgumentError, "Runlight: mysql() needs a url" if url.to_s.empty?

      Store::SqlStore.new(Db::Connect.mysql(url, statement_timeout: statement_timeout))
    end

    # The store a DATABASE_URL names, as the standalone server picks one: postgres:// or postgresql:// for
    # Postgres, mysql:// or mariadb:// for MySQL, and sqlite: or file: followed by a path for SQLite.
    def url(database_url)
      Store::SqlStore.new(Db::Connect.url(database_url))
    end

    # Runlight's tables in the database an ActiveRecord class connects to: the app's own by default. Writes
    # join a transaction the app has open.
    def active_record(connection_class = ::ActiveRecord::Base)
      Store::SqlStore.new(Db::Database.new(connection_class))
    end

    # A store over any Db::Database.
    def from_db(db)
      Store::SqlStore.new(db)
    end
  end
end
