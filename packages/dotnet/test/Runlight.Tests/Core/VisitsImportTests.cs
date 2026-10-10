using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Importers;
using Runlight.Store;
using Runlight.Tests.Store;
using Xunit;
using static Runlight.Tests.Core.Router;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>Visit history from Umami and from CSV files, as visits-import*.test.ts and visits-csv.test.ts test it at the store.</summary>
public sealed class VisitsImportTests : CoreTestCase
{
    private static JsObject Credentials() => new() { ["url"] = "https://umami.example.com", ["apiKey"] = "key" };

    private static List<object?> L(params object?[] items) => [.. items];

    /// <summary>A small Umami: one website, events answered by time window like the real API, newest first.</summary>
    private static Router Umami(List<JsObject> events, List<JsObject>? sessions = null, string created = "2026-03-01T08:00:00Z", bool newestFirst = true)
    {
        sessions ??= [];
        List<object?> Inside(Url url)
        {
            long from = long.Parse(url.SearchParams.Get("startAt")!, System.Globalization.CultureInfo.InvariantCulture);
            long to = long.Parse(url.SearchParams.Get("endAt")!, System.Globalization.CultureInfo.InvariantCulture);
            var rows = events.Where(e => At(e.Str("createdAt")!) >= from && At(e.Str("createdAt")!) <= to).Cast<object?>().ToList();
            if (newestFirst)
            {
                rows.Reverse();
            }
            return rows;
        }
        return new Router(
            R("/api/websites\\?", () => new JsObject { ["data"] = L(new JsObject { ["id"] = "w1", ["name"] = "Blog", ["domain"] = "blog.example.com" }), ["count"] = 1L }),
            R("/api/websites/w1$", () => new JsObject { ["id"] = "w1", ["createdAt"] = created }),
            R("/api/websites/w1/events\\?", (url, _) =>
            {
                var rows = Inside(url);
                return new JsObject { ["data"] = rows, ["count"] = (long)rows.Count };
            }),
            R("/api/websites/w1/sessions\\?", () => new JsObject { ["data"] = sessions.Cast<object?>().ToList(), ["count"] = (long)sessions.Count }));
    }

    private static JsObject E(string session, string at, string path, long type, JsObject? more = null)
    {
        var e = new JsObject { ["sessionId"] = session, ["createdAt"] = at, ["hostname"] = "blog.example.com", ["urlPath"] = path, ["eventType"] = type };
        return more == null ? e : e.With(more);
    }

    private static List<JsObject> FakeEvents()
    {
        var phone = new JsObject { ["country"] = "CA", ["city"] = "Toronto", ["device"] = "mobile", ["os"] = "iOS", ["browser"] = "ios" };
        var desk = new JsObject { ["country"] = "GB", ["city"] = "London", ["device"] = "desktop", ["os"] = "Mac OS", ["browser"] = "chrome" };
        return
        [
            // Visit 1: Google, two pages and a signup, in Toronto on a phone.
            E("s1", "2026-03-01T10:00:00.000Z", "/", 1, new JsObject { ["urlQuery"] = "utm_campaign=spring", ["referrerDomain"] = "www.google.com", ["referrerPath"] = "/", ["pageTitle"] = "Home" }.With(phone)),
            E("s1", "2026-03-01T10:02:00.000Z", "/pricing", 1, new JsObject { ["pageTitle"] = "Pricing" }.With(phone)),
            E("s1", "2026-03-01T10:03:00.000Z", "/pricing", 2, new JsObject { ["eventName"] = "Signup" }.With(phone)),
            // The same Umami session two hours later is a second visit.
            E("s1", "2026-03-01T12:30:00.000Z", "/blog", 1, phone),
            // Visit 3: direct, desktop, the next day.
            E("s2", "2026-03-02T09:00:00.000Z", "/", 1, desk),
            // A performance event is not a visit.
            E("s2", "2026-03-02T09:00:01.000Z", "/", 5, desk),
        ];
    }

    private static List<JsObject> Sessions() =>
    [
        new() { ["id"] = "s1", ["screen"] = "390x844", ["language"] = "en-CA", ["region"] = "CA-ON" },
        new() { ["id"] = "s2", ["screen"] = "1440x900", ["language"] = "en-GB", ["region"] = "GB-ENG" },
    ];

    private static Harness Make(SqlStore store, Router router, long now, string timezone = "UTC")
    {
        var t = Harness.Create(store, new SiteOptions { Hostnames = ["blog.example.com"], Timezone = timezone }, fetcher: router);
        t.Now = now;
        return t;
    }

    private static async Task<Harness> MakeAsync(string kind, Router router, long now, string timezone = "UTC") =>
        Make(await Databases.FreshAsync(kind), router, now, timezone);

    private static async Task<(long Pageviews, long Events, long Visits, long Steps)> ImportAllAsync(Harness t, JsObject? credentials = null)
    {
        string? cursor = null;
        long pageviews = 0, events = 0, visits = 0, steps = 0;
        do
        {
            var step = await Visits.ImportUmamiVisitsAsync(t.Rl, "default", credentials ?? Credentials(), "w1", cursor);
            cursor = step.Get("cursor") as string;
            pageviews += step.Long("pageviews");
            events += step.Long("events");
            visits += step.Long("visits");
            steps++;
            Assert.True(step.Num("done") <= step.Num("total"));
        }
        while (cursor != null);
        return (pageviews, events, visits, steps);
    }

    [Fact]
    public async Task An_umami_on_a_private_address_is_never_asked()
    {
        var router = Umami([]);
        router.Dns = _ => ["127.0.0.1"];
        var e = await Assert.ThrowsAsync<ImportError>(() => Visits.UmamiWebsitesAsync(Credentials(), router));
        Assert.Equal("unreachable", e.Code);
        var literal = new JsObject { ["url"] = "https://10.1.2.3", ["apiKey"] = "key" };
        Assert.Equal("unreachable", (await Assert.ThrowsAsync<ImportError>(() => Visits.UmamiWebsitesAsync(literal, router))).Code);
        var plain = new JsObject { ["url"] = "http://umami.example.com", ["apiKey"] = "key" };
        Assert.Equal("import_umami_address", (await Assert.ThrowsAsync<ImportError>(() => Visits.UmamiWebsitesAsync(plain, router))).Code);
        Assert.Empty(router.Requests); // nothing was sent
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Umami_visit_history_pageviews_and_events_become_visits_with_sources_places_and_devices(string kind)
    {
        var router = Umami(FakeEvents(), Sessions());
        Assert.Equal("[{\"id\":\"w1\",\"name\":\"Blog\",\"domain\":\"blog.example.com\"}]", J(await Visits.UmamiWebsitesAsync(Credentials(), router)));
        var t = await MakeAsync(kind, router, At("2026-03-04T00:00:00Z"));
        var totals = await ImportAllAsync(t);
        Assert.Equal((4L, 1L, 3L), (totals.Pageviews, totals.Events, totals.Visits));
        foreach (var (_, init) in router.Requests)
        {
            Assert.Equal("Bearer key", init.Headers.Get("authorization")); // every request carries the key
        }

        var q = t.Query("2026-03-01", "2026-03-03");
        var stats = await t.StatsAsync(q);
        Assert.Equal(4, stats.Num("pageviews"));
        Assert.Equal(3, stats.Num("visits"));
        Assert.Equal(2, stats.Num("visitors")); // one Umami session on one day is one visitor
        Assert.True(stats.Num("visitDuration") > 0); // imported visits take their length from first to last pageview
        Assert.Equal(["Google"], await t.ValuesAsync(q, "source"));
        Assert.Equal(["CA-ON", "GB-ENG"], await t.SortedAsync(q, "region"));
        Assert.Equal(["Chrome", "Safari"], await t.SortedAsync(q, "browser"));
        Assert.Equal(["Signup"], await t.ValuesAsync(q, "event"));
        Assert.Equal(["spring"], await t.ValuesAsync(q, "utm_campaign"));

        // Running it again carries on from where it stopped, so nothing doubles.
        t.Advance(DAY);
        var again = await Visits.ImportUmamiVisitsAsync(t.Rl, "default", Credentials(), "w1", null);
        Assert.Equal(0, again.Num("pageviews"));
        Assert.Equal(4, (await t.StatsAsync(q)).Num("pageviews"));

        // No imported visitor id lasts past a day.
        var days = new Dictionary<string, HashSet<string>>();
        foreach (var r in await t.Store.Db.AllAsync("SELECT visitor, ts FROM rl_events"))
        {
            string v = Sql.S(r.Get("visitor"));
            if (!days.TryGetValue(v, out var set))
            {
                days[v] = set = [];
            }
            set.Add(Js.IsoString((long)Js.Number(r.Get("ts")))[..10]);
        }
        Assert.All(days.Values, set => Assert.Single(set));
    }

    [Fact]
    public async Task Umami_visit_history_stops_where_Runlights_own_visits_begin()
    {
        var t = await MakeAsync("sqlite", Umami(FakeEvents(), Sessions()), At("2026-03-01T23:00:00Z"));
        // Runlight started counting on the evening of March 1st.
        await t.Rl.CollectAsync(Harness.Hit("https://x.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://blog.example.com/" }, ip: "203.0.113.9"));
        Assert.Equal(3, (await ImportAllAsync(t)).Pageviews); // March 2nd is left to Runlight
    }

    [Fact]
    public async Task A_step_that_failed_part_way_can_run_again_without_counting_anything_twice()
    {
        var watched = new WatchedDb((await Databases.FreshAsync("sqlite")).Db);
        var t = Make(new SqlStore(watched), Umami(FakeEvents(), Sessions()), At("2026-03-04T00:00:00Z"));
        await t.Rl.InitAsync();
        int writes = 0;
        watched.Before = (sql, _) =>
        {
            if (sql.StartsWith("INSERT INTO rl_events", StringComparison.Ordinal) && ++writes > 2)
            {
                throw new InvalidOperationException("connection lost");
            }
            return Task.CompletedTask;
        };
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => Visits.ImportUmamiVisitsAsync(t.Rl, "default", Credentials(), "w1", null));
        Assert.Equal("connection lost", e.Message);
        watched.Before = null;
        await ImportAllAsync(t);
        var stats = await t.StatsAsync(t.Query("2026-03-01", "2026-03-03"));
        Assert.Equal(4, stats.Num("pageviews"));
        Assert.Equal(3, stats.Num("visits"));
        var totals = (await t.Store.Db.AllAsync("SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions"))[0];
        Assert.Equal((4.0, 1.0), (Js.Number(totals.Get("pageviews")), Js.Number(totals.Get("events"))));
    }

    [Fact]
    public async Task Umami_visit_history_skips_days_older_than_the_site_keeps()
    {
        var t = await MakeAsync("sqlite", Umami(FakeEvents(), Sessions()), At("2026-09-01T12:00:00Z"));
        await t.Rl.InitAsync();
        // Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
        await t.Rl.SetRetentionAsync("default", 6);
        Assert.Equal(1, (await ImportAllAsync(t)).Pageviews); // only March 2nd comes in
    }

    [Fact]
    public async Task An_unreadable_saved_progress_setting_starts_as_if_there_were_none()
    {
        var t = await MakeAsync("sqlite", Umami(FakeEvents(), Sessions()), At("2026-03-04T00:00:00Z"));
        await t.Rl.InitAsync();
        await t.Rl.Store.SetSettingAsync("import:umami-visits:default:w1", "not a number");
        Assert.Equal(4, (await ImportAllAsync(t)).Pageviews); // every day is read from the website's start
    }

    [Fact]
    public async Task An_imported_visit_across_UTC_midnight_is_one_visit_on_the_sites_own_day()
    {
        var ca = new JsObject { ["country"] = "CA", ["device"] = "desktop", ["os"] = "Mac OS", ["browser"] = "chrome" };
        var events = new List<JsObject> { E("n1", "2026-03-02T23:55:00.000Z", "/", 1, ca), E("n1", "2026-03-03T00:05:00.000Z", "/about", 1, ca) };
        var t = await MakeAsync("sqlite", Umami(events, [new JsObject { ["id"] = "n1" }], "2026-03-02T00:00:00Z", false), At("2026-03-10T00:00:00Z"), "America/Toronto");
        await ImportAllAsync(t);
        var stats = await t.StatsAsync(t.Query("2026-03-02", "2026-03-02"));
        Assert.Equal((1.0, 1.0, 2.0), (stats.Num("visits"), stats.Num("visitors"), stats.Num("pageviews")));
    }

    private static JsObject Ev(string session, string iso, string path, string? name = null)
    {
        var e = new JsObject { ["sessionId"] = session, ["createdAt"] = Js.IsoString(At(iso)), ["hostname"] = "blog.example.com", ["urlPath"] = path, ["eventType"] = name != null ? 2L : 1L };
        if (name != null)
        {
            e["eventName"] = name;
        }
        return e;
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_imported_visit_that_runs_past_midnight_keeps_one_visitor_on_all_its_rows(string kind)
    {
        var events = new List<JsObject> { Ev("s1", "2026-03-01T23:50:00Z", "/a"), Ev("s1", "2026-03-02T00:05:00Z", "/b"), Ev("s1", "2026-03-02T00:06:00Z", "/b", "Signup"), Ev("s1", "2026-03-02T10:00:00Z", "/b"), Ev("s1", "2026-03-02T10:01:00Z", "/b", "Signup") };
        var t = await MakeAsync(kind, Umami(events, [], "2026-03-01T00:00:00.000Z"), At("2026-03-05T12:00:00Z"));
        await ImportAllAsync(t);
        Assert.Empty(await t.Store.Db.AllAsync("SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor"));
        var q = t.Query("2026-03-01", "2026-03-02");
        async Task<string> Read() => J(new JsObject
        {
            ["pages"] = (await t.Store.BreakdownAsync(q, "page", 10, 0)).Select(r => (object?)L(r.Get("value"), r.Get("visitors"))).ToList(),
            ["events"] = (await t.Store.BreakdownAsync(q, "event", 10, 0)).Select(r => (object?)L(r.Get("value"), r.Get("visitors"))).ToList(),
        });
        string raw = await Read();
        while (await t.Rl.BuildRollupsAsync() > 0)
        {
        }
        Assert.Equal(raw, await Read()); // the same before and after the days are built
        Assert.Contains("\"events\":[[\"Signup\",2]]", raw, StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_visit_that_crosses_into_the_next_import_step_has_its_first_day_built_again(string kind)
    {
        var events = new List<JsObject> { Ev("s0", "2026-03-02T10:00:00Z", "/"), Ev("s1", "2026-03-14T23:50:00Z", "/a"), Ev("s1", "2026-03-15T00:10:00Z", "/b"), Ev("s2", "2026-03-20T10:00:00Z", "/") };
        var t = await MakeAsync(kind, Umami(events, [], "2026-03-01T00:00:00.000Z"), At("2026-03-25T12:00:00Z"));
        string? cursor = (await Visits.ImportUmamiVisitsAsync(t.Rl, "default", Credentials(), "w1", null)).Get("cursor") as string;
        // The scheduled check builds days between two steps.
        while (await t.Rl.BuildRollupsAsync() > 0)
        {
        }
        while (cursor != null)
        {
            cursor = (await Visits.ImportUmamiVisitsAsync(t.Rl, "default", Credentials(), "w1", cursor)).Get("cursor") as string;
        }
        while (await t.Rl.BuildRollupsAsync() > 0)
        {
        }
        var q = t.Query("2026-03-14", "2026-03-14");
        async Task<JsObject> Read() => new()
        {
            ["stats"] = await t.StatsAsync(q),
            ["pages"] = (await t.Store.BreakdownAsync(q, "page", 10, 0)).Select(r => (object?)L(r.Get("value"), r.Get("pageviews"))).ToList(),
        };
        var rolled = await Read();
        await t.Store.ClearRollupsAsync("default");
        Assert.Equal(Loose(await Read()), Loose(rolled));
        Assert.Equal(2, rolled.Obj("stats")!.Num("pageviews"));
    }

    [Fact]
    public async Task A_step_cursor_carries_a_sign_in_token_but_never_an_API_key()
    {
        var events = new List<JsObject> { Ev("s0", "2026-03-02T10:00:00Z", "/"), Ev("s2", "2026-03-20T10:00:00Z", "/") };
        var t = await MakeAsync("sqlite", Umami(events, [], "2026-03-01T00:00:00.000Z"), At("2026-03-25T12:00:00Z"));
        var cursor = (JsObject)Json.Parse((string)(await Visits.ImportUmamiVisitsAsync(t.Rl, "default", Credentials(), "w1", null)).Get("cursor")!)!;
        Assert.Equal(["website", "day", "start", "end"], cursor.Keys);
        Assert.Equal(At("2026-03-15T00:00:00Z"), cursor.Num("day")); // fourteen days a step
        var e = await Assert.ThrowsAsync<ImportError>(() => Visits.ImportUmamiVisitsAsync(t.Rl, "default", Credentials(), "w/1", null));
        Assert.Equal("import_website", e.Code);
    }

    // ---- CSV

    private static List<object?> RunlightRows() =>
    [
        new JsObject { ["time"] = "2026-03-01T10:00:00Z", ["url"] = "https://blog.example.com/?utm_campaign=spring", ["referrer"] = "www.google.com", ["visitor"] = "a", ["country"] = "CA", ["region"] = "CA-ON", ["city"] = "Toronto", ["browser"] = "Safari", ["os"] = "iOS", ["device"] = "mobile", ["title"] = "Home" },
        new JsObject { ["time"] = "2026-03-01T10:02:00Z", ["url"] = "https://blog.example.com/pricing", ["visitor"] = "a", ["country"] = "CA", ["browser"] = "Safari", ["os"] = "iOS", ["device"] = "mobile" },
        new JsObject { ["time"] = "2026-03-01T10:03:00Z", ["url"] = "https://blog.example.com/pricing", ["event"] = "Signup", ["visitor"] = "a" },
        new JsObject { ["time"] = "1772442000", ["path"] = "/", ["hostname"] = "blog.example.com", ["visitor"] = "b", ["country"] = "GB", ["browser"] = "Chrome", ["os"] = "macOS", ["device"] = "desktop" },
        // Not a time at all.
        new JsObject { ["time"] = "yesterday", ["path"] = "/x", ["visitor"] = "c" },
    ];

    private static async Task<Harness> CsvAsync(long now = 0)
    {
        var t = await Harness.CreateAsync("sqlite", new SiteOptions { Hostnames = ["blog.example.com"], Timezone = "UTC" });
        t.Now = now != 0 ? now : At("2026-03-04T00:00:00Z");
        return t;
    }

    [Fact]
    public async Task Csv_in_Runlights_format_rows_become_visits_with_sources_places_devices_and_events()
    {
        var t = await CsvAsync();
        Assert.Equal("{\"pageviews\":3,\"events\":1,\"visits\":2,\"skipped\":1}", J(await Visits.ImportCsvVisitsAsync(t.Rl, "default", RunlightRows())));
        var q = t.Query("2026-03-01", "2026-03-03");
        var stats = await t.StatsAsync(q);
        Assert.Equal((3.0, 2.0, 2.0), (stats.Num("pageviews"), stats.Num("visits"), stats.Num("visitors")));
        Assert.Equal(["Google"], await t.ValuesAsync(q, "source"));
        Assert.Equal(["spring"], await t.ValuesAsync(q, "utm_campaign"));
        Assert.Equal(["Signup"], await t.ValuesAsync(q, "event"));
        Assert.Equal(["desktop", "mobile"], await t.SortedAsync(q, "device"));
        Assert.Equal(["CA-ON"], await t.ValuesAsync(q, "region"));

        // The same file again replaces what it brought in, so nothing doubles.
        await Visits.ImportCsvVisitsAsync(t.Rl, "default", RunlightRows());
        Assert.Equal(3, (await t.StatsAsync(q)).Num("pageviews"));
        Assert.Equal(2, (await t.StatsAsync(q)).Num("visits"));
    }

    [Fact]
    public async Task Csv_in_Runlights_format_without_a_visitor_column_every_row_is_its_own_visit()
    {
        var t = await CsvAsync();
        var rows = L(new JsObject { ["time"] = "2026-03-01 10:00:00", ["path"] = "/a" }, new JsObject { ["time"] = "2026-03-01 10:01:00", ["path"] = "/b?ref=x" });
        Assert.Equal(2, (await Visits.ImportCsvVisitsAsync(t.Rl, "default", rows)).Num("visits"));
        await Visits.ImportCsvVisitsAsync(t.Rl, "default", rows);
        var q = t.Query("2026-03-01", "2026-03-03");
        Assert.Equal(2, (await t.StatsAsync(q)).Num("visits")); // the same rows get the same ids the second time
        Assert.Equal(["/a", "/b"], await t.SortedAsync(q, "page"));
    }

    [Fact]
    public async Task Csv_from_Umamis_export_pageviews_and_named_events_come_across_other_event_types_do_not()
    {
        var t = await CsvAsync();
        var rows = L(
            new JsObject { ["website_id"] = "w1", ["session_id"] = "s1", ["created_at"] = "2026-03-01 10:00:00", ["hostname"] = "blog.example.com", ["url_path"] = "/", ["url_query"] = "", ["referrer_domain"] = "news.ycombinator.com", ["page_title"] = "Home", ["event_type"] = "1", ["country"] = "CA", ["subdivision1"] = "ON", ["city"] = "Toronto", ["browser"] = "ios", ["os"] = "iOS", ["device"] = "mobile", ["screen"] = "390x844", ["language"] = "en-CA" },
            new JsObject { ["website_id"] = "w1", ["session_id"] = "s1", ["created_at"] = "2026-03-01 10:03:00", ["hostname"] = "blog.example.com", ["url_path"] = "/pricing", ["event_type"] = "2", ["event_name"] = "Signup" },
            new JsObject { ["website_id"] = "w1", ["session_id"] = "s1", ["created_at"] = "2026-03-01 10:03:01", ["hostname"] = "blog.example.com", ["url_path"] = "/pricing", ["event_type"] = "5" },
            new JsObject { ["website_id"] = "w1", ["session_id"] = "s2", ["created_at"] = "2026-03-02T09:00:00.000Z", ["hostname"] = "blog.example.com", ["url_path"] = "/blog", ["event_type"] = "1", ["country"] = "GB", ["browser"] = "chrome", ["os"] = "Mac OS", ["device"] = "desktop" });
        Assert.Equal("{\"pageviews\":2,\"events\":1,\"visits\":2,\"skipped\":1}", J(await Visits.ImportCsvVisitsAsync(t.Rl, "default", rows)));
        var q = t.Query("2026-03-01", "2026-03-03");
        Assert.Equal(["Hacker News"], await t.ValuesAsync(q, "source"));
        Assert.Equal(["CA-ON"], await t.ValuesAsync(q, "region"));
        Assert.Equal(["Chrome", "Safari"], await t.SortedAsync(q, "browser"));
    }

    [Fact]
    public async Task Csv_rows_from_after_Runlights_own_first_visit_are_left_to_Runlight()
    {
        var t = await CsvAsync(At("2026-03-01T23:00:00Z"));
        await t.Rl.CollectAsync(Harness.Hit("https://x.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://blog.example.com/" }, ip: "203.0.113.9"));
        var step = await Visits.ImportCsvVisitsAsync(t.Rl, "default", RunlightRows().Take(4).ToList());
        Assert.Equal(2, step.Num("pageviews")); // March 2nd is left to Runlight
        Assert.Equal(1, step.Num("skipped"));
    }

    [Fact]
    public async Task A_CSV_it_cannot_read_and_a_batch_that_is_too_big_are_refused()
    {
        var t = await CsvAsync();
        var cases = new (object? Rows, string Code)[]
        {
            (L(new JsObject { ["date"] = "2026-03-01", ["visitors"] = "12" }), "import_csv_format"),
            (Enumerable.Repeat(RunlightRows()[0], 2001).ToList(), "import_csv_batch"),
            ("not rows", "import_csv_batch"),
        };
        foreach (var (rows, code) in cases)
        {
            var e = await Assert.ThrowsAsync<ImportError>(() => Visits.ImportCsvVisitsAsync(t.Rl, "default", rows));
            Assert.Equal(code, e.Code);
        }
        Assert.Equal(2, (await Visits.ImportCsvVisitsAsync(t.Rl, "default", RunlightRows())).Num("visits"));
    }
}
