using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Runlight.Store;
using Runlight.Tests.Store;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>The scheduled check and the rollups it builds, as rollups.test.ts and hardening.test.ts test the process around the store.</summary>
public sealed class CheckTests : CoreTestCase
{
    private static readonly string[] Pages = ["/", "/blog/one", "/blog/two", "/pricing", "/about"];
    private static readonly string[] Referrers = ["https://www.google.com/", "https://news.ycombinator.com/", "", "https://chatgpt.com/", "https://t.co/x"];
    private static readonly string[] Countries = ["GB", "US", "DE", "CA"];

    private static SiteOptions Site(string timezone) => new() { Hostnames = ["example.com"], Timezone = timezone };

    /// <summary>Every report this test compares before and after the days are built.</summary>
    private static async Task<JsObject> EverythingAsync(Harness t)
    {
        var output = new JsObject();
        var ranges = new (string, JsObject)[] { ("7d", t.Query("2026-09-30", "2026-10-06")), ("30d", t.Query("2026-09-07", "2026-10-06")), ("some", t.Query("2026-09-29", "2026-10-03")), ("all", await t.AllAsync()) };
        foreach (var (name, q) in ranges)
        {
            output["stats " + name] = await t.StatsAsync(q);
            output["hourly " + name] = await t.Store.HourlyAsync(q);
            foreach (string dimension in new[] { "page", "event", "entry", "exit", "source", "channel", "referrer", "country", "browser", "device", "os" })
            {
                output[dimension + " " + name] = await t.Store.BreakdownAsync(q, dimension, 3, 0);
                output[dimension + " " + name + " page 2"] = await t.Store.BreakdownAsync(q, dimension, 3, 3);
            }
        }
        output["filtered"] = await t.StatsAsync(t.Query("2026-09-07", "2026-10-06", null, new JsObject { ["dimension"] = "country", ["op"] = "is", ["value"] = "GB" }));
        return output;
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Reports_read_from_daily_rollups_match_reports_read_from_every_visit(string kind)
    {
        // Toronto, so local days and UTC days differ, starting ten days back.
        var t = await Harness.CreateAsync(kind, Site("America/Toronto"));
        long start = t.Now;
        t.Advance(-10 * 24 * HOUR);
        int n = 0;
        for (int day = 0; day < 10; day++)
        {
            for (int v = 0; v < 6; v++)
            {
                n++;
                string ip = "203.0.113." + (n % 40);
                var headers = new Dictionary<string, string> { ["x-vercel-ip-country"] = Countries[n % 4] };
                string? ua = n % 3 == 0 ? Harness.SafariIphone : null;
                for (int p = 0; p < 1 + (n % 3); p++)
                {
                    string id = "pv" + n + "x" + p;
                    await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com" + Pages[(n + p) % 5], ["r"] = p == 0 ? Referrers[n % 5] : "", ["i"] = id }, ua, ip, headers);
                    t.Advance(20_000 + (n % 5) * 7_000);
                    if (n % 2 == 0)
                    {
                        await t.SendAsync(new JsObject { ["k"] = "engagement", ["u"] = "https://example.com/", ["i"] = id, ["e"] = 9_000L + n * 100, ["d"] = 40L + (n % 60) }, ua, ip, headers);
                    }
                    if (n % 4 == 0)
                    {
                        await t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/", ["i"] = id, ["n"] = "Signup" }, ua, ip, headers);
                    }
                }
                t.Advance(3 * HOUR + (n % 7) * 60_000);
            }
            // A visit that runs past midnight: it belongs to the day it started.
            t.Advance(24 * HOUR - 6 * (3 * HOUR) - 30 * 60_000);
        }
        t.Advance(start - t.Now + 2 * HOUR);

        string before = Loose(await EverythingAsync(t));
        int built = 0;
        for (int made = await t.Rl.BuildRollupsAsync(); made > 0; made = await t.Rl.BuildRollupsAsync())
        {
            built += made;
        }
        Assert.True(built >= 8);
        Assert.Equal(0, await t.Rl.BuildRollupsAsync()); // a built day is not built again
        Assert.Equal(before, Loose(await EverythingAsync(t)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_late_event_and_engagement_on_an_old_pageview_are_counted_once_the_day_is_built_again(string kind)
    {
        var t = await Harness.CreateAsync(kind, Site("UTC"));
        // Evening of October 5th, then rollups built the next morning.
        t.Now = Utc(2026, 10, 5, 20);
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/", ["i"] = "late1" }, ip: "203.0.113.50");
        t.Advance(7 * HOUR);
        Assert.True(await t.Rl.BuildRollupsAsync() >= 1);
        // The tab was left open overnight: its event and engagement arrive now.
        await t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/", ["i"] = "late1", ["n"] = "Signup" }, ip: "203.0.113.50");
        await t.SendAsync(new JsObject { ["k"] = "engagement", ["u"] = "https://example.com/", ["i"] = "late1", ["e"] = 60_000L, ["d"] = 80L }, ip: "203.0.113.50");
        var q = t.Query("2026-10-05", "2026-10-05");
        async Task<JsObject> Read() => new()
        {
            ["stats"] = await t.StatsAsync(q),
            ["events"] = await t.Store.BreakdownAsync(q, "event", 10, 0),
            ["pages"] = await t.Store.BreakdownAsync(q, "page", 10, 0),
        };
        await t.Rl.BuildRollupsAsync();
        var rolled = await Read();
        await t.Store.ClearRollupsAsync("default");
        var raw = await Read();
        Assert.Equal(Loose(raw), Loose(rolled));
        Assert.Equal(0, raw.Obj("stats")!.Num("bounceRate")); // the event means the visit did not bounce
        Assert.Equal(["Signup"], ((List<JsObject>)raw.Get("events")!).Select(e => e.Str("value")));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task After_a_timezone_change_only_days_after_it_are_built(string kind)
    {
        var t = await Harness.CreateAsync(kind, Site("UTC"));
        await t.Rl.InitAsync();
        t.Now = Utc(2026, 10, 3, 10);
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/", ["r"] = "", ["i"] = "a1" }, ip: "203.0.113.1");
        t.Advance(10 * HOUR);
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/", ["r"] = "", ["i"] = "a2" }, ip: "203.0.113.1");
        t.Now = Utc(2026, 10, 4, 12);
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/", ["r"] = "", ["i"] = "b1" }, ip: "203.0.113.2");
        t.Now = Utc(2026, 10, 6, 12);
        Assert.True(await t.Rl.BuildRollupsAsync() >= 2);

        await t.Rl.UpdateSiteAsync("default", new JsObject { ["timezone"] = "Asia/Tokyo" });
        var q = t.Query("2026-10-03", "2026-10-05");
        var before = await t.StatsAsync(q);
        Assert.Equal(0, await t.Rl.BuildRollupsAsync()); // days before the change stay counted visit by visit
        Assert.Equal(J(before), J(await t.StatsAsync(q)));
        Assert.Equal(2, before.Num("visitors"));
        // A day that starts after the change is built as usual.
        t.Advance(3 * 24 * HOUR);
        Assert.True(await t.Rl.BuildRollupsAsync() >= 1);
    }

    private static string TempFile()
    {
        string file = Path.Combine(Path.GetTempPath(), "runlight-zones-" + Guid.NewGuid().ToString("N") + ".db");
        Databases.OnCleanup(() =>
        {
            SqliteConnection.ClearAllPools();
            foreach (string f in new[] { file, file + "-wal", file + "-shm" })
            {
                File.Delete(f);
            }
            return Task.CompletedTask;
        });
        return file;
    }

    private static SqlStore FileStore(string file)
    {
        var store = Stores.Sqlite(SqliteFactory.Instance, file);
        Databases.OnCleanup(() => store.CloseAsync().AsTask());
        return store;
    }

    [Fact]
    public async Task Two_processes_on_one_database_a_stale_timezone_builds_nothing_and_clears_nothing()
    {
        string file = TempFile();
        long now = Utc(2026, 10, 3, 12);
        var old = new Runlight(new RunlightOptions { Store = FileStore(file), Site = Site("UTC"), Now = () => now });
        await old.InitAsync();
        await old.CollectAsync(Harness.Hit("https://example.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/" }, Harness.SafariIphone, "203.0.113.1"));
        now = Utc(2026, 10, 6, 12);
        Assert.True(await old.BuildRollupsAsync() >= 2); // the old process builds in UTC
        async Task<long> Built() => (long)Js.Number((await old.Store.Db.AllAsync("SELECT COUNT(*) AS n FROM rl_rollup_days"))[0].Get("n"));

        // A new copy starts with the timezone changed in code: it clears the old days once, at startup.
        var fresh = new Runlight(new RunlightOptions { Store = FileStore(file), Site = Site("Asia/Tokyo"), Now = () => now });
        await fresh.InitAsync();
        Assert.Equal(0, await Built());
        // The old copy, still running, neither builds in UTC nor clears what the new one does.
        now += 3 * DAY;
        Assert.Equal(0, await old.BuildRollupsAsync());
        Assert.True(await fresh.BuildRollupsAsync() >= 1);
        long afterFresh = await Built();
        Assert.Equal(0, await old.BuildRollupsAsync());
        Assert.Equal(afterFresh, await Built()); // nothing cleared by the stale copy
    }

    [Fact]
    public async Task A_timezone_changed_in_the_dashboard_reaches_another_process_at_its_next_check()
    {
        string file = TempFile();
        long now = Utc(2026, 10, 6, 12);
        var a = new Runlight(new RunlightOptions { Store = FileStore(file), Site = Site("UTC"), Now = () => now });
        var b = new Runlight(new RunlightOptions { Store = FileStore(file), Site = Site("UTC"), Now = () => now });
        await a.InitAsync();
        await b.InitAsync();
        await a.UpdateSiteAsync("default", new JsObject { ["timezone"] = "Europe/Paris" });
        Assert.Equal("UTC", b.Site("default")!.Str("timezone"));
        // A visit after the change, and days enough for its day to be built.
        await b.Store.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)", [now + DAY, now + DAY]);
        now += 3 * DAY;
        Assert.Equal(0, await b.BuildRollupsAsync()); // holding the old timezone, it builds nothing
        await b.CheckAsync();
        Assert.Equal("Europe/Paris", b.Site("default")!.Str("timezone"));
        var days = (await b.Store.RollupDaysAsync("default")).Order(StringComparer.Ordinal).ToList();
        Assert.Equal(["2026-10-07", "2026-10-08"], days); // then it builds the days after the change
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Events_left_behind_by_an_older_version_whose_visit_retention_removed_are_swept_once(string kind)
    {
        var t = await Harness.CreateAsync(kind, Site("UTC"));
        await t.Rl.InitAsync();
        long old = t.Now - 400 * DAY;
        var db = t.Store.Db;
        await db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)", [old, old]);
        await db.RunAsync("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', 'v1', 's1', 'p1', '/', 'example.com')", [old]);
        // An event that joined the visit long after it started, as older versions allowed.
        await db.RunAsync("INSERT INTO rl_events (site, ts, kind, visitor, session, name, path, hostname) VALUES ('default', ?, 'event', 'v1', 's1', 'Late', '/', 'example.com')", [t.Now - 30 * DAY]);
        await t.Rl.SetRetentionAsync("default", 6);
        await t.Rl.IdleAsync();
        await t.Rl.CheckAsync();
        Assert.Empty(await db.AllAsync("SELECT name FROM rl_events WHERE site = 'default'"));
        Assert.Equal("1", await t.Store.SettingAsync("orphans-swept:default"));
    }

    [Fact]
    public async Task Planner_statistics_are_gathered_once_a_day()
    {
        var watched = new WatchedDb((await Databases.FreshAsync("sqlite")).Db);
        int analyzed = 0;
        watched.Before = (sql, _) =>
        {
            if (sql == "ANALYZE")
            {
                analyzed++;
            }
            return Task.CompletedTask;
        };
        var t = Harness.Create(new SqlStore(watched), Site("UTC"));
        await t.Rl.InitAsync();
        Assert.Equal(1, analyzed); // a database without statistics gets them at the start
        await t.Rl.CheckAsync();
        await t.Rl.CheckAsync();
        Assert.Equal(2, analyzed); // not again the same day
        t.Advance(DAY);
        await t.Rl.CheckAsync();
        Assert.Equal(3, analyzed);
        Assert.NotEmpty(await t.Store.Db.AllAsync("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'")); // statistics written
    }

    [Fact]
    public async Task Short_link_clicks_are_not_visits_in_the_heatmap_raw_or_rolled_up_nor_the_first_visit()
    {
        long clock = Utc(2026, 10, 7, 12);
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Sites = [new SiteOptions { Id = "a", Name = "Site A", Hostnames = ["a.com"] }], Now = () => clock });
        await rl.InitAsync();
        long day = Utc(2026, 10, 5, 15);
        // A session opened only by a short link click, then a real visit.
        await rl.Store.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'a', 'v1', ?, ?, 0, 0, 0)", [day - 3_600_000, day - 3_600_000]);
        await rl.Store.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'a', 'v2', ?, ?, 1, 0, 0)", [day, day]);
        Assert.Equal(day, await rl.Store.FirstOwnVisitAsync("a"));
        var query = new JsObject { ["site"] = "a", ["from"] = Utc(2026, 10, 1), ["to"] = Utc(2026, 10, 7), ["filters"] = new List<object?>() };
        static double Sum(List<JsObject> rows) => rows.Sum(r => r.Num("visits"));
        Assert.Equal(1, Sum(await rl.Store.HourlyAsync(query))); // raw
        clock += 3 * 3_600_000;
        await rl.BuildRollupsAsync();
        Assert.Equal(1, Sum(await rl.Store.HourlyAsync(query))); // rolled up
    }

    [Fact]
    public async Task A_check_reports_what_it_sent()
    {
        var t = await Harness.CreateAsync("sqlite");
        Assert.Equal("{\"ok\":true,\"reports\":{\"sent\":0,\"failed\":0}}", J(await t.Rl.CheckAsync()));
    }

    [Fact]
    public async Task Checks_asked_for_at_once_share_one_run()
    {
        var t = await Harness.CreateAsync("sqlite");
        var results = await Task.WhenAll(t.Rl.CheckAsync(), t.Rl.CheckAsync());
        Assert.Same(results[0], results[1]);
        Assert.NotSame(results[0], await t.Rl.CheckAsync()); // a later check runs again
    }
}
