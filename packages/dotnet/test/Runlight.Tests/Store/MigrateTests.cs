using System;
using System.Collections.Generic;
using System.Data.Common;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using MySqlConnector;
using Npgsql;
using Runlight.Db;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Store;

/// <summary>
/// Creating and upgrading the tables, and what each connection is set up to do: storage.test.ts,
/// postgres.test.ts, and mysql.test.ts, with the tables compared against the ones the TypeScript
/// SDK makes.
/// </summary>
public sealed class MigrateTests : IAsyncLifetime
{
    private readonly List<string> _files = [];

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync()
    {
        await Databases.CleanupAsync();
        SqliteConnection.ClearAllPools();
        foreach (string file in _files)
        {
            try
            {
                if (File.Exists(file))
                {
                    File.SetAttributes(file, FileAttributes.Normal);
                    File.Delete(file);
                }
            }
            catch (IOException)
            {
            }
        }
    }

    private string NewFile()
    {
        string file = Path.Combine(Path.GetTempPath(), "rl-migrate-" + Guid.NewGuid().ToString("N") + ".db");
        _files.AddRange([file, file + "-wal", file + "-shm"]);
        return file;
    }

    private static SqlStore Sqlite(string file)
    {
        var store = Stores.Sqlite(SqliteFactory.Instance, file);
        Databases.OnCleanup(() => store.CloseAsync().AsTask());
        return store;
    }

    /// <summary>The servers at hand, or "none".</summary>
    public static TheoryData<string> Servers() => Databases.ServerData();

    /// <summary>
    /// A store on a database of the kind, and a function that opens another store on the same one.
    /// MySQL has one database for the port's tests, so its tables are dropped first instead of a
    /// database being made.
    /// </summary>
    private async Task<(SqlStore Store, Func<SqlStore> Again)> SharedAsync(string kind)
    {
        if (kind == "sqlite")
        {
            string file = NewFile();
            return (Sqlite(file), () => Sqlite(file));
        }
        if (kind == "postgres")
        {
            string schema = await Databases.PgSchemaAsync();
            return (Databases.PgStore(schema), () => Databases.PgStore(schema));
        }
        await Databases.DropMysqlTablesAsync(kind);
        return (Databases.MysqlStore(kind), () => Databases.MysqlStore(kind));
    }

    private static async Task<long> TablesAsync(IDb db)
    {
        string sql = db.Dialect switch
        {
            "sqlite" => @"SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name LIKE 'rl\_%' ESCAPE '\'",
            "postgres" => "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = current_schema()",
            _ => "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()",
        };
        return (long)Js.Number((await db.AllAsync(sql))[0].Get("n"));
    }

    private const string Schema = "SELECT value FROM rl_meta WHERE \"key\" = 'schema'";

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Migrating_is_safe_any_number_of_times_and_records_the_schema_version(string kind)
    {
        var store = await Databases.FreshAsync(kind);
        await store.MigrateAsync();
        await store.MigrateAsync();
        await new SqlStore(store.Db).MigrateAsync();
        Assert.Equal(15, await TablesAsync(store.Db));
        Assert.Equal("[{\"value\":\"11\"}]", J(await store.Db.AllAsync(Schema)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_upgrade_that_stopped_after_adding_a_column_but_before_recording_its_version_starts_the_next_time(string kind)
    {
        if (kind == "mysql")
        {
            // MySQL 8.4 refuses the version 10 upgrade's TEXT column with a default, in TypeScript too; no
            // MySQL database was ever at version 9, since MySQL support came with version 11.
            Assert.Skip("MySQL tables start at version 11");
        }
        var (store, again) = await SharedAsync(kind);
        await store.MigrateAsync();
        // As an upgrade from version 9 leaves things when it stops between its two steps.
        await store.Db.RunAsync("UPDATE rl_meta SET value = '9' WHERE \"key\" = 'schema'");
        await store.CloseAsync();
        var next = again();
        await next.MigrateAsync();
        Assert.Equal("[{\"value\":\"11\"}]", J(await next.Db.AllAsync(Schema)));
        await next.CloseAsync();
    }

    [Fact]
    public async Task A_request_takes_a_current_schema_on_trust_and_the_full_pass_adds_what_is_missing()
    {
        string file = NewFile();
        await Sqlite(file).MigrateAsync();
        await Sqlite(file).Db.RunAsync("DROP INDEX rl_events_link");
        static async Task<string> Index(SqlStore store) => J(await store.Db.AllAsync("SELECT name FROM sqlite_master WHERE name = 'rl_events_link'"));
        var request = Sqlite(file);
        await request.MigrateAsync();
        Assert.True(await Index(request) == "[]", "a request at the current version does not go over every index");
        var cron = Sqlite(file);
        await cron.MigrateAsync(true);
        Assert.True(await Index(cron) == "[{\"name\":\"rl_events_link\"}]", "the full pass builds it again");
    }

    [Fact]
    public async Task A_database_that_can_only_be_read_still_answers_reports()
    {
        string file = NewFile();
        var first = Stores.Sqlite(SqliteFactory.Instance, file);
        await first.MigrateAsync();
        var site = new JsObject { ["id"] = "default", ["name"] = "Example", ["hostnames"] = new List<object?> { "example.com" }, ["timezone"] = "UTC" };
        await first.UpsertSiteAsync(site, 1);
        await first.CloseAsync();
        SqliteConnection.ClearAllPools();
        File.SetAttributes(file, FileAttributes.ReadOnly);
        var store = Sqlite(file);
        await store.MigrateAsync();
        await store.UpsertSiteAsync(site, 2);
        Assert.Equal("0", J((await store.StatsAsync(new JsObject { ["site"] = "default", ["from"] = 0L, ["to"] = 1L, ["filters"] = new List<object?>() })).Get("visits")));
    }

    [Theory]
    [MemberData(nameof(Servers))]
    public async Task Processes_starting_at_once_create_the_tables_once(string kind)
    {
        if (kind == "none")
        {
            Assert.Skip("Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.");
        }
        // Four stores with pools of their own, as four processes starting at once would have.
        var (store, again) = await SharedAsync(kind);
        var others = Enumerable.Range(0, 4).Select(_ => again()).ToList();
        await Task.WhenAll(others.Select(s => Task.Run(() => s.MigrateAsync())));
        Assert.Equal(15, await TablesAsync(store.Db));
        Assert.Equal("[{\"value\":\"11\"}]", J(await store.Db.AllAsync(Schema)));
    }

    private static async Task<string> SqliteSchemaAsync(SqlStore s) =>
        J(await s.Db.AllAsync(@"SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\_%' ESCAPE '\' ORDER BY name"));

    [Fact]
    public async Task The_tables_are_the_ones_the_TypeScript_SDK_makes_on_SQLite()
    {
        // A copy, since opening the fixture in WAL mode would write beside it.
        string file = NewFile();
        File.Copy(FixturePath("store.db"), file);
        var theirs = Sqlite(file);
        var mine = await Databases.FreshAsync("sqlite");
        await mine.MigrateAsync();
        Assert.Equal(await SqliteSchemaAsync(theirs), await SqliteSchemaAsync(mine));
    }

    /// <summary>The columns, indexes, and (on MySQL) tables of a store's database, as JSON.</summary>
    private static async Task<(string Json, int Tables)> DescribeAsync(SqlStore store)
    {
        List<JsObject> columns;
        var parts = new List<object?>();
        if (store.Db.Dialect == "postgres")
        {
            columns = await store.Db.AllAsync("SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position");
            parts.Add(columns);
            parts.Add(await store.Db.AllAsync(@"SELECT tablename, indexname, regexp_replace(indexdef, ' ON [a-z0-9_]+\.', ' ON ') AS def FROM pg_indexes WHERE schemaname = current_schema() ORDER BY indexname"));
        }
        else
        {
            columns = await store.Db.AllAsync("SELECT table_name, column_name, ordinal_position, column_type, is_nullable, column_default, collation_name, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position");
            parts.Add(columns);
            parts.Add(await store.Db.AllAsync("SELECT table_name, index_name, non_unique, seq_in_index, column_name, sub_part FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY table_name, index_name, seq_in_index"));
            parts.Add(await store.Db.AllAsync("SELECT table_name, table_collation, engine FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name"));
        }
        string key = columns.Count > 0 && columns[0].Has("table_name") ? "table_name" : "TABLE_NAME";
        return (J(parts), columns.Select(c => Js.String(c.Get(key))).Distinct(StringComparer.Ordinal).Count());
    }

    [Theory]
    [MemberData(nameof(Servers))]
    public async Task The_tables_are_the_ones_the_TypeScript_SDK_makes_on_Postgres_and_MySQL(string kind)
    {
        if (kind == "none")
        {
            Assert.Skip("Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL to compare the tables there too.");
        }
        string? node = Node.Binary();
        if (node == null)
        {
            Assert.Skip("node 22 or later, with the repository installed, makes the TypeScript tables; neither was found.");
        }
        var (mine, _) = await SharedAsync(kind);
        await mine.MigrateAsync();
        string mineJson = (await DescribeAsync(mine)).Json;
        string theirsUrl;
        SqlStore theirs;
        if (kind == "postgres")
        {
            string schema = await Databases.PgSchemaAsync();
            string url = Databases.PgUrl()!;
            theirsUrl = url + (url.Contains('?', StringComparison.Ordinal) ? "&" : "?") + "options=" + Uri.EscapeDataString("-c search_path=" + schema);
            theirs = Databases.PgStore(schema);
        }
        else
        {
            // The one MySQL database: the TypeScript SDK makes its tables where these were.
            await mine.CloseAsync();
            await Databases.DropMysqlTablesAsync(kind);
            theirsUrl = Databases.MysqlUrls()[kind];
            theirs = Databases.MysqlStore(kind);
        }
        var (status, _, error) = await Node.StoreAsync(node, "migrate", theirsUrl);
        Assert.True(status == 0, error);
        var (expected, tables) = await DescribeAsync(theirs);
        Assert.Equal(15, tables);
        Assert.Equal(expected, mineJson);
    }

    [Fact]
    public async Task Postgres_keeps_its_statement_timeout_after_building_tables_and_drops_an_index_a_build_left_unusable()
    {
        if (Databases.PgUrl() == null)
        {
            Assert.Skip("RUNLIGHT_TEST_PG is not set");
        }
        var store = await Databases.FreshAsync("postgres", 120_000);
        static async Task<string> Timeout(SqlStore s) => Js.String((await s.Db.AllAsync("SHOW statement_timeout"))[0].Get("statement_timeout"));
        Assert.Equal("2min", await Timeout(store));
        await store.MigrateAsync();
        // RESET comes back to the timeout the connection started with.
        Assert.Equal("2min", await Timeout(store));
        try
        {
            await store.Db.RunAsync("UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'rl_events_link'::regclass");
        }
        catch (DbException)
        {
            Assert.Skip("marking an index unusable needs a superuser");
        }
        const string Valid = "SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass";
        Assert.Equal("[{\"valid\":false}]", J(await store.Db.AllAsync(Valid)));
        await new SqlStore(store.Db).MigrateAsync(true);
        // Dropped, and built again.
        Assert.Equal("[{\"valid\":true}]", J(await store.Db.AllAsync(Valid)));
        var none = Databases.PgStore(await Databases.PgSchemaAsync(), 0);
        Assert.Equal("0", await Timeout(none));
    }

    [Theory]
    [MemberData(nameof(Servers))]
    public async Task A_MySQL_session_is_the_one_mysql2_opens(string kind)
    {
        if (kind is "none" or "postgres")
        {
            Assert.Skip("MySQL only");
        }
        var store = await Databases.FreshAsync(kind, 120_000);
        var row = (await store.Db.AllAsync("SELECT @@sql_mode AS mode, @@character_set_client AS charset, VERSION() AS version"))[0];
        var modes = Js.String(row.Get("mode")).Split(',');
        // mysql2 asks for it when it connects.
        Assert.Contains("IGNORE_SPACE", modes);
        Assert.DoesNotContain("ANSI_QUOTES", modes);
        Assert.DoesNotContain("NO_BACKSLASH_ESCAPES", modes);
        Assert.Equal("utf8mb4", row.Get("charset"));
        bool mariadb = Js.String(row.Get("version")).Contains("mariadb", StringComparison.OrdinalIgnoreCase);
        string limit = mariadb ? "SELECT @@max_statement_time AS t" : "SELECT @@max_execution_time AS t";
        Assert.Equal(mariadb ? 120 : 120_000, Js.Number((await store.Db.AllAsync(limit))[0].Get("t")));

        // Names in double quotes are names, and a backslash in quoted text is a backslash.
        await store.MigrateAsync();
        await store.SetSettingAsync(@"a\b", @"c\d");
        Assert.Equal(J(new List<object?> { new JsObject { ["key"] = @"a\b", ["value"] = @"c\d" } }), J(await store.Db.AllAsync(@"SELECT ""key"", value FROM rl_settings WHERE ""key"" LIKE 'a\b' ESCAPE '|'")));
        Assert.Equal(J(new List<object?> { new JsObject { ["b"] = @"\" } }), J(await store.Db.AllAsync(@"SELECT '\' AS b")));

        // One lock per database while the tables are made, with the statement timeout lifted meanwhile.
        const string Lock = "IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48)))";
        var seen = await store.Db.ExclusiveAsync(async db => (await db.AllAsync("SELECT " + Lock + " IS NOT NULL AS held, " + (mariadb ? "@@max_statement_time" : "@@max_execution_time") + " AS t"))[0]);
        Assert.Equal(1, Js.Number(seen.Get("held")));
        Assert.Equal(0, Js.Number(seen.Get("t")));
        // And put back after.
        Assert.Equal(mariadb ? 120 : 120_000, Js.Number((await store.Db.AllAsync(limit))[0].Get("t")));
        Assert.Null((await store.Db.AllAsync("SELECT " + Lock + " AS id"))[0].Get("id"));

        // Sums arrive as numbers the store can read, and a transaction reads what was committed before each statement.
        Assert.Equal("3", Js.String((await store.Db.AllAsync("SELECT SUM(x) AS s FROM (SELECT 1 AS x UNION ALL SELECT 2) t"))[0].Get("s")));
        var level = await store.Db.TransactionAsync(async db => (await db.AllAsync("SELECT @@transaction_isolation AS level"))[0].Get("level"));
        Assert.Contains(Js.String(level), new[] { "READ-COMMITTED", "REPEATABLE-READ" });
    }

    [Theory]
    [MemberData(nameof(Servers))]
    public async Task A_connection_the_server_drops_is_replaced_and_the_process_carries_on(string kind)
    {
        if (kind == "none")
        {
            Assert.Skip("Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.");
        }
        var store = await Databases.FreshAsync(kind);
        await store.MigrateAsync();
        string idSql = kind == "postgres" ? "SELECT pg_backend_pid() AS id" : "SELECT CONNECTION_ID() AS id";
        object? id = (await store.Db.AllAsync(idSql))[0].Get("id");
        if (kind == "postgres")
        {
            await using var admin = NpgsqlDataSource.Create(Databases.PgConnectionString(Databases.PgUrl()!));
            await using var cmd = admin.CreateCommand("SELECT pg_terminate_backend(" + Js.String(id) + ")");
            await cmd.ExecuteNonQueryAsync();
        }
        else
        {
            await using var admin = new MySqlDataSource(Databases.MysqlConnectionString(Databases.MysqlUrls()[kind]));
            await using var conn = await admin.OpenConnectionAsync();
            await using var cmd = conn.CreateCommand();
            cmd.CommandText = "KILL " + Js.String(id);
            await cmd.ExecuteNonQueryAsync();
        }
        await Task.Delay(200);
        var log = new StringWriter();
        var stderr = Console.Error;
        Console.SetError(log);
        List<JsObject> sites;
        try
        {
            sites = await store.SitesAsync();
        }
        finally
        {
            Console.SetError(stderr);
        }
        Assert.Empty(sites);
        // The lost connection was reported. MySqlConnector checks a pooled connection as it hands it
        // out (it resets the session) and opens a new one in its place, so on MySQL no statement ever
        // meets the dead connection, and there is nothing to report.
        if (kind == "postgres")
        {
            Assert.Contains("connection was lost", log.ToString(), StringComparison.Ordinal);
        }
        Assert.NotEqual(Js.String(id), Js.String((await store.Db.AllAsync(idSql))[0].Get("id")));
    }

    [Fact]
    public void The_schema_version_is_the_TypeScript_one()
    {
        Assert.Equal(11, Sql.SchemaVersion);
        Assert.Equal("utf8mb4_0900_bin", SqlStore.MysqlCollation);
    }
}
