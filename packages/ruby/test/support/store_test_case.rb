# frozen_string_literal: true

require_relative "seed"
require_relative "watched_db"
require_relative "node"

# What store tests need beyond test_helper's Databases: a Postgres schema or a MySQL database of their own
# for a test that opens several stores on one database, dropped in teardown.
module StoreDatabases
  @cleanups = []

  # A new schema in the Postgres test database.
  def self.pg_schema
    name = "rl_test_#{SecureRandom.hex(5)}"
    admin = Runlight::Db::Connect.postgres(Databases.pg_url)
    admin.run("CREATE SCHEMA #{name}")
    @cleanups << lambda do
      admin.run("DROP SCHEMA IF EXISTS #{name} CASCADE")
      admin.close
    end
    name
  end

  # A new database on a MySQL server, and its URL.
  def self.mysql_database(kind)
    url = Databases.mysql_urls.fetch(kind)
    name = "rl_test_rb_#{SecureRandom.hex(5)}"
    admin = Runlight::Db::Connect.mysql(url)
    admin.run("CREATE DATABASE #{name}")
    @cleanups << lambda do
      admin.run("DROP DATABASE IF EXISTS #{name}")
      admin.close
    end
    url.sub(%r{/[^/?]*(\?|\z)}) { "/#{name}#{Regexp.last_match(1)}" }
  end

  # Closes a store when the test ends.
  def self.closing(store)
    @cleanups << -> { store.close }
    store
  end

  def self.cleanup
    while (clean = @cleanups.pop)
      begin
        clean.call
      rescue StandardError => e
        warn "Runlight tests: cleanup: #{e.message}"
      end
    end
  end
end

# Store tests that run on every database at hand (see Databases).
class StoreTestCase < Minitest::Test
  DAY = Seed::DAY
  HOUR = Seed::HOUR
  MIN = Seed::MIN

  # Date.UTC(2026, 9, 6, 12), the clock the TypeScript tests start from.
  NOW = 1_791_288_000_000

  # Defines one test per database kind, as a PHPUnit data provider gives one case per kind.
  def self.on_each(name, kinds = Databases.kinds, &body)
    kinds.each do |kind|
      define_method("test_#{name}_on_#{kind}") { instance_exec(kind, &body) }
    end
  end

  def teardown
    StoreDatabases.cleanup
    super
  end

  # A fresh store with its tables and the site "default" in UTC.
  def store(kind, timezone = "UTC")
    store = Databases.fresh(kind)
    store.migrate
    store.upsert_site({ "id" => "default", "name" => "Example", "hostnames" => ["example.com"], "timezone" => timezone }, NOW)
    store
  end

  # A query over a range, with filters given as [dimension, op, value].
  def q(from, to, *filters)
    { "site" => "default", "from" => from, "to" => to, "filters" => filters.map { |f| { "dimension" => f[0], "op" => f[1], "value" => f[2] } } }
  end

  # The UTC day holding NOW, as a query.
  def today(*filters)
    q(NOW - 12 * HOUR, NOW + 12 * HOUR, *filters)
  end

  def goal(id, fields)
    { "id" => id, "site" => "default", "name" => id, "kind" => "event", "match" => "", "clickBy" => "", "valueMode" => "none", "value" => 0,
      "valueProp" => "", "currency" => "USD", "createdAt" => 0 }.merge(fields)
  end
end
