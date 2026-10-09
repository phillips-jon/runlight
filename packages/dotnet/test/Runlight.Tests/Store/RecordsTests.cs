using System;
using System.Collections.Generic;
using System.Data.Common;
using System.Linq;
using System.Threading.Tasks;
using Xunit;
using static Runlight.Tests.Store.Seed;

namespace Runlight.Tests.Store;

/// <summary>Sites, links, shares, tokens, reports, settings, salts, and the live view, at the store, on every database.</summary>
public sealed class RecordsTests : StoreTestCase
{
    private static JsObject Site(string id, string name, string[] hostnames, string timezone) =>
        new() { ["id"] = id, ["name"] = name, ["hostnames"] = hostnames.Cast<object?>().ToList(), ["timezone"] = timezone };

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Sites_are_kept_with_their_overrides_and_a_deleted_sites_records_go_with_it(string kind)
    {
        var store = await StoreAsync(kind);
        await store.UpsertSiteAsync(Site("shop", "Shop", ["shop.example.com", "store.example.com"], "Europe/London"), NOW);
        // Unchanged, it is left alone; changed, it is updated, keeping when it was made.
        await store.UpsertSiteAsync(Site("shop", "Shop", ["shop.example.com", "store.example.com"], "Europe/London"), NOW + 1);
        await store.UpsertSiteAsync(Site("shop", "A shop", ["shop.example.com"], "Europe/London"), NOW + 2);
        Same(L(Site("shop", "A shop", ["shop.example.com"], "Europe/London"), Site("default", "Example", ["example.com"], "UTC")), await store.SitesAsync());
        Same(L(NOW), (await store.Db.AllAsync("SELECT created_at FROM rl_sites WHERE id = 'shop'")).Select(r => (object?)(long)Js.Number(r.Get("created_at"))).ToList());
        await store.SetSiteOverridesAsync("shop", new JsObject { ["name"] = "Renamed", ["timezone"] = "Asia/Tokyo" });
        await store.SetSiteOverridesAsync("default", []);
        var overrides = await store.SiteOverridesAsync();
        Same(new JsObject { ["default"] = new JsObject(), ["shop"] = new JsObject { ["name"] = "Renamed", ["timezone"] = "Asia/Tokyo" } }, JsObject.From(overrides.OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => new KeyValuePair<string, object?>(e.Key, e.Value))));
        // No overrides is an empty object.
        Assert.Equal("{}", (await store.Db.AllAsync("SELECT overrides FROM rl_sites WHERE id = 'default'"))[0].Get("overrides"));

        long t = NOW - HOUR;
        await VisitAsync(store, "s1", "v1", t, [], [Pv("/", t, "p1")], "shop");
        await VisitAsync(store, "s2", "v2", t - 40 * DAY, [], [Pv("/", t - 40 * DAY, "p2")], "shop");
        await VisitAsync(store, "s3", "v3", t, [], [Pv("/", t, "p3")]);
        await store.SaveGoalAsync(Goal("g1", new JsObject { ["site"] = "shop", ["match"] = "x" }));
        await store.InsertShareAsync(new JsObject { ["id"] = "sh", ["site"] = "shop", ["name"] = "", ["createdAt"] = 1L });
        await store.AddLinkDomainAsync("go.shop.example", "shop", 1);
        await store.BuildRollupDayAsync("shop", "2026-10-05", NOW - 36 * HOUR, NOW - 12 * HOUR);
        Assert.Equal(t, await store.LastSeenAsync("shop"));
        await store.DeleteSiteAsync("shop");
        Same(L("default"), Column(await store.SitesAsync(), "id"));
        foreach (string table in new[] { "rl_events", "rl_sessions", "rl_goals", "rl_shares", "rl_link_domains", "rl_rollups", "rl_rollup_days" })
        {
            Assert.True(Js.Number((await store.Db.AllAsync("SELECT COUNT(*) AS n FROM " + table + " WHERE site = 'shop'"))[0].Get("n")) == 0, table);
        }
        // The other site keeps its visits.
        Same(1, (await store.StatsAsync(Today())).Get("visits"));
        Assert.Null(await store.LastSeenAsync("shop"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Short_links_and_their_clicks(string kind)
    {
        var store = await StoreAsync(kind);
        string id = new('l', 24);
        var link = new JsObject { ["id"] = id, ["site"] = "default", ["domain"] = "", ["slug"] = "launch", ["name"] = "Launch", ["url"] = "https://example.com/launch", ["createdAt"] = NOW - DAY, ["updatedAt"] = NOW - DAY };
        await store.InsertLinkAsync(link);
        Same(link, await store.LinkBySlugAsync("launch"));
        // A slug is unique across every domain while its link lives.
        await Assert.ThrowsAnyAsync<DbException>(() => store.InsertLinkAsync(link.With(new JsObject { ["id"] = new string('m', 24), ["domain"] = "go.example.com" })));
        await store.UpdateLinkAsync(link.With(new JsObject { ["domain"] = "go.example.com", ["name"] = "Moved", ["updatedAt"] = NOW }));
        var moved = (await store.LinkByIdAsync(id))!;
        Same(L("go.example.com", "Moved", NOW), L(moved.Get("domain"), moved.Get("name"), moved.Get("updatedAt")));
        for (int i = 0; i < 40; i++)
        {
            long ts = NOW - i * HOUR;
            string session = i % 4 != 0 ? "c" + i : "";
            if (session != "")
            {
                await VisitAsync(store, session, "cv" + (i % 3), ts, new JsObject { ["source"] = i % 2 != 0 ? "Twitter" : "Direct", ["country"] = i % 2 != 0 ? "GB" : "US" });
            }
            await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = ts, ["kind"] = "click", ["visitor"] = session == "" ? "" : "cv" + (i % 3), ["session"] = session, ["pageview"] = "", ["path"] = "", ["hostname"] = "", ["title"] = "", ["name"] = "", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = id });
            if (session != "")
            {
                await store.TouchSessionAsync(session, ts, "click", "");
            }
        }
        var listed = await store.LinksAsync("default", NOW - 2 * DAY, NOW + 1);
        // Clicks imported as counts add to clicks only.
        Same(L(40, 3), L(listed[0].Get("clicks"), listed[0].Get("visitors")));
        var buckets = new List<JsObject>();
        for (int h = 0; h < 45; h++)
        {
            buckets.Add(new JsObject { ["start"] = NOW - 44 * HOUR + h * HOUR, ["end"] = NOW - 43 * HOUR + h * HOUR });
        }
        var series = await store.LinkSeriesAsync("default", id, buckets);
        // More buckets than one statement takes.
        Assert.Equal(45, series.Count);
        Assert.Equal(40, series.Sum(p => p.Num("clicks")));
        Same(
            L(new JsObject { ["value"] = "Twitter", ["visitors"] = 3, ["events"] = 20 }, new JsObject { ["value"] = "Direct", ["visitors"] = 3, ["events"] = 10 }),
            await store.LinkBreakdownAsync("default", id, 0, NOW + 1, "source", 5));
        // A click alone is not a visit.
        Same(0, (await store.StatsAsync(Q(0, NOW + 1))).Get("visits"));

        await store.DeleteLinkAsync(id, NOW);
        Assert.Null(await store.LinkBySlugAsync("launch"));
        Assert.Null(await store.LinkByIdAsync(id));
        Same(L(), await store.LinksAsync("default", 0, NOW + 1));
        await store.InsertLinkAsync(link.With(new JsObject { ["id"] = new string('n', 24) }));
        // A deleted link frees its slug.
        Assert.Equal(new string('n', 24), (await store.LinkBySlugAsync("launch"))!.Get("id"));

        await store.AddLinkDomainAsync("go.example.com", "default", 1);
        await store.AddLinkDomainAsync("go.example.com", "other", 2);
        await store.AddLinkDomainAsync("a.example.com", "default", 3);
        // A domain stays with its first site.
        Same(L(new JsObject { ["domain"] = "a.example.com", ["site"] = "default" }, new JsObject { ["domain"] = "go.example.com", ["site"] = "default" }), await store.LinkDomainsAsync());
        await store.RemoveLinkDomainAsync("go.example.com");
        Same(L("a.example.com"), Column(await store.LinkDomainsAsync(), "domain"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Shares_tokens_reports_and_settings(string kind)
    {
        var store = await StoreAsync(kind);
        await store.InsertShareAsync(new JsObject { ["id"] = "s1", ["site"] = "default", ["name"] = "Client", ["createdAt"] = 1L });
        await store.InsertShareAsync(new JsObject { ["id"] = "s2", ["site"] = "default", ["name"] = "", ["createdAt"] = 2L });
        await store.RenameShareAsync("s1", "Renamed");
        Same(L("s2", "s1"), Column(await store.SharesAsync("default"), "id"));
        Same(new JsObject { ["id"] = "s1", ["site"] = "default", ["name"] = "Renamed", ["createdAt"] = 1 }, await store.ShareByIdAsync("s1"));
        await store.DeleteShareAsync("s1");
        Assert.Null(await store.ShareByIdAsync("s1"));

        var token = new JsObject { ["id"] = "t1", ["name"] = "Script", ["site"] = "", ["scope"] = "read", ["hash"] = new string('h', 64), ["hint"] = "abcd", ["createdAt"] = 5L, ["lastUsedAt"] = null };
        await store.InsertTokenAsync(token);
        await store.InsertTokenAsync(token.With(new JsObject { ["id"] = "t2", ["site"] = "default", ["scope"] = "manage", ["hash"] = new string('g', 64), ["createdAt"] = 6L }));
        await store.TouchTokenAsync("t1", 99);
        Same(token.With(new JsObject { ["lastUsedAt"] = 99 }), await store.TokenByHashAsync(new string('h', 64)));
        Same(L("t2", "t1"), Column(await store.TokensAsync(), "id"));
        Assert.True(await store.DeleteTokenAsync("t1"), "a token that was there");
        Assert.False(await store.DeleteTokenAsync("t1"), "and once it is gone");

        var report = new JsObject { ["id"] = "r1", ["site"] = "default", ["email"] = "a@example.com", ["frequency"] = "weekly", ["lang"] = "en", ["token"] = new string('q', 32), ["origin"] = "", ["lastPeriod"] = "", ["lastSentAt"] = null, ["createdAt"] = 7L };
        await store.InsertReportAsync(report);
        Assert.True(await store.ClaimReportAsync("r1", "w:2026-09-28", 100), "the first claim wins");
        Assert.False(await store.ClaimReportAsync("r1", "w:2026-09-28", 101), "a second, at once, does not");
        Same(report.With(new JsObject { ["lastPeriod"] = "w:2026-09-28", ["lastSentAt"] = 100 }), await store.ReportByAsync("token", new string('q', 32)));
        await store.ReleaseReportAsync("r1", "w:2026-09-28", "");
        Assert.Equal("", (await store.ReportByAsync("id", "r1"))!.Get("lastPeriod"));
        Assert.Single(await store.ReportsAsync());
        Assert.Single(await store.ReportsAsync("default"));
        Assert.Empty(await store.ReportsAsync("elsewhere"));
        await store.DeleteReportAsync("r1");
        Assert.Null(await store.ReportByAsync("id", "r1"));

        await store.SetSettingAsync("remote:a", "1");
        await store.SetSettingAsync("remote:a", "2");
        await store.SetSettingAsync("remote_b", "3");
        await store.SetSettingAsync("remote%c", "4");
        await store.SetSettingAsync(@"remote\d", "5");
        Assert.Equal("2", await store.SettingAsync("remote:a"));
        Same(L(new JsObject { ["key"] = "remote:a", ["value"] = "2" }), await store.SettingsStartingWithAsync("remote:"));
        // An underscore is taken literally.
        Same(L(new JsObject { ["key"] = "remote_b", ["value"] = "3" }), await store.SettingsStartingWithAsync("remote_"));
        Same(L(new JsObject { ["key"] = "remote%c", ["value"] = "4" }), await store.SettingsStartingWithAsync("remote%"));
        // And a backslash, on MySQL too.
        Same(L(new JsObject { ["key"] = @"remote\d", ["value"] = "5" }), await store.SettingsStartingWithAsync(@"remote\"));
        await store.SetSettingAsync("remote:a", null);
        Assert.Null(await store.SettingAsync("remote:a"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Salts_sessions_and_the_live_view(string kind)
    {
        var store = await StoreAsync(kind);
        Assert.Equal("first", await store.SaltAsync("2026-10-06", "first"));
        // Two racing callers agree on one.
        Assert.Equal("first", await store.SaltAsync("2026-10-06", "second"));
        await store.SaltAsync("2026-10-05", "old");
        await store.DropSaltsBeforeAsync("2026-10-06");
        Assert.Null(await store.SaltIfExistsAsync("2026-10-05"));
        Assert.Equal("first", await store.SaltIfExistsAsync("2026-10-06"));

        long t = NOW - 3 * MIN;
        await VisitAsync(store, "s1", "v1", t - HOUR, new JsObject { ["source"] = "Google", ["country"] = "GB", ["city"] = "London", ["device"] = "Desktop" }, [Pv("/", t - HOUR, "old"), Pv("/pricing", t, "p1"), Ev("Signup", t + 1000, null)]);
        await VisitAsync(store, "s2", "v2", t, new JsObject { ["country"] = "US" }, [Pv("/", t, "p2")]);
        Same(new JsObject { ["id"] = "s1", ["visitor"] = "v1" }, await store.OpenSessionAsync("default", ["v0", "v1"], t - 1));
        Assert.Null(await store.OpenSessionAsync("default", ["v1"], t + 2000));
        Assert.Null(await store.OpenSessionAsync("default", [], 0));
        Same(new JsObject { ["session"] = "s1", ["visitor"] = "v1", ["path"] = "/pricing", ["hostname"] = "example.com", ["ts"] = t, ["startedAt"] = t - HOUR, ["lastAt"] = t + 1000 }, await store.PageviewAsync("default", "p1"));
        Assert.Null(await store.PageviewAsync("default", "nope"));

        var live = await store.RealtimeAsync("default", NOW);
        Same(2, live.Get("visitors"));
        Same(L(new JsObject { ["value"] = "/", ["visitors"] = 1 }, new JsObject { ["value"] = "/pricing", ["visitors"] = 1 }), live.Get("pages"));
        Same(L(new JsObject { ["value"] = "Google", ["visitors"] = 1 }), live.Get("sources"));
        Same(L(new JsObject { ["value"] = "GB", ["visitors"] = 1 }, new JsObject { ["value"] = "US", ["visitors"] = 1 }), live.Get("countries"));
        var minutes = live.Arr("minutes")!;
        Assert.Equal(30, minutes.Count);
        Same(2, minutes[26]);
        var recent = live.Arr("recent")!;
        Same(new JsObject { ["ts"] = t + 1000, ["kind"] = "event", ["path"] = "/pricing", ["name"] = "Signup", ["country"] = "GB", ["city"] = "London", ["source"] = "Google", ["device"] = "Desktop" }, recent[0]);
        Assert.Equal(3, recent.Count);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task AI_agent_fetches_are_their_own_rows_outside_visits(string kind)
    {
        var store = await StoreAsync(kind);
        string[] agents = ["GPTBot", "GPTBot", "ClaudeBot", "ClaudeBot", "Amazonbot"];
        for (int i = 0; i < agents.Length; i++)
        {
            await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = NOW - i * MIN, ["kind"] = "fetch", ["visitor"] = "", ["session"] = "", ["pageview"] = "", ["path"] = i % 2 != 0 ? "/a" : "/b", ["hostname"] = "example.com", ["title"] = "", ["name"] = agents[i], ["props"] = new JsObject { ["company"] = "X", ["kind"] = "crawler" }, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        }
        static JsObject Row(string value, int fetches) => new() { ["value"] = value, ["visitors"] = 0, ["fetches"] = fetches };
        Same(L(Row("ClaudeBot", 2), Row("GPTBot", 2), Row("Amazonbot", 1)), await store.BreakdownAsync(Today(), "ai_agent", 10, 0));
        Same(L(Row("/a", 2)), await store.BreakdownAsync(Today(), "ai_page", 1, 1));
        Same(0, (await store.StatsAsync(Today())).Get("visits"));
        Assert.Equal("{\"company\":\"X\",\"kind\":\"crawler\"}", (await store.Db.AllAsync("SELECT props FROM rl_events WHERE kind = 'fetch' LIMIT 1"))[0].Get("props"));
    }
}
