using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Store.Seed;

namespace Runlight.Tests.Store;

/// <summary>
/// What the reports count, at the store: the store-level parts of counting.test.ts, filters.test.ts,
/// goals.test.ts, funnels.test.ts, journeys.test.ts, props.test.ts, and mysql.test.ts. Visits are
/// written through the store as the tracker writes them.
/// </summary>
/// <remarks>
/// Goals.goalFrom and Funnels.funnelFrom are not in the .NET port yet, so the goals and funnels here
/// are written as those functions return them for the PHP test's input (a pasted URL as its path, a
/// currency in capitals), and what the PHP test asks of goalFrom, funnelFrom, and clickRules
/// themselves waits for that port.
/// </remarks>
public sealed class CountingTests : StoreTestCase
{
    /// <summary>The stats numbers asked for.</summary>
    private static List<object?> Pick(JsObject stats, params string[] keys) => keys.Select(stats.Get).ToList();

    private static JsObject Step(string kind, string match) => new() { ["kind"] = kind, ["match"] = match };

    /// <summary>A funnel as funnelFrom returns it, its steps already in recorded form.</summary>
    private static JsObject Funnel(string id, string name, long createdAt, params JsObject[] steps) =>
        new() { ["id"] = id, ["site"] = "default", ["name"] = name, ["steps"] = steps.Cast<object?>().ToList(), ["createdAt"] = createdAt };

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Goals_funnels_and_event_properties_count_visits_by_when_they_started_with_or_without_a_filter(string kind)
    {
        var store = await StoreAsync(kind);
        // Two people start at 23:50 on the 5th and sign up at 00:10 on the 6th; a third visits on the 6th.
        long start = NOW - 12 * HOUR - 10 * MIN;
        foreach (int i in new[] { 1, 2 })
        {
            await VisitAsync(store, "s" + i, "v" + i, start, new JsObject { ["country"] = "GB" }, [Pv("/signup", start, "p" + i), Ev("Signup", start + 20 * MIN, new JsObject { ["plan"] = "pro" })]);
        }
        await VisitAsync(store, "s3", "v3", start + 80 * MIN, [], [Pv("/", start + 80 * MIN, "q")]);
        var goal = Goal(new string('a', 24), new JsObject { ["name"] = "Signup", ["match"] = "Signup" });
        await store.SaveGoalAsync(goal);
        var funnel = Funnel(new string('b', 24), "Signup", 0, Step("page", "/signup"), Step("event", "Signup"));
        await store.SaveFunnelAsync(funnel);
        long day5 = Utc(2026, 10, 5);
        foreach (var filters in new[] { Array.Empty<string[]>(), [F("country", "not", "ZZ")], [F("page", "contains", "/")] })
        {
            async Task<string> Read(long from)
            {
                var query = Q(from, from + DAY, filters);
                var totals = await store.GoalTotalsAsync(query, goal);
                double visitors = await store.VisitorsAsync(query);
                var events = (await store.BreakdownAsync(query, "event", 10, 0)).Select(r => (object?)(Js.String(r.Get("value")) + ":" + Js.String(r.Get("events")))).ToList();
                return J(L(totals.Get("conversions"), visitors > 0 ? totals.Num("visitors") / visitors : 0, await store.FunnelCountsAsync(query, funnel), (await store.EventPropKeysAsync(query, "Signup")).Count, events));
            }
            string label = J(filters);
            Assert.True(J(L(2, 1, L(2, 2), 1, L("Signup:2"))) == await Read(day5), "the visits that started on the 5th " + label + ": " + await Read(day5));
            Assert.True(J(L(0, 0, L(0, 0), 0, L())) == await Read(day5 + DAY), "nothing that started on the 6th converted " + label + ": " + await Read(day5 + DAY));
        }
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Contains_finds_capitals_beyond_ASCII_and_two_page_filters_count_both_pages(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "s1", "v1", t, new JsObject { ["utmCampaign"] = "Über" }, [Pv("/a", t, "a"), Pv("/b", t + MIN, "b")]);
        foreach (string value in new[] { "über", "Über", "ÜBER", "ber" })
        {
            Same(1, (await store.StatsAsync(Today(F("utm_campaign", "contains", value)))).Get("visits"), "contains " + value);
        }
        var both = await store.StatsAsync(Today(F("page", "is", "/a"), F("page", "is", "/b")));
        Same(L(1, 2), Pick(both, "visits", "pageviews"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_page_goal_funnel_or_filter_written_in_plain_letters_matches_the_encoded_path(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "s1", "v1", t, [], [Pv(Runlight.Sources.RecordedPath("/café")!, t, "a")]);
        // As goalFrom makes it: its pagePattern records the path as the browser writes it.
        var goal = Goal(new string('c', 24), new JsObject { ["name"] = "Café", ["kind"] = "page", ["match"] = Runlight.Sources.RecordedPath("/café"), ["createdAt"] = NOW });
        await store.SaveGoalAsync(goal);
        Same(1, (await store.GoalTotalsAsync(Today(), goal)).Get("conversions"));
        Same(1, (await store.StatsAsync(Today(F("page", "is", "/café")))).Get("visits"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_event_that_joins_a_visit_already_ended_counts_without_reopening_it(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - 6 * HOUR;
        await VisitAsync(store, "s1", "v1", t, [], [Pv("/", t, "p1")]);
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = t + 2 * HOUR, ["kind"] = "event", ["visitor"] = "v1", ["session"] = "s1", ["pageview"] = "p1", ["path"] = "/", ["hostname"] = "example.com", ["title"] = "", ["name"] = "Late", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        await store.TouchSessionAsync("s1", t + 2 * HOUR, "event", "/", false);
        // Still ended.
        Assert.Null(await store.OpenSessionAsync("default", ["v1"], t + HOUR));
        Same(L(new JsObject { ["value"] = "Late", ["visitors"] = 1, ["events"] = 1 }), await store.BreakdownAsync(Today(), "event", 10, 0));
        Same(0, (await store.StatsAsync(Today())).Get("bounceRate"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Time_on_page_is_over_every_pageview_counting_quick_ones_as_none(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        for (int i = 0; i < 4; i++)
        {
            var rows = new List<object?[]> { Pv("/a", t, "v" + i) };
            if (i == 0)
            {
                rows.Add(Eng("v0", t + 1000, 60_000, 50));
            }
            await VisitAsync(store, "s" + i, "v" + i, t, [], rows);
        }
        var row = (await store.BreakdownAsync(Today(), "page", 10, 0))[0];
        Same(L(15_000, 50), L(row.Get("timeOnPage"), row.Get("scrollDepth")));
    }

    [Fact]
    public async Task Journeys_applies_a_filter_before_its_cap_on_visits_and_says_when_the_cap_was_reached()
    {
        var store = await StoreAsync("sqlite");
        long start = Utc(2026, 10, 6);
        // Ten visits from Britain early in the day, then more from the US than journeys reads.
        await store.TransactionAsync(async tx =>
        {
            for (int i = 0; i < 10 + SqlStore.JourneyVisits; i++)
            {
                long ts = start + i;
                await tx.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, country) VALUES (?, 'default', ?, ?, ?, 1, '/', '/', ?)", ["s" + i, "v" + i, ts, ts, i < 10 ? "GB" : "US"]);
                await tx.Db.RunAsync("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, ?, '/', 'example.com')", [ts, "v" + i, "s" + i, "p" + i]);
            }
        });
        static int Sessions(List<JsObject> rows) => rows.Select(r => r.Str("session")).Distinct(StringComparer.Ordinal).Count();
        var (britain, britainSampled) = await store.JourneyPagesAsync(Q(start, start + DAY, F("country", "is", "GB")), 5);
        // Every British visit, though they are older than the newest visits read.
        Assert.Equal(10, Sessions(britain));
        Assert.False(britainSampled);
        var (all, allSampled) = await store.JourneyPagesAsync(Q(start, start + DAY), 5);
        Assert.Equal(SqlStore.JourneyVisits, Sessions(all));
        Assert.True(allSampled);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_page_goal_or_funnel_step_for_a_hash_route_counts_that_route_only(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        for (int i = 0; i < 5; i++)
        {
            var rows = new List<object?[]> { Pv("/", t, "h" + i) };
            if (i < 2)
            {
                rows.Add(Pv("/#/cart", t + 1000, "c" + i));
                rows.Add(Pv("/#/thanks", t + 2000, "t" + i));
            }
            await VisitAsync(store, "s" + i, "v" + i, t, [], rows);
        }
        // As goalFrom and funnelFrom make them from "/#/thanks", "/#/cart", and "https://example.com/#/thanks".
        var goal = Goal(new string('d', 24), new JsObject { ["name"] = "Thanks", ["kind"] = "page", ["match"] = "/#/thanks", ["createdAt"] = NOW });
        var funnel = Funnel(new string('e', 24), "Checkout", NOW, Step("page", "/#/cart"), Step("page", "/#/thanks"));
        var totals = await store.GoalTotalsAsync(Today(), goal);
        Same(L(2, 2), L(totals.Get("conversions"), totals.Get("visitors")));
        Same(L(2, 2), await store.FunnelCountsAsync(Today(), funnel));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Page_and_hostname_filters_together_count_pageviews_matching_both(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "s1", "v1", t, [], [Pv("/pricing", t, "a", "example.com"), Pv("/start", t + 1000, "b", "docs.example.com"), Pv("/pricing", t + 2000, "c", "docs.example.com")]);
        var query = Today(F("page", "is", "/pricing"), F("hostname", "is", "docs.example.com"));
        Same(1, (await store.StatsAsync(query)).Get("pageviews"));
        Same(L(L("/pricing", 1)), (await store.BreakdownAsync(query, "page", 10, 0)).Select(r => (object?)L(r.Get("value"), r.Get("pageviews"))).ToList());
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Contains_ignores_case_in_any_mix_in_paths_too_and_filters_take_paths_as_the_browser_writes_them(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "s1", "v1", t, new JsObject { ["utmCampaign"] = "ÉcoleÉté" }, [Pv(Runlight.Sources.RecordedPath("/Über-uns")!, t, "a")]);
        await VisitAsync(store, "s2", "v2", t, [], [Pv(Runlight.Sources.RecordedPath("/a^b")!, t, "b")]);
        await VisitAsync(store, "s3", "v3", t, [], [Pv(Runlight.Sources.RecordedPath("/#/x{y}")!, t, "c")]);
        async Task<object?> Visits(string d, string op, string v) => (await store.StatsAsync(Today(F(d, op, v)))).Get("visits");
        foreach (string value in new[] { "écoleété", "ÉCOLEÉTÉ", "eÉté" })
        {
            Same(1, await Visits("utm_campaign", "contains", value), value);
        }
        foreach (string value in new[] { "über", "ÜBER", "Über-Uns" })
        {
            Same(1, await Visits("page", "contains", value), value);
        }
        Same(1, await Visits("page", "is", "/a^b"));
        Same(1, await Visits("page", "is", "/#/x{y}"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Time_on_page_leaves_out_imported_views_which_can_report_no_time(string kind)
    {
        var store = await StoreAsync(kind);
        // Nine pageviews written as the Umami import writes them: no pageview id, never any engaged time.
        long day = Utc(2026, 10, 5, 10);
        for (int i = 0; i < 9; i++)
        {
            await store.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1)", ["i" + i, "v" + i, day + i, day + i]);
            await store.Db.RunAsync("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')", [day + i, "v" + i, "i" + i]);
        }
        long t = NOW - HOUR;
        await VisitAsync(store, "live", "lv", t, [], [Pv("/pricing", t, "live"), Eng("live", t + 1000, 60_000, null)]);
        var week = Q(NOW - 7 * DAY, NOW + DAY);
        async Task<JsObject> Row() => (await store.BreakdownAsync(week, "page", 10, 0)).First(r => r.Str("value") == "/pricing");
        var row = await Row();
        Same(L(10, 60_000), L(row.Get("pageviews"), row.Get("timeOnPage")));
        await BuildDaysAsync(store, "default", NOW - 7 * DAY, NOW + DAY);
        Same(60_000, (await Row()).Get("timeOnPage"), "the same once the days are built");
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_filter_picks_visits_and_the_numbers_describe_those_whole_visits(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - 3 * HOUR;
        // Visit A: two pages and a Signup. Visit B: one page, no Signup.
        await VisitAsync(store, "a", "va", t, [], [Pv("/", t, "a1"), Pv("/pricing", t + 30_000, "a2"), Ev("Signup", t + 60_000, null)]);
        await VisitAsync(store, "b", "vb", t + 60_000, [], [Pv("/blog", t + 60_000, "b1")]);
        Task<JsObject> Stats(params string[][] f) => store.StatsAsync(Today(f));
        Same(L(1, 1, 2), Pick(await Stats(F("event", "is", "Signup")), "visitors", "visits", "pageviews"), "the visits with a Signup, and all their pageviews");
        Same(L(1, 1), Pick(await Stats(F("page", "is", "/pricing")), "visits", "pageviews"), "a page filter counts that page's views");
        Same(1, (await Stats(F("page", "is", "/pricing"), F("event", "is", "Signup"))).Get("visits"), "a page and an event in the same visit");
        Same(L(1, 1), Pick(await Stats(F("event", "not", "Signup")), "visits", "pageviews"), "is not means visits that never had one");

        var buckets = new List<JsObject>();
        for (int h = 0; h < 24; h++)
        {
            buckets.Add(new JsObject { ["start"] = NOW - 12 * HOUR + h * HOUR, ["end"] = NOW - 11 * HOUR + h * HOUR });
        }
        var points = await store.SeriesAsync(new JsObject { ["site"] = "default", ["filters"] = L(new JsObject { ["dimension"] = "event", ["op"] = "is", ["value"] = "Signup" }) }, buckets);
        Same(L(1, 2), L(points.Sum(p => p.Num("visits")), points.Sum(p => p.Num("pageviews"))), "the chart agrees");
        var pages = (await store.BreakdownAsync(Today(F("event", "is", "Signup")), "page", 10, 0)).Select(r => r.Str("value")).OrderBy(v => v, StringComparer.Ordinal).Cast<object?>().ToList();
        Same(L("/", "/pricing"), pages, "the pages of the visits that signed up");
        Same(L("Signup"), Column(await store.BreakdownAsync(Today(F("page", "is", "/pricing")), "event", 10, 0), "value"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Goals_count_events_page_patterns_and_revenue_including_visits_from_before_the_goal(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "a", "v1", t, new JsObject { ["source"] = "Google" }, [Pv("/pricing", t, "a1"), Ev("Purchase", t + 1, new JsObject { ["revenue"] = 49L }), Pv("/thanks", t + 2, "a2")]);
        await VisitAsync(store, "b", "v2", t, [], [Pv("/pricing", t, "b1"), Ev("Purchase", t + 1, new JsObject { ["revenue"] = "19.50" }), Pv("/thanks/pro", t + 2, "b2")]);
        await VisitAsync(store, "c", "v3", t, [], [Pv("/", t, "c1"), Ev("Purchase", t + 1, new JsObject { ["revenue"] = "not a number" })]);

        // As goalFrom makes them: a currency in capitals, a pasted URL as its path, a click goal by selector.
        var purchase = Goal("0000000000000000000000a1", new JsObject { ["name"] = "Purchase", ["kind"] = "event", ["match"] = "Purchase", ["valueMode"] = "prop", ["valueProp"] = "revenue", ["currency"] = "USD", ["createdAt"] = NOW });
        var thanks = Goal("0000000000000000000000a2", new JsObject { ["name"] = "Thank you page", ["kind"] = "page", ["match"] = "/thanks*", ["valueMode"] = "fixed", ["value"] = 9.99, ["createdAt"] = NOW });
        var button = Goal("0000000000000000000000a3", new JsObject { ["name"] = "Buy button", ["kind"] = "click", ["clickBy"] = "selector", ["match"] = ".buy", ["createdAt"] = NOW });
        foreach (var g in new[] { purchase, thanks, button })
        {
            await store.SaveGoalAsync(g);
        }
        Same(3, await store.VisitorsAsync(Today()));
        var all = await store.GoalTotalsAllAsync(Today(), await store.GoalsAsync("default"));
        Same(new JsObject { ["conversions"] = 3, ["visitors"] = 3, ["revenue"] = 68.5 }, all[purchase.Str("id")!], "numbers and numeric strings add up; anything else counts as nothing");
        Same(2, all[thanks.Str("id")!].Get("conversions"));
        // A decimal fixed value works on every database, Postgres too.
        Assert.Equal(19.98, all[thanks.Str("id")!].Num("revenue"), 1e-9);
        Same(0, all[button.Str("id")!].Get("conversions"));
        Same(all[thanks.Str("id")!], await store.GoalTotalsAsync(Today(), thanks));

        var pages = await store.GoalBreakdownAsync(Today(), purchase, "path");
        Same(L(L("/pricing", 2), L("/", 1)), pages.Select(r => (object?)L(r.Get("value"), r.Get("conversions"))).ToList());
        Same(68.5, (await store.GoalTotalsAsync(Today(), purchase)).Get("revenue"));
        var series = await store.GoalSeriesAsync(new JsObject { ["site"] = "default", ["filters"] = L() }, purchase, [new JsObject { ["start"] = NOW - 12 * HOUR, ["end"] = NOW }, new JsObject { ["start"] = NOW, ["end"] = NOW + 12 * HOUR }]);
        Assert.Equal(3, series.Sum(p => p.Num("conversions")));
        // What clickRules builds the tracker's rules from: the click goal as saved.
        var saved = (await store.GoalsAsync()).First(g => g.Str("kind") == "click");
        Same(L("default", "selector", ".buy", "Buy button"), L(saved.Get("site"), saved.Get("clickBy"), saved.Get("match"), saved.Get("name")));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Renaming_a_click_goal_renames_its_past_clicks(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "a", "v1", t, [], [Pv("/", t, "a1"), Ev("Buy", t + 1, null)]);
        var before = Goal(new string('c', 24), new JsObject { ["name"] = "Buy", ["kind"] = "click", ["clickBy"] = "selector", ["match"] = ".buy" });
        await store.SaveGoalAsync(before);
        var after = before.With(new JsObject { ["name"] = "Buy now" });
        await store.SaveGoalAsync(after, before);
        Same(1, (await store.GoalTotalsAsync(Today(), after)).Get("conversions"));
        Assert.Equal("Buy now", (await store.GoalByIdAsync(before.Str("id")!))!.Get("name"));
        await store.DeleteGoalAsync(before.Str("id")!);
        Assert.Empty(await store.GoalsAsync("default"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Funnel_steps_in_the_same_millisecond_both_count_and_one_row_never_counts_as_two_steps(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - MIN;
        await VisitAsync(store, "a", "v1", t, [], [Pv("/pricing", t, "a1"), Ev("Signup", t, null)]);
        var same = Funnel(new string('1', 24), "Same moment", NOW, Step("page", "/pricing"), Step("event", "Signup"));
        var twice = Funnel(new string('2', 24), "Twice", NOW, Step("page", "/pricing"), Step("page", "/pricing"));
        Same(L(1, 1), await store.FunnelCountsAsync(Today(), same));
        Same(L(1, 0), await store.FunnelCountsAsync(Today(), twice), "one pageview is not two steps");
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_funnel_counts_visits_that_took_each_step_in_order_within_one_visit(string kind)
    {
        var store = await StoreAsync(kind);
        int n = 0;
        async Task Visit(params (string Path, string? Event)[] steps)
        {
            n++;
            long t = NOW - 3 * HOUR + n * 10 * MIN;
            var rows = new List<object?[]>();
            for (int i = 0; i < steps.Length; i++)
            {
                rows.Add(steps[i].Event == null ? Pv(steps[i].Path, t + i * MIN, "p" + n + "x" + i) : Ev(steps[i].Event!, t + i * MIN, null, steps[i].Path));
            }
            await VisitAsync(store, "s" + n, "v" + n, t, [], rows);
        }
        // All three steps in order; two steps, then gone; the right pages in the wrong order; never on pricing.
        await Visit(("/pricing", null), ("/signup", "Signup"), ("/welcome", null));
        await Visit(("/pricing", null), ("/signup", "Signup"));
        await Visit(("/welcome", null), ("/pricing", null));
        await Visit(("/blog", null), ("/welcome", null));

        // As funnelFrom makes it from "https://example.com/pricing*", "Signup", and "welcome".
        var funnel = Funnel(new string('f', 24), "Signup", NOW, Step("page", "/pricing*"), Step("event", "Signup"), Step("page", "/welcome"));
        await store.SaveFunnelAsync(funnel);
        Same(L(3, 2, 1), await store.FunnelCountsAsync(Today(), (await store.FunnelsAsync("default"))[0]));
        // Filters choose which visits enter. The Signup events were sent from /signup, so a page filter finds them.
        Same(L(2, 2, 1), await store.FunnelCountsAsync(Today(F("page", "is", "/signup")), funnel));
        var changed = Funnel(funnel.Str("id")!, "Signup flow", NOW, Step("page", "/pricing"), Step("page", "/welcome"));
        await store.SaveFunnelAsync(changed);
        Same(L(3, 1), await store.FunnelCountsAsync(Today(), (await store.FunnelsAsync("default"))[0]));
        await store.DeleteFunnelAsync(funnel.Str("id")!);
        Assert.Empty(await store.FunnelsAsync("default"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Journey_pages_reads_each_visits_pages_in_order(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        string[][] visits = [["/", "/pricing", "/signup"], ["/", "/pricing", "/pricing", "/about"], ["/blog"]];
        for (int i = 0; i < visits.Length; i++)
        {
            var rows = new List<object?[]>();
            for (int j = 0; j < visits[i].Length; j++)
            {
                rows.Add(Pv(visits[i][j], t + i * MIN + j * 10_000L, "p" + i + "x" + j));
            }
            await VisitAsync(store, "s" + i, "v" + i, t + i * MIN, [], rows);
        }
        var (rows2, sampled) = await store.JourneyPagesAsync(Today(), 3);
        Assert.False(sampled);
        static JsObject R(string session, string path) => new() { ["session"] = session, ["path"] = path };
        Same(
            L(R("s0", "/"), R("s0", "/pricing"), R("s0", "/signup"), R("s1", "/"), R("s1", "/pricing"), R("s1", "/about"), R("s2", "/blog")),
            rows2,
            "a refresh is not a step");
        var (none, noneSampled) = await store.JourneyPagesAsync(Q(0, 1), 3);
        Assert.Empty(none);
        Assert.False(noneSampled);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_events_properties_and_their_values_filtered_like_everything_else(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - HOUR;
        await VisitAsync(store, "a", "v1", t, [],
        [
            Pv("/", t, "a1"),
            Ev("Outbound link", t + 1, new JsObject { ["url"] = "https://github.com/x" }),
            Ev("Outbound link", t + 2, new JsObject { ["url"] = "https://news.ycombinator.com/" }),
            Ev("Signup", t + 3, new JsObject { ["plan"] = "pro", ["seats"] = 3L }),
            Ev("Signup", t + 4, new JsObject { ["plan"] = "team" }),
            Ev("404", t + 5, new JsObject { ["path"] = "/missing" }),
        ]);
        await VisitAsync(store, "b", "v2", t, [], [Pv("/blog", t, "b1"), Ev("Outbound link", t + 1, new JsObject { ["url"] = "https://github.com/x" }, "/blog")]);

        Same(L(new JsObject { ["key"] = "url", ["events"] = 3 }), await store.EventPropKeysAsync(Today(), "Outbound link"));
        Same(
            L(new JsObject { ["value"] = "https://github.com/x", ["events"] = 2, ["visitors"] = 2 }, new JsObject { ["value"] = "https://news.ycombinator.com/", ["events"] = 1, ["visitors"] = 1 }),
            await store.EventPropValuesAsync(Today(), "Outbound link", "url", 10));
        Same(L("plan", "seats"), Column(await store.EventPropKeysAsync(Today(), "Signup"), "key"));
        Same(L(new JsObject { ["value"] = "3", ["events"] = 1, ["visitors"] = 1 }), await store.EventPropValuesAsync(Today(), "Signup", "seats", 10));
        Same(L("https://github.com/x"), Column(await store.EventPropValuesAsync(Today(F("page", "is", "/blog")), "Outbound link", "url", 10), "value"));
        Assert.Empty(await store.EventPropKeysAsync(Today(), "Nothing"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task The_longest_values_the_tracker_accepts_are_kept_whole(string kind)
    {
        var store = await StoreAsync(kind);
        long t = NOW - 3 * HOUR;
        string path = "/" + new string('p', 999);
        static string Utm(char c) => new(c, 200);
        await VisitAsync(store, "a", "v1", t, new JsObject
        {
            ["referrerHost"] = new string('r', 60) + ".example.org",
            ["referrerPath"] = "/" + new string('q', 499),
            ["utmSource"] = Utm('s'),
            ["utmMedium"] = Utm('m'),
            ["utmCampaign"] = Utm('c'),
            ["utmTerm"] = Utm('t'),
            ["utmContent"] = Utm('o'),
        }, [Pv(path, t, "a1")]);
        var props = new JsObject();
        for (int i = 0; i < 8; i++)
        {
            props[i + new string('k', 59)] = new string('v', 500);
        }
        await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = t + 1, ["kind"] = "pageview", ["visitor"] = "v1", ["session"] = "a", ["pageview"] = "a2", ["path"] = "/x", ["hostname"] = "example.com", ["title"] = new string('t', 500), ["name"] = "", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        string name = new('n', 120);
        await VisitAsync(store, "b", "v2", t, [], [Pv("/", t, "b1"), Ev(name, t + 1, props)]);

        Assert.Contains(path, Column(await store.BreakdownAsync(Today(), "page", 10, 0), "value"));
        foreach (var (dimension, c) in new[] { ("utm_source", 's'), ("utm_medium", 'm'), ("utm_campaign", 'c'), ("utm_term", 't'), ("utm_content", 'o') })
        {
            Same(L(Utm(c)), Column(await store.BreakdownAsync(Today(), dimension, 10, 0), "value"));
        }
        Assert.Equal(name, (await store.BreakdownAsync(Today(), "event", 10, 0))[0].Get("value"));
        Assert.Equal(8, (await store.EventPropKeysAsync(Today(), name)).Count);
        Same(L(new string('v', 500)), Column(await store.EventPropValuesAsync(Today(), name, "0" + new string('k', 59), 10), "value"));
        // A day of them adds up the same way.
        await BuildDaysAsync(store, "default", NOW - DAY, NOW + 12 * HOUR);
        Assert.Contains(path, Column(await store.BreakdownAsync(Q(NOW - 7 * DAY, NOW + DAY), "page", 10, 0), "value"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Text_is_compared_exactly_and_sorted_by_code_point_case_and_trailing_spaces_included(string kind)
    {
        var store = await StoreAsync(kind);
        string[] values = ["a", "a ", "A", "b", "é", "É", char.ConvertFromUtf32(0x1F600), ((char)0xFFFD).ToString(), "a\t"];
        long t = NOW - HOUR;
        for (int i = 0; i < values.Length; i++)
        {
            await VisitAsync(store, "s" + i, "v" + i, t, new JsObject { ["utmCampaign"] = values[i] }, [Pv("/", t, "x" + i), Ev("Pick", t + 1, new JsObject { ["choice"] = values[i] })]);
        }
        // PHP's sort() of UTF-8 bytes: code point order.
        var sorted = values.ToList();
        sorted.Sort(Sql.CodeOrder);
        var rows = await store.EventPropValuesAsync(Today(), "Pick", "choice", 20);
        Same(sorted, Column(rows, "value"));
        Same(Enumerable.Repeat(1, values.Length).ToList(), Column(rows, "events"), "no two values counted as one");
        Same(sorted, Column(await store.BreakdownAsync(Today(), "utm_campaign", 20, 0), "value"));
        Same(1, (await store.StatsAsync(Today(F("utm_campaign", "is", "a ")))).Get("visits"), "a trailing space is part of the value");
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Short_link_clicks_are_not_visits_in_the_heatmap_raw_or_rolled_up_nor_the_first_visit(string kind)
    {
        var store = await StoreAsync(kind);
        long day = Utc(2026, 10, 5, 15);
        // A session opened only by a short link click, then a real visit.
        await store.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'default', 'v1', ?, ?, 0, 0, 0)", [day - HOUR, day - HOUR]);
        await store.Db.RunAsync("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'default', 'v2', ?, ?, 1, 0, 0)", [day, day]);
        Same(day, await store.FirstOwnVisitAsync("default"));
        Same(day - HOUR, await store.FirstSeenAsync("default"));
        var query = Q(Utc(2026, 10, 1), Utc(2026, 10, 7));
        static double Sum(List<JsObject> rows) => rows.Sum(r => r.Num("visits"));
        Assert.Equal(1, Sum(await store.HourlyAsync(query)));
        await BuildDaysAsync(store, "default", query.Long("from"), query.Long("to"));
        // Rolled up.
        Assert.Equal(1, Sum(await store.HourlyAsync(query)));
    }
}
