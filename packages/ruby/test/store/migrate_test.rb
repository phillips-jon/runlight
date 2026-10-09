# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "rbconfig"
require "open3"
require_relative "../support/store_test_case"

# Creating and upgrading the tables, and what each connection is set up to do: storage.test.ts,
# postgres.test.ts, and mysql.test.ts, with the tables compared against the ones the TypeScript SDK makes.
class StoreMigrateTest < StoreTestCase
  SqlStore = Runlight::Store::SqlStore
  Stores = Runlight::Stores

  def setup
    super
    @files = []
  end

  def teardown
    super
    @files.each do |file|
      next unless File.exist?(file)

      File.chmod(0o644, file)
      File.delete(file)
    end
  end

  # Every database but SQLite at hand.
  def self.servers
    Databases.kinds - ["sqlite"]
  end

  def file
    file = File.join(Dir.tmpdir, "rl-migrate-#{SecureRandom.hex(6)}.db")
    @files.push(file, "#{file}-wal", "#{file}-shm")
    file
  end

  # A store on a database of the kind, a lambda that opens another store on the same one, and the arguments
  # test/support/migrate.rb takes to open it too.
  def shared(kind)
    if kind == "sqlite"
      file = file()
      return [StoreDatabases.closing(Stores.sqlite(file)), -> { StoreDatabases.closing(Stores.sqlite(file)) }, ["sqlite", file]]
    end
    if kind == "postgres"
      schema = StoreDatabases.pg_schema
      url = Databases.pg_url
      return [StoreDatabases.closing(Stores.postgres(url, schema: schema)), -> { StoreDatabases.closing(Stores.postgres(url, schema: schema)) }, ["postgres", url, schema]]
    end
    url = StoreDatabases.mysql_database(kind)
    [StoreDatabases.closing(Stores.mysql(url)), -> { StoreDatabases.closing(Stores.mysql(url)) }, ["mysql", url]]
  end

  def tables(db)
    sql = case db.dialect
          when "sqlite" then "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name LIKE 'rl\\_%' ESCAPE '\\'"
          when "postgres" then "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = current_schema()"
          else "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'rl\\_%'"
          end
    Integer(db.all(sql)[0]["n"])
  end

  def schema_version(db)
    db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'").map { |r| { "value" => r["value"].to_s } }
  end

  on_each "migrating_is_safe_any_number_of_times_and_records_the_schema_version" do |kind|
    store = Databases.fresh(kind)
    store.migrate
    store.migrate
    SqlStore.new(store.db).migrate
    assert_equal 15, tables(store.db)
    assert_equal [{ "value" => "11" }], schema_version(store.db)
  end

  on_each "an_upgrade_that_stopped_after_adding_a_column_but_before_recording_its_version_starts_the_next_time" do |kind|
    # MySQL 8.4 refuses the version 10 upgrade's TEXT column with a default, in TypeScript too; no MySQL
    # database was ever at version 9, since MySQL support came with version 11.
    skip "MySQL tables start at version 11" if kind == "mysql"

    store, again = shared(kind)
    store.migrate
    # As an upgrade from version 9 leaves things when it stops between its two steps.
    store.db.run("UPDATE rl_meta SET value = '9' WHERE \"key\" = 'schema'")
    store.close
    following = again.call
    following.migrate
    assert_equal [{ "value" => "11" }], schema_version(following.db)
  end

  def test_a_request_takes_a_current_schema_on_trust_and_the_full_pass_adds_what_is_missing
    file = file()
    StoreDatabases.closing(Stores.sqlite(file)).migrate
    StoreDatabases.closing(Stores.sqlite(file)).db.run("DROP INDEX rl_events_link")
    index = ->(store) { store.db.all("SELECT name FROM sqlite_master WHERE name = 'rl_events_link'") }
    request = StoreDatabases.closing(Stores.sqlite(file))
    request.migrate
    assert_equal [], index.call(request), "a request at the current version does not go over every index"
    cron = StoreDatabases.closing(Stores.sqlite(file))
    cron.migrate(true)
    assert_equal [{ "name" => "rl_events_link" }], index.call(cron), "the full pass builds it again"
  end

  def test_a_database_that_can_only_be_read_still_answers_reports
    file = file()
    first = Stores.sqlite(file)
    first.migrate
    site = { "id" => "default", "name" => "Example", "hostnames" => ["example.com"], "timezone" => "UTC" }
    first.upsert_site(site, 1)
    first.close
    File.chmod(0o444, file)
    store = StoreDatabases.closing(Stores.sqlite(file))
    store.migrate
    store.upsert_site(site, 2)
    assert_equal 0, store.stats({ "site" => "default", "from" => 0, "to" => 1, "filters" => [] })["visits"]
  end

  on_each "processes_starting_at_once_create_the_tables_once", servers do |kind|
    store, _, args = shared(kind)
    script = File.expand_path("../support/migrate.rb", __dir__)
    threads = Array.new(4) { Thread.new { Open3.capture3(RbConfig.ruby, script, *args) } }
    threads.each do |thread|
      out, err, status = thread.value
      assert status.success?, "#{out} #{err}"
      assert_equal "ok\n", out
    end
    assert_equal 15, tables(store.db)
  end

  def test_the_tables_are_the_ones_the_type_script_sdk_makes_on_sqlite
    theirs = StoreDatabases.closing(Stores.sqlite(Fixtures.path("store.db")))
    mine = StoreDatabases.closing(Stores.sqlite(":memory:"))
    mine.migrate
    schema = ->(s) { s.db.all("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name") }
    assert_equal schema.call(theirs), schema.call(mine)
  end

  on_each "the_tables_are_the_ones_the_type_script_sdk_makes_on_postgres_and_mysql", servers do |kind|
    node = Node.binary
    skip "node 22 or later, with the repository installed, makes the TypeScript tables; neither was found." if node.nil?

    mine, = shared(kind)
    mine.migrate
    if kind == "postgres"
      schema = StoreDatabases.pg_schema
      url = Databases.pg_url
      theirs_url = "#{url}#{url.include?("?") ? "&" : "?"}options=#{URI.encode_www_form_component("-c search_path=#{schema}").gsub("+", "%20")}"
      theirs = StoreDatabases.closing(Stores.postgres(url, schema: schema))
    else
      theirs_url = StoreDatabases.mysql_database(kind)
      theirs = StoreDatabases.closing(Stores.mysql(theirs_url))
    end
    status, _, err = Node.store(node, ["migrate", theirs_url])
    assert_equal 0, status, err
    describe = lambda do |store|
      if store.db.dialect == "postgres"
        columns = store.db.all("SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position")
        indexes = store.db.all("SELECT tablename, indexname, regexp_replace(indexdef, ' ON [a-z0-9_]+\\.', ' ON ') AS def FROM pg_indexes WHERE schemaname = current_schema() ORDER BY indexname")
        [columns, indexes]
      else
        columns = store.db.all("SELECT table_name, column_name, ordinal_position, column_type, is_nullable, column_default, collation_name, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position")
        indexes = store.db.all("SELECT table_name, index_name, non_unique, seq_in_index, column_name, sub_part FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY table_name, index_name, seq_in_index")
        list = store.db.all("SELECT table_name, table_collation, engine FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name")
        [columns, indexes, list]
      end
    end
    expected = describe.call(theirs)
    assert_equal 15, expected[0].map { |c| c["table_name"] || c["TABLE_NAME"] }.uniq.length
    assert_equal expected, describe.call(mine)
  end

  def test_postgres_keeps_its_statement_timeout_after_building_tables_and_drops_an_index_a_build_left_unusable
    skip "RUNLIGHT_TEST_PG is not set" if Databases.pg_url.nil?

    store = Databases.fresh("postgres")
    assert_equal "2min", store.db.all("SHOW statement_timeout")[0]["statement_timeout"]
    store.migrate
    assert_equal "2min", store.db.all("SHOW statement_timeout")[0]["statement_timeout"], "RESET comes back to the timeout the connection started with"
    begin
      store.db.run("UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'rl_events_link'::regclass")
    rescue ActiveRecord::StatementInvalid
      skip "marking an index unusable needs a superuser"
    end
    assert_equal [{ "valid" => false }], store.db.all("SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass")
    SqlStore.new(store.db).migrate(true)
    assert_equal [{ "valid" => true }], store.db.all("SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass"), "dropped, and built again"
    none = StoreDatabases.closing(Stores.postgres(Databases.pg_url, statement_timeout: 0))
    assert_equal "0", none.db.all("SHOW statement_timeout")[0]["statement_timeout"]
  end

  on_each "a_mysql_session_is_the_one_mysql2_opens", servers - ["postgres"] do |kind|
    store = Databases.fresh(kind)
    row = store.db.all("SELECT @@sql_mode AS mode, @@character_set_client AS charset, VERSION() AS version")[0]
    modes = row["mode"].to_s.split(",")
    assert_includes modes, "IGNORE_SPACE", "mysql2 asks for it when it connects"
    refute_includes modes, "ANSI_QUOTES"
    refute_includes modes, "NO_BACKSLASH_ESCAPES"
    assert_equal "utf8mb4", row["charset"]
    mariadb = row["version"].to_s.downcase.include?("mariadb")
    limit_sql = mariadb ? "SELECT @@max_statement_time AS t" : "SELECT @@max_execution_time AS t"
    assert_equal mariadb ? 120 : 120_000, Float(store.db.all(limit_sql)[0]["t"])

    # Names in double quotes are names, and a backslash in quoted text is a backslash.
    store.migrate
    store.set_setting("a\\b", "c\\d")
    assert_equal [{ "key" => "a\\b", "value" => "c\\d" }], store.db.all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE 'a\\b' ESCAPE '|'")
    assert_equal [{ "b" => "\\" }], store.db.all("SELECT '\\' AS b")

    # One lock per database while the tables are made, with the statement timeout lifted meanwhile.
    seen = nil
    store.db.exclusive do |db|
      seen = db.all("SELECT IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))) IS NOT NULL AS held, #{mariadb ? "@@max_statement_time" : "@@max_execution_time"} AS t")[0]
    end
    assert_equal 1, Integer(seen["held"])
    assert_equal 0, Float(seen["t"])
    assert_equal mariadb ? 120 : 120_000, Float(store.db.all(limit_sql)[0]["t"]), "and put back after"
    assert_nil store.db.all("SELECT IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))) AS id")[0]["id"]

    # Sums arrive as numbers the store can read, and a transaction reads what was committed before each statement.
    assert_equal 3, Runlight::Store::Sql.num(store.db.all("SELECT SUM(x) AS s FROM (SELECT 1 AS x UNION ALL SELECT 2) t")[0]["s"])
    level = store.db.transaction { |db| db.all("SELECT @@transaction_isolation AS level")[0]["level"] }
    assert_includes ["READ-COMMITTED", "REPEATABLE-READ"], level
  end

  on_each "a_connection_the_server_drops_is_replaced_and_the_process_carries_on", servers do |kind|
    store = Databases.fresh(kind)
    store.migrate
    if kind == "postgres"
      id = store.db.all("SELECT pg_backend_pid() AS id")[0]["id"]
      admin = Runlight::Db::Connect.postgres(Databases.pg_url)
      admin.all("SELECT pg_terminate_backend(?)", [Integer(id)])
    else
      id = store.db.all("SELECT CONNECTION_ID() AS id")[0]["id"]
      admin = Runlight::Db::Connect.mysql(Databases.mysql_urls.fetch(kind))
      admin.run("KILL #{Integer(id)}")
    end
    admin.close
    sleep 0.2
    sites, said = capture_io { @sites = store.sites }
    assert_equal [], @sites
    assert_empty sites
    assert_includes said, "connection was lost", "the lost connection was reported"
    refute_equal id, store.db.all(kind == "postgres" ? "SELECT pg_backend_pid() AS id" : "SELECT CONNECTION_ID() AS id")[0]["id"]
  end

  def test_the_schema_version_is_the_type_script_one
    assert_equal 11, Runlight::Store::Sql::SCHEMA_VERSION
    assert_equal "utf8mb4_0900_bin", SqlStore::MYSQL_COLLATION
  end
end
