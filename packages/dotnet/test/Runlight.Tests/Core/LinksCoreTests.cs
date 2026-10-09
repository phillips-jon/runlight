using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>Short links, as links.test.ts tests them: made through Links, followed through LinkHandler and LinkDomainResponseAsync.</summary>
public sealed class LinksCoreTests : CoreTestCase
{
    /// <summary>A link domain added as the routes add one.</summary>
    private static async Task AddDomainAsync(Harness t, string domain, string site = "default")
    {
        await t.Store.AddLinkDomainAsync(domain, site, t.Now);
        t.Rl.ForgetLinkDomains();
    }

    private static async Task RemoveDomainAsync(Harness t, string domain)
    {
        await t.Store.RemoveLinkDomainAsync(domain);
        t.Rl.ForgetLinkDomains();
    }

    private static Request Get(string url, Headers? headers = null) => new(url, "GET", headers ?? new Headers { ["user-agent"] = Harness.ChromeMac });

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Create_follow_and_count_a_short_link(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        var link = await t.Rl.Links.CreateAsync("default", new JsObject { ["url"] = "https://thedailypreset.com/presets/golden?ref=x" });
        Assert.Matches(new Regex("^[a-z2-9]{6}$"), link.Str("slug")!);
        Assert.Equal("thedailypreset.com/presets/golden", link.Str("name"));

        var follow = t.Rl.LinkHandler();
        Task<Response> Go(string path, Dictionary<string, string>? headers = null)
        {
            var h = new Headers { ["user-agent"] = Harness.ChromeMac, ["x-forwarded-for"] = "203.0.113.9" };
            foreach (var (k, v) in headers ?? [])
            {
                h.Set(k, v);
            }
            return follow(new Request("https://example.com" + path, "GET", h));
        }
        var response = await Go("/go/" + link.Str("slug") + "?utm_source=newsletter&utm_medium=email", new() { ["referer"] = "https://mail.google.com/" });
        Assert.Equal(302, response.Status);
        Assert.Equal("https://thedailypreset.com/presets/golden?ref=x", response.Headers.Get("location"));
        Assert.Equal("no-store", response.Headers.Get("cache-control"));
        Assert.Equal("no-referrer-when-downgrade", response.Headers.Get("referrer-policy"));
        var missing = await Go("/go/nope");
        Assert.Equal(404, missing.Status);
        Assert.Equal("Not found", missing.Text());
        Assert.Equal("text/plain; charset=utf-8", missing.Headers.Get("content-type"));
        // Link previews and crawlers are sent on but not counted.
        Assert.Equal(302, (await Go("/go/" + link.Str("slug"), new() { ["user-agent"] = "facebookexternalhit/1.1" })).Status);

        var today = await t.TodayAsync();
        var list = await t.Store.LinksAsync("default", today.Long("from"), today.Long("to"));
        Assert.Equal(1, list[0].Num("clicks"));
        Assert.Equal(1, list[0].Num("visitors"));
        Assert.Equal("[{\"value\":\"Newsletter\",\"visitors\":1,\"events\":1}]", J(await t.Store.LinkBreakdownAsync("default", link.Str("id")!, today.Long("from"), today.Long("to"), "source", 10)));

        // Clicks are not visits: the site's own numbers do not move.
        var site = await t.StatsAsync(today);
        Assert.Equal(0, site.Num("visitors"));
        Assert.Equal(0, site.Num("pageviews"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Custom_link_domains_answer_at_their_root_and_only_for_their_own_links(string kind)
    {
        var t = await Harness.CreateAsync(kind);
        await t.Rl.InitAsync();
        await AddDomainAsync(t, "t.thedailypreset.com");
        await t.Rl.Links.CreateAsync("default", new JsObject { ["url"] = "https://thedailypreset.com/a", ["slug"] = "a", ["domain"] = "t.thedailypreset.com" });
        await t.Rl.Links.CreateAsync("default", new JsObject { ["url"] = "https://example.com/b", ["slug"] = "b" });

        Task<Response?> At(string host, string path) => t.Rl.LinkDomainResponseAsync(new Request("https://" + host + path, "GET", new Headers { ["host"] = host, ["user-agent"] = Harness.ChromeMac }));
        Assert.Equal("https://thedailypreset.com/a", (await At("t.thedailypreset.com", "/a"))?.Headers.Get("location"));
        Assert.Equal(404, (await At("t.thedailypreset.com", "/b"))?.Status); // the main site's links are not on the link domain
        Assert.Null(await At("example.com", "/a")); // other hosts carry on as normal
        Assert.Null(await At("t.thedailypreset.com", "/runlight/api/sites")); // the dashboard's own paths are left alone
        // The app's own link path answers for every link, as a fallback that never changes.
        Assert.Equal(302, (await t.Rl.LinkHandler()(Get("https://example.com/go/a"))).Status);
        var check = await At("t.thedailypreset.com", Runlight.LinkDomainCheck);
        Assert.Equal("{\"runlight\":true,\"domain\":\"t.thedailypreset.com\"}", check?.Text());
        Assert.Equal("application/json", check?.Headers.Get("content-type"));

        // Removing the domain keeps its links: they fall back to the app's own path.
        await RemoveDomainAsync(t, "t.thedailypreset.com");
        Assert.Null(await At("t.thedailypreset.com", "/a")); // the removed domain is no longer answered
        Assert.Equal("https://thedailypreset.com/a", (await t.Rl.LinkHandler()(Get("https://example.com/go/a"))).Headers.Get("location"));
        var a = (await t.Store.LinksAsync("default", 0, t.Now + 1)).First(l => l.Str("slug") == "a");
        Assert.Equal("t.thedailypreset.com", a.Str("domain")); // the link remembers its domain

        // Adding it back brings the links home again.
        await AddDomainAsync(t, "t.thedailypreset.com");
        Assert.Equal("https://thedailypreset.com/a", (await At("t.thedailypreset.com", "/a"))?.Headers.Get("location"));
    }

    [Fact]
    public async Task A_click_is_counted_as_a_click_with_its_source_and_never_with_an_address()
    {
        var t = await Harness.CreateAsync("sqlite");
        var link = await t.Rl.Links.CreateAsync("default", new JsObject { ["url"] = "https://a.com/", ["slug"] = "x" });
        await t.Rl.LinkHandler()(Get("https://example.com/go/x", new Headers { ["user-agent"] = Harness.ChromeMac, ["x-forwarded-for"] = "192.0.2.77", ["accept-language"] = "fr-CA,fr;q=0.9", ["host"] = "example.com:8080" }));
        var e = (await t.Store.Db.AllAsync("SELECT kind, name, link, path, hostname FROM rl_events"))[0];
        Assert.Equal("click x " + link.Str("id") + " /go/x example.com", string.Join(" ", e.Select(kv => Js.String(kv.Value))));
        var session = (await t.Store.Db.AllAsync("SELECT language, pageviews FROM rl_sessions"))[0];
        Assert.Equal("fr-CA", session.Str("language"));
        Assert.DoesNotContain("192.0.2.77", J(await t.Store.Db.AllAsync("SELECT * FROM rl_sessions")), StringComparison.Ordinal);
        // A HEAD request, as a link checker sends, is answered and not counted.
        await t.Rl.LinkHandler()(new Request("https://example.com/go/x", "HEAD", new Headers { ["user-agent"] = Harness.ChromeMac }));
        Assert.Equal(1, await t.CountAsync("SELECT COUNT(*) AS n FROM rl_events"));
    }
}
