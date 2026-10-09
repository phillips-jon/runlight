using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Server;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests.Server;

/// <summary>
/// Clears every environment variable the server and its settings read for a test and puts them back after, so
/// a variable set where the tests run never changes what they see.
/// </summary>
public abstract class ServerTestCase : IAsyncLifetime
{
    private static readonly string[] Names = ["RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV", "RUNLIGHT_URL", "RUNLIGHT_GEO", "DATA_DIR", "DATABASE_URL", "TRUST_PROXY", "RUNLIGHT_CONFIG", "PORT", "HOST"];
    private readonly Dictionary<string, string?> _saved = [];

    public virtual ValueTask InitializeAsync()
    {
        foreach (string name in Names)
        {
            _saved[name] = Environment.GetEnvironmentVariable(name);
            Environment.SetEnvironmentVariable(name, null);
        }
        return ValueTask.CompletedTask;
    }

    public virtual async ValueTask DisposeAsync()
    {
        foreach (var (name, value) in _saved)
        {
            Environment.SetEnvironmentVariable(name, value);
        }
        await Databases.CleanupAsync();
    }
}

/// <summary>The standalone server's own behaviour, as packages/php/tests/Server/StandaloneTest.php checks the PHP one's.</summary>
public sealed class StandaloneTests : ServerTestCase
{
    private const string Origin = "https://stats.example.com";
    private const string Code = "one-time-code";

    private long _now = 1_791_374_400_000; // 2026-10-07 12:00 UTC

    private Standalone Make(SqlStore store, string? setupCode = Code, string? token = null, string? url = null, string? setupWhere = null) => new(new StandaloneOptions
    {
        Store = store,
        Secret = new string('s', 64),
        Now = () => _now,
        SetupCode = setupCode,
        Token = token,
        Url = url,
        SetupWhere = setupWhere,
    });

    private static Request Req(string path, string method = "GET", Dictionary<string, string>? headers = null, string body = "", string? host = null) =>
        new((host != null ? "https://" + host : Origin) + path, method, new Headers(headers ?? []), body);

    private static Request Form(string path, Dictionary<string, string> fields, Dictionary<string, string>? headers = null)
    {
        var all = new Dictionary<string, string>(headers ?? []) { ["content-type"] = "application/x-www-form-urlencoded" };
        return Req(path, "POST", all, new SearchParams(fields).ToString());
    }

    private static string CookieOf(Response response) => (response.Headers.Get("set-cookie") ?? "").Split(';')[0];

    private static readonly Dictionary<string, string> Auth = new() { ["authorization"] = "Bearer script-token", ["content-type"] = "application/json" };

    private static string J(object? body) => Json.Stringify(body);

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task A_new_server_is_locked_until_the_setup_code_makes_the_first_account(string kind)
    {
        var server = Make(await Databases.FreshAsync(kind), setupWhere: "in setup.txt");
        Assert.Equal(403, (await server.HandleAsync(Req("/"))).Status);
        Assert.Contains("Open the setup link in setup.txt", (await server.HandleAsync(Req("/"))).Text(), StringComparison.Ordinal);
        Assert.Equal(403, (await server.HandleAsync(Req("/setup?code=wrong"))).Status);
        Assert.Equal(403, (await server.HandleAsync(Form("/setup", new() { ["code"] = "wrong", ["email"] = "a@b.co", ["password"] = "long enough pw" }))).Status);
        Assert.Equal(200, (await server.HandleAsync(Req("/setup?code=" + Code))).Status);
        var mismatch = await server.HandleAsync(Form("/setup", new() { ["code"] = Code, ["email"] = "a@b.co", ["password"] = "a long password", ["again"] = "a long pasword" }));
        Assert.Equal(400, mismatch.Status); // the password is asked twice
        var made = await server.HandleAsync(Form("/setup", new() { ["code"] = Code, ["email"] = "Jon@Example.com", ["password"] = "a long password", ["again"] = "a long password" }));
        Assert.Equal(303, made.Status);
        Assert.Equal("/", made.Headers.Get("location"));
        Assert.Equal(200, (await server.HandleAsync(Req("/", "GET", new() { ["cookie"] = CookieOf(made) }))).Status); // signed straight in
        Assert.Equal("/login", (await server.HandleAsync(Req("/setup?code=" + Code))).Headers.Get("location")); // setup closes once an account exists
    }

    [Fact]
    public async Task With_no_code_the_first_account_is_made_with_the_token()
    {
        var server = Make(await Databases.FreshAsync("sqlite"), setupCode: null, token: "script-token");
        Assert.Equal("/setup", (await server.HandleAsync(Req("/"))).Headers.Get("location"));
        Assert.Equal(403, (await server.HandleAsync(Form("/setup", new() { ["code"] = "wrong", ["email"] = "a@b.co", ["password"] = "a long password", ["again"] = "a long password" }))).Status);
        var made = await server.HandleAsync(Form("/setup", new() { ["code"] = "script-token", ["email"] = "a@b.co", ["password"] = "a long password", ["again"] = "a long password" }));
        Assert.Equal(303, made.Status);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Sign_in_sign_out_and_sessions_that_end_with_a_password_change(string kind)
    {
        var server = Make(await Databases.FreshAsync(kind));
        await server.Accounts.SetPasswordAsync("jon@example.com", "a long password", _now);
        var away = await server.HandleAsync(Req("/?period=7d"));
        Assert.Equal(303, away.Status);
        Assert.Equal("/login?next=" + Uri.EscapeDataString("/?period=7d"), away.Headers.Get("location"));
        Assert.Equal(401, (await server.HandleAsync(Req("/api/sites"))).Status);
        Assert.Equal(401, (await server.HandleAsync(Form("/login", new() { ["email"] = "jon@example.com", ["password"] = "nope nope nope" }))).Status);

        var ok = await server.HandleAsync(Form("/login", new() { ["email"] = "JON@example.com", ["password"] = "a long password", ["next"] = "//evil.example" }));
        Assert.Equal(303, ok.Status);
        Assert.Equal("/", ok.Headers.Get("location")); // a next address off this server is ignored
        string cookie = CookieOf(ok);
        Assert.Equal(200, (await server.HandleAsync(Req("/api/sites", "GET", new() { ["cookie"] = cookie }))).Status);
        Assert.Contains("data-sign-out=\"/logout\"", (await server.HandleAsync(Req("/", "GET", new() { ["cookie"] = cookie }))).Text(), StringComparison.Ordinal);
        Assert.Contains("Max-Age=0", (await server.HandleAsync(Req("/logout"))).Headers.Get("set-cookie") ?? "", StringComparison.Ordinal);

        await server.Accounts.SetPasswordAsync("jon@example.com", "another long password", _now);
        Assert.Equal(401, (await server.HandleAsync(Req("/api/sites", "GET", new() { ["cookie"] = cookie }))).Status); // a new password signs out every browser
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Sites_are_added_counted_and_short_links_answer_on_their_own_domains(string kind)
    {
        var server = Make(await Databases.FreshAsync(kind), token: "script-token");
        await server.Accounts.SetPasswordAsync("jon@example.com", "a long password", _now);

        Assert.Equal(201, (await server.HandleAsync(Req("/api/sites", "POST", Auth, J(new JsObject { ["name"] = "Blog", ["hostnames"] = "blog.example.com" })))).Status);
        Assert.Equal(200, (await server.HandleAsync(Req("/s.js"))).Status);
        var hit = await server.HandleAsync(Req("/e", "POST", new() { ["user-agent"] = "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", ["x-forwarded-for"] = "203.0.113.9", ["content-type"] = "text/plain;charset=UTF-8" }, J(new JsObject { ["k"] = "pageview", ["u"] = "https://blog.example.com/post", ["s"] = "blog.example.com" })));
        Assert.Equal(202, hit.Status);
        var stats = (JsObject)Json.Parse((await server.HandleAsync(Req("/api/stats?site=blog.example.com&period=today", "GET", Auth))).Text())!;
        Assert.Equal(1.0, stats.Obj("stats")!.Num("pageviews"));

        Assert.Equal(201, (await server.HandleAsync(Req("/api/link-domains?site=blog.example.com", "POST", Auth, J(new JsObject { ["domain"] = "go.example.com" })))).Status);
        var made = (JsObject)Json.Parse((await server.HandleAsync(Req("/api/links?site=blog.example.com", "POST", Auth, J(new JsObject { ["url"] = "https://blog.example.com/launch", ["slug"] = "launch", ["domain"] = "go.example.com" })))).Text())!;
        Assert.Equal("launch", made.Obj("link")!.Str("slug"));
        var shortLink = await server.HandleAsync(Req("/launch", host: "go.example.com"));
        Assert.Equal(302, shortLink.Status);
        Assert.Equal("https://blog.example.com/launch", shortLink.Headers.Get("location"));
        Assert.Equal(302, (await server.HandleAsync(Req("/go/launch"))).Status); // every link also answers at /go/:slug on the server itself

        var health = await server.HandleAsync(Req("/healthz"));
        Assert.Equal((200, "ok"), (health.Status, health.Text()));
        Assert.Equal(401, (await server.HandleAsync(Req("/api/sites", "GET", new() { ["authorization"] = "Bearer wrong" }))).Status);
    }

    [Fact]
    public async Task A_link_domain_never_takes_over_the_dashboards_own_name_sign_in_or_api()
    {
        var server = Make(await Databases.FreshAsync("sqlite"), token: "script-token");
        await server.Accounts.SetPasswordAsync("jon@example.com", "a long password", _now);
        await server.HandleAsync(Req("/api/sites", "POST", Auth, J(new JsObject { ["name"] = "Blog", ["hostnames"] = "blog.example.com" })));
        Task<Response> AddDomain(string domain, string host) => server.HandleAsync(Req("/api/link-domains?site=blog.example.com", "POST", Auth, J(new JsObject { ["domain"] = domain }), host));

        // Someone signs in at stats.example.com, so a caller naming another Host cannot add it afterwards.
        string cookie = CookieOf(await server.HandleAsync(Form("/login", new() { ["email"] = "jon@example.com", ["password"] = "a long password" })));
        Assert.Equal(200, (await server.HandleAsync(Req("/api/sites", "GET", new() { ["cookie"] = cookie }))).Status);
        foreach (string host in new[] { "decoy.example.org", "203.0.113.5", "stats.example.com." })
        {
            Assert.Equal(400, (await AddDomain("stats.example.com", host)).Status);
        }

        // Added anyway: its short links answer, and the server's own pages stay the server's.
        await server.Runlight.Store.AddLinkDomainAsync("stats.example.com", "blog.example.com", _now);
        server.Runlight.ForgetLinkDomains();
        await server.HandleAsync(Req("/api/links?site=blog.example.com", "POST", Auth, J(new JsObject { ["url"] = "https://blog.example.com/a", ["slug"] = "login", ["domain"] = "stats.example.com" })));
        await server.HandleAsync(Req("/api/links?site=blog.example.com", "POST", Auth, J(new JsObject { ["url"] = "https://blog.example.com/b", ["slug"] = "sale", ["domain"] = "stats.example.com" })));
        Assert.Equal(302, (await server.HandleAsync(Req("/sale"))).Status);
        Assert.Equal(200, (await server.HandleAsync(Req("/login"))).Status); // sign-in is still the sign-in page
        Assert.Equal(200, (await server.HandleAsync(Req("/", "GET", new() { ["cookie"] = cookie }))).Status); // the dashboard opens for someone signed in
        Assert.Equal(404, (await server.HandleAsync(Req("/"))).Status);
        Assert.Equal(200, (await server.HandleAsync(Req("/api/link-domains/stats.example.com?site=blog.example.com", "DELETE", new() { ["cookie"] = cookie }))).Status); // so it can be removed
        Assert.Equal(404, (await server.HandleAsync(Req("/sale"))).Status);

        // With the public address set, short links never answer there, and nobody can add it under any Host.
        var named = Make(await Databases.FreshAsync("sqlite"), token: "script-token", url: Origin);
        await named.HandleAsync(Req("/api/sites", "POST", Auth, J(new JsObject { ["name"] = "Blog", ["hostnames"] = "blog.example.com" })));
        Assert.Equal(400, (await named.HandleAsync(Req("/api/link-domains?site=blog.example.com", "POST", Auth, J(new JsObject { ["domain"] = "stats.example.com" }), "decoy.example.org"))).Status);
        await named.Runlight.Store.AddLinkDomainAsync("stats.example.com", "blog.example.com", _now);
        named.Runlight.ForgetLinkDomains();
        await named.HandleAsync(Req("/api/links?site=blog.example.com", "POST", Auth, J(new JsObject { ["url"] = "https://blog.example.com/b", ["slug"] = "sale", ["domain"] = "stats.example.com" })));
        Assert.Equal(404, (await named.HandleAsync(Req("/sale"))).Status);
        Assert.Equal(403, (await named.HandleAsync(Req("/"))).Status); // the dashboard, waiting for setup
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Only_the_owner_and_admins_teach_the_server_its_names(string kind)
    {
        var store = await Databases.FreshAsync(kind);
        var server = Make(store);
        var owner = await server.Accounts.SetPasswordAsync("jon@example.com", "a long password", _now);
        var viewer = await server.Accounts.SetPasswordAsync("viewer@example.com", "another long one", _now, "viewer");
        string As(JsObject user) => "runlight_session=" + Uri.EscapeDataString(server.Accounts.SessionFor(user, _now));
        async Task<List<object?>> Names() => (List<object?>)Json.Parse(await server.Runlight.Store.SettingAsync("server-hosts") ?? "[]")!;
        for (int i = 0; i < 25; i++)
        {
            await server.HandleAsync(Req("/api/sites", "GET", new() { ["cookie"] = As(viewer), ["x-forwarded-host"] = "junk" + i + ".example.org" }));
        }
        Assert.Empty(await Names()); // a viewer's made-up forwarded names fill nothing
        await server.HandleAsync(Req("/api/sites", "GET", new() { ["cookie"] = As(owner), ["x-forwarded-host"] = "203.0.113.7:8080" }));
        await server.HandleAsync(Req("/api/sites", "GET", new() { ["cookie"] = As(owner) }));
        Assert.Equal(["stats.example.com"], (await Names()).Cast<string>()); // an owner's are learned, if they are domain names

        // Another process sharing the database reads them back from it.
        var again = new Standalone(new StandaloneOptions { Store = store, Secret = new string('s', 64), Now = () => _now });
        var json = new Dictionary<string, string> { ["cookie"] = As(owner), ["content-type"] = "application/json" };
        await again.HandleAsync(Req("/api/sites", "POST", json, J(new JsObject { ["name"] = "Blog", ["hostnames"] = "blog.example.com" })));
        Assert.Equal(400, (await again.HandleAsync(Req("/api/link-domains?site=blog.example.com", "POST", json, J(new JsObject { ["domain"] = "stats.example.com" }), "decoy.example.org"))).Status);
    }

    [Fact]
    public async Task Check_runs_the_scheduled_work()
    {
        var result = await Make(await Databases.FreshAsync("sqlite")).CheckAsync();
        Assert.Equal("{\"ok\":true,\"reports\":{\"sent\":0,\"failed\":0}}", Json.Stringify(result));
    }
}
