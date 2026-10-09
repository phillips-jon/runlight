using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Importers;
using Xunit;
using static Runlight.Tests.Core.Router;
using static Runlight.Tests.Fixtures;
using Index = Runlight.Importers.Index;

namespace Runlight.Tests.Core;

/// <summary>Link imports written into the store, as importers.test.ts tests them.</summary>
public sealed class ImportStepTests : CoreTestCase
{
    private const long Now = 1_791_288_000_000;

    private static List<object?> L(params object?[] items) => [.. items];

    private static async Task<Runlight> RunlightAsync(Router router) =>
        new(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Fetcher = router, Now = () => Now });

    private static async Task<(Runlight Rl, long Links, long Clicks, long Skipped, List<object?> Failed)> RunAllAsync(Router router, string source, JsObject credentials)
    {
        var rl = await RunlightAsync(router);
        string? cursor = null;
        double done = 0;
        long links = 0, clicks = 0, skipped = 0;
        var failed = new List<object?>();
        do
        {
            var step = await Index.ImportStepAsync(rl, "default", source, credentials, cursor, done);
            cursor = step.Get("cursor") as string;
            done = step.Num("done");
            links += step.Long("links");
            clicks += step.Long("clicks");
            skipped += step.Long("skipped");
            failed.AddRange(step.Arr("failed")!);
        }
        while (cursor != null);
        return (rl, links, clicks, skipped, failed);
    }

    private static Task<List<JsObject>> LinksAsync(Runlight rl) => rl.Store.LinksAsync("default", 0, Now + 1);

    [Fact]
    public async Task Dub_every_click_where_the_plan_allows()
    {
        var router = new Router(
            R("api\\.dub\\.co/links\\?.*startingAfter=l2", () => L()),
            R("api\\.dub\\.co/links\\?", () => L(
                new JsObject { ["id"] = "l1", ["domain"] = "dub.sh", ["key"] = "launch", ["url"] = "https://a.com/launch", ["title"] = "Launch", ["createdAt"] = "2026-01-02T00:00:00Z" },
                new JsObject { ["id"] = "l2", ["domain"] = "go.brand.com", ["key"] = "sale", ["url"] = "https://a.com/sale", ["title"] = null, ["createdAt"] = "2026-02-03T00:00:00Z" })),
            R("/events\\?.*linkId=l1", () => L(
                new JsObject { ["timestamp"] = "2026-03-01T10:00:00Z", ["click"] = new JsObject { ["id"] = "c1", ["country"] = "CA", ["city"] = "Toronto", ["device"] = "Mobile", ["browser"] = "Chrome", ["os"] = "iOS", ["referer"] = "instagram.com", ["refererUrl"] = "https://instagram.com/" } },
                new JsObject { ["timestamp"] = "2026-03-02T10:00:00Z", ["click"] = new JsObject { ["id"] = "c2", ["country"] = "US", ["device"] = "Desktop", ["browser"] = "Safari", ["os"] = "Mac OS", ["referer"] = "(direct)" } })),
            R("/events\\?.*linkId=l2", () => L()));
        var (rl, links, clicks, _, _) = await RunAllAsync(router, "dub", new JsObject { ["apiKey"] = "dub_test" });
        Assert.Equal(2, links);
        Assert.Equal(2, clicks);
        var bySlug = (await LinksAsync(rl)).ToDictionary(l => l.Str("slug")!);
        Assert.Equal("", bySlug["launch"].Str("domain")); // dub.sh stays behind; the link moves to /go
        Assert.Equal("go.brand.com", bySlug["sale"].Str("domain")); // branded domains come across
        Assert.Equal("{\"domain\":\"go.brand.com\",\"site\":\"default\"}", J((await rl.Store.LinkDomainsAsync())[0]));
        var session = (await rl.Store.Db.AllAsync("SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1"))[0];
        Assert.Equal("{\"country\":\"CA\",\"source\":\"Instagram\",\"device\":\"mobile\"}", J(session));
        Assert.Equal(1, Js.Number((await rl.Store.Db.AllAsync("SELECT imported FROM rl_sessions LIMIT 1"))[0].Get("imported")));
    }

    [Fact]
    public async Task Dub_daily_counts_when_the_plan_has_no_events_API()
    {
        var router = new Router(
            R("api\\.dub\\.co/links\\?", () => L(new JsObject { ["id"] = "l1", ["domain"] = "dub.sh", ["key"] = "x", ["url"] = "https://a.com", ["title"] = "X", ["createdAt"] = "2026-01-02T00:00:00Z" })),
            R("/events\\?", () => (403, (object?)new JsObject { ["error"] = new JsObject { ["message"] = "Business plan required" } })),
            R("/analytics\\?", () => L(new JsObject { ["start"] = "2026-03-01T00:00:00.000Z", ["clicks"] = 3L }, new JsObject { ["start"] = "2026-03-02T00:00:00.000Z", ["clicks"] = 0L })));
        var (rl, _, clicks, _, _) = await RunAllAsync(router, "dub", new JsObject { ["apiKey"] = "dub_test" });
        Assert.Equal(3, clicks);
        var row = (await LinksAsync(rl))[0];
        Assert.Equal(3, row.Num("clicks"));
        Assert.Equal(0, row.Num("visitors")); // daily counts add clicks, not made-up visitors
        var times = (await rl.Store.Db.AllAsync("SELECT ts FROM rl_events ORDER BY ts")).Select(r => (long)Js.Number(r.Get("ts")));
        long day = Utc(2026, 3, 1);
        Assert.Equal([day + 14_400_000, day + 43_200_000, day + 72_000_000], times); // spread through the day
    }

    [Fact]
    public async Task Bitly_every_group_custom_back_halves_daily_counts()
    {
        var router = new Router(
            R("/v4/groups$", () => new JsObject { ["groups"] = L(new JsObject { ["guid"] = "G1" }, new JsObject { ["guid"] = "G2" }) }),
            R("/groups/G1/bitlinks", () => new JsObject
            {
                ["links"] = L(
                    new JsObject { ["id"] = "bit.ly/3abc", ["link"] = "https://bit.ly/3abc", ["long_url"] = "https://a.com/1", ["title"] = "One", ["created_at"] = "2026-01-01T00:00:00+0000", ["custom_bitlinks"] = L("https://t.brand.com/one") },
                    new JsObject { ["id"] = "bit.ly/gone", ["link"] = "https://bit.ly/gone", ["long_url"] = "https://a.com/x", ["title"] = "Gone", ["created_at"] = "2026-01-01T00:00:00+0000", ["is_deleted"] = true }),
                ["pagination"] = new JsObject { ["search_after"] = "" },
            }),
            R("/groups/G2/bitlinks", () => new JsObject { ["links"] = L(new JsObject { ["id"] = "bit.ly/4def", ["link"] = "https://bit.ly/4def", ["long_url"] = "https://a.com/2", ["title"] = null, ["created_at"] = "2026-02-01T00:00:00+0000" }), ["pagination"] = new JsObject() }),
            R("/bitlinks/bit\\.ly%2F3abc/clicks", () => new JsObject { ["link_clicks"] = L(new JsObject { ["clicks"] = 5L, ["date"] = "2026-03-01T00:00:00+0000" }, new JsObject { ["clicks"] = 2L, ["date"] = "2026-03-02T00:00:00+0000" }) }),
            R("/bitlinks/bit\\.ly%2F4def/clicks", () => (402, (object?)new JsObject { ["message"] = "UPGRADE_REQUIRED" })));
        var (rl, links, clicks, _, _) = await RunAllAsync(router, "bitly", new JsObject { ["token"] = "bitly_test" });
        Assert.Equal(2, links); // the deleted link is skipped
        Assert.Equal(7, clicks);
        var pairs = (await LinksAsync(rl)).Select(l => l.Str("domain") + " " + l.Str("slug")).Order(StringComparer.Ordinal);
        Assert.Equal([" 4def", "t.brand.com one"], pairs);
    }

    [Fact]
    public async Task Short_io_every_domain_paged_with_daily_counts_in_either_shape()
    {
        var router = new Router(
            R("api\\.short\\.io/api/domains", () => L(new JsObject { ["id"] = 7L, ["hostname"] = "s.brand.com" })),
            R("api/links\\?.*pageToken=P2", () => new JsObject { ["links"] = L(new JsObject { ["idString"] = "lnk2", ["id"] = 2L, ["path"] = "two", ["originalURL"] = "https://a.com/2", ["createdAt"] = "2026-02-01T00:00:00Z" }), ["nextPageToken"] = null }),
            R("api/links\\?domain_id=7", () => new JsObject { ["links"] = L(new JsObject { ["idString"] = "lnk1", ["id"] = 1L, ["path"] = "one", ["originalURL"] = "https://a.com/1", ["title"] = "One", ["createdAt"] = "2026-01-01T00:00:00Z" }), ["nextPageToken"] = "P2" }),
            R("statistics/link/lnk1/by_interval", () => new JsObject { ["clickStatistics"] = L(new JsObject { ["x"] = "2026-03-01T00:00:00Z", ["y"] = 4L }) }),
            R("statistics/link/lnk2/by_interval", () => new JsObject { ["clickStatistics"] = new JsObject { ["datasets"] = L(new JsObject { ["data"] = L(new JsObject { ["x"] = Utc(2026, 3, 2), ["y"] = 1L }) }) } }));
        var (_, links, clicks, _, _) = await RunAllAsync(router, "shortio", new JsObject { ["apiKey"] = "sk_test" });
        Assert.Equal(2, links);
        Assert.Equal(5, clicks);
    }

    [Fact]
    public async Task Rebrandly_links_only_paged_by_the_last_id()
    {
        static List<object?> Page(int from, int n) => [.. Enumerable.Range(from, n).Select(i => (object?)new JsObject { ["id"] = "r" + i, ["slashtag"] = "s" + i, ["destination"] = "https://a.com/" + i, ["domain"] = new JsObject { ["fullName"] = "rebrand.ly" }, ["createdAt"] = "2026-01-01T00:00:00Z" })];
        var router = new Router(
            R("/links\\?.*last=r24", () => Page(25, 3)),
            R("rebrandly\\.com/v1/links\\?", () => Page(0, 25)));
        var (rl, links, clicks, _, _) = await RunAllAsync(router, "rebrandly", new JsObject { ["apiKey"] = "rb_test" });
        Assert.Equal(28, links);
        Assert.Equal(0, clicks);
        Assert.Equal("", (await LinksAsync(rl))[0].Str("domain")); // rebrand.ly stays behind
    }

    [Fact]
    public async Task Umami_signs_in_with_a_username_and_password_and_re_runs_skip_what_is_there()
    {
        var router = new Router(
            R("/api/auth/login", (_, init) => ((JsObject)Json.Parse(init.BodyText!)!).Str("password") == "pw" ? new JsObject { ["token"] = "tok" } : new JsObject()),
            R("/api/links\\?", () => new JsObject { ["data"] = L(new JsObject { ["id"] = "u-1", ["name"] = "Golden", ["url"] = "https://a.com", ["slug"] = "golden", ["createdAt"] = "2026-01-01T00:00:00Z", ["deletedAt"] = null, ["customDomain"] = new JsObject { ["domain"] = "t.brand.com" } }), ["count"] = 1L }),
            R("/websites/u-1/events", () => new JsObject { ["data"] = L(new JsObject { ["sessionId"] = "s1", ["createdAt"] = "2026-03-01T00:00:00Z", ["urlPath"] = "/golden", ["urlQuery"] = "utm_source=newsletter", ["referrerDomain"] = "", ["referrerPath"] = "", ["country"] = "GB", ["city"] = "London", ["device"] = "mobile", ["os"] = "iOS", ["browser"] = "ios" }), ["count"] = 1L }),
            R("/websites/u-1/sessions", () => new JsObject { ["data"] = L(new JsObject { ["id"] = "s1", ["screen"] = "390x844", ["language"] = "en-GB", ["region"] = "ENG" }), ["count"] = 1L }));
        var rl = await RunlightAsync(router);
        var creds = new JsObject { ["url"] = "https://stats.example.com/", ["username"] = "jon", ["password"] = "pw" };
        var first = await Index.ImportStepAsync(rl, "default", "umami", creds, null, 0);
        Assert.Equal(1, first.Num("links"));
        Assert.Equal(1, first.Num("clicks"));
        Assert.StartsWith("POST stats.example.com/api/auth/login", router.Calls[0], StringComparison.Ordinal);
        var s = (await rl.Store.Db.AllAsync("SELECT region, source, browser FROM rl_sessions"))[0];
        Assert.Equal("{\"region\":\"GB-ENG\",\"source\":\"Newsletter\",\"browser\":\"Safari\"}", J(s));
        var again = await Index.ImportStepAsync(rl, "default", "umami", creds, null, 0);
        Assert.Equal(1, again.Num("skipped"));
        var e = await Assert.ThrowsAsync<ImportError>(() => Index.ImportStepAsync(rl, "default", "umami", new JsObject { ["url"] = "nope" }, null, 0));
        Assert.Contains("Umami address", e.Message, StringComparison.Ordinal);
        e = await Assert.ThrowsAsync<ImportError>(() => Index.ImportStepAsync(rl, "default", "nowhere", new JsObject(), null, 0));
        Assert.Contains("cannot import", e.Message, StringComparison.Ordinal);
        Assert.Equal("{\"source\":\"nowhere\"}", J(e.Params));
    }

    [Fact]
    public async Task Umami_a_link_already_here_with_the_same_slug_and_destination_is_skipped_before_its_history_is_fetched()
    {
        var router = new Router(
            R("/api/links\\?", () => new JsObject { ["data"] = L(new JsObject { ["id"] = "u-9", ["name"] = "Golden", ["url"] = "https://a.com/", ["slug"] = "golden", ["createdAt"] = "2026-01-01T00:00:00Z", ["deletedAt"] = null }), ["count"] = 1L }),
            R("/websites/u-9/", () => new JsObject { ["data"] = L(), ["count"] = 0L }));
        var rl = await RunlightAsync(router);
        await rl.InitAsync();
        // Brought in earlier some other way, such as a CSV, so it has no Umami id.
        await rl.Links.CreateAsync("default", new JsObject { ["url"] = "https://a.com", ["slug"] = "golden", ["name"] = "Golden" });
        var step = await Index.ImportStepAsync(rl, "default", "umami", new JsObject { ["url"] = "https://stats.example.com/", ["apiKey"] = "k" }, null, 0);
        Assert.Equal(1, step.Num("skipped"));
        Assert.Equal(0, step.Num("links"));
        Assert.DoesNotContain(router.Calls, c => c.Contains("/websites/u-9/", StringComparison.Ordinal)); // no history was fetched for it
    }

    [Fact]
    public async Task Umami_a_link_list_without_a_count_gives_no_total_and_pages_on_while_pages_are_full()
    {
        static JsObject Link(int i) => new() { ["id"] = "u" + i, ["name"] = "N" + i, ["url"] = "https://a.com/" + i, ["slug"] = "s" + i, ["createdAt"] = "2026-01-01T00:00:00Z", ["deletedAt"] = null };
        var router = new Router(
            R("/api/links\\?page=1&", () => new JsObject { ["data"] = Enumerable.Range(0, 5).Select(i => (object?)Link(i)).ToList() }),
            R("/api/links\\?page=2&", () => new JsObject { ["data"] = L(Link(5)), ["count"] = "six" }),
            R("/websites/", () => new JsObject { ["data"] = L(), ["count"] = 0L }));
        var rl = await RunlightAsync(router);
        var creds = new JsObject { ["url"] = "https://stats.example.com", ["apiKey"] = "k" };
        var first = await Index.ImportStepAsync(rl, "default", "umami", creds, null, 0);
        Assert.Null(first.Get("total"));
        Assert.NotNull(first.Get("cursor")); // a full page may have more after it
        var second = await Index.ImportStepAsync(rl, "default", "umami", creds, (string)first.Get("cursor")!, first.Num("done"));
        Assert.Equal("[null,6,null]", J(L(second.Get("cursor"), second.Get("done"), second.Get("total"))));
        var empty = await Index.ImportStepAsync(await RunlightAsync(new Router(R("/api/links\\?", () => new JsObject { ["data"] = L() }))), "default", "umami", creds, null, 0);
        Assert.Equal("[null,0,null]", J(L(empty.Get("cursor"), empty.Get("done"), empty.Get("total"))));
    }

    [Fact]
    public async Task A_link_whose_slug_is_taken_or_unusable_is_reported_with_a_code()
    {
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite") });
        await rl.InitAsync();
        await rl.Links.CreateAsync("default", new JsObject { ["url"] = "https://elsewhere.com", ["slug"] = "taken", ["name"] = "Other" });
        JsObject Foreign(string id, string slug, string domain, string name, string url) => new() { ["sourceId"] = id, ["slug"] = slug, ["domain"] = domain, ["name"] = name, ["url"] = url, ["createdAt"] = 0L };
        var taken = await Write.WriteLinkAsync(rl, "default", "dub", Foreign("x", "taken", "", "X", "https://a.com"), new JsObject());
        Assert.Equal("{\"status\":\"failed\",\"clicks\":0,\"reason\":\"/taken is already used by \\\"Other\\\"\",\"code\":\"import_slug_taken\",\"params\":{\"slug\":\"taken\",\"name\":\"Other\"}}", J(taken));
        var bad = await Write.WriteLinkAsync(rl, "default", "dub", Foreign("y", "a/b", "", "", "https://a.com"), new JsObject());
        Assert.Equal("import_slug_bad", bad.Str("code"));
        var made = await Write.WriteLinkAsync(rl, "default", "dub", Foreign("z", "fine", "www.Go.Brand.com", "", "https://a.com/z"), new JsObject { ["clicks"] = L(new JsObject { ["ts"] = 5_000L, ["visit"] = "v", ["path"] = "/fine", ["query"] = "?utm_campaign=c" }) });
        Assert.Equal("{\"status\":\"created\",\"clicks\":1}", J(made));
        var link = (await rl.Store.LinkBySlugAsync("fine"))!;
        Assert.Equal(["go.brand.com", "fine", Write.ImportedLinkId("dub", "z")], new[] { link.Str("domain"), link.Str("name"), link.Str("id") });
        Assert.Equal("c", (await rl.Store.Db.AllAsync("SELECT utm_campaign FROM rl_sessions"))[0].Str("utm_campaign"));
        // The same link again.
        Assert.Equal("{\"status\":\"skipped\",\"clicks\":0}", J(await Write.WriteLinkAsync(rl, "default", "dub", Foreign("z", "fine", "", "", "https://a.com/z"), new JsObject())));
    }
}
