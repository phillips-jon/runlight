using System;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Routes.Make;

namespace Runlight.Tests.Routes;

/// <summary>oauth.test.ts, ported through the routes as the PHP's tests/Routes/OAuthTest.php, the MCP call and the token list included.</summary>
public sealed class OAuthRoutesTests : RoutesTestCase
{
    private static string B64url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static string Form(params (string Name, string Value)[] fields)
    {
        var parameters = new SearchParams();
        foreach (var (name, value) in fields)
        {
            parameters.Append(name, value);
        }
        return parameters.ToString();
    }

    private static Headers With(Headers a, params (string Name, string Value)[] more)
    {
        var headers = new Headers(a);
        foreach (var (name, value) in more)
        {
            headers.Set(name, value);
        }
        return headers;
    }

    [Fact]
    public async Task An_app_connects_to_the_mcp_server_over_oauth()
    {
        var rl = await RunlightAsync(sites: [Site("a", "Site A", ["a.com"]), Site("b", "Site B", ["b.com"])]);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        const string origin = "https://x.com";
        var owner = H(("authorization", "Bearer secret"));
        var form = H(("content-type", "application/x-www-form-urlencoded"));

        // The MCP endpoint points at the metadata.
        var refused = await routes.HandleAsync(At(origin + "/runlight/mcp", "POST", H(("content-type", "application/json")), "{}"));
        Assert.Equal(401, refused.Status);
        var m = System.Text.RegularExpressions.Regex.Match(refused.Headers.Get("www-authenticate") ?? "", "resource_metadata=\"([^\"]+)\"");
        Assert.Equal(origin + "/runlight/.well-known/oauth-protected-resource", m.Groups[1].Value);
        var resource = Obj(await routes.HandleAsync(At(m.Groups[1].Value)));
        Assert.Equal("[\"" + origin + "/runlight\"]", Json.Stringify(resource.Get("authorization_servers")));
        Assert.Equal(origin + "/runlight/mcp", resource.Str("resource"));
        var server = Obj(await routes.HandleAsync(At(origin + "/.well-known/oauth-authorization-server/runlight")));
        Assert.Equal(origin + "/runlight/oauth/token", server.Str("token_endpoint"));
        Assert.Equal("[\"S256\"]", Json.Stringify(server.Get("code_challenge_methods_supported")));

        // Registration.
        Assert.Equal(400, (await routes.HandleAsync(At(origin + "/runlight/oauth/register", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["redirect_uris"] = L("http://evil.example/cb") })))).Status);
        var registered = await routes.HandleAsync(At(origin + "/runlight/oauth/register", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["client_name"] = "Claude", ["redirect_uris"] = L("https://claude.ai/api/mcp/auth_callback") })));
        Assert.Equal(201, registered.Status);
        string clientId = Obj(registered).Str("client_id")!;

        // Consent: signed out it says so; signed in it asks; allowing sends a code back.
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        string challenge = B64url(SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(verifier)));
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/api/mcp/auth_callback"), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", "xyz"));
        Assert.Equal(401, (await routes.HandleAsync(At(origin + "/runlight/oauth/authorize?" + parameters))).Status);
        var wrongRedirect = new SearchParams(parameters);
        wrongRedirect.Set("redirect_uri", "https://evil.example/cb");
        Assert.Equal(400, (await routes.HandleAsync(At(origin + "/runlight/oauth/authorize?" + wrongRedirect, "GET", owner))).Status); // never sends a code to an address the app did not register
        var consent = await routes.HandleAsync(At(origin + "/runlight/oauth/authorize?" + parameters, "GET", owner));
        Assert.Equal(200, consent.Status);
        string page = consent.Text();
        Assert.Matches("Claude</strong> wants to read your Runlight stats", page);
        Assert.Matches("sends you back to <strong>claude\\.ai</strong>", page); // the page shows where the answer goes
        var deny = await routes.HandleAsync(At(origin + "/runlight/oauth/authorize", "POST", With(owner, ("content-type", "application/x-www-form-urlencoded")), parameters + "&decision=deny"));
        Assert.Matches("error=access_denied&state=xyz", deny.Headers.Get("location") ?? "");
        var forged = await routes.HandleAsync(At(origin + "/runlight/oauth/authorize", "POST", With(owner, ("origin", "https://evil.example"), ("content-type", "application/x-www-form-urlencoded")), parameters + "&decision=allow"));
        Assert.Equal(403, forged.Status);
        var allowHeaders = With(owner, ("origin", origin), ("content-type", "application/x-www-form-urlencoded"));
        var allow = await routes.HandleAsync(At(origin + "/runlight/oauth/authorize", "POST", allowHeaders, parameters + "&decision=allow&site=b"));
        var back = new Url(allow.Headers.Get("location") ?? "");
        Assert.Equal("https://claude.ai/api/mcp/auth_callback", back.Origin + back.Pathname);
        Assert.Equal("xyz", back.SearchParams.Get("state"));
        string code = back.SearchParams.Get("code")!;

        // The token: PKCE checked, the code good once.
        Task<Response> Exchange(string code, string used) => routes.HandleAsync(At(origin + "/runlight/oauth/token", "POST", form, Form(("grant_type", "authorization_code"), ("code", code), ("client_id", clientId), ("redirect_uri", "https://claude.ai/api/mcp/auth_callback"), ("code_verifier", used))));
        Assert.Equal("invalid_grant", Obj(await Exchange(code, "wrong-verifier")).Str("error"));
        Assert.Equal("invalid_grant", Obj(await Exchange(code, verifier)).Str("error")); // a code that failed once is spent

        // Again, properly this time.
        var second = await routes.HandleAsync(At(origin + "/runlight/oauth/authorize", "POST", allowHeaders, parameters + "&decision=allow&site=b"));
        string code2 = new Url(second.Headers.Get("location") ?? "").SearchParams.Get("code")!;
        var issued = Obj(await Exchange(code2, verifier));
        Assert.Equal("Bearer", issued.Str("token_type"));
        Assert.Equal("read", issued.Str("scope"));
        Assert.Equal("b", issued.Str("site"));

        var call = await routes.HandleAsync(At(origin + "/runlight/mcp", "POST", H(("authorization", "Bearer " + issued.Str("access_token")), ("content-type", "application/json")), Json.Stringify(new JsObject { ["jsonrpc"] = "2.0", ["id"] = 1L, ["method"] = "tools/call", ["params"] = new JsObject { ["name"] = "list_sites", ["arguments"] = new JsObject() } })));
        string text = ((JsObject)Obj(call).Obj("result")!.Arr("content")![0]!).Str("text")!;
        Assert.Equal("[\"b\"]", Json.Stringify(Column(((JsObject)Json.Parse(text)!).Get("sites"), "id"))); // the token reads only the site chosen at consent
        var tokens = Obj(await routes.HandleAsync(At(origin + "/runlight/api/tokens", "GET", owner)));
        Assert.Equal("[[\"Claude (OAuth)\",\"b\"]]", Json.Stringify(tokens.Arr("tokens")!.Cast<JsObject>().Select(t => (object?)L(t.Get("name"), t.Get("site"))).ToList()));
    }

    [Fact]
    public async Task Registering_stores_nothing_so_a_flood_of_registrations_never_keeps_a_real_app_out()
    {
        long now = Utc(2026, 10, 7, 12);
        var rl = await RunlightAsync(sites: [Site("a", "Site A", ["a.com"])], now: () => now);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        var owner = H(("authorization", "Bearer secret"));
        Task<Response> Register(string name, string ip = "", string redirect = "https://app.example/cb") =>
            routes.HandleAsync(At("https://x.com/runlight/oauth/register", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["client_name"] = name, ["redirect_uris"] = L(redirect) })), ip);
        for (int i = 0; i < 500; i++)
        {
            Assert.Equal(201, (await Register("flood " + i)).Status);
        }
        Assert.Empty(await rl.Store.SettingsStartingWithAsync("oauth-client:"));
        Assert.Empty(await rl.Store.SettingsStartingWithAsync("oauth-used:"));

        // A real app still registers, and its id names it and its address, signed, so nobody can change them.
        var claude = await Register("Claude", "", "https://claude.ai/cb");
        Assert.Equal(201, claude.Status);
        string clientId = Obj(claude).Str("client_id")!;
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        (string, string)[] fields = [("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_challenge", B64url(SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(verifier)))), ("code_challenge_method", "S256")];
        string parameters = Form(fields);
        Assert.Matches("Claude</strong> wants to read", (await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + parameters, "GET", owner))).Text());
        string[] parts = clientId.Split('.');
        string forged = B64url(System.Text.Encoding.UTF8.GetBytes(Json.Stringify(new JsObject { ["n"] = "Claude", ["r"] = L("https://evil.example/cb"), ["t"] = now }))) + "." + parts[1];
        Assert.NotEqual(parts[0], forged.Split('.')[0]);
        var forgedFields = fields.Select(f => f.Item1 == "client_id" ? ("client_id", forged) : f.Item1 == "redirect_uri" ? ("redirect_uri", "https://evil.example/cb") : f).ToArray();
        Assert.Equal(400, (await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + Form(forgedFields), "GET", owner))).Status);

        // Allowed and swapped for a token, the app gets its first row.
        var allow = await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize", "POST", With(owner, ("origin", "https://x.com"), ("content-type", "application/x-www-form-urlencoded")), parameters + "&decision=allow"));
        string code = new Url(allow.Headers.Get("location") ?? "").SearchParams.Get("code")!;
        var issued = await routes.HandleAsync(At("https://x.com/runlight/oauth/token", "POST", H(("content-type", "application/x-www-form-urlencoded")), Form(("grant_type", "authorization_code"), ("code", code), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_verifier", verifier))));
        Assert.Equal(200, issued.Status);
        Assert.Single(await rl.Store.SettingsStartingWithAsync("oauth-used:"));

        // An app stored before ids were signed still works, and one that never connected goes after a day.
        await rl.Store.SetSettingAsync("oauth-client:" + new string('a', 32), Json.Stringify(new JsObject { ["name"] = "Old", ["redirects"] = L("https://old.example/cb"), ["createdAt"] = now }));
        var oldFields = fields.Select(f => f.Item1 == "client_id" ? ("client_id", new string('a', 32)) : f.Item1 == "redirect_uri" ? ("redirect_uri", "https://old.example/cb") : f).ToArray();
        Assert.Equal(200, (await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + Form(oldFields), "GET", owner))).Status);
        now += 86_400_000;
        await Register("Another");
        Assert.Empty(await rl.Store.SettingsStartingWithAsync("oauth-client:"));

        // One address registers at most ten a minute.
        for (int i = 0; i < 10; i++)
        {
            Assert.Equal(201, (await Register("app " + i, "203.0.113.9")).Status);
        }
        Assert.Equal(429, (await Register("one more", "203.0.113.9")).Status);
        Assert.Equal(201, (await Register("one more", "203.0.113.10")).Status);
    }

    [Fact]
    public async Task Before_an_owner_has_allowed_an_app_once_a_request_it_got_wrong_ends_on_a_page()
    {
        var rl = await RunlightAsync(sites: [Site("a", "Site A", ["a.com"])]);
        var routes = rl.Routes(new RoutesOptions { SignIn = "/login", Authorize = (_, _) => Task.FromResult<object>(false) });
        var registered = await routes.HandleAsync(At("https://x.com/runlight/oauth/register", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["client_name"] = "x", ["redirect_uris"] = L("https://evil.example/landing") })));
        string clientId = Obj(registered).Str("client_id")!;
        foreach (var asked in new[] { new[] { ("response_type", "token") }, new[] { ("response_type", "code"), ("code_challenge_method", "plain"), ("code_challenge", new string('a', 43)) } })
        {
            var answer = await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + Form([("client_id", clientId), ("redirect_uri", "https://evil.example/landing"), ("state", "x"), .. asked])));
            Assert.Equal(400, answer.Status);
            Assert.Null(answer.Headers.Get("location"));
        }
    }

    [Fact]
    public async Task A_signed_in_viewer_is_told_only_an_owner_can_connect_never_sent_to_sign_in_again()
    {
        var rl = await RunlightAsync(sites: [Site("a", "Site A", ["a.com"])]);
        var routes = rl.Routes(new RoutesOptions { SignIn = "/login", Authorize = (r, _) => Task.FromResult<object>(r.Headers.Get("cookie") == "viewer" ? "read" : false) });
        var registered = await routes.HandleAsync(At("https://x.com/runlight/oauth/register", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["client_name"] = "Claude", ["redirect_uris"] = L("https://claude.ai/cb") })));
        string clientId = Obj(registered).Str("client_id")!;
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://claude.ai/cb"), ("code_challenge", new string('a', 43)), ("code_challenge_method", "S256"));
        var signedOut = await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + parameters));
        Assert.Equal(303, signedOut.Status);
        Assert.StartsWith("/login?next=%2Frunlight%2Foauth%2Fauthorize%3Fresponse_type%3Dcode", signedOut.Headers.Get("location") ?? "", StringComparison.Ordinal);
        var viewer = await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + parameters, "GET", H(("cookie", "viewer"))));
        Assert.Equal(403, viewer.Status);
        Assert.Matches("only an owner of this Runlight can connect Claude", viewer.Text());
    }

    [Fact]
    public async Task A_manage_grant_names_one_site_and_records_the_hubs_origin()
    {
        var rl = await RunlightAsync(sites: [Site("a", "Site A", ["a.com"]), Site("b", "Site B", ["b.com"])]);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        var owner = H(("authorization", "Bearer secret"));
        string clientId = Obj(await routes.HandleAsync(At("https://x.com/runlight/oauth/register", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["client_name"] = "Hub", ["redirect_uris"] = L("https://hub.example.net/cb") })))).Str("client_id")!;
        string verifier = B64url(RandomNumberGenerator.GetBytes(32));
        string parameters = Form(("response_type", "code"), ("client_id", clientId), ("redirect_uri", "https://hub.example.net/cb"), ("code_challenge", OAuth.S256(verifier)), ("code_challenge_method", "S256"), ("scope", "read manage"), ("site", "b"));
        string page = (await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize?" + parameters, "GET", owner))).Text();
        Assert.Contains("<option value=\"b\" selected>Site B</option>", page, StringComparison.Ordinal); // the site asked for is offered first
        Assert.DoesNotContain("Every site", page, StringComparison.Ordinal);
        var form = With(owner, ("origin", "https://x.com"), ("content-type", "application/x-www-form-urlencoded"));
        var noSite = await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize", "POST", form, parameters.Replace("site=b", "site=", StringComparison.Ordinal) + "&decision=allow"));
        Assert.Equal("https://hub.example.net/cb?error=invalid_request&error_description=Pick+the+site+to+manage", noSite.Headers.Get("location"));
        var allow = await routes.HandleAsync(At("https://x.com/runlight/oauth/authorize", "POST", form, parameters.Replace("site=b", "site=a", StringComparison.Ordinal) + "&decision=allow"));
        string code = new Url(allow.Headers.Get("location") ?? "").SearchParams.Get("code")!;
        var issued = Obj(await routes.HandleAsync(At("https://x.com/runlight/oauth/token", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["grant_type"] = "authorization_code", ["code"] = code, ["client_id"] = clientId, ["redirect_uri"] = "https://hub.example.net/cb", ["code_verifier"] = verifier }))));
        Assert.Equal("manage a", issued.Str("scope") + " " + issued.Str("site"));
        var tokens = Obj(await routes.HandleAsync(At("https://x.com/runlight/api/tokens", "GET", owner))).Arr("tokens")!;
        Assert.Equal("https://hub.example.net", await rl.Store.SettingAsync("token-origin:" + ((JsObject)tokens[0]!).Str("id")));
    }
}
