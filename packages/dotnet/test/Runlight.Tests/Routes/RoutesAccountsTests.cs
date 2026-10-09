using System;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Routes.Make;

namespace Runlight.Tests.Routes;

/// <summary>accounts.test.ts's route-level tests, as the PHP's tests/Accounts/RoutesAccountsTest.php: an app with routes accounts on.</summary>
public sealed class RoutesAccountsTests : RoutesTestCase
{
    private static Request Form(string path, string cookie = "", params (string Name, string Value)[] fields)
    {
        var parameters = new SearchParams();
        foreach (var (name, value) in fields)
        {
            parameters.Append(name, value);
        }
        var headers = H(("content-type", "application/x-www-form-urlencoded"));
        if (cookie.Length > 0)
        {
            headers.Set("cookie", cookie);
        }
        return new Request("https://example.com" + path, "POST", headers, parameters.ToString());
    }

    private static Request Get(string path, Headers? headers = null) => new("https://example.com" + path, "GET", headers, "");

    private static string CookieOf(Response response) => (response.Headers.Get("set-cookie") ?? "").Split(';')[0];

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task An_app_with_accounts_on_makes_its_first_account_with_its_token_then_invites_people_by_role(string kind)
    {
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync(kind), Secret = new string('k', 64) });
        var routes = rl.Routes(new RoutesOptions { Token = "app-token", Accounts = true });
        Task<Response> Handler(Request r) => routes.HandleAsync(r);
        Task<Response> Json(string cookie, string method, string path, object? body = null) =>
            Handler(new Request("https://example.com/runlight" + path, method, H(("cookie", cookie), ("content-type", "application/json")), body == null ? "" : global::Runlight.Json.Stringify(body)));

        // Nobody yet: the dashboard sends you to set up, which asks for the app's token.
        var start = await Handler(Get("/runlight/"));
        Assert.Equal(303, start.Status);
        Assert.Equal("/runlight/setup", start.Headers.Get("location"));
        string page = (await Handler(Get("/runlight/setup"))).Text();
        Assert.Matches("RUNLIGHT_TOKEN", page);
        Assert.Matches("action=\"/runlight/setup\"", page);
        Assert.Matches("href=\"/runlight/auth\\.css\"", page);
        var wrong = await Handler(Form("/runlight/setup", "", ("code", "guess"), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")));
        Assert.Equal(403, wrong.Status);
        var made = await Handler(Form("/runlight/setup", "", ("code", "app-token"), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")));
        Assert.Equal(303, made.Status);
        Assert.Equal("/runlight/", made.Headers.Get("location"));
        Assert.Matches("Path=/runlight;", made.Headers.Get("set-cookie") ?? ""); // the session is for Runlight's paths only
        string owner = CookieOf(made);
        Assert.Equal("/runlight/login", (await Handler(Get("/runlight/setup"))).Headers.Get("location")); // setup closes once there is an account

        // Signed in, the dashboard and its API answer; signed out, they do not.
        Assert.Equal(200, (await Handler(Get("/runlight/", H(("cookie", owner))))).Status);
        Assert.Matches("data-accounts=\"\"", (await Handler(Get("/runlight/", H(("cookie", owner))))).Text());
        Assert.Equal(401, (await Handler(Get("/runlight/api/sites"))).Status);
        Assert.Equal(200, (await Handler(Get("/runlight/api/sites", H(("cookie", owner))))).Status);
        Assert.Equal(200, (await Handler(Get("/runlight/api/sites", H(("authorization", "Bearer app-token"))))).Status); // a script's token still works
        Assert.Equal("owner", Obj(await Json(owner, "GET", "/api/account")).Obj("account")!.Str("role"));

        // The owner invites a member, who joins with their own password.
        var sent = Obj(await Json(owner, "POST", "/api/people", new JsObject { ["email"] = "mo@example.com", ["role"] = "member" }));
        Assert.False(sent.Bool("emailed")); // no mail service here, so the link is for passing on
        Assert.True(sent.Has("emailed"));
        var link = new Url(sent.Str("link")!);
        Assert.Equal("/runlight/invite", link.Pathname);
        Assert.Matches("as a member", (await Handler(Get(link.Pathname + link.Search))).Text());
        var joined = await Handler(Form("/runlight/invite", "", ("code", link.SearchParams.Get("code") ?? ""), ("password", "another long one"), ("again", "another long one")));
        Assert.Equal(303, joined.Status);
        string member = CookieOf(joined);

        // A member changes a site's settings, but not people, the mail service, or the assistant's settings.
        Assert.Equal(201, (await Json(member, "POST", "/api/goals", new JsObject { ["name"] = "Signup", ["kind"] = "page", ["match"] = "/thanks" })).Status);
        Assert.Equal(403, (await Json(member, "GET", "/api/people")).Status);
        Assert.Equal("admin_only", Obj(await Json(member, "PUT", "/api/mail", new JsObject())).Str("code"));
        Assert.Equal(403, (await Json(member, "PUT", "/api/assistant", new JsObject())).Status);

        // Signing out ends the session; signing in again with the password starts one.
        var signedOut = await Handler(Get("/runlight/logout"));
        Assert.Equal("/runlight/login", signedOut.Headers.Get("location"));
        Assert.Equal("/runlight/login", (await Handler(Get("/runlight/"))).Headers.Get("location"));
        var back = await Handler(Form("/runlight/login", "", ("email", "mo@example.com"), ("password", "another long one"), ("next", "/runlight/?period=7d")));
        Assert.Equal(303, back.Status);
        Assert.Equal("/runlight/?period=7d", back.Headers.Get("location"));
        var elsewhere = await Handler(Form("/runlight/login", "", ("email", "mo@example.com"), ("password", "another long one"), ("next", "//evil.example/")));
        Assert.Equal("/runlight/", elsewhere.Headers.Get("location")); // never sent off the app
    }

    [Fact]
    public async Task In_development_or_left_open_on_purpose_the_first_account_needs_no_proof_in_production_without_a_token_setup_stays_shut()
    {
        (string, string)[] fields = [("code", ""), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")];
        Environment.SetEnvironmentVariable("NODE_ENV", "development");
        var dev = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite") }).Routes(new RoutesOptions { Accounts = true });
        string page = (await dev.HandleAsync(Get("/runlight/setup"))).Text();
        Assert.DoesNotMatch("RUNLIGHT_TOKEN", page);
        var made = await dev.HandleAsync(Form("/runlight/setup", "", fields));
        Assert.Equal(303, made.Status);

        Environment.SetEnvironmentVariable("NODE_ENV", "production");
        var open = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite") }).Routes(new RoutesOptions { Token = null, Accounts = true });
        Assert.Equal(200, (await open.HandleAsync(Get("/runlight/setup"))).Status); // token: null leaves setup open, as it leaves everything
        var prod = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Secret = new string('k', 64) }).Routes(new RoutesOptions { Accounts = true });
        var shut = await prod.HandleAsync(Get("/runlight/setup"));
        Assert.Equal(403, shut.Status);
        Assert.Matches("Set RUNLIGHT_TOKEN", shut.Text());
        var tried = await prod.HandleAsync(Form("/runlight/setup", "", fields));
        Assert.Equal(403, tried.Status);
    }
}
