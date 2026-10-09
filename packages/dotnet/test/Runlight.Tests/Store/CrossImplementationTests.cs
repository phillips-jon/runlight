using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Store;

/// <summary>
/// One database, every implementation. packages/php/tests/fixtures/store.db was built by the
/// TypeScript SDK and store.json holds what its SqlStore reads answered; the .NET store must answer
/// the same over a copy of that file, and over the same rows copied into Postgres and MySQL.
/// </summary>
public sealed class CrossImplementationTests : IAsyncLifetime
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
                File.Delete(file);
            }
            catch (IOException)
            {
            }
        }
    }

    private string Copy()
    {
        string file = Path.Combine(Path.GetTempPath(), "rl-store-" + Guid.NewGuid().ToString("N") + ".db");
        File.Copy(FixturePath("store.db"), file);
        _files.AddRange([file, file + "-wal", file + "-shm"]);
        return file;
    }

    private static List<JsObject> Calls() => Load("store").Arr("calls")!.Cast<JsObject>().ToList();

    /// <summary>A read's answer, called by the SDK's method name with the fixture's arguments.</summary>
    public static async Task<object?> AnswerAsync(SqlStore store, string method, List<object?> args)
    {
        JsObject O(int i) => (JsObject)args[i]!;
        string S(int i) => (string)args[i]!;
        long L(int i) => (long)Js.Num(args[i]);
        int I(int i) => (int)Js.Num(args[i]);
        List<JsObject> Os(int i) => ((List<object?>)args[i]!).Cast<JsObject>().ToList();
        switch (method)
        {
            case "sites":
                return await store.SitesAsync();
            case "siteOverrides":
                return JsObject.From((await store.SiteOverridesAsync()).Select(e => new KeyValuePair<string, object?>(e.Key, e.Value)));
            case "lastSeen":
                return await store.LastSeenAsync(S(0));
            case "firstSeen":
                return await store.FirstSeenAsync(S(0));
            case "firstOwnVisit":
                return await store.FirstOwnVisitAsync(S(0));
            case "rollupDays":
                {
                    var days = await store.RollupDaysAsync(S(0));
                    days.Sort(StringComparer.Ordinal);
                    return days;
                }
            case "stats":
                return await store.StatsAsync(O(0));
            case "visitors":
                return await store.VisitorsAsync(O(0));
            case "hourly":
                return await store.HourlyAsync(O(0));
            case "breakdown":
                return await store.BreakdownAsync(O(0), S(1), I(2), I(3));
            case "series":
                return await store.SeriesAsync(O(0), Os(1));
            case "goalTotalsAll":
                return JsObject.From((await store.GoalTotalsAllAsync(O(0), Os(1))).Select(e => new KeyValuePair<string, object?>(e.Key, e.Value)));
            case "goalTotals":
                return await store.GoalTotalsAsync(O(0), O(1));
            case "goalBreakdown":
                return await store.GoalBreakdownAsync(O(0), O(1), S(2), args.Count > 3 ? I(3) : 10);
            case "goalSeries":
                return await store.GoalSeriesAsync(O(0), O(1), Os(2));
            case "funnelCounts":
                return await store.FunnelCountsAsync(O(0), O(1));
            case "journeyPages":
                {
                    var (rows, sampled) = await store.JourneyPagesAsync(O(0), I(1));
                    return new JsObject { ["rows"] = rows, ["sampled"] = sampled };
                }
            case "eventPropKeys":
                return await store.EventPropKeysAsync(O(0), S(1));
            case "eventPropValues":
                return await store.EventPropValuesAsync(O(0), S(1), S(2), I(3));
            case "links":
                return await store.LinksAsync(S(0), L(1), L(2));
            case "linkSeries":
                return await store.LinkSeriesAsync(S(0), S(1), Os(2));
            case "linkBreakdown":
                return await store.LinkBreakdownAsync(S(0), S(1), L(2), L(3), S(4), I(5));
            case "realtime":
                return await store.RealtimeAsync(S(0), L(1));
            case "goals":
                return await store.GoalsAsync(args.Count > 0 ? (string?)args[0] : null);
            case "goalById":
                return await store.GoalByIdAsync(S(0));
            case "funnels":
                return await store.FunnelsAsync(S(0));
            case "linkBySlug":
                return await store.LinkBySlugAsync(S(0));
            case "linkById":
                return await store.LinkByIdAsync(S(0));
            case "linkDomains":
                return await store.LinkDomainsAsync();
            case "shares":
                return await store.SharesAsync(S(0));
            case "shareById":
                return await store.ShareByIdAsync(S(0));
            case "tokens":
                return await store.TokensAsync();
            case "tokenByHash":
                return await store.TokenByHashAsync(S(0));
            case "reports":
                return await store.ReportsAsync(args.Count > 0 ? (string?)args[0] : null);
            case "reportBy":
                return await store.ReportByAsync(S(0), S(1));
            case "setting":
                return await store.SettingAsync(S(0));
            case "settingsStartingWith":
                return await store.SettingsStartingWithAsync(S(0));
            case "saltIfExists":
                return await store.SaltIfExistsAsync(S(0));
            case "pageview":
                return await store.PageviewAsync(S(0), S(1));
            case "openSession":
                return await store.OpenSessionAsync(S(0), ((List<object?>)args[1]!).Cast<string>().ToList(), L(2));
            default:
                throw new InvalidOperationException("no such read: " + method);
        }
    }

    private static async Task AssertAnswersAsync(SqlStore store, string label)
    {
        var failures = new List<string>();
        var calls = Calls();
        for (int i = 0; i < calls.Count; i++)
        {
            var call = calls[i];
            string expected = J(call.Get("result"));
            string actual;
            try
            {
                actual = J(Wf(await AnswerAsync(store, call.Str("method")!, call.Arr("args")!)));
            }
            catch (Exception e)
            {
                actual = e.GetType().Name + ": " + e.Message;
            }
            if (actual != expected)
            {
                string args = J(call.Get("args"));
                failures.Add("#" + i + " " + call.Str("method") + "(" + args[..Math.Min(300, args.Length)] + ")\n  expected " + expected + "\n  actual   " + actual);
            }
        }
        NoFailures(failures.Select(f => label + ": " + f).ToList(), 15);
    }

    [Fact]
    public void The_fixture_covers_every_kind_of_read()
    {
        var methods = Calls().Select(c => c.Str("method")).ToHashSet();
        Assert.True(Calls().Count > 1500);
        foreach (string method in new[] { "stats", "series", "hourly", "breakdown", "goalTotalsAll", "goalSeries", "funnelCounts", "journeyPages", "eventPropKeys", "eventPropValues", "links", "linkSeries", "realtime" })
        {
            Assert.Contains(method, methods);
        }
    }

    [Fact]
    public async Task DotNet_reads_a_database_the_TypeScript_SDK_wrote_and_answers_the_same()
    {
        var store = Stores.Sqlite(SqliteFactory.Instance, Copy());
        await store.MigrateAsync();
        await AssertAnswersAsync(store, "sqlite");
        // Opening it changed nothing a reader would see: the schema is the same version.
        Assert.Equal("[{\"value\":\"11\"}]", J(await store.Db.AllAsync("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")));
        await store.CloseAsync();
    }

    [Theory]
    [MemberData(nameof(Databases.ServerData), MemberType = typeof(Databases))]
    public async Task The_same_rows_in_Postgres_and_MySQL_answer_the_same(string kind)
    {
        if (kind == "none")
        {
            Assert.Skip("Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL to compare Postgres and MySQL too.");
        }
        var source = Stores.Sqlite(SqliteFactory.Instance, Copy());
        var target = await Databases.FreshAsync(kind);
        await target.MigrateAsync();
        string[] tables = ["rl_meta", "rl_sites", "rl_salts", "rl_sessions", "rl_events", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_settings", "rl_reports", "rl_tokens", "rl_funnels", "rl_rollup_days", "rl_rollups"];
        await target.TransactionAsync(async into =>
        {
            foreach (string table in tables)
            {
                await into.Db.RunAsync("DELETE FROM " + table);
                foreach (var row in await source.Db.AllAsync("SELECT * FROM " + table))
                {
                    var columns = row.Keys.Select(c => "\"" + c + "\"");
                    await into.Db.RunAsync("INSERT INTO " + table + " (" + string.Join(", ", columns) + ") VALUES (" + string.Join(", ", row.Keys.Select(_ => "?")) + ")", [.. row.Select(e => e.Value)]);
                }
            }
        });
        await AssertAnswersAsync(target, kind);
        await source.CloseAsync();
    }

    [Fact]
    public async Task The_TypeScript_SDK_reads_a_database_DotNet_wrote_and_answers_the_same()
    {
        string? node = Node.Binary();
        if (node == null)
        {
            Assert.Skip("node 22 or later, with the repository installed, reads the .NET database; neither was found.");
        }
        string file = Path.Combine(Path.GetTempPath(), "rl-dotnet-" + Guid.NewGuid().ToString("N") + ".db");
        _files.AddRange([file, file + "-wal", file + "-shm"]);
        var store = Stores.Sqlite(SqliteFactory.Instance, file);
        var calls = await Seed.EverythingAsync(store);
        var mine = new List<string>();
        foreach (var call in calls)
        {
            mine.Add(J(Wf(await AnswerAsync(store, call.Str("method")!, call.Arr("args")!))));
        }
        await store.Db.RunAsync("PRAGMA journal_mode = DELETE");
        await store.CloseAsync();
        SqliteConnection.ClearAllPools();

        string callsFile = Path.Combine(Path.GetTempPath(), "rl-calls-" + Guid.NewGuid().ToString("N") + ".json");
        _files.Add(callsFile);
        await File.WriteAllTextAsync(callsFile, J(calls));
        var (status, output, error) = await Node.StoreAsync(node, "read", file, callsFile);
        Assert.True(status == 0, error);
        Assert.True(Json.TryParse(output, out object? parsed) && parsed is List<object?>, output[..Math.Min(500, output.Length)] + "\n" + error);
        var theirs = (List<object?>)parsed!;
        Assert.Equal(calls.Count, theirs.Count);
        var failures = new List<string>();
        for (int i = 0; i < calls.Count; i++)
        {
            string b = J(theirs[i]);
            if (mine[i] != b)
            {
                failures.Add("#" + i + " " + calls[i].Str("method") + "\n  dotnet " + mine[i] + "\n  ts     " + b);
            }
        }
        NoFailures(failures, 15);
        Assert.True(calls.Count > 100);
    }
}
