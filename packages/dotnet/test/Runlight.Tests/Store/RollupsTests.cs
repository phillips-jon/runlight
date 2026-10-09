using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Store.Seed;

namespace Runlight.Tests.Store;

/// <summary>Daily rollups, as rollups.test.ts and counting.test.ts test them at the store.</summary>
public sealed class RollupsTests : StoreTestCase
{
    private static readonly string[] Pages = ["/", "/blog/one", "/blog/two", "/pricing", "/about"];
    private static readonly string[] Sources = ["Google", "Hacker News", "", "ChatGPT", "Twitter"];
    private static readonly string[] Countries = ["GB", "US", "DE", "CA"];

    /// <summary>Ten days of visits, some running past midnight, ending two hours before NOW.</summary>
    private static async Task TenDaysAsync(SqlStore store)
    {
        long now = NOW - 10 * DAY;
        int n = 0;
        for (int day = 0; day < 10; day++)
        {
            for (int v = 0; v < 6; v++)
            {
                n++;
                long start = now;
                var rows = new List<object?[]>();
                for (int p = 0; p < 1 + n % 3; p++)
                {
                    string id = "pv" + n + "x" + p;
                    rows.Add(Pv(Pages[(n + p) % 5], now, id));
                    now += 20_000 + (n % 5) * 7_000;
                    if (n % 2 == 0)
                    {
                        rows.Add(Eng(id, now, 9_000 + n * 100L, 40 + n % 60));
                    }
                    if (n % 4 == 0)
                    {
                        rows.Add(Ev("Signup", now, null));
                    }
                }
                string source = Sources[n % 5];
                // Visitor ids change every day, as the daily salt changes them.
                await VisitAsync(store, "s" + n, "v" + (n % 4) + Date(start, "yyyyMMdd"), start, new JsObject
                {
                    ["source"] = source,
                    ["channel"] = source == "" ? "Direct" : "Referral",
                    ["referrerHost"] = source == "" ? "" : "x.example",
                    ["country"] = Countries[n % 4],
                    ["device"] = n % 3 == 0 ? "Mobile" : "Desktop",
                    ["browser"] = n % 3 == 0 ? "Safari" : "Chrome",
                    ["os"] = n % 3 == 0 ? "iOS" : "macOS",
                }, rows);
                now += 3 * HOUR + (n % 7) * MIN;
            }
            // A visit that runs past midnight belongs to the day it started.
            now += DAY - 6 * (3 * HOUR) - 30 * MIN;
        }
    }

    /// <summary>Every report the dashboard asks the store for, as JSON, for comparing before and after.</summary>
    private static async Task<Dictionary<string, string>> EverythingAsync(SqlStore store)
    {
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        var ranges = new (string Name, long From, long To)[]
        {
            ("7d", NOW - 7 * DAY, NOW + DAY),
            ("30d", NOW - 30 * DAY, NOW + DAY),
            ("odd", NOW - 6 * DAY - 5 * HOUR, NOW - 2 * DAY + 3 * HOUR),
            ("today", NOW - 12 * HOUR, NOW + 12 * HOUR),
            ("all", 0, NOW + DAY),
        };
        foreach (var (name, from, to) in ranges)
        {
            var query = Q(from, to);
            output["stats " + name] = J(await store.StatsAsync(query));
            var buckets = new List<JsObject>();
            for (long at = from == 0 ? NOW - 12 * DAY : from; at < to; at += DAY)
            {
                buckets.Add(new JsObject { ["start"] = at, ["end"] = Math.Min(at + DAY, to) });
            }
            output["series " + name] = J(await store.SeriesAsync(query, buckets));
            var hourly = await store.HourlyAsync(query);
            output["hourly " + name] = J(hourly.OrderBy(r => r.Num("quarter")).ToList());
            foreach (string dimension in new[] { "page", "event", "entry", "exit", "source", "channel", "referrer", "country", "browser", "device", "os" })
            {
                output[dimension + " " + name] = J(await store.BreakdownAsync(query, dimension, 3, 0));
                output[dimension + " " + name + " page 2"] = J(await store.BreakdownAsync(query, dimension, 3, 3));
            }
        }
        output["filtered"] = J(await store.StatsAsync(Q(NOW - 30 * DAY, NOW + DAY, F("country", "is", "GB"))));
        return output;
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Reports_read_from_daily_rollups_match_reports_read_from_every_visit(string kind)
    {
        var store = await StoreAsync(kind);
        await TenDaysAsync(store);
        var before = await EverythingAsync(store);
        Assert.True(await BuildDaysAsync(store, "default", NOW - 11 * DAY, NOW) >= 8);
        Assert.Equal(11, (await store.RollupDaysAsync("default")).Count);
        var after = await EverythingAsync(store);
        foreach (var (key, value) in before)
        {
            Assert.True(value == after[key], key + "\n  before " + value + "\n  after  " + after[key]);
        }

        // Proof the reports read the rollups: with the built days' raw visits gone, a long range still adds up.
        var span = (await store.Db.AllAsync("SELECT MIN(start_at) AS s, MAX(end_at) AS e FROM rl_rollup_days"))[0];
        long s = (long)Js.Number(span.Get("s"));
        long e = (long)Js.Number(span.Get("e"));
        await store.Db.RunAsync("DELETE FROM rl_events WHERE ts >= ? AND ts < ?", [s, e - 2 * HOUR]);
        await store.Db.RunAsync("DELETE FROM rl_sessions WHERE started_at >= ? AND started_at < ?", [s, e - 2 * HOUR]);
        var again = await EverythingAsync(store);
        foreach (string key in new[] { "stats 30d", "source 30d", "page 30d", "event 30d", "hourly 30d" })
        {
            Assert.True(before[key] == again[key], key + " comes from rollups\n  before " + before[key] + "\n  again  " + again[key]);
        }
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_late_event_and_engagement_on_an_old_pageview_are_counted_once_the_day_is_built_again(string kind)
    {
        var store = await StoreAsync(kind);
        // Evening of October 5th, then rollups built the next morning.
        long start = Utc(2026, 10, 5, 20);
        await VisitAsync(store, "s1", "v1", start, [], [Pv("/", start, "late1")]);
        long day5 = Utc(2026, 10, 5);
        await store.BuildRollupDayAsync("default", "2026-10-05", day5, day5 + DAY);
        // The tab was left open overnight: its event and engagement arrive now.
        long late = start + 7 * HOUR;
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = late, ["kind"] = "event", ["visitor"] = "v1", ["session"] = "s1", ["pageview"] = "late1", ["path"] = "/", ["hostname"] = "example.com", ["title"] = "", ["name"] = "Signup", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        await store.TouchSessionAsync("s1", late, "event", "/", false);
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = late, ["kind"] = "engagement", ["visitor"] = "v1", ["session"] = "s1", ["pageview"] = "late1", ["path"] = "/", ["hostname"] = "example.com", ["title"] = "", ["name"] = "", ["props"] = null, ["engagedMs"] = 60_000L, ["scroll"] = 80L, ["link"] = "" });
        await store.AddEngagementAsync("s1", 60_000);
        await store.TouchedOldVisitAsync("default", start, late - 2 * HOUR);
        // The day is forgotten.
        Assert.Empty(await store.RollupDaysAsync("default"));
        await store.TouchedOldVisitAsync("default", start, start - 1);
        var query = Q(day5, day5 + DAY);
        async Task<string> Read() => J(L(await store.StatsAsync(query), await store.BreakdownAsync(query, "event", 10, 0), await store.BreakdownAsync(query, "page", 10, 0)));
        await store.BuildRollupDayAsync("default", "2026-10-05", day5, day5 + DAY);
        string rolled = await Read();
        await store.ClearRollupsAsync("default");
        Assert.Empty(await store.RollupDaysAsync("default"));
        Assert.Equal(rolled, await Read());
        // The event means the visit did not bounce.
        Same(0, (await store.StatsAsync(query)).Get("bounceRate"));
        Same(L("Signup"), Column(await store.BreakdownAsync(query, "event", 10, 0), "value"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Ties_come_in_code_point_order_the_same_before_and_after_the_days_are_built(string kind)
    {
        var store = await StoreAsync(kind);
        string[] values = ["alpha", "Zeta", "beta", "Gamma", "émile", "Émile", "_x", "a-b", "ab"];
        long t = NOW - DAY;
        for (int i = 0; i < values.Length; i++)
        {
            await VisitAsync(store, "s" + i, "v" + i, t + i * MIN, new JsObject { ["utmCampaign"] = values[i] }, [Pv("/", t + i * MIN, "pv" + i)]);
        }
        var expected = values.OrderBy(v => v, StringComparer.Ordinal).Cast<object?>().ToList();
        var week = Q(NOW - 7 * DAY, NOW + DAY);
        Same(expected, Column(await store.BreakdownAsync(week, "utm_campaign", 20, 0), "value"), "read from every visit");
        await BuildDaysAsync(store, "default", NOW - 2 * DAY, NOW);
        Same(expected, Column(await store.BreakdownAsync(week, "utm_campaign", 20, 0), "value"), "read from rollups");
    }

    /// <summary>Visits some days back, built, as the two clearing tests start.</summary>
    private static async Task<(SqlStore Store, JsObject Month, string Before)> BuiltAsync(string kind, int days)
    {
        var store = await StoreAsync(kind);
        for (int d = 0; d < days; d++)
        {
            long t = NOW - (days + 2 - d) * DAY;
            await VisitAsync(store, "s" + d, "v" + d, t, [], [Pv("/", t, "d" + d)]);
        }
        await BuildDaysAsync(store, "default", NOW - (days + 3) * DAY, NOW - DAY);
        var month = Q(NOW - 30 * DAY, NOW + DAY);
        return (store, month, J(await store.StatsAsync(month)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_day_built_by_another_process_while_it_is_being_cleared_is_never_left_marked_built_without_its_numbers(string kind)
    {
        var (store, month, before) = await BuiltAsync(kind, 4);
        var watched = new WatchedDb(store.Db);
        var view = new SqlStore(watched);
        bool raced = false;
        watched.AfterRun = async (sql, _) =>
        {
            if (!raced && sql.StartsWith("DELETE FROM rl_rollup_days WHERE site = ? AND start_at", StringComparison.Ordinal))
            {
                raced = true;
                watched.AfterRun = null;
                // Another process builds the days right after their marks are deleted.
                await BuildDaysAsync(store, "default", NOW - 7 * DAY, NOW - DAY);
            }
        };
        await view.ClearRollupsAsync("default", from: NOW - 4 * DAY, to: NOW);
        Assert.True(raced);
        Assert.Equal(before, J(await store.StatsAsync(month)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Clearing_days_that_stops_part_way_leaves_none_marked_built_without_its_numbers(string kind)
    {
        var (store, month, before) = await BuiltAsync(kind, 8);
        var watched = new WatchedDb(store.Db);
        int deletes = 0;
        watched.Before = (sql, _) =>
        {
            if (sql.StartsWith("DELETE FROM rl_rollups WHERE", StringComparison.Ordinal) && ++deletes > 3)
            {
                throw new InvalidOperationException("connection lost");
            }
            return Task.CompletedTask;
        };
        // The clear should have stopped.
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new SqlStore(watched).ClearRollupsAsync("default"));
        Assert.Equal("connection lost", error.Message);
        Assert.Equal(before, J(await store.StatsAsync(month)));
        await BuildDaysAsync(store, "default", NOW - 12 * DAY, NOW - DAY);
        Assert.Equal(before, J(await store.StatsAsync(month)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Retention_drops_old_visits_with_their_events_and_forgets_the_days_they_were_in(string kind)
    {
        var store = await StoreAsync(kind);
        long[] ats = [Utc(2025, 10, 1), Utc(2026, 7, 1), Utc(2026, 10, 6)];
        for (int i = 0; i < ats.Length; i++)
        {
            long t = ats[i] + HOUR;
            await VisitAsync(store, "s" + i, "v" + i, t, [], [Pv("/", t, "p" + i), Ev("E", t + 1, null)]);
        }
        // An event of the oldest visit that came after the cutoff goes with it.
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = Utc(2025, 10, 1) + DAY, ["kind"] = "event", ["visitor"] = "v0", ["session"] = "s0", ["pageview"] = "", ["path"] = "/", ["hostname"] = "", ["title"] = "", ["name"] = "Late", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        var all = Q(0, NOW + DAY);
        Same(3, (await store.StatsAsync(all)).Get("visits"));
        await store.BuildRollupDayAsync("default", "2026-07-01", Utc(2026, 7, 1), Utc(2026, 7, 2));
        await store.DropBeforeAsync("default", Utc(2026, 4, 6));
        Same(2, (await store.StatsAsync(all)).Get("visits"), "the visit from a year ago is gone");
        Same(0, (await store.Db.AllAsync("SELECT COUNT(*) AS n FROM rl_events WHERE session = 's0'"))[0].Get("n"), "its events, even the late one");
        Same(L("2026-07-01"), await store.RollupDaysAsync("default"), "a day after the cutoff stays built");
        await store.DropBeforeAsync("default", Utc(2026, 8, 1));
        Same(1, (await store.StatsAsync(all)).Get("visits"));
        Assert.Empty(await store.RollupDaysAsync("default"));

        // Events whose visit is gone, as an older version left them, are swept.
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = NOW - DAY, ["kind"] = "pageview", ["visitor"] = "x", ["session"] = "gone", ["pageview"] = "g", ["path"] = "/", ["hostname"] = "", ["title"] = "", ["name"] = "", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = NOW - DAY, ["kind"] = "fetch", ["visitor"] = "", ["session"] = "", ["pageview"] = "", ["path"] = "/", ["hostname"] = "", ["title"] = "", ["name"] = "GPTBot", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        await store.DropOrphansAsync("default", 0, NOW + DAY);
        Same(0, (await store.Db.AllAsync("SELECT COUNT(*) AS n FROM rl_events WHERE session = 'gone'"))[0].Get("n"));
        Same(1, (await store.Db.AllAsync("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'fetch'"))[0].Get("n"), "rows of no visit stay");
    }
}
