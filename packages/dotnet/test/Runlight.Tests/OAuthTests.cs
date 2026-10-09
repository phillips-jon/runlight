using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Xunit;

namespace Runlight.Tests;

/// <summary>
/// oauth.test.ts, ported onto OAuth.OAuthResponseAsync with a stand-in for the Runlight and its routes: sites a and
/// b, an owner who sends "Bearer secret", and a reader who sends the cookie "viewer". The MCP call and the token
/// list through the API wait for the routes; the store is read in their place.
/// </summary>
public sealed class OAuthTests : IAsyncLifetime
{
    private long _now = DateTimeOffset.Parse("2026-10-07T12:00:00Z", System.Globalization.CultureInfo.InvariantCulture).ToUnixTimeMilliseconds();

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    private static readonly Dictionary<string, string> Owner = new() { ["authorization"] = "Bearer secret" };

    private async Task<OAuthContext> ContextAsync(string[]? siteIds = null, string? signIn = null, bool readers = false)
    {
        var store = await Databases.FreshAsync("sqlite");
        await store.MigrateAsync();
        var sites = (siteIds ?? ["a", "b"]).Select(id => new JsObject { ["id"] = id, ["name"] = "Site " + id.ToUpperInvariant() }).ToList();
        return new OAuthContext
        {
            Store = store,
            Base = "/runlight",
            Now = () => _now,
            Init = _ => Task.CompletedTask,
            ClientIp = (_, ip) => ip ?? "",
            Sites = _ => Task.FromResult(sites),
            Site = (id, _) => Task.FromResult(sites.FirstOrDefault(s => s.Str("id") == id)),
            IsRemote = (_, _) => Task.FromResult(false),
            IsOwner = (r, _) => Task.FromResult(r.Headers.Get("authorization") == "Bearer secret"),
            SignIn = signIn,
            IsReader = readers ? (r, _) => Task.FromResult(r.Headers.Get("cookie") == "viewer") : null,
        };
    }

    private static string B64url(byte[] bytes) => Crypto.Base64url(bytes);

    private static Request At(string url, string method = "GET", Dictionary<string, string>? headers = null, string? body = null)
    {
        var h = new Headers(headers ?? []);
        if (body != null && !h.Has("content-type"))
        {
            h.Set("content-type", "text/plain;charset=UTF-8");
        }
        return new Request(url, method, h, body ?? "");
    }

    private static Dictionary<string, string> With(Dictionary<string, string> a, Dictionary<string, string> b)
    {
        var o = new Dictionary<string, string>(a);
        foreach (var e in b)
        {
            o[e.Key] = e.Value;
        }
        return o;
    }

    private static readonly Dictionary<string, string> FormType = new() { ["content-type"] = "application/x-www-form-urlencoded" };

    private static string Form(params (string Key, string Value)[] fields) =>
        new SearchParams(fields.Select(f => new KeyValuePair<string, string>(f.Key, f.Value))).ToString();

    private static async Task<Response> H(OAuthContext ctx, Request request, string ip = "")
    {
        var url = new Url(request.Url);
        string path = url.Pathname.StartsWith("/runlight/", StringComparison.Ordinal) ? url.Pathname["/runlight".Length..] : url.Pathname;
        return (await OAuth.OAuthResponseAsync(ctx, request, path, url, ip))!;
    }

    private static JsObject Body(Response r) => (JsObject)Json.Parse(r.Text())!;

    private static string Register(string name, string redirect) =>
        Json.Stringify(new JsObject { ["client_name"] = name, ["redirect_uris"] = new List<object?> { redirect } });

    private static readonly Dictionary<string, string> JsonType = new() { ["content-type"] = "application/json" };

    [Fact]
    public async Task An_app_connects_over_oauth()
    {
        var ctx = await ContextAsync();
        const string origin = "https://x.com";
        var resource = Body(await H(ctx, At(OAuth.ResourceMetadataUrl(origin, "/runlight"))));
        Assert.Equal("[\"https://x.com/runlight\"]", Json.Stringify(resource.Get("authorization_servers")));
        Assert.Equal(origin + "/runlight/mcp", resource.Str("resource"));
        var server = Body(await H(ctx, At(origin + "/runlight/.well-known/oauth-authorization-server")));
        Assert.Equal(origin + "/runlight/oauth/token", server.Str("token_endpoint"));
        Assert.Equal("[\"S256\"]", Json.Stringify(server.Get("code_challenge_methods_supported")));
        var options = await H(ctx, At(origin + "/runlight/oauth/token", "OPTIONS"));
        Assert.Equal(204, options.Status);
        Assert.Equal("*", options.Headers.Get("access-control-allow-origin"));

        // Registration.
        Assert.Equal(400, (await H(ctx, At(origin + "/runlight/oauth/register", "POST", JsonType, Json.Stringify(new JsObject { ["redirect_uris"] = new List<object?> { "http://evil.example/cb" } })))).Status);
        var registered = await H(ctx, At(origin + "/runlight/oauth/register", "POST", JsonType, Register("Claude", "https://claude.ai/api/mcp/auth_callback")));
        Assert.Equal(201, registered.Status);
        string clientId = Body(registered).Str("client_id")!;

        // Consent: signed out it says so; signed in it asks; allowing sends a code back.
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        string challenge = OAuth.S256(verifier);
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/api/mcp/auth_callback"), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", "xyz"));
        Assert.Equal(401, (await H(ctx, At(origin + "/runlight/oauth/authorize?" + parameters))).Status);
        var wrongRedirect = new SearchParams(parameters);
        wrongRedirect.Set("redirect_uri", "https://evil.example/cb");
        Assert.Equal(400, (await H(ctx, At(origin + "/runlight/oauth/authorize?" + wrongRedirect, "GET", Owner))).Status);
        var consent = await H(ctx, At(origin + "/runlight/oauth/authorize?" + parameters, "GET", Owner));
        Assert.Equal(200, consent.Status);
        string page = consent.Text();
        Assert.Contains("Claude</strong> wants to read your Runlight stats", page);
        Assert.Contains("sends you back to <strong>claude.ai</strong>", page);
        Assert.Contains("<option value=\"b\">Site B only</option>", page);
        var deny = await H(ctx, At(origin + "/runlight/oauth/authorize", "POST", With(Owner, FormType), parameters + "&decision=deny"));
        Assert.Contains("error=access_denied&state=xyz", deny.Headers.Get("location"), StringComparison.Ordinal);
        var forged = await H(ctx, At(origin + "/runlight/oauth/authorize", "POST", With(With(Owner, FormType), new() { ["origin"] = "https://evil.example" }), parameters + "&decision=allow"));
        Assert.Equal(403, forged.Status);
        var allow = await H(ctx, At(origin + "/runlight/oauth/authorize", "POST", With(With(Owner, FormType), new() { ["origin"] = origin }), parameters + "&decision=allow&site=b"));
        var back = new Url(allow.Headers.Get("location")!);
        Assert.Equal("https://claude.ai/api/mcp/auth_callback", back.Origin + back.Pathname);
        Assert.Equal("xyz", back.SearchParams.Get("state"));
        string code = back.SearchParams.Get("code")!;

        // The token: PKCE checked, the code good once.
        Task<Response> Exchange(string c, string used) => H(ctx, At(origin + "/runlight/oauth/token", "POST", FormType, Form(("grant_type", "authorization_code"), ("code", c), ("client_id", clientId), ("redirect_uri", "https://claude.ai/api/mcp/auth_callback"), ("code_verifier", used))));
        Assert.Equal("invalid_grant", Body(await Exchange(code, "wrong-verifier")).Str("error"));
        Assert.Equal("invalid_grant", Body(await Exchange(code, verifier)).Str("error"));

        // Again, properly this time.
        var second = await H(ctx, At(origin + "/runlight/oauth/authorize", "POST", With(With(Owner, FormType), new() { ["origin"] = origin }), parameters + "&decision=allow&site=b"));
        string code2 = new Url(second.Headers.Get("location")!).SearchParams.Get("code")!;
        var issued = Body(await Exchange(code2, verifier));
        Assert.Equal("Bearer", issued.Str("token_type"));
        Assert.Equal("read", issued.Str("scope"));
        Assert.Equal("b", issued.Str("site"));
        var tokens = await ctx.Store.TokensAsync();
        Assert.Equal(["Claude (OAuth) b"], tokens.Select(t => t.Str("name") + " " + t.Str("site")));
        Assert.Equal(Hash.Sha256(issued.Str("access_token")!), tokens[0].Str("hash"));
    }

    [Fact]
    public async Task Registering_stores_nothing_so_a_flood_of_registrations_never_keeps_a_real_app_out()
    {
        var ctx = await ContextAsync(["a"]);
        Task<Response> RegisterAs(string name, string ip = "", string redirect = "https://app.example/cb") =>
            H(ctx, At("https://x.com/runlight/oauth/register", "POST", JsonType, Register(name, redirect)), ip);
        for (int i = 0; i < 500; i++)
        {
            Assert.Equal(201, (await RegisterAs("flood " + i)).Status);
        }
        Assert.Empty(await ctx.Store.SettingsStartingWithAsync("oauth-client:"));
        Assert.Empty(await ctx.Store.SettingsStartingWithAsync("oauth-used:"));

        // A real app still registers, and its id names it and its address, signed, so nobody can change them.
        var claude = await RegisterAs("Claude", "", "https://claude.ai/cb");
        Assert.Equal(201, claude.Status);
        string clientId = Body(claude).Str("client_id")!;
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        var fields = new List<(string Key, string Value)> { ("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_challenge", OAuth.S256(verifier)), ("code_challenge_method", "S256") };
        string parameters = Form([.. fields]);
        Assert.Contains("Claude</strong> wants to read", (await H(ctx, At("https://x.com/runlight/oauth/authorize?" + parameters, "GET", Owner))).Text());
        string[] parts = clientId.Split('.');
        string forged = B64url(Js.Utf8(Json.Stringify(new JsObject { ["n"] = "Claude", ["r"] = new List<object?> { "https://evil.example/cb" }, ["t"] = _now }))) + "." + parts[1];
        Assert.NotEqual(parts[0], forged.Split('.')[0]);
        var forgedFields = new List<(string Key, string Value)> { ("client_id", forged), ("redirect_uri", "https://evil.example/cb"), ("response_type", "code"), ("code_challenge", OAuth.S256(verifier)), ("code_challenge_method", "S256") };
        Assert.Equal(400, (await H(ctx, At("https://x.com/runlight/oauth/authorize?" + Form([.. forgedFields]), "GET", Owner))).Status);

        // Allowed and swapped for a token, the app gets its first row.
        var allow = await H(ctx, At("https://x.com/runlight/oauth/authorize", "POST", With(With(Owner, FormType), new() { ["origin"] = "https://x.com" }), parameters + "&decision=allow"));
        string code = new Url(allow.Headers.Get("location")!).SearchParams.Get("code")!;
        var issued = await H(ctx, At("https://x.com/runlight/oauth/token", "POST", FormType, Form(("grant_type", "authorization_code"), ("code", code), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_verifier", verifier))));
        Assert.Equal(200, issued.Status);
        Assert.Single(await ctx.Store.SettingsStartingWithAsync("oauth-used:"));

        // An app stored before ids were signed still works, and one that never connected goes after a day.
        await ctx.Store.SetSettingAsync("oauth-client:" + new string('a', 32), Json.Stringify(new JsObject { ["name"] = "Old", ["redirects"] = new List<object?> { "https://old.example/cb" }, ["createdAt"] = _now }));
        var oldFields = new List<(string Key, string Value)> { ("client_id", new string('a', 32)), ("redirect_uri", "https://old.example/cb"), ("response_type", "code"), ("code_challenge", OAuth.S256(verifier)), ("code_challenge_method", "S256") };
        Assert.Equal(200, (await H(ctx, At("https://x.com/runlight/oauth/authorize?" + Form([.. oldFields]), "GET", Owner))).Status);
        _now += 86_400_000;
        await RegisterAs("Another");
        Assert.Empty(await ctx.Store.SettingsStartingWithAsync("oauth-client:"));

        // One address registers at most ten a minute.
        for (int i = 0; i < 10; i++)
        {
            Assert.Equal(201, (await RegisterAs("app " + i, "203.0.113.9")).Status);
        }
        Assert.Equal(429, (await RegisterAs("one more", "203.0.113.9")).Status);
        Assert.Equal(201, (await RegisterAs("one more", "203.0.113.10")).Status);
    }

    [Fact]
    public async Task Before_an_owner_has_allowed_an_app_once_a_request_it_got_wrong_ends_on_a_page()
    {
        var ctx = await ContextAsync(["a"], signIn: "/login");
        string clientId = Body(await H(ctx, At("https://x.com/runlight/oauth/register", "POST", JsonType, Register("x", "https://evil.example/landing")))).Str("client_id")!;
        foreach (var asked in new[] { new[] { ("response_type", "token") }, new[] { ("response_type", "code"), ("code_challenge_method", "plain"), ("code_challenge", new string('a', 43)) } })
        {
            var fields = new List<(string Key, string Value)> { ("client_id", clientId), ("redirect_uri", "https://evil.example/landing"), ("state", "x") };
            fields.AddRange(asked);
            var answer = await H(ctx, At("https://x.com/runlight/oauth/authorize?" + Form([.. fields])));
            Assert.Equal(400, answer.Status);
            Assert.Null(answer.Headers.Get("location"));
        }
    }

    [Fact]
    public async Task A_signed_in_viewer_is_told_only_an_owner_can_connect_never_sent_to_sign_in_again()
    {
        var ctx = await ContextAsync(["a"], signIn: "/login", readers: true);
        string clientId = Body(await H(ctx, At("https://x.com/runlight/oauth/register", "POST", JsonType, Register("Claude", "https://claude.ai/cb")))).Str("client_id")!;
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_challenge", new string('a', 43)), ("code_challenge_method", "S256"));
        var signedOut = await H(ctx, At("https://x.com/runlight/oauth/authorize?" + parameters));
        Assert.Equal(303, signedOut.Status);
        Assert.StartsWith("/login?next=%2Frunlight%2Foauth%2Fauthorize%3Fresponse_type%3Dcode", signedOut.Headers.Get("location"), StringComparison.Ordinal);
        var viewer = await H(ctx, At("https://x.com/runlight/oauth/authorize?" + parameters, "GET", new() { ["cookie"] = "viewer" }));
        Assert.Equal(403, viewer.Status);
        Assert.Contains("only an owner of this Runlight can connect Claude", viewer.Text());
    }

    [Fact]
    public async Task A_manage_grant_names_one_site_and_records_the_hubs_origin()
    {
        var ctx = await ContextAsync();
        string clientId = Body(await H(ctx, At("https://x.com/runlight/oauth/register", "POST", JsonType, Register("Hub", "https://hub.example.net/cb")))).Str("client_id")!;
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://hub.example.net/cb"), ("code_challenge", OAuth.S256(verifier)), ("code_challenge_method", "S256"), ("scope", "read manage"), ("site", "b"));
        string page = (await H(ctx, At("https://x.com/runlight/oauth/authorize?" + parameters, "GET", Owner))).Text();
        Assert.Contains("<option value=\"b\" selected>Site B</option>", page);
        Assert.DoesNotContain("Every site", page);
        Assert.Contains("this site" + (char)0x2019 + "s stats", page);
        var form = With(With(Owner, FormType), new() { ["origin"] = "https://x.com" });
        var noSite = await H(ctx, At("https://x.com/runlight/oauth/authorize", "POST", form, parameters.Replace("site=b", "site=", StringComparison.Ordinal) + "&decision=allow"));
        Assert.Equal("https://hub.example.net/cb?error=invalid_request&error_description=Pick+the+site+to+manage", noSite.Headers.Get("location"));
        var allow = await H(ctx, At("https://x.com/runlight/oauth/authorize", "POST", form, parameters.Replace("site=b", "site=a", StringComparison.Ordinal) + "&decision=allow"));
        string code = new Url(allow.Headers.Get("location")!).SearchParams.Get("code")!;
        var issued = Body(await H(ctx, At("https://x.com/runlight/oauth/token", "POST", JsonType, Json.Stringify(new JsObject { ["grant_type"] = "authorization_code", ["code"] = code, ["client_id"] = clientId, ["redirect_uri"] = "https://hub.example.net/cb", ["code_verifier"] = verifier }))));
        Assert.Equal("manage a", issued.Str("scope") + " " + issued.Str("site"));
        var tokens = await ctx.Store.TokensAsync();
        Assert.Equal("https://hub.example.net", await ctx.Store.SettingAsync("token-origin:" + tokens[0].Str("id")));
    }

    [Fact]
    public async Task Someone_who_can_no_longer_make_tokens_gets_none()
    {
        var ctx = await ContextAsync();
        var made = new List<string>();
        var withAccounts = new OAuthContext
        {
            Store = ctx.Store,
            Base = ctx.Base,
            Now = ctx.Now,
            Init = ctx.Init,
            ClientIp = ctx.ClientIp,
            Sites = ctx.Sites,
            Site = ctx.Site,
            IsRemote = ctx.IsRemote,
            IsOwner = ctx.IsOwner,
            AccountOf = (_, _) => Task.FromResult<string?>("u1"),
            TokenMade = (token, by, _) =>
            {
                made.Add(by);
                return Task.FromResult(false);
            },
        };
        string clientId = Body(await H(withAccounts, At("https://x.com/runlight/oauth/register", "POST", JsonType, Register("Claude", "https://claude.ai/cb")))).Str("client_id")!;
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_challenge", OAuth.S256(verifier)), ("code_challenge_method", "S256"));
        var allow = await H(withAccounts, At("https://x.com/runlight/oauth/authorize", "POST", With(Owner, FormType), parameters + "&decision=allow"));
        string code = new Url(allow.Headers.Get("location")!).SearchParams.Get("code")!;
        var refused = Body(await H(withAccounts, At("https://x.com/runlight/oauth/token", "POST", FormType, Form(("grant_type", "authorization_code"), ("code", code), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_verifier", verifier)))));
        Assert.Equal("Whoever allowed this app can no longer connect it", refused.Str("error_description"));
        Assert.Equal(["u1"], made);
        Assert.Empty(await ctx.Store.TokensAsync());
    }
}
