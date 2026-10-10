using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Routes.Make;

namespace Runlight.Tests.Routes;

/// <summary>
/// manage.test.ts, ported as the PHP's tests/Routes/ManageTest.php: what a hub's manage token may change, link
/// domains kept off the dashboard's own names, and a hub that never shows an install's answer as a page.
/// </summary>
public sealed class ManageTests : RoutesTestCase
{
    private sealed record Answer(int Status, object? Body);

    /// <summary>An app with two sites and an owner token, as a hub would connect to.</summary>
    private static async Task<(Runlight Rl, Func<string, string, string, object?, Task<Answer>> Call, Func<string, string, Task<string>> MakeToken)> AppAsync()
    {
        var rl = await RunlightAsync(sites: [Site("blog", hostnames: ["blog.example.com"]), Site("shop", hostnames: ["shop.example.com"])]);
        var routes = rl.Routes(new RoutesOptions { Token = "owner", Origin = "https://app.example.com" });
        async Task<Answer> Call(string method, string path, string auth, object? body = null)
        {
            var headers = H(("authorization", "Bearer " + auth));
            if (body != null)
            {
                headers.Set("content-type", "application/json");
            }
            var answer = await routes.HandleAsync(new Request("https://app.example.com/runlight" + path, method, headers, body == null ? "" : Json.Stringify(body)));
            return new Answer(answer.Status, Json.TryParse(answer.Text()));
        }
        async Task<string> MakeToken(string scope, string site) =>
            ((JsObject)(await Call("POST", "/api/tokens", "owner", new JsObject { ["name"] = "Hub", ["scope"] = scope, ["site"] = site })).Body!).Str("secret")!;
        return (rl, Call, MakeToken);
    }

    private static int Count(object? body, string key) => ((JsObject)body!).Arr(key)!.Count;

    [Fact]
    public async Task A_manage_token_changes_its_own_sites_settings_and_nothing_else()
    {
        var (_, call, make) = await AppAsync();
        Assert.Equal(400, (await call("POST", "/api/tokens", "owner", new JsObject { ["name"] = "Hub", ["scope"] = "manage" })).Status); // a manage token is for one site
        string manage = await make("manage", "blog");

        Assert.Equal("{\"scope\":\"manage\",\"site\":\"blog\"}", Json.Stringify((await call("GET", "/api/token", manage, null)).Body));
        Assert.Equal(201, (await call("POST", "/api/goals?site=blog", manage, new JsObject { ["name"] = "Signup", ["kind"] = "event", ["match"] = "Signup" })).Status);
        Assert.Equal(201, (await call("POST", "/api/goals", manage, new JsObject { ["name"] = "No site given", ["kind"] = "event", ["match"] = "x" })).Status); // its site is assumed
        Assert.Equal(2, Count((await call("GET", "/api/goals?site=blog", "owner", null)).Body, "goals"));
        Assert.Equal(404, (await call("POST", "/api/goals?site=shop", manage, new JsObject { ["name"] = "Elsewhere", ["kind"] = "event", ["match"] = "x" })).Status); // never another site
        Assert.Equal(0, Count((await call("GET", "/api/goals?site=shop", "owner", null)).Body, "goals"));
        Assert.Equal(404, (await call("PATCH", "/api/sites/shop", manage, new JsObject { ["name"] = "Mine now" })).Status);
        Assert.Equal(403, (await call("PATCH", "/api/sites/blog", manage, new JsObject { ["hostnames"] = "evil.example" })).Status);

        // Everything beyond one site's settings stays the owner's.
        Assert.Equal(401, (await call("GET", "/api/tokens", manage, null)).Status);
        Assert.Equal(403, (await call("POST", "/api/tokens", manage, new JsObject { ["name"] = "More", ["site"] = "blog" })).Status);
        Assert.Equal(403, (await call("PUT", "/api/mail", manage, new JsObject { ["service"] = "webhook" })).Status);
        Assert.Equal(200, (await call("GET", "/api/mail?site=blog", manage, null)).Status); // it can see which mail service sends reports
        Assert.Equal(201, (await call("POST", "/api/shares?site=blog", manage, new JsObject { ["name"] = "For the team" })).Status); // share links for its site are its to make
        Assert.Equal(404, (await call("POST", "/api/shares?site=shop", manage, new JsObject { ["name"] = "x" })).Status);
        Assert.Equal(403, (await call("DELETE", "/api/sites/blog", manage, null)).Status);
        Assert.Equal(403, (await call("POST", "/api/links/import?site=blog", manage, new JsObject { ["rows"] = L() })).Status);

        Assert.Equal(201, (await call("POST", "/api/links?site=blog", manage, new JsObject { ["url"] = "https://example.org/", ["slug"] = "hello" })).Status);
        Assert.Equal(1, Count((await call("GET", "/api/links?site=blog", manage, null)).Body, "links"));
        Assert.Equal(201, (await call("POST", "/api/reports?site=blog", manage, new JsObject { ["email"] = "me@example.com" })).Status);
        Assert.Equal(200, (await call("PATCH", "/api/sites/blog", manage, new JsObject { ["name"] = "The blog", ["retentionMonths"] = 12L })).Status);
    }

    [Fact]
    public async Task A_read_token_still_only_reads()
    {
        var (_, call, make) = await AppAsync();
        string read = await make("read", "blog");
        Assert.Equal("{\"scope\":\"read\",\"site\":\"blog\"}", Json.Stringify((await call("GET", "/api/token", read, null)).Body));
        Assert.Equal(403, (await call("POST", "/api/goals?site=blog", read, new JsObject { ["name"] = "Signup", ["kind"] = "event", ["match"] = "Signup" })).Status);
        Assert.Equal(200, (await call("GET", "/api/stats?site=blog&period=today", read, null)).Status);
    }

    [Fact]
    public async Task A_link_domain_can_never_be_where_the_dashboard_or_a_counted_site_lives()
    {
        var (_, call, _) = await AppAsync();
        Assert.Equal(400, (await call("POST", "/api/link-domains?site=blog", "owner", new JsObject { ["domain"] = "app.example.com" })).Status); // the dashboard's own host
        Assert.Equal(400, (await call("POST", "/api/link-domains?site=blog", "owner", new JsObject { ["domain"] = "shop.example.com" })).Status); // a site's domain
        Assert.Equal(201, (await call("POST", "/api/link-domains?site=blog", "owner", new JsObject { ["domain"] = "go.example.com" })).Status);
    }

    [Fact]
    public async Task Link_domains_stay_off_the_configured_address_and_the_names_people_signed_in_from()
    {
        var sent = new MailCatcher();
        var rl = await RunlightAsync(sites: [Site("blog", hostnames: ["blog.example.com"])], fetcher: sent, secret: "k");
        var routes = rl.Routes(new RoutesOptions { Token = "owner", Origin = "https://stats.example.com", OwnHosts = () => ["dash.example.net:443"] });
        Task<Response> Call(string method, string path, string auth = "owner", object? body = null) =>
            routes.HandleAsync(new Request("https://decoy.example.org/runlight" + path, method, H(("authorization", "Bearer " + auth), ("content-type", "application/json")), body == null ? "" : Json.Stringify(body)));
        async Task<int> Add(string domain) => (await Call("POST", "/api/link-domains?site=blog", "owner", new JsObject { ["domain"] = domain })).Status;
        foreach (string taken in new[] { "stats.example.com", "stats.example.com.", "www.stats.example.com", "dash.example.net", "decoy.example.org" })
        {
            Assert.True(400 == await Add(taken), taken);
        }
        // Names inside private networks, which the check would make the install fetch.
        foreach (string inside in new[] { "metadata.google.internal", "db.corp", "printer.local", "nas.home.arpa", "router.lan", "10.0.0.5.nip.io", "app.localhost" })
        {
            Assert.True(400 == await Add(inside), inside);
        }
        Assert.Equal(201, await Add("go.example.org"));
        // One saved before that rule is never fetched.
        await rl.Store.AddLinkDomainAsync("db.internal", "blog", 0);
        var check = Obj(await Call("GET", "/api/link-domains/db.internal/check?site=blog"));
        Assert.True(check.Has("target")); // and where a domain should point
        check.Remove("target");
        Assert.Equal("{\"domain\":\"db.internal\",\"working\":false,\"reason\":\"is not a public domain name\",\"code\":\"check_not_public\"}", Json.Stringify(check));

        // A hub's reports link to the configured address, never to the Host it names, and its samples share one wait.
        await rl.SaveMailSettingsAsync(new JsObject { ["service"] = "webhook", ["url"] = "https://hooks.example.net/mail", ["from"] = "reports@example.com" });
        string manage = Obj(await Call("POST", "/api/tokens", "owner", new JsObject { ["name"] = "Hub", ["scope"] = "manage", ["site"] = "blog" })).Str("secret")!;
        var first = Obj(await Call("POST", "/api/reports?site=blog", manage, new JsObject { ["email"] = "a@example.com" })).Obj("report")!;
        var second = Obj(await Call("POST", "/api/reports?site=blog", manage, new JsObject { ["email"] = "b@example.com" })).Obj("report")!;
        Assert.Equal(["https://stats.example.com/runlight", "https://stats.example.com/runlight"], (await rl.Store.ReportsAsync("blog")).Select(r => r.Str("origin")));
        Assert.Equal(200, (await Call("POST", "/api/reports/" + first.Str("id") + "/send?site=blog", manage)).Status); // the first sample goes out
        Assert.Single(sent.Mail);
        Assert.Equal("a@example.com", sent.Mail[0].Str("to"));
        Assert.Contains("https://stats.example.com/runlight", sent.Mail[0].Str("text"), StringComparison.Ordinal); // its links point at the configured address
        var waits = await Call("POST", "/api/reports/" + second.Str("id") + "/send?site=blog", manage);
        Assert.Equal(429, waits.Status); // another report waits too
        Assert.Equal("sample_soon_hub", Obj(waits).Str("code"));
        await Call("DELETE", "/api/reports/" + second.Str("id") + "?site=blog", manage);
        var again = Obj(await Call("POST", "/api/reports?site=blog", manage, new JsObject { ["email"] = "b@example.com" })).Obj("report")!;
        Assert.Equal(429, (await Call("POST", "/api/reports/" + again.Str("id") + "/send?site=blog", manage)).Status); // and so does one added again
        Assert.Single(sent.Mail);
    }

    [Fact]
    public async Task Without_its_own_address_an_app_gives_a_hub_no_link_domains_or_reports()
    {
        // As the quickstart sets it up: one site, no origin, and the app answers on more names than the site's.
        var rl = await RunlightAsync(site: Site(name: "example.com", hostnames: ["example.com"]));
        var routes = rl.Routes(new RoutesOptions { Token = "owner" });
        async Task<Answer> Call(string host, string method, string path, string auth, object? body = null)
        {
            var headers = H(("host", host), ("authorization", "Bearer " + auth));
            if (body != null)
            {
                headers.Set("content-type", "application/json");
            }
            var answer = await routes.HandleAsync(new Request("https://" + host + "/runlight" + path, method, headers, body == null ? "" : Json.Stringify(body)));
            return new Answer(answer.Status, Json.TryParse(answer.Text()));
        }
        string manage = ((JsObject)(await Call("app.example.com", "POST", "/api/tokens", "owner", new JsObject { ["name"] = "Hub", ["site"] = "default", ["scope"] = "manage" })).Body!).Str("secret")!;
        // From the deployment's other name, where the app's own name is not the request's Host.
        var add = await Call("example-app.vercel.app", "POST", "/api/link-domains", manage, new JsObject { ["domain"] = "app.example.com" });
        Assert.Equal(400, add.Status);
        Assert.Equal("origin_needed", ((JsObject)add.Body!).Str("code"));
        Assert.Equal("origin_needed", ((JsObject)(await Call("example-app.vercel.app", "POST", "/api/reports", manage, new JsObject { ["email"] = "cfo@example.com" })).Body!).Str("code"));
        Assert.Equal(201, (await Call("app.example.com", "POST", "/api/link-domains", "owner", new JsObject { ["domain"] = "go.example.com" })).Status); // the owner still adds them

        // On a link domain the dashboard's paths pass to the app, so the owner can always reach it there.
        foreach (string path in new[] { "/runlight", "/runlight/api/sites" })
        {
            Assert.Null(await rl.LinkDomainResponseAsync(new Request("https://go.example.com" + path, "GET", H(("host", "go.example.com")))));
        }
        Assert.Equal(404, (await rl.LinkDomainResponseAsync(new Request("https://go.example.com/nothing", "GET", H(("host", "go.example.com")))))?.Status);
        // Middleware that never made the routes leaves the default path alone too.
        var apart = await RunlightAsync(site: Site(name: "example.com", hostnames: ["example.com"]), store: rl.Store);
        Assert.Null(await apart.LinkDomainResponseAsync(new Request("https://go.example.com/runlight", "GET", H(("host", "go.example.com")))));
    }

    /// <summary>An install that answers a hub with a page, a redirect, and a long error.</summary>
    private sealed class Evil : IFetcher
    {
        public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
        {
            string path = new Url(url).Pathname;
            var json = H(("content-type", "application/json"));
            return Task.FromResult(path switch
            {
                _ when path.StartsWith("/runlight/api/sites", StringComparison.Ordinal) => new Response(Json.Stringify(new JsObject { ["sites"] = L(new JsObject { ["id"] = "x", ["name"] = "X", ["timezone"] = "UTC", ["hostnames"] = L("x.example.com") }) }), 200, json),
                _ when path.StartsWith("/runlight/api/stats", StringComparison.Ordinal) => new Response("<script>alert(1)</script>", 200, H(("content-type", "text/html"))),
                _ when path.StartsWith("/runlight/api/series", StringComparison.Ordinal) => new Response("", 302, H(("location", "http://169.254.169.254/"))),
                _ when path.StartsWith("/runlight/api/rhythm", StringComparison.Ordinal) => new Response(Json.Stringify(new JsObject { ["error"] = "Your session ended. Sign in again at https://evil.example/login " + new string('x', 1000), ["code"] = "link_taken", ["params"] = new JsObject { ["slug"] = "a", ["n"] = 5L } }), 400, json),
                _ => new Response("{}", 404),
            });
        }
    }

    [Fact]
    public async Task The_hub_never_passes_on_an_installs_answer_as_a_page_nor_follows_its_redirects()
    {
        var hub = await RunlightAsync(managedSites: true, secret: new string('k', 32), fetcher: new Evil(), localInstalls: true);
        var routes = hub.Routes(new RoutesOptions { Token = "owner" });
        Task<Response> Call(string path, string method = "GET", string? body = null) =>
            routes.HandleAsync(new Request("https://hub.example.com/runlight" + path, method, H(("authorization", "Bearer owner"), ("content-type", "application/json")), body ?? ""));
        var added = await Call("/api/sites", "POST", Json.Stringify(new JsObject { ["remote"] = new JsObject { ["url"] = "http://127.0.0.1:9/runlight", ["token"] = "rl_x" } }));
        string id = Obj(added).Obj("site")!.Str("id")!;
        var page = await Call("/api/stats?site=" + id + "&period=today");
        Assert.Matches("^application/json", page.Headers.Get("content-type") ?? "");
        Assert.Equal("nosniff", page.Headers.Get("x-content-type-options"));
        Assert.Matches("default-src 'none'", page.Headers.Get("content-security-policy") ?? "");
        Assert.Equal(502, (await Call("/api/series?site=" + id + "&period=today")).Status); // a redirect is reported, not followed
        // An install's error says where it came from, short, with only its code and string params.
        var said = Obj(await Call("/api/rhythm?site=" + id + "&period=today"));
        Assert.Matches("^127\\.0\\.0\\.1:9: Your session ended", said.Str("error")!);
        Assert.True(said.Str("error")!.Length < 340);
        Assert.Equal("link_taken", said.Str("code"));
        Assert.Equal("{\"slug\":\"a\"}", Json.Stringify(said.Get("params")));
    }
}

/// <summary>A mail webhook that keeps what it is sent, standing in for the small HTTP server manage.test.ts starts.</summary>
public sealed class MailCatcher : IFetcher
{
    public List<JsObject> Mail { get; } = [];

    public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
    {
        Mail.Add((JsObject)Json.Parse(init?.BodyText ?? "{}")!);
        return Task.FromResult(new Response("ok"));
    }
}
