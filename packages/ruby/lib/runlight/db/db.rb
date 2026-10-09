# frozen_string_literal: true

require "active_record"

module Runlight
  module Db
    # The little a store needs from a database, over an ActiveRecord connection
    # pool, for SQLite, Postgres, and MySQL or MariaDB, doing per connection
    # what the TypeScript drivers do (stores/sqlite.ts, stores/postgres.ts, and
    # stores/mysql.ts).
    #
    # SQL uses `?` placeholders on every dialect and is written for SQLite and
    # Postgres. Each `?` outside quotes is filled in on the client with the
    # value written as a literal, as mysql2 fills them in for the TypeScript
    # driver. On MySQL each statement also goes through mysql_text first: a
    # "quoted" name in backticks, and a backslash inside 'text' doubled, since
    # MySQL reads it as an escape where standard SQL takes it literally.
    #
    # Rows come back as Hashes keyed by column name; numbers may arrive as
    # strings, so the store casts what it reads.
    class Database
      # Arbitrary but fixed, so every Runlight process takes the same lock to create tables.
      MIGRATION_LOCK = 7_331_906

      # One lock per MySQL database, so installs sharing a server do not wait on each other. Lock names are 64
      # characters at most.
      MYSQL_LOCK = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))"

      attr_reader :connection_class

      # connection_class: an ActiveRecord::Base subclass whose pool to use (ActiveRecord::Base for the app's
      # own database). owned: whether close may drop the pool (never one the app passed in).
      # statement_timeout: MySQL only, the session's statement timeout in milliseconds, which exclusive lifts
      # while it builds tables and puts back after, as the TypeScript driver does for a pool it made.
      def initialize(connection_class = ::ActiveRecord::Base, owned: false, statement_timeout: 0, dialect: nil)
        @connection_class = connection_class
        @owned = owned
        @statement_timeout = statement_timeout
        @dialect = dialect
        @held = 0
      end

      # "sqlite", "postgres", or "mysql".
      def dialect
        @dialect ||= self.class.dialect_of(connection { |c| c.adapter_name })
      end

      def self.dialect_of(adapter)
        case adapter.to_s.downcase
        when /sqlite/ then "sqlite"
        when /postg|postgis/ then "postgres"
        when /mysql|trilogy|maria/ then "mysql"
        else raise ArgumentError, "Runlight: the #{adapter} adapter is not supported; use SQLite, Postgres, MySQL, or MariaDB"
        end
      end

      # The rows a statement returns, as Hashes with String keys. A statement that returns no rows gives none.
      def all(sql, params = [])
        statement do |c|
          result = c.exec_query(text(c, sql, params), "Runlight")
          result.columns.empty? ? [] : result.to_a
        end
      end

      def run(sql, params = [])
        statement do |c|
          result = c.execute(text(c, sql, params), "Runlight")
          result.clear if result.respond_to?(:clear) && result.class.name == "PG::Result"
        end
        nil
      end

      # Runs an UPDATE or DELETE and says how many rows it matched. The store asks this of MySQL, which has no
      # RETURNING; ActiveRecord connects to MySQL with the found rows flag, so matched rows are counted.
      def affected(sql, params = [])
        statement { |c| c.exec_update(text(c, sql, params), "Runlight").to_i }
      end

      # Runs the block in one transaction, committed when it returns and rolled back when it raises. A
      # transaction already open (the store's, or the app's) is joined, not nested. Yields this database.
      def transaction
        connection do |c|
          if c.transaction_open?
            yield self
          elsif dialect == "mysql"
            # As Postgres does by default: each statement sees what was committed before it began, and InnoDB
            # takes no gap locks, so two writers to neighbouring rows do not deadlock.
            c.transaction(isolation: :read_committed) { yield self }
          else
            c.transaction { yield self }
          end
        end
      end

      # Runs the block while holding a database-wide lock, so two processes starting at once do not race to
      # create the same tables. Yields this database.
      def exclusive(&block)
        connection do |c|
          @held += 1
          begin
            locked(c, &block)
          ensure
            @held -= 1
          end
        end
      end

      def close
        return unless @owned

        @connection_class.connection_pool.disconnect!
      end

      # MySQL's statement timeout as a session setting, which MySQL and MariaDB name differently. MariaDB counts
      # seconds and applies it to every statement; MySQL counts milliseconds and applies it to reads.
      def limit_statements(ms)
        connection do |c|
          @mariadb = c.select_value("SELECT VERSION() AS v").to_s.match?(/mariadb/i) if @mariadb.nil?
          c.execute(@mariadb ? "SET SESSION max_statement_time = #{Json.number(ms / 1000.0)}" : "SET SESSION max_execution_time = #{ms.to_i}")
        end
      end

      # SQL written for SQLite and Postgres as MySQL and MariaDB read it: a "quoted" identifier is quoted with
      # backticks, and a backslash inside 'text' is doubled. With params, each `?` outside quotes becomes its
      # value through the block (mysql2's escaping when none is given).
      def self.mysql_text(sql, params = nil, &escape)
        fill(sql, params, mysql: true, &(escape || method(:mysql_escape)))
      end

      # A value as a MySQL literal, as mysql2's escape() writes the values Runlight binds.
      def self.mysql_escape(value)
        case value
        when nil then "NULL"
        when true then "true"
        when false then "false"
        when Integer then value.to_s
        when Float then Json.number(value)
        else
          escaped = value.to_s.gsub(/[\0\b\t\x1a\n\r"'\\]/) do |c|
            { "\0" => "\\0", "\b" => "\\b", "\t" => "\\t", "\x1a" => "\\Z", "\n" => "\\n", "\r" => "\\r",
              '"' => '\\"', "'" => "\\'", "\\" => "\\\\" }[c]
          end
          "'#{escaped}'"
        end
      end

      # Walks the statement once: each `?` outside quotes becomes the next value through the block, and on
      # MySQL a "quoted" name takes backticks and a backslash in 'text' is doubled.
      def self.fill(sql, params, mysql: false)
        return sql if params.nil? && !mysql
        return sql if !mysql && params.empty? && !sql.include?("?")

        out = +""
        n = 0
        quote = nil
        sql.each_char do |ch|
          if quote
            if ch == quote
              quote = nil
              out << (mysql && ch == '"' ? "`" : ch)
            elsif mysql && quote == "'" && ch == "\\"
              out << "\\\\"
            elsif mysql && quote == '"' && ch == "`"
              out << "``"
            else
              out << ch
            end
          elsif ch == "'" || ch == '"' || ch == "`"
            quote = ch
            out << (mysql && ch == '"' ? "`" : ch)
          elsif ch == "?" && !params.nil?
            raise ArgumentError, "Runlight: a statement has more placeholders than values" if n >= params.length

            out << yield(params[n])
            n += 1
          else
            out << ch
          end
        end
        raise ArgumentError, "Runlight: a statement has more values than placeholders" if !params.nil? && n != params.length

        out
      end

      private

      def connection(&block)
        @connection_class.connection_pool.with_connection(&block)
      end

      # A statement on a connection. A connection the server dropped (a restart, a failover, an idle timeout)
      # is replaced, as a pool replaces it, and the statement sent again: it never reached the server. Not
      # inside a transaction or a lock, whose work went with the connection.
      def statement(&block)
        connection(&block)
      rescue ::ActiveRecord::ConnectionFailed => e
        raise if dialect == "sqlite" || @held.positive? || connection(&:transaction_open?)

        warn "Runlight: a #{dialect == "mysql" ? "MySQL" : "Postgres"} connection was lost; it reconnects on the next query. #{e.message}"
        connection do |c|
          c.reconnect!
          block.call(c)
        end
      end

      def text(connection, sql, params)
        params = Array(params)
        return self.class.mysql_text(sql, params) if dialect == "mysql"

        self.class.fill(sql, params) { |value| literal(connection, value) }
      end

      # A value as a literal for SQLite or Postgres. A float is written as JavaScript writes it, which every
      # database reads back as the same number.
      def literal(connection, value)
        case value
        when nil then "NULL"
        when true then dialect == "sqlite" ? "1" : "TRUE"
        when false then dialect == "sqlite" ? "0" : "FALSE"
        when Integer then value.to_s
        when Float
          return "NULL" if value.nan? || value.infinite?

          Json.number(value)
        else connection.quote(Js.scrub(value.to_s))
        end
      end

      def locked(c)
        # SQLite's file lock already serialises its writers.
        return yield(self) if dialect == "sqlite"

        if dialect == "postgres"
          # Asked for again and again rather than waited on: a waiting statement would hold up an index being
          # built CONCURRENTLY by whoever has the lock, and the two would wait on each other for good.
          sleep 0.1 until truthy(c.select_value("SELECT pg_try_advisory_lock(#{MIGRATION_LOCK}) AS ok"))
          begin
            return yield(self)
          ensure
            begin
              c.execute("SELECT pg_advisory_unlock(#{MIGRATION_LOCK})")
            rescue StandardError
              # A lost connection ends its session, and the lock with it.
            end
          end
        end
        loop do
          ok = c.select_value("SELECT GET_LOCK(#{MYSQL_LOCK}, 5) AS ok")
          raise "Runlight: MySQL refused the lock for creating tables" if ok.nil?
          break if ok.to_i == 1
          # Not got within 5 seconds: another process is creating the tables. Ask again.
        end
        begin
          # An index on a big table takes a while to build, so the build may run past the statement timeout.
          limit_statements(0) if @statement_timeout.positive?
          result = yield(self)
          limit_statements(@statement_timeout) if @statement_timeout.positive?
          result
        ensure
          begin
            c.execute("DO RELEASE_LOCK(#{MYSQL_LOCK})")
          rescue StandardError
            # A lost connection ends its session, and the lock with it.
          end
        end
      end

      def truthy(value)
        value == true || value == "t" || value == 1 || value == "1" || value == "true"
      end
    end
  end
end
