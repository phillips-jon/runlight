using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Npgsql;
using Runlight.AspNetCore;
using Runlight.Http;
using Runlight.Server;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests.Server;

/// <summary>
/// The server's settings, its command line, its Kestrel host, and DB-IP's monthly download, in a project folder of
/// their own, as packages/php/tests/Server/CliTest.php checks the PHP drop-in's.
/// </summary>
public sealed class CliTests : ServerTestCase
{
    /// <summary>The served test's port, in the range kept for this port's servers (5300 to 5349).</summary>
    private const int ServePort = 5321;

    private const long October = 1_791_374_400_000; // 2026-10-07

    private readonly string _root = Path.Combine(Path.GetTempPath(), "runlight-cli-" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6)));

    public override ValueTask InitializeAsync()
    {
        Directory.CreateDirectory(_root);
        return base.InitializeAsync();
    }

    public override async ValueTask DisposeAsync()
    {
        await base.DisposeAsync();
        SqliteConnection.ClearAllPools();
        try
        {
            Directory.Delete(_root, true);
        }
        catch (IOException)
        {
        }
    }

    private static SqlStore OpenStore(string? url, string path) => Stores.Sqlite(SqliteFactory.Instance, path);

    private void Configure(Dictionary<string, string> settings) =>
        File.WriteAllText(_root + "/config.json", Json.Stringify(JsObject.From(settings.Select(e => new KeyValuePair<string, object?>(e.Key, e.Value)))));

    private Config Settings()
    {
        var config = new Config(_root, null, OpenStore);
        Databases.OnCleanup(() => config.CloseAsync());
        return config;
    }

    /// <summary>The exit code, what it printed, and what it complained.</summary>
    private async Task<(int Code, string Out, string Err)> CliAsync(params string[] args)
    {
        var output = new StringWriter();
        var error = new StringWriter();
        int code = await Cli.RunAsync(args, _root, output, error, () => October, openStore: OpenStore);
        return (code, output.ToString(), error.ToString());
    }

    [Fact]
    public async Task Settings_come_from_config_json_with_paths_from_the_project_folder()
    {
        Configure(new() { ["RUNLIGHT_URL"] = "https://stats.example.com", ["TRUST_PROXY"] = "cf-connecting-ip", ["RUNLIGHT_GEO"] = "off" });
        var config = Settings();
        Assert.Equal("https://stats.example.com", config.Url());
        Assert.Equal(new ProxyTrust(true, "cf-connecting-ip"), config.TrustProxy());
        Assert.Equal(_root + "/runlight-data", config.DataDir());
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(config.DataDir())); // the data folder is private
        }
        Assert.Null(config.Geo());
        Assert.Null(config.DbIp());

        string secret = config.Secret();
        Assert.Matches("^[0-9a-f]{64}\\z", secret);
        Assert.Equal(secret, Settings().Secret()); // the secret is made once and kept
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(_root + "/runlight-data/secret"));
        }

        // The environment wins over the file.
        Environment.SetEnvironmentVariable("TRUST_PROXY", "false");
        Assert.Equal(new ProxyTrust(false, null), Settings().TrustProxy());

        Configure(new() { ["RUNLIGHT_URL"] = "https://stats.example.com/dashboard" });
        var e = Assert.Throws<InvalidOperationException>(() => Settings().Url());
        Assert.Contains("set RUNLIGHT_URL to the dashboard's address only", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_setup_code_is_written_down_once_and_unlocks_the_first_account()
    {
        Configure(new() { ["RUNLIGHT_URL"] = "https://stats.example.com", ["RUNLIGHT_GEO"] = "off" });
        var config = Settings();
        var server = config.Standalone();
        string text = File.ReadAllText(config.SetupFile());
        Assert.Matches(new Regex("^Open this link to create the first Runlight account\\. It works only while Runlight has no account\\.\\nhttps://stats\\.example\\.com/setup\\?code=[A-Za-z0-9_-]{12}\\n\\z"), text);
        Assert.Equal(config.SetupCode(), Settings().SetupCode()); // every process reads the same code
        var page = await server.HandleAsync(new Request("https://stats.example.com/"));
        Assert.Equal(403, page.Status);
        Assert.Contains("in the file setup.txt", page.Text(), StringComparison.Ordinal);
        Assert.Equal(200, (await server.HandleAsync(new Request("https://stats.example.com/setup?code=" + config.SetupCode()))).Status);

        var (code, output, _) = await CliAsync("setup");
        Assert.Equal(0, code);
        Assert.Equal(text, output);
    }

    [Fact]
    public async Task Password_makes_the_owner_then_gives_a_new_password_and_turns_off_two_factor()
    {
        Configure(new() { ["RUNLIGHT_GEO"] = "off" });
        var (code, output, _) = await CliAsync("password", "Jon@Example.com");
        Assert.Equal(0, code);
        Assert.Matches(new Regex("^Account made, as the owner, for jon@example\\.com: [^ \\n]{16}\\nSign in, and change it by running this again whenever you like\\.\\n\\z"), output);
        Assert.False(File.Exists(_root + "/runlight-data/setup.txt")); // no setup link is made for a server that has an account

        var server = Settings().Standalone(setup: false);
        var user = await server.Accounts.ByEmailAsync("jon@example.com");
        await server.Runlight.Store.Db.RunAsync("UPDATE rl_users SET totp_secret = ? WHERE id = ?", ["sealed", user!.Str("id")]);
        Assert.True((await server.Accounts.ByEmailAsync("jon@example.com"))!.Bool("twoFactor"));

        (code, output, _) = await CliAsync("password", "jon@example.com");
        Assert.Equal(0, code);
        string password = Regex.Match(output, ": ([^ \\n]+)\\n").Groups[1].Value;
        Assert.StartsWith("New password for jon@example.com: ", output, StringComparison.Ordinal);
        Assert.Contains("Two-factor sign-in is now off for this account; turn it on again under Account.\n", output, StringComparison.Ordinal);
        Assert.False((await server.Accounts.ByEmailAsync("jon@example.com"))!.Bool("twoFactor"));
        Assert.NotNull(await server.Accounts.SignInAsync("jon@example.com", password)); // the printed password signs in

        (_, output, _) = await CliAsync("setup");
        Assert.Equal("Runlight already has an account. To get into one, run runlight password <email>.\n", output);

        string error;
        (code, _, error) = await CliAsync("password");
        Assert.Equal(1, code);
        Assert.Contains("name the account", error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Migrate_cron_help_and_unknown_commands()
    {
        Configure(new() { ["RUNLIGHT_GEO"] = "off" });
        var (code, output, error) = await CliAsync("migrate");
        Assert.Equal(0, code);
        Assert.Equal("Runlight's tables are up to date in " + _root + "/runlight-data/runlight.db.\n", output);
        Assert.True(File.Exists(_root + "/runlight-data/runlight.db"));

        // A setup link written before the first account goes at the next check.
        var config = Settings();
        config.SetupCode();
        await config.CloseAsync();
        await CliAsync("password", "jon@example.com");
        (code, output, error) = await CliAsync("cron");
        Assert.Equal((0, "", ""), (code, output, error)); // cron is quiet when all is well
        Assert.False(File.Exists(_root + "/runlight-data/setup.txt"));

        (code, _, error) = await CliAsync("nonsense");
        Assert.Equal(1, code);
        Assert.Contains("unknown command \"nonsense\"", error, StringComparison.Ordinal);

        (code, _, error) = await CliAsync("cron", "--config", _root + "/missing.json");
        Assert.Equal(1, code);
        Assert.Contains("there is no config file at", error, StringComparison.Ordinal);

        (code, output, _) = await CliAsync("--help");
        Assert.Equal(0, code);
        Assert.Contains("runlight agents --log <file>    Count AI agents from a web server's access log", output, StringComparison.Ordinal);
        Assert.StartsWith("Runlight " + Version.Current + ", privacy friendly", output, StringComparison.Ordinal);
        (_, output, _) = await CliAsync("--version");
        Assert.Equal(Version.Current + "\n", output);
        (code, _, error) = await CliAsync("serve");
        Assert.Equal(1, code);
        Assert.Contains("the server runs from the runlight tool", error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_sqlite_file_gets_its_folder()
    {
        var store = Stores.Sqlite(SqliteFactory.Instance, _root + "/data/deeper/runlight.db");
        await store.MigrateAsync();
        await store.CloseAsync();
        Assert.True(File.Exists(_root + "/data/deeper/runlight.db"));
    }

    [Fact]
    public async Task Serve_answers_on_kestrel_says_how_to_make_the_first_account_and_stops_when_asked()
    {
        Configure(new() { ["PORT"] = Js.Str(ServePort), ["HOST"] = "127.0.0.1", ["RUNLIGHT_GEO"] = "off" });
        using var stop = new CancellationTokenSource();
        var output = new StringWriter();
        var error = new StringWriter();
        var running = Cli.RunAsync(["serve"], _root, output, error, () => October, openStore: OpenStore, serve: (config, server, said) => StandaloneHost.RunAsync(config, server, said, stop.Token));
        using var client = new HttpClient();
        string health = "";
        for (int i = 0; i < 200 && health != "ok"; i++)
        {
            try
            {
                health = await client.GetStringAsync("http://127.0.0.1:" + ServePort + "/healthz");
            }
            catch (HttpRequestException)
            {
                await Task.Delay(25);
            }
        }
        Assert.Equal("ok", health);
        var home = await client.GetAsync("http://127.0.0.1:" + ServePort + "/");
        Assert.Equal(403, (int)home.StatusCode); // waiting for setup
        Assert.False(home.Headers.Contains("Server"));
        var script = await client.GetAsync("http://127.0.0.1:" + ServePort + "/s.js");
        Assert.Equal(200, (int)script.StatusCode);
        await stop.CancelAsync();
        Assert.Equal(0, await running);
        Assert.Matches(new Regex("^Runlight " + Regex.Escape(Version.Current) + " is listening on http://127\\.0\\.0\\.1:" + ServePort + "\\nData: .*runlight\\.db\\n\\nNo account yet\\. Open this link to create the first one:\\n  http://127\\.0\\.0\\.1:" + ServePort + "/setup\\?code=[A-Za-z0-9_-]{12}\\n\\n\\z"), output.ToString());
        Assert.Equal("", error.ToString());
    }

    [Fact]
    public void Database_urls_become_the_drivers_connection_strings()
    {
        Assert.Equal("postgres", DatabaseUrl.Kind("postgres://u@h/d"));
        Assert.Equal("postgres", DatabaseUrl.Kind("postgresql://u@h/d"));
        Assert.Equal("mysql", DatabaseUrl.Kind("mysql://u@h/d"));
        Assert.Equal("mysql", DatabaseUrl.Kind("MariaDB://u@h/d"));
        Assert.Null(DatabaseUrl.Kind("sqlite:/x.db"));
        var pg = new NpgsqlConnectionStringBuilder(DatabaseUrl.Postgres("postgres://run%40light:p%3Ba%20ss@db.example.com/stats?sslmode=verify-full"));
        Assert.Equal(("db.example.com", 5432, "stats", "run@light", "p;a ss", SslMode.VerifyFull), (pg.Host, pg.Port, pg.Database, pg.Username, pg.Password, pg.SslMode));
        var my = new MySqlConnector.MySqlConnectionStringBuilder(DatabaseUrl.MySql("mariadb://root:runlight@127.0.0.1:33114/runlight"));
        Assert.Equal(("127.0.0.1", 33114u, "runlight", "root", "runlight", "utf8mb4"), (my.Server, my.Port, my.Database, my.UserID, my.Password, my.CharacterSet));
        Assert.Throws<ArgumentException>(() => DatabaseUrl.Postgres("not a url"));
    }

    [Fact]
    public async Task A_postgres_url_opens_the_store()
    {
        if (Databases.PgUrl() == null)
        {
            Assert.Skip("RUNLIGHT_TEST_PG is not set");
        }
        string schema = await Databases.PgSchemaAsync();
        var b = new NpgsqlConnectionStringBuilder(DatabaseUrl.Postgres(Databases.PgUrl()!)) { SearchPath = schema };
        var store = Stores.Postgres(NpgsqlDataSource.Create(b.ConnectionString), 120_000);
        Databases.OnCleanup(() => store.CloseAsync().AsTask());
        await store.MigrateAsync();
        await store.SetSettingAsync("hello", "world");
        Assert.Equal("world", await store.SettingAsync("hello"));
    }

    [Fact]
    public async Task Db_ip_downloads_this_month_or_last_and_keeps_only_the_newest()
    {
        byte[] db = Convert.FromBase64String(((JsObject)Fixtures.Load("geo").Arr("databases")![0]!).Str("base64")!);
        string dir = _root + "/geo";
        var asked = new List<string>();
        var logged = new List<string>();
        var published = new List<string> { "2026-09" };
        Task<bool> Download(string url, string file, CancellationToken _)
        {
            asked.Add(url);
            string release = Regex.Match(url, "lite-([0-9]{4}-[0-9]{2})\\.mmdb\\.gz\\z").Groups[1].Value;
            if (!published.Contains(release))
            {
                return Task.FromResult(false);
            }
            File.WriteAllBytes(file, Gzip(db));
            return Task.FromResult(true);
        }
        var geo = new DbIp(dir, "city", Download, logged.Add);
        Assert.Null(geo.Lookup()); // nothing to look up before the first download

        await geo.RefreshAsync(October);
        Assert.Equal(["https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz", "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz"], asked); // a month's file appears a day or so in, so last month's stands in
        Assert.Equal(["Runlight: location data from DB-IP (2026-09) is ready."], logged);
        Assert.Equal(dir + "/dbip-city-lite-2026-09.mmdb", geo.Newest());
        Assert.NotNull(geo.Lookup());
        Assert.Null(geo.Current()("203.0.113.1")); // a running server reads nothing until it loads the release
        geo.LoadNewest();

        published.Add("2026-10");
        asked.Clear();
        await geo.RefreshAsync(October);
        Assert.Equal(["https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz"], asked);
        Assert.Equal([dir + "/dbip-city-lite-2026-10.mmdb"], Directory.GetFiles(dir).Select(f => dir + "/" + Path.GetFileName(f))); // older releases go
        asked.Clear();
        await geo.RefreshAsync(October);
        Assert.Empty(asked); // once this month is there, nothing is fetched

        // January's fallback is December of the year before, and a broken file is never kept.
        var broken = new DbIp(dir + "/country", "country", (url, file, _) =>
        {
            File.WriteAllBytes(file, Gzip("not a database"u8.ToArray()));
            return Task.FromResult(true);
        }, logged.Add);
        await broken.RefreshAsync(1_798_761_600_000 + 86_400_000); // 2027-01-02
        Assert.Contains("dbip-country-lite-2026-12.mmdb.gz", logged[^1], StringComparison.Ordinal);
        Assert.Null(broken.Newest());
    }

    private static byte[] Gzip(byte[] bytes)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionMode.Compress))
        {
            gzip.Write(bytes);
        }
        return output.ToArray();
    }
}
