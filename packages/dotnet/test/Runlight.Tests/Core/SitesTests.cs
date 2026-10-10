using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>Sites in code and in the dashboard, retention, and connected installs, as sites.test.ts and hub.test.ts test them without routes.</summary>
public sealed class SitesTests : CoreTestCase
{
    private static readonly string Key = new('k', 32);

    private static Task<SettingsError> Refused(Func<Task> fn, string code) => Refused<SettingsError>(fn, code);

    private static List<object?> L(params object?[] items) => [.. items];

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Managed_sites_are_added_changed_and_deleted_and_outlive_a_restart(string kind)
    {
        var store = await Databases.FreshAsync(kind);
        var t = Harness.Create(store, new SiteOptions { Name = "Ignored" }, managedSites: true);
        var rl = t.Rl;
        await rl.InitAsync();
        Assert.Empty(rl.Sites()); // no sites until one is added; the site in code is ignored

        await Refused(() => rl.AddSiteAsync(new JsObject { ["name"] = "Blog" }), "site_domain_needed");
        await Refused(() => rl.AddSiteAsync(new JsObject { ["hostnames"] = "not a domain" }), "site_domain_invalid");
        var blog = await rl.AddSiteAsync(new JsObject { ["name"] = "Blog", ["hostnames"] = "https://www.blog.example.com/path", ["timezone"] = "Europe/London" });
        Assert.Equal("{\"id\":\"blog.example.com\",\"name\":\"Blog\",\"hostnames\":[\"blog.example.com\"],\"timezone\":\"Europe/London\"}", J(blog));
        var shop = await rl.AddSiteAsync(new JsObject { ["hostnames"] = L("shop.example.com", "store.example.com") });
        Assert.Equal("shop.example.com", shop.Str("name")); // the name defaults to the domain
        var taken = await Refused(() => rl.AddSiteAsync(new JsObject { ["hostnames"] = "store.example.com" }), "site_domain_taken");
        Assert.Contains("already belongs to shop.example.com", taken.Message, StringComparison.Ordinal);
        await Refused(() => rl.AddSiteAsync(new JsObject { ["hostnames"] = "x.example.com", ["timezone"] = "Nowhere" }), "unknown_timezone");

        // Visits reach the right site by hostname, across origins.
        Task Send(string page, string ip) => rl.CollectAsync(Harness.Hit("https://stats.example.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = page }, ip: ip));
        await Send("https://blog.example.com/hello", "203.0.113.1");
        await Send("https://store.example.com/", "203.0.113.2");
        await Send("https://elsewhere.example/", "203.0.113.3");
        Assert.Equal(1, (await t.StatsAsync(await t.TodayAsync("blog.example.com"))).Num("pageviews"));
        Assert.Equal(1, (await t.StatsAsync(await t.TodayAsync("shop.example.com"))).Num("pageviews"));

        var renamed = await rl.UpdateSiteAsync("shop.example.com", new JsObject { ["name"] = "Shop", ["hostnames"] = "shop.example.com" });
        Assert.Equal("[\"shop.example.com\"]", J(renamed.Get("hostnames")));
        await Refused(() => rl.UpdateSiteAsync("shop.example.com", new JsObject { ["hostnames"] = "blog.example.com" }), "site_domain_taken");
        await Refused(() => rl.UpdateSiteAsync("shop.example.com", new JsObject { ["name"] = new string('x', 81) }), "site_name");

        // A restart reads the sites back from the database.
        var again = new Runlight(new RunlightOptions { Store = store, ManagedSites = true });
        await again.InitAsync();
        Assert.Equal(["blog.example.com Blog", "shop.example.com Shop"], again.Sites().Select(s => s.Str("id") + " " + s.Str("name")));

        await rl.DeleteSiteAsync("shop.example.com");
        await Refused(() => rl.DeleteSiteAsync("shop.example.com"), "unknown_site");
        Assert.Equal(["blog.example.com"], rl.Sites().Select(s => s.Str("id")));
        Assert.Equal(0, await t.CountAsync("SELECT COUNT(*) AS n FROM rl_events WHERE site = ?", "shop.example.com")); // a deleted site's visits go with it
    }

    [Fact]
    public async Task Sites_set_in_code_cannot_be_added_or_deleted_but_can_be_renamed()
    {
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Site = new SiteOptions { Name = "Code" } });
        await Refused(() => rl.AddSiteAsync(new JsObject { ["hostnames"] = "a.com" }), "sites_in_code");
        await Refused(() => rl.DeleteSiteAsync("default"), "sites_in_code");
        Assert.False(rl.ManagedSites);
        var site = await rl.UpdateSiteAsync("default", new JsObject { ["name"] = " Renamed ", ["timezone"] = "Europe/Paris" });
        Assert.Equal("{\"id\":\"default\",\"name\":\"Renamed\",\"hostnames\":[],\"timezone\":\"Europe/Paris\"}", J(site));
        Assert.Equal("{\"name\":\"Renamed\",\"timezone\":\"Europe/Paris\"}", J((await rl.Store.SiteOverridesAsync())["default"]));
        await Refused(() => rl.UpdateSiteAsync("nope", new JsObject { ["name"] = "x" }), "unknown_site");
    }

    [Fact]
    public async Task A_second_server_process_on_the_same_database_sees_new_sites_and_connected_installs_at_its_next_check()
    {
        var store = await Databases.FreshAsync("sqlite");
        var fetcher = new FakeFetcher((url, init) => Response.JsonOf(new JsObject { ["sites"] = L(new JsObject { ["id"] = "default", ["name"] = "App", ["timezone"] = "UTC", ["hostnames"] = L("app.example.com") }) }));
        var one = new Runlight(new RunlightOptions { Store = store, ManagedSites = true, Secret = Key, Fetcher = fetcher });
        var two = new Runlight(new RunlightOptions { Store = store, ManagedSites = true, Secret = Key, Fetcher = fetcher });
        await one.InitAsync();
        await two.InitAsync();
        await one.AddSiteAsync(new JsObject { ["hostnames"] = "new.example.com" });
        await one.AddSiteAsync(new JsObject { ["remote"] = new JsObject { ["url"] = "https://app.example.com/runlight", ["token"] = "rl_x" } });
        Assert.Empty(two.Sites()); // not yet
        await two.CheckAsync();
        Assert.Equal(["app.example.com", "new.example.com"], two.Sites().Select(s => s.Str("id")!).Order(StringComparer.Ordinal));
        Assert.Equal("https://app.example.com/runlight", two.Remote("app.example.com")!.Str("url"));
        string stored = (await store.SettingAsync("remote:app.example.com"))!;
        Assert.StartsWith("v1:", stored, StringComparison.Ordinal);
        Assert.DoesNotContain("rl_x", stored, StringComparison.Ordinal); // the token is sealed
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_sites_retention_setting_deletes_visits_older_than_it_allows(string kind)
    {
        var t = await Harness.CreateAsync(kind, new SiteOptions { Hostnames = ["example.com"] });
        Task Hit(string ip) => t.SendAsync(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/" }, ip: ip);
        async Task<double> Visits() => (await t.StatsAsync(await t.AllAsync())).Num("visits");
        t.Now = Utc(2025, 10, 1);
        await Hit("203.0.113.1");
        t.Now = Utc(2026, 7, 1);
        await Hit("203.0.113.2");
        t.Now = Utc(2026, 10, 6, 12);
        await Hit("203.0.113.3");
        Assert.Equal(3, await Visits());
        Assert.Null(await t.Rl.RetentionAsync("default")); // everything is kept by default

        await Refused(() => t.Rl.SetRetentionAsync("default", 7), "retention_bad");
        await Refused(() => t.Rl.SetRetentionAsync("elsewhere", 6), "unknown_site");
        await t.Rl.SetRetentionAsync("default", 6);
        Assert.Equal(3, await Visits()); // the deleting waits for idle, as TS runs it after answering
        await t.Rl.IdleAsync();
        Assert.Equal(6, await t.Rl.RetentionAsync("default"));
        Assert.Equal(2, await Visits()); // the visit from a year ago is gone

        t.Now = Utc(2027, 2, 1);
        await t.Rl.CheckAsync();
        Assert.Equal(1, await Visits()); // the scheduled check keeps trimming
        await t.Rl.SetRetentionAsync("default", null);
        Assert.Null(await t.Rl.RetentionAsync("default"));
    }

    [Fact]
    public async Task Retention_counts_back_calendar_months_as_setUTCMonth_does()
    {
        var t = await Harness.CreateAsync("sqlite");
        await t.Rl.InitAsync();
        await t.Rl.SetRetentionAsync("default", 6);
        t.Now = Utc(2026, 8, 31, 10, 30) + 123;
        // February 31st runs on to March 3rd, as JavaScript's dates do.
        Assert.Equal(Utc(2026, 3, 3, 10, 30) + 123, await t.Rl.RetentionCutoffAsync("default"));
    }

    [Fact]
    public async Task Deleting_a_site_forgets_its_retention_its_plugin_key_and_its_Umami_import_progress()
    {
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), ManagedSites = true });
        await rl.InitAsync();
        var site = await rl.AddSiteAsync(new JsObject { ["hostnames"] = "gone.example.com" });
        string id = site.Str("id")!;
        await rl.SetRetentionAsync(id, 12);
        await rl.Store.SetSettingAsync("observe-key:" + id, "rlo_x");
        await rl.Store.SetSettingAsync("import:umami-visits:" + id + ":w1", "{}");
        await rl.DeleteSiteAsync(id);
        await rl.IdleAsync();
        Assert.Null(await rl.Store.SettingAsync("retention:" + id));
        Assert.Null(await rl.Store.SettingAsync("observe-key:" + id));
        Assert.Null(await rl.Store.SettingAsync("import:umami-visits:" + id + ":w1"));
    }

    [Fact]
    public async Task A_connected_install_is_read_through_its_API_at_most_once_a_minute()
    {
        var answers = new Queue<Response>();
        var fetcher = new FakeFetcher((url, init) => answers.Count > 0 ? answers.Dequeue() : Response.JsonOf(new JsObject { ["sites"] = L() }));
        var t = await Harness.CreateAsync("sqlite", managedSites: true, secret: Key, fetcher: fetcher);
        answers.Enqueue(Response.JsonOf(new JsObject { ["sites"] = L(new JsObject { ["id"] = "default", ["name"] = "Shop", ["timezone"] = "Europe/Paris", ["hostnames"] = L("shop.example.com") }) }));
        answers.Enqueue(new Response("", 404));
        var site = await t.Rl.AddSiteAsync(new JsObject { ["remote"] = new JsObject { ["url"] = "https://shop.example.com/runlight/", ["token"] = "rl_1" } });
        string id = site.Str("id")!;
        Assert.Equal("{\"id\":\"shop.example.com\",\"name\":\"Shop\",\"hostnames\":[],\"timezone\":\"Europe/Paris\"}", J(site));
        Assert.Equal("{\"url\":\"https://shop.example.com/runlight\",\"token\":\"rl_1\",\"site\":\"default\",\"hostnames\":[\"shop.example.com\"],\"scope\":\"read\"}", J(t.Rl.Remote(id)));
        Assert.Equal("Bearer rl_1", fetcher.Requests[0].Headers.Str("authorization"));

        answers.Enqueue(Response.JsonOf(new JsObject { ["sites"] = L(new JsObject { ["id"] = "default", ["lastSeen"] = 123L, ["retentionMonths"] = 12L }) }));
        Assert.Equal("{\"lastSeen\":123,\"retentionMonths\":12,\"connection\":\"ok\"}", J(await t.Rl.RemoteInfoAsync(id)));
        int asked = fetcher.Requests.Count;
        Assert.Equal(123, await t.Rl.RemoteLastSeenAsync(id)); // from what it said a moment ago
        Assert.Equal(asked, fetcher.Requests.Count);
        t.Advance(60_000);
        answers.Enqueue(new Response("{\"error\":\"Unauthorized\"}", 401));
        var info = (await t.Rl.RemoteInfoAsync(id))!;
        Assert.Equal("refused", info.Str("connection"));
        Assert.Equal(123, info.Num("lastSeen")); // the last visit it gave before
        Assert.Equal("{\"lastSeen\":123,\"connection\":\"refused\"}", J(info)); // retention unknown, as TS leaves it undefined
        t.Rl.ForgetRemoteInfo(id);

        // Hits never land on a site counted elsewhere, even when they name it.
        await t.Rl.CollectAsync(Harness.Hit("https://stats.example.com/runlight/e", new JsObject { ["k"] = "pageview", ["u"] = "https://shop.example.com/", ["s"] = id }));
        Assert.Equal(0, await t.CountAsync("SELECT COUNT(*) AS n FROM rl_events"));
        await Refused(() => t.Rl.SetRetentionAsync(id, 6), "unknown_site");

        // Deleting it asks the install to delete the token, and keeps nothing of it here.
        answers.Enqueue(new Response("", 204));
        await t.Rl.DeleteSiteAsync(id);
        var last = fetcher.Requests[^1];
        Assert.Equal(("DELETE", "https://shop.example.com/runlight/api/token"), (last.Method, last.Url));
        Assert.Empty(await t.Store.SettingsStartingWithAsync("remote:"));
    }

    [Fact]
    public async Task Connecting_again_with_a_manage_token_upgrades_the_same_connection_and_revokes_the_old_token()
    {
        string scope = "read";
        var fetcher = new FakeFetcher((url, init) =>
        {
            if (url.EndsWith("/api/sites", StringComparison.Ordinal))
            {
                return Response.JsonOf(new JsObject { ["sites"] = L(new JsObject { ["id"] = "default", ["name"] = "Shop", ["timezone"] = "UTC", ["hostnames"] = L("shop.example.com") }) });
            }
            if (init.Method == "DELETE")
            {
                return new Response("", 204);
            }
            return Response.JsonOf(new JsObject { ["scope"] = scope, ["site"] = "default" });
        });
        var hub = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), ManagedSites = true, Secret = Key, Fetcher = fetcher, LocalInstalls = true });
        string first = (await hub.AddSiteAsync(new JsObject { ["remote"] = new JsObject { ["url"] = "http://127.0.0.1:4100/runlight", ["token"] = "rl_read" } })).Str("id")!;
        Assert.Equal("read", hub.Remote(first)!.Str("scope"));
        scope = "manage";
        string second = (await hub.AddSiteAsync(new JsObject { ["remote"] = new JsObject { ["url"] = "http://127.0.0.1:4100/runlight", ["token"] = "rl_manage" } })).Str("id")!;
        Assert.Equal(first, second);
        Assert.Equal("manage", hub.Remote(first)!.Str("scope"));
        Assert.Equal("rl_manage", hub.Remote(first)!.Str("token"));
        Assert.Single(hub.Sites());
        var revoked = fetcher.Requests.Where(r => r.Method == "DELETE").ToList();
        Assert.Equal("Bearer rl_read", revoked[0].Headers.Str("authorization")); // the old token was deleted there
    }

    [Fact]
    public async Task A_connection_is_refused_with_a_code_the_dashboard_can_say()
    {
        object? answer = null;
        var fetcher = new FakeFetcher((url, init) => answer is "network" ? throw new FetchException("Could not connect") : (Response)answer!);
        var hub = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), ManagedSites = true, Fetcher = fetcher });
        JsObject Remote(string url, string token) => new() { ["remote"] = new JsObject { ["url"] = url, ["token"] = token } };
        await Refused(() => hub.AddSiteAsync(Remote("http://example.com", "x")), "connect_url");
        await Refused(() => hub.AddSiteAsync(Remote("https://example.com", " ")), "install_token");
        answer = "network";
        var e = await Refused(() => hub.AddSiteAsync(Remote("https://example.com:8443/runlight", "x")), "unreachable");
        Assert.Equal("{\"host\":\"example.com:8443\"}", J(e.Params));
        answer = new Response("", 401);
        await Refused(() => hub.AddSiteAsync(Remote("https://example.com", "x")), "install_refused");
        answer = Response.JsonOf(new JsObject { ["sites"] = L() });
        e = await Refused(() => hub.AddSiteAsync(Remote("https://example.com", "x")), "connect_not_runlight");
        Assert.Equal("{\"url\":\"https://example.com\"}", J(e.Params));
    }

    [Fact]
    public async Task An_install_on_a_private_address_is_never_asked_and_a_redirect_is_not_followed()
    {
        var fetcher = new FakeFetcher((_, _) => Response.Redirect("http://169.254.169.254/latest/meta-data", 302));
        var hub = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), ManagedSites = true, Fetcher = fetcher });
        JsObject Remote(string url) => new() { ["remote"] = new JsObject { ["url"] = url, ["token"] = "x" } };
        await Refused(() => hub.AddSiteAsync(Remote("https://127.0.0.1")), "unreachable");
        await Refused(() => hub.AddSiteAsync(Remote("https://[::ffff:10.0.0.1]")), "unreachable");
        fetcher.Dns = _ => ["192.168.1.10"];
        await Refused(() => hub.AddSiteAsync(Remote("https://hub.internal")), "unreachable");
        Assert.Empty(fetcher.Requests); // nothing was sent
        fetcher.Dns = _ => ["93.184.215.14"];
        await Refused(() => hub.AddSiteAsync(Remote("https://hub.example")), "connect_not_runlight");
        Assert.Equal(["https://hub.example/api/sites"], fetcher.Requests.Select(r => r.Url)); // the redirect stopped
        // An install on this machine, for trying things out, only when code allows it.
        await Refused(() => hub.AddSiteAsync(Remote("http://127.0.0.1:4100")), "connect_url");
        var local = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), ManagedSites = true, Fetcher = fetcher, LocalInstalls = true });
        await Refused(() => local.AddSiteAsync(Remote("http://127.0.0.1:4100")), "connect_not_runlight");
        Assert.Equal("http://127.0.0.1:4100/api/sites", fetcher.Requests[1].Url);
        await Refused(() => local.AddSiteAsync(Remote("http://10.0.0.1")), "connect_url");
    }

    [Fact]
    public async Task Assistant_settings_keep_a_key_only_for_the_same_service_at_the_same_address()
    {
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Secret = Key });
        await rl.InitAsync();
        await Refused(() => rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "nope" }), "assistant_provider");
        await Refused(() => rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "anthropic" }), "assistant_key");
        await Refused(() => rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "custom", ["model"] = "m" }), "assistant_address");
        await Refused(() => rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "custom", ["baseUrl"] = "ftp://x", ["model"] = "m" }), "assistant_address_bad");
        await Refused(() => rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "openai", ["key"] = "k" }), "assistant_model");
        await rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "anthropic", ["key"] = "sk-1" });
        Assert.Equal("{\"provider\":\"anthropic\",\"model\":\"\",\"baseUrl\":\"\",\"key\":\"sk-1\"}", J(await rl.AssistantSettingsAsync()));
        Assert.DoesNotContain("sk-1", await rl.Store.SettingAsync("assistant"), StringComparison.Ordinal);
        await rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "anthropic", ["model"] = "claude-x", ["key"] = "" });
        Assert.Equal("sk-1", (await rl.AssistantSettingsAsync())!.Str("key")); // same service, blank key: kept
        await Refused(() => rl.SaveAssistantSettingsAsync(new JsObject { ["provider"] = "anthropic", ["baseUrl"] = "https://proxy.example/v1/", ["key"] = "" }), "assistant_key");
        await rl.SaveAssistantSettingsAsync(null);
        Assert.Null(await rl.AssistantSettingsAsync());
    }
}
