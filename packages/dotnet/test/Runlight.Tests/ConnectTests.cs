using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests;

/// <summary>
/// Connecting an install through its consent page, as hub.test.ts and the PHP's Core/ConnectTest.php test it, with
/// the install played by a router. The Runlight core is not here yet, so its addSite is a stand-in that records
/// what it was given; what the core then stores for the site is for the core's own tests.
/// </summary>
public sealed class ConnectTests : IAsyncLifetime
{
    private const string App = "http://127.0.0.1:4100/runlight";

    private long _now = 1_791_288_000_000;

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    /// <summary>A fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests' serve() does.</summary>
    private sealed class Router(params (string Pattern, Func<object?> Answer)[] routes) : IFetcher
    {
        public List<(string Url, FetchInit Init)> Requests { get; } = [];

        public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
        {
            init ??= new FetchInit();
            Requests.Add((url, init));
            string href = new Url(url).Href;
            foreach (var (pattern, answer) in routes)
            {
                if (Regex.IsMatch(href, pattern))
                {
                    object? result = answer();
                    var (status, body) = result is ValueTuple<int, object?> pair ? pair : (200, result);
                    return Task.FromResult(new Response(Json.Stringify(body), status, new Headers { ["content-type"] = "application/json" }));
                }
            }
            return Task.FromResult(new Response("{}", 404));
        }
    }

    private sealed class Down : IFetcher
    {
        public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default) =>
            throw new FetchException("refused");
    }

    private static List<object?> L(params object?[] items) => [.. items];

    /// <summary>An install that speaks OAuth, as an app's Runlight does.</summary>
    private static Router Install(JsObject? meta = null, JsObject? registered = null, int registerStatus = 201)
    {
        meta ??= new JsObject
        {
            ["authorization_endpoint"] = "http://127.0.0.1:4100/runlight/oauth/authorize",
            ["token_endpoint"] = "http://127.0.0.1:4100/runlight/oauth/token",
            ["registration_endpoint"] = "http://127.0.0.1:4100/runlight/oauth/register",
            ["scopes_supported"] = L("read", "manage"),
        };
        registered ??= new JsObject { ["client_id"] = "c1" };
        return new Router(
            ("/\\.well-known/oauth-authorization-server$", () => meta),
            ("/oauth/register$", () => (registerStatus, (object?)registered)),
            ("/oauth/token$", () => new JsObject { ["access_token"] = "rl_manage", ["site"] = "blog" }));
    }

    /// <summary>The hub's parts: its store, its clock, and a stand-in addSite that records each input.</summary>
    private sealed class Hub(SqlStore store, IFetcher fetcher, Func<long> now)
    {
        public SqlStore Store { get; } = store;

        public List<JsObject> Added { get; } = [];

        public Task<string> StartAsync(object? input, string back, string site = "") => Connect.StartConnectAsync(Store, fetcher, now, input, back, site);

        public Task<string> FinishAsync(SearchParams parameters) => Connect.FinishConnectAsync(Store, fetcher, now, input =>
        {
            Added.Add(input);
            return Task.FromResult(new JsObject { ["id"] = "blog.example.com" });
        }, parameters);
    }

    private async Task<Hub> HubAsync(string kind, IFetcher fetcher)
    {
        var store = await Databases.FreshAsync(kind);
        await store.MigrateAsync();
        return new Hub(store, fetcher, () => _now);
    }

    private static async Task<ConnectError> Refused(Func<Task> fn, string code)
    {
        var e = await Assert.ThrowsAsync<ConnectError>(fn);
        Assert.Equal(code, e.Code);
        return e;
    }

    private static SearchParams Q(params (string Name, string Value)[] pairs) => new(pairs.Select(p => new KeyValuePair<string, string>(p.Name, p.Value)));

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_hub_connects_an_app_through_its_consent_page_for_the_one_site_the_owner_picked(string kind)
    {
        var router = Install();
        var hub = await HubAsync(kind, router);
        const string back = "http://localhost:4900/runlight/api/sites/connect/done";
        var consent = new Url(await hub.StartAsync(App + "/", back));
        Assert.Equal("http://127.0.0.1:4100/runlight/oauth/authorize", consent.Origin + consent.Pathname);
        var q = consent.SearchParams;
        Assert.Equal(["code", "c1", back, "S256", "manage"], new[] { q.Get("response_type"), q.Get("client_id"), q.Get("redirect_uri"), q.Get("code_challenge_method"), q.Get("scope") });
        Assert.Matches("^[a-f0-9]{32}$", q.Get("state"));
        Assert.Null(q.Get("site"));
        Assert.Equal(Json.Stringify(new JsObject { ["client_name"] = "Runlight at localhost:4900", ["redirect_uris"] = L(back) }), router.Requests[1].Init.BodyText);

        var pending = (JsObject)Json.Parse((await hub.Store.SettingAsync("connect:" + q.Get("state")))!)!;
        string verifier = pending.Str("verifier")!;
        Assert.Equal(Convert.ToBase64String(SHA256.HashData(Js.Utf8(verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_'), q.Get("code_challenge"));
        Assert.Equal(_now + 15 * 60_000, pending.Long("expires"));

        string id = await hub.FinishAsync(Q(("state", q.Get("state")!), ("code", "the-code")));
        Assert.Equal("blog.example.com", id);
        Assert.Equal("{\"remote\":{\"url\":\"" + App + "\",\"token\":\"rl_manage\",\"site\":\"blog\"}}", Json.Stringify(Assert.Single(hub.Added)));
        var exchange = router.Requests.First(r => r.Url.EndsWith("/oauth/token", StringComparison.Ordinal));
        var form = new SearchParams(exchange.Init.BodyText!);
        Assert.Equal(["authorization_code", "the-code", "c1", back, verifier], new[] { form.Get("grant_type"), form.Get("code"), form.Get("client_id"), form.Get("redirect_uri"), form.Get("code_verifier") });

        // A code works once.
        await Refused(() => hub.FinishAsync(Q(("state", q.Get("state")!), ("code", "the-code"))), "expired");
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task What_went_wrong_comes_back_as_a_code(string kind)
    {
        var hub = await HubAsync(kind, Install());
        async Task<SearchParams> Start(string site = "") => new Url(await hub.StartAsync(App, "https://hub.example/done", site)).SearchParams;
        Assert.Equal("blog", (await Start("blog")).Get("site"));
        var denied = await Start();
        await Refused(() => hub.FinishAsync(Q(("state", denied.Get("state")!), ("error", "access_denied"))), "denied");
        var other = await Start();
        var e = await Refused(() => hub.FinishAsync(Q(("state", other.Get("state")!), ("error", "server_error"), ("error_description", "Sign in again"))), "refused");
        Assert.Equal("Sign in again", e.Message);
        await Refused(() => hub.FinishAsync(Q(("state", "not-a-state"))), "expired");
        // An attempt nobody came back from in time.
        var late = await Start();
        _now += 16 * 60_000;
        await Refused(() => hub.FinishAsync(Q(("state", late.Get("state")!))), "expired");
        // Starting again clears the ones that ran out.
        await Start();
        Assert.Single(await hub.Store.SettingsStartingWithAsync("connect:"));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_hub_only_follows_an_installs_own_endpoints_when_connecting(string kind)
    {
        var hostile = Install(new JsObject
        {
            ["authorization_endpoint"] = "http://127.0.0.1:1/authorize",
            ["token_endpoint"] = "http://169.254.169.254/token",
            ["registration_endpoint"] = "http://169.254.169.254/register",
            ["scopes_supported"] = L("read", "manage"),
        });
        var hub = await HubAsync(kind, hostile);
        var e = await Refused(() => hub.StartAsync("http://127.0.0.1:4100", "https://hub.example/done"), "endpoints");
        Assert.Contains("named endpoints on another address", e.Message, StringComparison.Ordinal);
        Assert.Single(hostile.Requests);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_install_that_cannot_connect_says_why(string kind)
    {
        await Refused(async () => await (await HubAsync(kind, Install())).StartAsync("ftp://x", "https://hub.example/done"), "url");
        await Refused(async () => await (await HubAsync(kind, new Router())).StartAsync(App, "https://hub.example/done"), "not_runlight");
        var old = Install(new JsObject
        {
            ["authorization_endpoint"] = App + "/oauth/authorize",
            ["token_endpoint"] = App + "/oauth/token",
            ["registration_endpoint"] = App + "/oauth/register",
            ["scopes_supported"] = L("read"),
        });
        await Refused(async () => await (await HubAsync(kind, old)).StartAsync(App, "https://hub.example/done"), "old");
        var e = await Refused(async () => await (await HubAsync(kind, Install(null, new JsObject { ["error_description"] = "redirect_uris must use https" }, 400))).StartAsync(App, "http://hub.example/done"), "register");
        Assert.Equal("{\"url\":\"" + App + "\",\"reason\":\"redirect_uris must use https.\"}", Json.Stringify(e.Params));
        e = await Refused(async () => await (await HubAsync(kind, Install(null, new JsObject { ["nope"] = true }, 400))).StartAsync(App, "http://hub.example/done"), "register");
        Assert.Equal("This server's address must use https.", e.Params.Str("reason"));
        e = await Refused(async () => await (await HubAsync(kind, new Down())).StartAsync(App, "https://hub.example/done"), "unreachable");
        Assert.Equal("{\"host\":\"127.0.0.1:4100\"}", Json.Stringify(e.Params));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_install_whose_scopes_supported_is_not_a_list_counts_as_an_older_runlight(string kind)
    {
        foreach (object? scopes in new object?[] { "unmanaged", "manage", 7.0 })
        {
            var odd = Install(new JsObject
            {
                ["authorization_endpoint"] = App + "/authorize",
                ["token_endpoint"] = App + "/token",
                ["registration_endpoint"] = App + "/register",
                ["scopes_supported"] = scopes,
            });
            var e = await Refused(async () => await (await HubAsync(kind, odd)).StartAsync(App, "https://hub.example/done"), "old");
            Assert.Contains("older Runlight", e.Message, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void The_install_address_is_https_or_this_machine()
    {
        Assert.Equal("https://example.com/runlight", Connect.InstallUrl("  https://example.com/runlight//  "));
        Assert.Equal("http://localhost:4100", Connect.InstallUrl("http://localhost:4100/"));
        Assert.Equal("http://127.0.0.1", Connect.InstallUrl("http://127.0.0.1"));
        foreach (object? bad in new object?[] { null, "", "http://example.com", "http://localhost.example.com", "ftp://x", 5.0 })
        {
            Assert.Equal("url", Assert.Throws<ConnectError>(() => Connect.InstallUrl(bad)).Code);
        }
    }
}
