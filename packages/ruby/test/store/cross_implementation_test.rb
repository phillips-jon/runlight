# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../support/store_test_case"

# One database, every implementation. packages/php/tests/fixtures/store.db was built by the TypeScript SDK and
# store.json holds what its SqlStore reads answered (scripts/php-fixtures-store.mts); the Ruby store must
# answer the same over a copy of that file, and over the same rows copied into Postgres and MySQL. Then the
# other way: Ruby writes a database and the TypeScript store reads it, when node is at hand.
class StoreCrossImplementationTest < StoreTestCase
  Stores = Runlight::Stores
  Json = Runlight::Json

  def setup
    super
    @files = []
  end

  def teardown
    super
    @files.each { |file| FileUtils.rm_f(file) }
  end

  def fixture
    Fixtures.load("store")
  end

  # The answers as JSON, read once.
  def self.expected
    @expected ||= Fixtures.load("store")["calls"].map { |call| Json.encode(call["result"]) }
  end

  def expected
    self.class.expected
  end

  def copy
    file = File.join(Dir.tmpdir, "rl-store-#{SecureRandom.hex(6)}.db")
    FileUtils.cp(Fixtures.path("store.db"), file)
    @files.push(file, "#{file}-wal", "#{file}-shm")
    file
  end

  # A read's answer in JSON's terms, as the script writes it. The method is the TypeScript name.
  def answer(store, call)
    method = call["method"].gsub(/[A-Z]/) { |c| "_#{c.downcase}" }
    result = store.public_send(method, *call["args"])
    result = result.sort if call["method"] == "rollupDays"
    result
  end

  def assert_answers(store, label)
    failures = []
    fixture["calls"].each_with_index do |call, i|
      actual = begin
        Json.encode(answer(store, call))
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
      next if actual == expected[i]

      failures << "##{i} #{call["method"]}(#{Json.encode(call["args"])[0, 300]})\n  expected #{expected[i]}\n  actual   #{actual}"
    end
    assert_equal [], failures.first(15), "#{label}: #{failures.length} of #{fixture["calls"].length} reads differ"
  end

  def test_the_fixture_covers_every_kind_of_read
    methods = fixture["calls"].map { |c| c["method"] }.uniq
    assert_operator fixture["calls"].length, :>, 1500
    %w[stats series hourly breakdown goalTotalsAll goalSeries funnelCounts journeyPages eventPropKeys eventPropValues links linkSeries realtime].each do |method|
      assert_includes methods, method
    end
  end

  def test_ruby_reads_a_database_the_type_script_sdk_wrote_and_answers_the_same
    store = StoreDatabases.closing(Stores.sqlite(copy))
    store.migrate
    assert_answers(store, "sqlite")
    # Opening it changed nothing a reader would see: the schema is the same version.
    assert_equal [{ "value" => "11" }], store.db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")
  end

  on_each "the_same_rows_in_postgres_and_mysql_answer_the_same", Databases.kinds - ["sqlite"] do |kind|
    source = StoreDatabases.closing(Stores.sqlite(copy))
    target = Databases.fresh(kind)
    target.migrate
    tables = %w[rl_meta rl_sites rl_salts rl_sessions rl_events rl_links rl_link_domains rl_shares rl_goals rl_settings rl_reports rl_tokens rl_funnels rl_rollup_days rl_rollups]
    target.transaction do |into|
      tables.each do |table|
        into.db.run("DELETE FROM #{table}")
        source.db.all("SELECT * FROM #{table}").each do |row|
          columns = row.keys.map { |c| "\"#{c}\"" }
          into.db.run("INSERT INTO #{table} (#{columns.join(", ")}) VALUES (#{(["?"] * row.length).join(", ")})", row.values)
        end
      end
    end
    assert_answers(target, kind)
  end

  def test_the_type_script_sdk_reads_a_database_ruby_wrote_and_answers_the_same
    node = Node.binary
    skip "node 22 or later, with the repository installed, reads the Ruby database; neither was found." if node.nil?

    file = File.join(Dir.tmpdir, "rl-ruby-#{SecureRandom.hex(6)}.db")
    @files.push(file, "#{file}-wal", "#{file}-shm")
    store = Stores.sqlite(file)
    calls = Seed.everything(store)
    mine = calls.map { |call| answer(store, call) }
    store.db.run("PRAGMA journal_mode = DELETE")
    store.close

    calls_file = File.join(Dir.tmpdir, "rl-calls-#{SecureRandom.hex(6)}.json")
    @files << calls_file
    File.write(calls_file, Json.encode(calls))
    status, out, err = Node.store(node, ["read", file, calls_file])
    assert_equal 0, status, err
    theirs = Json.try_decode(out)
    assert_kind_of Array, theirs, "#{out[0, 500]}\n#{err}"
    assert_equal calls.length, theirs.length
    failures = []
    calls.each_with_index do |call, i|
      a = Json.encode(mine[i])
      b = Json.encode(theirs[i])
      failures << "##{i} #{call["method"]}\n  ruby #{a}\n  ts   #{b}" if a != b
    end
    assert_equal [], failures.first(15), "#{failures.length} reads differ"
    assert_operator calls.length, :>, 100
  end
end
