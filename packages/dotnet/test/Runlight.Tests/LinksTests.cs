using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// Short links made, changed, and imported through Links, as links.test.ts and the PHP LinksTest
/// test them, on every database. Following a link is the core's, tested with it.
/// </summary>
public sealed class LinksTests : IAsyncLifetime
{
    private long _now = 1_791_471_600_000;

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    private async Task<(SqlStore Store, Links Links)> FreshAsync(string kind)
    {
        var store = await Databases.FreshAsync(kind);
        await store.MigrateAsync();
        await store.UpsertSiteAsync(new JsObject { ["id"] = "default", ["name"] = "Example", ["hostnames"] = new System.Collections.Generic.List<object?> { "example.com" }, ["timezone"] = "UTC" }, _now);
        return (store, new Links(store, () => _now, ct => store.MigrateAsync(cancellationToken: ct)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_link_gets_a_slug_and_a_name(string kind)
    {
        var (store, links) = await FreshAsync(kind);
        var link = await links.CreateAsync("default", new JsObject { ["url"] = "https://thedailypreset.com/presets/golden?ref=x" });
        Assert.Matches(new Regex("^[a-z2-9]{6}$"), link.Str("slug"));
        Assert.Equal("thedailypreset.com/presets/golden", link.Str("name"));
        Assert.Equal("https://thedailypreset.com/presets/golden?ref=x", link.Str("url"));
        var stored = await store.LinkBySlugAsync(link.Str("slug")!);
        Assert.Equal(link.Str("id"), stored!.Str("id"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Slugs_are_checked_unique_per_domain_and_freed_by_deleting(string kind)
    {
        var (store, links) = await FreshAsync(kind);
        await links.CreateAsync("default", new JsObject { ["url"] = "https://a.com", ["slug"] = "launch" });
        var taken = await Assert.ThrowsAsync<LinkError>(() => links.CreateAsync("default", new JsObject { ["url"] = "https://b.com", ["slug"] = "launch" }));
        Assert.Contains("taken", taken.Message, StringComparison.Ordinal);
        Assert.Equal(("link_taken", "{\"slug\":\"launch\"}"), (taken.Code, J(taken.Params))); // a code the dashboard can translate
        foreach (var (input, code) in new[]
        {
            (new JsObject { ["url"] = "https://b.com", ["slug"] = "has space" }, "link_slug"),
            (new JsObject { ["url"] = "javascript:alert(1)" }, "link_protocol"),
            (new JsObject { ["url"] = "not a url" }, "link_url"),
            (new JsObject { ["url"] = "https://b.com", ["domain"] = "t.unknown.com" }, "link_domain"),
        })
        {
            var error = await Assert.ThrowsAsync<LinkError>(() => links.CreateAsync("default", input));
            Assert.Equal(code, error.Code);
        }
        string id = (await store.LinksAsync("default", 0, _now + 1))[0].Str("id")!;
        var renamed = await links.UpdateAsync(id, new JsObject { ["slug"] = "launch-2", ["name"] = "Launch" });
        Assert.Equal("launch-2", renamed.Str("slug"));
        Assert.Equal("Launch", renamed.Str("name"));
        Assert.Equal("https://a.com/", renamed.Str("url")); // a key left out is left alone
        await links.RemoveAsync(id);
        await links.CreateAsync("default", new JsObject { ["url"] = "https://c.com", ["slug"] = "launch-2" });
        Assert.Single(await store.LinksAsync("default", 0, _now + 1)); // a deleted link's slug is free again
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => links.RemoveAsync("nope"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_slug_is_unique_across_every_domain(string kind)
    {
        var (store, links) = await FreshAsync(kind);
        await store.AddLinkDomainAsync("t.a.com", "default", _now);
        var link = await links.CreateAsync("default", new JsObject { ["url"] = "https://a.com/sale", ["slug"] = "sale", ["domain"] = "t.a.com" });
        Assert.Equal("t.a.com", link.Str("domain"));
        await Assert.ThrowsAsync<LinkError>(() => links.CreateAsync("default", new JsObject { ["url"] = "https://b.com/sale", ["slug"] = "sale" }));
        // Keeping a link's domain needs no check, even while that domain is removed.
        await store.RemoveLinkDomainAsync("t.a.com");
        var kept = await links.UpdateAsync(link.Str("id")!, new JsObject { ["domain"] = "www.t.a.com", ["name"] = "" });
        Assert.Equal(("t.a.com", "a.com/sale"), (kept.Str("domain"), kept.Str("name")));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Csv_rows_in_the_Umami_forks_format_import_and_bad_rows_say_why(string kind)
    {
        var (store, links) = await FreshAsync(kind);
        await store.AddLinkDomainAsync("t.thedailypreset.com", "default", _now);
        var result = await links.ImportAsync("default",
        [
            new JsObject { ["link_name"] = "Golden hour", ["destination_url"] = "https://thedailypreset.com/golden", ["link_slug"] = "golden", ["tracking_domain"] = "t.thedailypreset.com" },
            new JsObject { ["name"] = "Plain", ["url"] = "https://example.com/plain" },
            new JsObject { ["name"] = "Broken", ["url"] = "not a url" },
            new JsObject { ["name"] = "Duplicate", ["url"] = "https://example.com/x", ["slug"] = "golden", ["domain"] = "t.thedailypreset.com" },
        ]);
        Assert.Equal(2L, result.Get("created"));
        var failed = result.Arr("failed")!.Cast<JsObject>().ToList();
        Assert.Equal([3L, 4L], failed.Select(f => f.Get("row")));
        Assert.Equal("{\"row\":3,\"reason\":\"The destination must be a full URL, starting with https://\",\"code\":\"link_url\",\"params\":{}}", J(failed[0]));
        var all = await store.LinksAsync("default", 0, _now + 1);
        Assert.Equal(2, all.Count);
        Assert.Contains(all, l => l.Str("domain") == "t.thedailypreset.com" && l.Str("slug") == "golden");
    }

    [Fact]
    public async Task A_link_on_another_sites_domain_is_refused()
    {
        var (store, links) = await FreshAsync("sqlite");
        await store.UpsertSiteAsync(new JsObject { ["id"] = "b", ["name"] = "B", ["hostnames"] = new System.Collections.Generic.List<object?> { "b.com" }, ["timezone"] = "UTC" }, _now);
        await store.AddLinkDomainAsync("go.a.com", "default", 0);
        Assert.Equal("go.a.com", (await links.CreateAsync("default", new JsObject { ["url"] = "https://a.com/x", ["domain"] = "go.a.com" })).Str("domain"));
        await Assert.ThrowsAsync<LinkError>(() => links.CreateAsync("b", new JsObject { ["url"] = "https://b.com/x", ["domain"] = "go.a.com" }));
        _now++;
    }
}
