using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;
using Runlight.Tests.Store;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>The tracker endpoint's work, as ingest.test.ts, audit.test.ts, and hardening.test.ts test it, read back from the store.</summary>
public sealed class IngestTests : CoreTestCase
{
    private static JsObject Pv(string url, string id, string? referrer = null) =>
        referrer == null ? new JsObject { ["k"] = "pageview", ["u"] = url, ["i"] = id } : new JsObject { ["k"] = "pageview", ["u"] = url, ["r"] = referrer, ["i"] = id };

    private static SiteOptions Hosts(params string[] hostnames) => new() { Hostnames = hostnames };

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_visit_pageviews_an_event_engagement_and_the_reports_that_follow(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/?utm_source=chatgpt.com", ["r"] = "https://chatgpt.com/", ["i"] = "pv1", ["t"] = "Home", ["w"] = 1440L, ["h"] = 900L, ["l"] = "en-GB" },
            headers: new() { ["x-vercel-ip-country"] = "GB", ["x-vercel-ip-country-region"] = "ENG", ["x-vercel-ip-city"] = "London" });
        t.Advance(20_000);
        await t.SendAsync(new JsObject { ["k"] = "engagement", ["u"] = "https://example.com/", ["i"] = "pv1", ["e"] = 18_000L, ["d"] = 75L });
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/pricing", ["r"] = "https://example.com/", ["i"] = "pv2", ["w"] = 1440L, ["h"] = 900L });
        t.Advance(5_000);
        await t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/pricing", ["i"] = "pv2", ["n"] = "Signup", ["p"] = new JsObject { ["plan"] = "pro" } });

        // A second visitor on a phone who bounces.
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/blog/post", ["r"] = "https://news.ycombinator.com/", ["i"] = "pv3", ["w"] = 390L, ["h"] = 844L }, Harness.SafariIphone, "198.51.100.7");
        await t.SendAsync(new JsObject { ["k"] = "engagement", ["u"] = "https://example.com/blog/post", ["i"] = "pv3", ["e"] = 4_000L }, Harness.SafariIphone, "198.51.100.7");

        var today = await t.TodayAsync();
        Assert.Equal("{\"visitors\":2,\"visits\":2,\"pageviews\":3,\"viewsPerVisit\":1.5,\"bounceRate\":0.5,\"visitDuration\":11000}", J(await t.StatsAsync(today)));
        Assert.Equal(
            Loose(Json.Parse("[{\"value\":\"AI\",\"visitors\":1,\"visits\":1,\"pageviews\":2,\"bounceRate\":0,\"visitDuration\":18000},{\"value\":\"Social\",\"visitors\":1,\"visits\":1,\"pageviews\":1,\"bounceRate\":1,\"visitDuration\":4000}]")),
            Loose(await t.Store.BreakdownAsync(today, "channel", 10, 0)));
        Assert.Equal(["ChatGPT", "Hacker News"], await t.ValuesAsync(today, "source"));
        Assert.Equal(["GB"], await t.ValuesAsync(today, "country"));
        Assert.Equal(["GB-ENG"], await t.ValuesAsync(today, "region"));
        Assert.Equal(["desktop", "mobile"], await t.SortedAsync(today, "device"));
        Assert.Equal(["1440x900", "390x844"], await t.SortedAsync(today, "screen"));
        Assert.Equal("[{\"value\":\"Signup\",\"visitors\":1,\"events\":1}]", J(await t.Store.BreakdownAsync(today, "event", 10, 0)));
        var home = (await t.Store.BreakdownAsync(today, "page", 10, 0)).First(p => p.Str("value") == "/");
        Assert.Equal(Loose(Json.Parse("{\"value\":\"/\",\"visitors\":1,\"pageviews\":1,\"timeOnPage\":18000,\"scrollDepth\":75}")), Loose(home));
        var props = Json.Parse(Sql.S((await t.Store.Db.AllAsync("SELECT props FROM rl_events WHERE kind = 'event'"))[0].Get("props")));
        Assert.Equal("{\"plan\":\"pro\"}", J(props));

        var live = await t.Store.RealtimeAsync("default", t.Now);
        Assert.Equal(2, live.Num("visitors"));
        Assert.Equal(4, live.Arr("recent")!.Count); // three pageviews and an event
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Thirty_idle_minutes_start_a_new_session_and_a_new_day_is_a_new_visitor(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        await t.SendAsync(Pv("https://example.com/", "a1"));
        t.Advance(29 * MIN);
        await t.SendAsync(Pv("https://example.com/a", "a2"));
        t.Advance(31 * MIN);
        await t.SendAsync(Pv("https://example.com/b", "a3"));
        var stats = await t.StatsAsync(await t.TodayAsync());
        Assert.Equal(2, stats.Num("visits"));
        Assert.Equal(1, stats.Num("visitors"));

        t.Advance(24 * 60 * MIN);
        await t.SendAsync(Pv("https://example.com/", "a4"));
        // The same person on another day is counted again.
        Assert.Equal(2, (await t.StatsAsync(t.Query("2026-10-01", "2026-10-07"))).Num("visitors"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_session_that_runs_past_midnight_UTC_stays_one_session(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        t.Advance(11 * 60 * MIN + 50 * MIN);
        await t.SendAsync(Pv("https://example.com/", "m1"));
        t.Advance(20 * MIN);
        await t.SendAsync(Pv("https://example.com/next", "m2"));
        var stats = await t.StatsAsync(t.Query("2026-10-01", "2026-10-07"));
        Assert.Equal(1, stats.Num("visits"));
        Assert.Equal(2, stats.Num("pageviews"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_salt_is_deleted_once_its_day_has_ended_everywhere(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        await t.SendAsync(Pv("https://example.com/", "s1"));
        for (int i = 0; i < 3; i++)
        {
            t.Advance(24 * 60 * MIN);
            await t.SendAsync(Pv("https://example.com/", "s" + (i + 2)));
        }
        await t.Rl.CheckAsync();
        // October 9th at noon UTC: the earliest timezone is on the 8th and still needs the 7th.
        var days = (await t.Store.Db.AllAsync("SELECT day FROM rl_salts ORDER BY day")).Select(r => Sql.S(r.Get("day"))).ToList();
        Assert.Equal(["2026-10-07", "2026-10-08", "2026-10-09"], days);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_visitor_is_one_visitor_for_the_whole_of_the_sites_own_day(string kind)
    {
        // Toronto: 11pm on the 6th and 1am on the 7th UTC are both the evening of October 6th.
        var t = await Harness.CreateAsync(kind, new SiteOptions { Timezone = "America/Toronto" });
        t.Advance(11 * 60 * MIN);
        await t.SendAsync(Pv("https://example.com/", "t1"));
        t.Advance(2 * 60 * MIN);
        await t.SendAsync(Pv("https://example.com/later", "t2"));
        var stats = await t.StatsAsync(t.Query("2026-10-06", "2026-10-06"));
        Assert.Equal(2, stats.Num("visits")); // two hours apart is two visits
        Assert.Equal(1, stats.Num("visitors")); // but one visitor, since it is the same day in Toronto
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Nothing_identifying_is_stored(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        await t.SendAsync(Pv("https://example.com/?email=jane@example.org&utm_campaign=x", "p1"), ip: "192.0.2.55");
        string dump = J(new List<object?> { await t.Store.Db.AllAsync("SELECT * FROM rl_sessions"), await t.Store.Db.AllAsync("SELECT * FROM rl_events") });
        Assert.DoesNotContain("192.0.2.55", dump, StringComparison.Ordinal);
        Assert.DoesNotContain("jane@example.org", dump, StringComparison.Ordinal);
        Assert.DoesNotContain("AppleWebKit", dump, StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Bots_AI_agents_junk_and_other_sites_are_dropped_quietly(string kind)
    {
        var t = await Harness.CreateAsync(kind, Hosts("example.com"));
        await t.SendAsync(Pv("https://example.com/", "b1"), "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)");
        await t.SendAsync(Pv("https://example.com/", "b2"), "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)");
        await t.SendAsync(Pv("https://elsewhere.net/", "b3"));
        await t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "javascript:alert(1)" });
        await t.SendAsync(new JsObject { ["k"] = "nonsense", ["u"] = "https://example.com/" });
        await t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/" });
        await t.Rl.CollectAsync(new Request("https://example.com/runlight/e", "POST", new Headers { ["user-agent"] = Harness.ChromeMac }, "{not json"));
        // Too long, whatever the length header says.
        await t.Rl.CollectAsync(new Request("https://example.com/runlight/e", "POST", new Headers { ["user-agent"] = Harness.ChromeMac }, Json.Stringify(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/", ["t"] = new string('x', 9000) })));
        await t.Rl.CollectAsync(new Request("https://example.com/runlight/e", "POST", new Headers { ["user-agent"] = Harness.ChromeMac, ["content-length"] = "99999" }, Json.Stringify(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/" })));
        Assert.Equal(0, (await t.StatsAsync(await t.TodayAsync())).Num("pageviews"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task AI_agents_are_recorded_as_fetches_by_observe(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        Task<bool> Fetch(string path, string ua) => t.Rl.ObserveAsync(new Request("https://example.com" + path, "GET", new Headers { ["user-agent"] = ua, ["host"] = "example.com" }));
        Assert.True(await Fetch("/blog/post", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ChatGPT-User/1.0; +https://openai.com/bot"));
        Assert.True(await Fetch("/blog/post", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)"));
        Assert.False(await Fetch("/logo.png", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)"));
        Assert.False(await Fetch("/", Harness.ChromeMac));
        var today = await t.TodayAsync();
        Assert.Equal("[{\"value\":\"ChatGPT-User\",\"visitors\":0,\"fetches\":1},{\"value\":\"ClaudeBot\",\"visitors\":0,\"fetches\":1}]", J(await t.Store.BreakdownAsync(today, "ai_agent", 10, 0)));
        Assert.Equal("[{\"value\":\"/blog/post\",\"visitors\":0,\"fetches\":2}]", J(await t.Store.BreakdownAsync(today, "ai_page", 10, 0)));
        Assert.Equal(0, (await t.StatsAsync(today)).Num("visitors")); // fetches are not visits
        // A log reader's time: older than a week is dropped, ahead of now counts as now.
        const string ua = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)";
        Assert.False(await t.Rl.ObserveAsync(new Request("https://example.com/old", "GET", new Headers { ["user-agent"] = ua }), t.Now - 8 * DAY));
        Assert.True(await t.Rl.ObserveAsync(new Request("https://example.com/later", "GET", new Headers { ["user-agent"] = ua }), t.Now + DAY));
        Assert.Equal(t.Now, (long)Js.Number((await t.Store.Db.AllAsync("SELECT ts FROM rl_events WHERE path = '/later'"))[0].Get("ts")));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Several_sites_in_one_install_told_apart_by_hostname(string kind)
    {
        var t = await Harness.CreateAsync(kind, sites: [new SiteOptions { Id = "brand-a", Hostnames = ["brand-a.com"] }, new SiteOptions { Id = "brand-b", Hostnames = ["brand-b.com"], Timezone = "America/Toronto" }]);
        await t.SendAsync(Pv("https://www.brand-a.com/", "x1"));
        await t.SendAsync(Pv("https://brand-b.com/", "x2"));
        await t.SendAsync(Pv("https://brand-b.com/two", "x3"));
        Assert.Equal(1, (await t.StatsAsync(await t.TodayAsync("brand-a"))).Num("pageviews"));
        Assert.Equal(2, (await t.StatsAsync(await t.TodayAsync("brand-b"))).Num("pageviews"));
        Assert.Equal(2, t.Rl.Sites().Count);
        Assert.Null(t.Rl.Site("brand-c"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_visitors_pageview_and_events_make_one_session(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        await t.SendAsync(Pv("https://example.com/", "p1"));
        await t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/", ["n"] = "Signup", ["i"] = "p1" });
        await t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/", ["n"] = "Clicked" });
        var stats = await t.StatsAsync(await t.TodayAsync());
        Assert.Equal(1, stats.Num("visits"));
        Assert.Equal(1, stats.Num("visitors"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_managed_install_counts_the_first_hit_it_gets_before_anything_else_has_loaded_its_sites(string kind)
    {
        var store = await Databases.FreshAsync(kind);
        var first = new Runlight(new RunlightOptions { Store = store, ManagedSites = true });
        await first.AddSiteAsync(new JsObject { ["hostnames"] = "blog.example.com" });
        var cold = new Runlight(new RunlightOptions { Store = store, ManagedSites = true, Now = () => Harness.START });
        await cold.CollectAsync(Harness.Hit("https://stats.example.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://blog.example.com/" }, ip: "203.0.113.4"));
        Assert.Equal(1, Js.Number((await store.Db.AllAsync("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'"))[0].Get("n")));
    }

    [Fact]
    public async Task A_burst_of_hits_from_one_new_visitor_opens_one_session()
    {
        // TS takes turns per visitor, so a pageview and the events right after it, arriving together, find one session.
        var t = await Harness.CreateAsync("sqlite");
        await t.Rl.InitAsync();
        await Task.WhenAll(Enumerable.Range(0, 8).Select(i => Task.Run(() => t.SendAsync(new JsObject { ["k"] = "event", ["u"] = "https://example.com/", ["n"] = "E" + i }))));
        Assert.Equal(1, await t.CountAsync("SELECT COUNT(*) AS n FROM rl_sessions"));
        Assert.Equal(8, await t.CountAsync("SELECT COUNT(*) AS n FROM rl_events"));
    }

    [Fact]
    public async Task A_region_name_from_a_location_database_is_kept_readable_and_a_code_stays_a_code()
    {
        var names = new Dictionary<string, JsObject>
        {
            ["203.0.113.1"] = new() { ["country"] = "ca", ["region"] = "Ontario", ["city"] = "Toronto" },
            ["203.0.113.2"] = new() { ["country"] = "GB", ["region"] = "ENG", ["city"] = "London" },
        };
        var t = await Harness.CreateAsync("sqlite", geo: ip => names.GetValueOrDefault(ip));
        foreach (string ip in names.Keys)
        {
            await t.Rl.CollectAsync(Harness.Hit("https://x.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://x.com/" }, "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", ip));
        }
        Assert.Equal(["CA-Ontario", "GB-ENG"], await t.SortedAsync(await t.TodayAsync(), "region"));
    }

    [Fact]
    public async Task Tracker_requests_over_the_per_address_limit_are_dropped_until_the_next_minute()
    {
        var t = await Harness.CreateAsync("sqlite", Hosts("example.com"), rateLimit: 3);
        t.Now = Utc(2026, 10, 6, 12) + Random.Shared.Next(1, 1_000_000) * 60_000L;
        Task Hit(string ip, int n) => t.Rl.CollectAsync(Harness.Hit("https://example.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/" + n }, "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", ip));
        string ip = "203.0.113." + Random.Shared.Next(1, 250);
        for (int n = 0; n < 5; n++)
        {
            await Hit(ip, n);
        }
        await Hit("198.51.100." + Random.Shared.Next(1, 250), 9);
        Task<long> Views() => t.CountAsync("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'");
        Assert.Equal(4, await Views()); // three from the busy address, one from the other
        t.Advance(60_000);
        await Hit(ip, 7);
        Assert.Equal(5, await Views()); // a new minute starts a new count
    }

    [Fact]
    public async Task A_tracker_hit_that_finds_the_database_busy_is_tried_again_at_the_time_it_arrived()
    {
        var watched = new WatchedDb((await Databases.FreshAsync("sqlite")).Db);
        var t = Harness.Create(new SqlStore(watched), new SiteOptions { Hostnames = ["example.com"], Timezone = "UTC" });
        await t.Rl.InitAsync();
        int refused = 0;
        watched.Before = (sql, _) =>
        {
            if (refused < 2 && sql.Contains("FROM rl_sessions WHERE site = ? AND visitor IN", StringComparison.Ordinal))
            {
                refused++;
                throw new InvalidOperationException("timeout exceeded when trying to connect");
            }
            return Task.CompletedTask;
        };
        long arrived = t.Now;
        await t.SendAsync(Pv("https://example.com/", "busy"));
        watched.Before = null;
        Assert.Equal(2, refused);
        Assert.Equal(1, (await t.StatsAsync(await t.TodayAsync())).Num("pageviews"));
        Assert.Equal(arrived, (long)Js.Number((await t.Store.Db.AllAsync("SELECT ts FROM rl_events"))[0].Get("ts")));
    }

    [Fact]
    public async Task A_local_test_counts_while_a_site_is_being_set_up_and_local_traffic_is_ignored_after_its_first_visit()
    {
        var t = await Harness.CreateAsync("sqlite", Hosts("example.com"));
        Task Hit(string url) => t.Rl.CollectAsync(Harness.Hit("https://x.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = url }, ip: "203.0.113.5"));
        async Task<double> Views() => (await t.StatsAsync(await t.TodayAsync())).Num("pageviews");
        await Hit("http://localhost:3000/");
        Assert.Equal(1, await Views()); // the first local test shows up
        await Hit("http://localhost:3000/again");
        await Hit("http://myapp.test/");
        Assert.Equal(1, await Views()); // after that, local hits are ignored
        await Hit("https://example.com/");
        Assert.Equal(2, await Views());
    }

    [Fact]
    public async Task The_client_address_comes_from_the_header_trusted_or_the_connection()
    {
        static Request R(Headers headers) => new("https://example.com/", "GET", headers, "", "192.0.2.9");
        var store = await Databases.FreshAsync("sqlite");
        var standard = new Runlight(new RunlightOptions { Store = store });
        Assert.Equal("198.51.100.2", standard.ClientIp(R(new Headers { ["x-forwarded-for"] = "203.0.113.1, 198.51.100.2" }))); // the last entry, which the nearest proxy wrote
        Assert.Equal("203.0.113.3", standard.ClientIp(R(new Headers { ["x-real-ip"] = "203.0.113.3" })));
        Assert.Equal("203.0.113.4", standard.ClientIp(R(new Headers { ["cf-connecting-ip"] = "203.0.113.4" })));
        Assert.Equal("192.0.2.9", standard.ClientIp(R(new Headers()))); // the connection, with no header
        Assert.Equal("192.0.2.1", standard.ClientIp(R(new Headers()), "192.0.2.1")); // the context names the connection
        var off = new Runlight(new RunlightOptions { Store = store, TrustProxy = false });
        Assert.Equal("192.0.2.9", off.ClientIp(R(new Headers { ["x-forwarded-for"] = "203.0.113.1" })));
        var cf = new Runlight(new RunlightOptions { Store = store, TrustProxy = "cf-connecting-ip" });
        Assert.Equal("203.0.113.4", cf.ClientIp(R(new Headers { ["x-forwarded-for"] = "203.0.113.1", ["cf-connecting-ip"] = "203.0.113.4" })));
        Assert.Equal("192.0.2.9", cf.ClientIp(R(new Headers { ["x-forwarded-for"] = "203.0.113.1" })));
    }

    [Fact]
    public async Task With_TrustProxy_left_at_its_default_a_public_address_with_no_proxy_header_is_warned_about_once()
    {
        static Request R(Headers headers) => new("https://example.com/", "GET", headers, "", "192.0.2.9");
        var store = await Databases.FreshAsync("sqlite");
        var said = new StringWriter();
        var stderr = Console.Error;
        Console.SetError(said);
        try
        {
            var quiet = new Runlight(new RunlightOptions { Store = store, TrustProxy = true });
            Assert.Equal("8.8.8.8", quiet.ClientIp(R(new Headers()), "8.8.8.8"));
            Assert.Equal("", said.ToString()); // set on purpose, never second-guessed

            var rl = new Runlight(new RunlightOptions { Store = store });
            rl.ClientIp(R(new Headers { ["x-forwarded-for"] = "8.8.4.4" }), "10.0.0.2");
            rl.ClientIp(R(new Headers()), "127.0.0.1");
            rl.ClientIp(R(new Headers()), "192.168.1.5");
            Assert.Equal("", said.ToString()); // a proxy's header, or a private or loopback address, says nothing
            Assert.Equal("8.8.8.8", rl.ClientIp(R(new Headers()), "8.8.8.8"));
            rl.ClientIp(R(new Headers()), "1.1.1.1");
            var lines = said.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
            Assert.Single(lines); // said once
            Assert.Contains("TrustProxy = false", lines[0], StringComparison.Ordinal);
        }
        finally
        {
            Console.SetError(stderr);
        }
    }

    [Fact]
    public async Task Options_are_checked_as_TS_checks_them()
    {
        var store = await Databases.FreshAsync("sqlite");
        var cases = new (Func<RunlightOptions> Options, string Error)[]
        {
            (() => new RunlightOptions { Store = store, Site = new SiteOptions { Timezone = "Mars/Base" } }, "unknown timezone"),
            (() => new RunlightOptions { Store = store, Site = new SiteOptions { Id = "has space" } }, "must be letters"),
            (() => new RunlightOptions { Store = store, Sites = [new SiteOptions { Id = "a", Hostnames = ["a.com"] }, new SiteOptions { Id = "b" }] }, "give each one its hostnames"),
            (() => new RunlightOptions { Store = store, Sites = [new SiteOptions { Id = "a", Hostnames = ["a.com"] }, new SiteOptions { Id = "a", Hostnames = ["b.com"] }] }, "share an id"),
        };
        foreach (var (options, error) in cases)
        {
            var e = Assert.Throws<ArgumentException>(() => new Runlight(options()));
            Assert.Contains(error, e.Message, StringComparison.Ordinal);
        }
        var rl = new Runlight(new RunlightOptions { Store = store, Site = new SiteOptions { Hostnames = ["www.Example.com"] }, LinkPath = "//links/" });
        Assert.Equal("/links", rl.LinkPath);
        Assert.Equal("[{\"id\":\"default\",\"name\":\"www.Example.com\",\"hostnames\":[\"example.com\"],\"timezone\":\"UTC\"}]", J(rl.Sites()));
    }
}
