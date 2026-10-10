# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "runlight"
require "minitest/autorun"
require "securerandom"

ActiveRecord::Base.logger = nil if defined?(ActiveRecord::Base)

# The made-up installs and services the fake fetchers answer (an Umami at stats.example.com, an install at
# install.example.net) resolve to a public address, so fetches that only go to the public internet reach them.
# Tests of the address checks themselves pass a lookup of their own.
Runlight::Safefetch.resolver = lambda do |name|
  name.match?(/(\A|\.)example\.(com|net)\z/) ? ["93.184.215.14"] : Runlight::Safefetch.lookup(name)
end

# The language-neutral fixtures the PHP port's tests read (scripts/php-fixtures-*.mts writes them from the
# TypeScript SDK), and the conformance files, read where they are rather than copied.
module Fixtures
  ROOT = File.expand_path("../../..", __dir__)
  DIR = File.join(ROOT, "packages/php/tests/fixtures")
  CONFORMANCE = File.join(ROOT, "conformance")

  @loaded = {}

  def self.load(name)
    @loaded[name] ||= Runlight::Json.decode(File.read(File.join(DIR, "#{name}.json")))
  end

  def self.conformance(name)
    @loaded["conformance/#{name}"] ||= Runlight::Json.decode(File.read(File.join(CONFORMANCE, "#{name}.json")))
  end

  def self.path(name)
    File.join(DIR, name)
  end

  # A short label for a case, for messages.
  def self.label(value)
    text = Runlight::Json.encode(value)
    text.length > 160 ? "#{text[0, 160]}..." : text
  end
end

# The databases the store tests run on: SQLite always; Postgres when RUNLIGHT_TEST_PG is set (each test gets a
# schema of its own inside runlight_test_ruby); MySQL 8.4 and MariaDB 11.4 when RUNLIGHT_TEST_MYSQL is set
# (each test empties Runlight's tables in runlight_test_ruby first, so those tests run one at a time). Either
# variable may hold a URL; set to anything else (such as 1), the local test servers are used.
module Databases
  PG_URL = "postgres://joncphillips@127.0.0.1:5432/runlight_test_ruby"
  MYSQL_URLS = {
    "mysql" => "mysql://root:runlight@127.0.0.1:33084/runlight_test_ruby",
    "mariadb" => "mysql://root:runlight@127.0.0.1:33114/runlight_test_ruby",
  }.freeze

  @cleanups = []
  @mysql = {}

  def self.kinds
    kinds = ["sqlite"]
    kinds << "postgres" if pg_url
    kinds.concat(mysql_urls.keys)
    kinds
  end

  def self.pg_url
    value = ENV["RUNLIGHT_TEST_PG"].to_s.strip
    return nil if value.empty?

    value.include?("://") ? value : PG_URL
  end

  def self.mysql_urls
    value = ENV["RUNLIGHT_TEST_MYSQL"].to_s.strip
    return {} if value.empty?

    urls = value.split(/[\s,]+/).select { |u| u.include?("://") }
    return MYSQL_URLS if urls.empty?

    urls.each_with_index.to_h { |url, i| [i.zero? ? "mysql" : "mysql#{i}", url] }
  end

  # A fresh, empty database of a kind, dropped (or emptied) by cleanup.
  def self.db(kind)
    return Runlight::Db::Connect.sqlite(":memory:") if kind == "sqlite"

    if kind == "postgres"
      name = "rl_test_#{SecureRandom.hex(5)}"
      admin = (@pg_admin ||= Runlight::Db::Connect.postgres(pg_url))
      admin.run("CREATE SCHEMA #{name}")
      db = Runlight::Db::Connect.postgres(pg_url, schema: name)
      @cleanups << lambda do
        db.close
        admin.run("DROP SCHEMA IF EXISTS #{name} CASCADE")
      end
      return db
    end
    url = mysql_urls.fetch(kind)
    db = (@mysql[kind] ||= begin
      hold_mysql_lock(url)
      Runlight::Db::Connect.mysql(url)
    end)
    empty_mysql(db)
    db
  end

  # Every test process shares the one MySQL test database, so a process takes a named lock on a connection
  # of its own before its first MySQL test and keeps it until it exits: two processes never use it at once.
  def self.hold_mysql_lock(url)
    holder = Runlight::Db::Connect.mysql(url, statement_timeout: 0)
    connection = holder.connection_class.connection_pool.checkout
    loop do
      break if connection.select_value("SELECT GET_LOCK('runlight_test_ruby_tests', 60)").to_i == 1
    end
    (@locks ||= []) << connection
  end

  def self.fresh(kind)
    Runlight::Stores.from_db(db(kind))
  end

  # Drops every rl_ table in the MySQL test database, so the next test starts from nothing.
  def self.empty_mysql(db)
    tables = db.all("SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'rl\\_%'")
    return if tables.empty?

    db.run("SET FOREIGN_KEY_CHECKS = 0")
    tables.each { |row| db.run("DROP TABLE IF EXISTS `#{row.values.first}`") }
    db.run("SET FOREIGN_KEY_CHECKS = 1")
  end

  def self.cleanup
    while (clean = @cleanups.pop)
      begin
        clean.call
      rescue StandardError => e
        warn "Runlight tests: could not drop a test database: #{e.message}"
      end
    end
  end
end

# A fetcher that records each request and answers from a queue: a Response, or "timeout" or "network" to fail.
class RecordingFetcher
  attr_reader :requests

  def initialize(queue = [])
    @queue = queue.dup
    @requests = []
  end

  def fetch(url, init = {})
    headers = init["headers"]
    headers = headers.all.transform_values { |v| v.join(", ") } if headers.is_a?(Runlight::Http::Headers)
    @requests << { "url" => url, "method" => init["method"] || "GET", "headers" => headers || {},
                   "body" => init["body"], "timeoutMs" => init["timeoutMs"] }
    answer = @queue.shift
    raise "No canned answer left" if answer.nil?
    raise Runlight::Http::FetchError.new("The operation timed out", timed_out: true) if answer == "timeout"
    raise Runlight::Http::FetchError, "Could not connect" if answer == "network"

    answer
  end
end

# A fetcher that records every request and answers from a block, so a test can require the exact method, URL,
# headers, and body a service is sent. Headers are recorded as the TS fixtures record them: lowercase names in
# order, as iterating Fetch Headers gives them.
class FakeFetcher
  attr_reader :requests, :inits

  def initialize(&answer)
    @answer = answer
    @requests = []
    @inits = []
  end

  def fetch(url, init = {})
    headers = {}
    Runlight::Http::Headers.new(init["headers"] || {}).each { |name, value| headers[name] = value }
    @requests << { "method" => init["method"] || "GET", "url" => url, "headers" => headers, "body" => init["body"].to_s }
    @inits << init
    @answer.call(url, init)
  end
end

module Minitest
  class Test
    def teardown
      Databases.cleanup
      super
    end
  end
end
