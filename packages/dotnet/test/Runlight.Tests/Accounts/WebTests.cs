using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Store;
using Xunit;
using AccountsStore = Runlight.Accounts.Accounts;

namespace Runlight.Tests.Accounts;

/// <summary>
/// The little of a Runlight that accounts on the web reach for: its store, its mail, the client's address, and
/// work run after the answer. Mail is kept in a list instead of sent; <see cref="MailFails"/> makes sending throw.
/// </summary>
public sealed class StandIn
{
    private readonly List<Func<Task>> _later = [];

    public StandIn(SqlStore store)
    {
        Store = store;
    }

    public SqlStore Store { get; }

    public List<JsObject> Sent { get; } = [];

    public JsObject? Mail { get; set; }

    public Exception? MailFails { get; set; }

    public Task<JsObject?> MailSettingsAsync() => Task.FromResult(Mail);

    public Task SendMailAsync(JsObject message)
    {
        if (MailFails != null)
        {
            throw MailFails;
        }
        Sent.Add(message);
        return Task.CompletedTask;
    }

    /// <summary>The last X-Forwarded-For entry, else the connection's address, as Runlight reads it by default.</summary>
    public static string ClientIp(Request request, string? ip)
    {
        string? header = request.Headers.Get("x-forwarded-for");
        if (header != null && header.Trim().Length > 0)
        {
            return header.Split(',').Select(p => p.Trim()).Where(p => p.Length > 0).Last();
        }
        return ip ?? "";
    }

    public void Later(Func<Task> work) => _later.Add(work);

    /// <summary>Runs the work kept for after the answer, as an adapter does once the answer is out.</summary>
    public async Task IdleAsync()
    {
        while (_later.Count > 0)
        {
            var work = _later[0];
            _later.RemoveAt(0);
            await work();
        }
    }
}

/// <summary>An error with a code and params of its own, as MailError has.</summary>
public sealed class CodedError : Exception
{
    public CodedError(string message, string code, JsObject parameters)
        : base(message)
    {
        Code = code;
        Params = parameters;
    }

    public string Code { get; }

    public JsObject Params { get; }
}

/// <summary>
/// Accounts on the web, through Web.HandleAsync as the routes call it, with a stand-in for the Runlight. The cases
/// follow accounts.test.ts and the accounts conformance scenario; the same flows through the real routes wait for
/// the core.
/// </summary>
public sealed class WebTests : IAsyncLifetime
{
    private const long Start = 1_791_288_000_000;
    private const string Base = "/runlight";
    private const string Forgot = "https://runlight.sh/docs/configuration/#accounts";

    private long _now = Start;
    private StandIn _rl = null!;

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    private async Task<Web> WebAsync(FirstAccount? first = null, string? home = null)
    {
        var store = await Databases.FreshAsync("sqlite");
        await store.MigrateAsync();
        _rl = new StandIn(store);
        var rl = _rl;
        return new Web(new WebOptions
        {
            Store = store,
            Secret = new string('k', 64),
            Base = Base,
            Now = () => _now,
            FirstAccount = first ?? FirstAccount.Token("app-token"),
            Home = home == null ? null : () => home,
            Forgot = Forgot,
            MailSettings = _ => rl.MailSettingsAsync(),
            SendMail = (message, _) => rl.SendMailAsync(message),
            ClientIp = StandIn.ClientIp,
            Later = rl.Later,
        });
    }

    private static Request Req(string path, string method = "GET", Dictionary<string, string>? headers = null, string body = "") =>
        new("https://example.com/runlight" + path, method, new Headers(headers ?? []), body);

    private static string FormBody(params (string Key, string Value)[] fields) =>
        new SearchParams(fields.Select(f => new KeyValuePair<string, string>(f.Key, f.Value))).ToString();

    private static Request Form(string path, string cookie, params (string Key, string Value)[] fields)
    {
        var headers = new Dictionary<string, string> { ["content-type"] = "application/x-www-form-urlencoded" };
        if (cookie.Length > 0)
        {
            headers["cookie"] = cookie;
        }
        return Req(path, "POST", headers, FormBody(fields));
    }

    private static Request Form(string path, params (string Key, string Value)[] fields) => Form(path, "", fields);

    private static Request JsonReq(string cookie, string method, string path, object? body = null) =>
        Req(path, method, new Dictionary<string, string> { ["cookie"] = cookie, ["content-type"] = "application/json" }, body == null ? "" : Json.Stringify(body));

    private static Request Signed(string cookie) => Req("/", "GET", new Dictionary<string, string> { ["cookie"] = cookie });

    private static async Task<Response?> HandleAsync(Web web, Request request)
    {
        string path = new Url(request.Url).Pathname[Base.Length..];
        return await web.HandleAsync(request, path.Length > 0 ? path : "/");
    }

    private static async Task<Response> H(Web web, Request request) => (await HandleAsync(web, request))!;

    private static string CookieOf(Response response) => (response.Headers.GetSetCookie() is { Count: > 0 } c ? c[0] : "").Split(';')[0];

    private static JsObject BodyOf(Response response) => (JsObject)Json.Parse(response.Text())!;

    private static JsObject O(params (string Key, object? Value)[] pairs)
    {
        var o = new JsObject();
        foreach (var (k, v) in pairs)
        {
            o.Set(k, v);
        }
        return o;
    }

    private static Task<Response> Owner(Web web) =>
        H(web, Form("/setup", ("code", "app-token"), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")));

    private static async Task<string> OwnerCookie(Web web) => CookieOf(await Owner(web));

    [Fact]
    public async Task An_app_makes_its_first_account_with_its_token()
    {
        var web = await WebAsync();
        var start = await H(web, Req("/"));
        Assert.Equal(303, start.Status);
        Assert.Equal("/runlight/setup", start.Headers.Get("location"));
        Assert.Equal("no-store", start.Headers.Get("cache-control"));
        var page = await H(web, Req("/setup"));
        Assert.Equal(Pages.SetupPage(Base, "", askCode: true), page.Text());
        Assert.Equal("default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'", page.Headers.Get("content-security-policy"));
        Assert.Contains("href=\"/runlight/auth.css\"", page.Text());

        var wrong = await H(web, Form("/setup", ("code", "guess"), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")));
        Assert.Equal(403, wrong.Status);
        Assert.Equal(Pages.SetupPage(Base, "", "That is not this app's RUNLIGHT_TOKEN.", "jon@example.com", askCode: true), wrong.Text());
        var typo = await H(web, Form("/setup", ("code", "app-token"), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long passwore")));
        Assert.Equal(400, typo.Status);
        Assert.Contains("The two passwords are not the same.", typo.Text());
        var shortOne = await H(web, Form("/setup", ("code", "app-token"), ("email", "jon@example.com"), ("password", "short"), ("again", "short")));
        Assert.Equal(400, shortOne.Status);
        Assert.Contains("Use a password of at least 10 characters", shortOne.Text());

        var made = await Owner(web);
        Assert.Equal(303, made.Status);
        Assert.Equal("/runlight/", made.Headers.Get("location"));
        var cookie = made.Headers.GetSetCookie();
        Assert.Single(cookie);
        Assert.Matches(new Regex("^runlight_session=[a-f0-9]{24}\\.[0-9]+\\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=2592000; Secure\\z"), cookie[0]);
        Assert.Equal("/runlight/login", (await H(web, Req("/setup"))).Headers.Get("location"));

        string owner = CookieOf(made);
        Assert.Null(await HandleAsync(web, Signed(owner)));
        Assert.Equal(true, await web.AccessAsync(Signed(owner)));
        Assert.Equal(false, await web.AccessAsync(Req("/")));
        var answer = await H(web, JsonReq(owner, "GET", "/api/account"));
        var user = (await web.Accounts.ByEmailAsync("jon@example.com"))!;
        Assert.Equal(
            Json.Stringify(O(("account", O(("id", user.Str("id")), ("email", "jon@example.com"), ("role", "owner"), ("createdAt", Start), ("twoFactor", false), ("recoveryLeft", 0L))))),
            answer.Text());
        Assert.Equal("application/json; charset=utf-8", answer.Headers.Get("content-type"));
        Assert.Equal(user.Str("id"), await web.AccountOfAsync(Signed(owner)));

        // Signed out, the dashboard sends you to sign in, and keeps where you were going.
        Assert.Equal("/runlight/login?next=%2Frunlight%2F%3Fperiod%3D7d", (await H(web, Req("/?period=7d"))).Headers.Get("location"));
        Assert.Equal("/runlight/login", (await H(web, Req("/"))).Headers.Get("location"));
    }

    [Fact]
    public async Task A_server_code_open_and_locked_setups()
    {
        string code = Web.SetupCode();
        Assert.Matches(new Regex("^[A-Za-z0-9_-]{12}\\z"), code);
        var web = await WebAsync(FirstAccount.Code(code));
        Assert.Equal(403, (await H(web, Req("/"))).Status);
        Assert.Equal(Pages.SetupLockedPage(Base), (await H(web, Req("/setup?code=nope"))).Text());
        Assert.Equal(Pages.SetupPage(Base, code), (await H(web, Req("/setup?code=" + code))).Text());
        Assert.Equal(403, (await H(web, Req("/login"))).Status);
        Assert.Equal(403, (await H(web, Form("/setup", ("code", "nope"), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")))).Status);

        var open = await WebAsync(FirstAccount.Open);
        Assert.Equal("/runlight/setup", (await H(open, Req("/"))).Headers.Get("location"));
        Assert.Equal("/runlight/setup", (await H(open, Req("/login"))).Headers.Get("location"));
        Assert.DoesNotContain("RUNLIGHT_TOKEN", (await H(open, Req("/setup"))).Text());
        Assert.Equal(303, (await H(open, Form("/setup", ("code", ""), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")))).Status);

        var locked = await WebAsync(FirstAccount.Locked);
        var shut = await H(locked, Req("/setup"));
        Assert.Equal(403, shut.Status);
        Assert.Contains("Set RUNLIGHT_TOKEN", shut.Text());
        Assert.Equal(403, (await H(locked, Form("/setup", ("code", ""), ("email", "jon@example.com"), ("password", "a long password"), ("again", "a long password")))).Status);

        var css = await H(locked, Req("/auth.css"));
        Assert.True(Pages.AuthCss == css.Text());
        Assert.Equal("text/css; charset=utf-8", css.Headers.Get("content-type"));
        Assert.Equal("public, max-age=3600", css.Headers.Get("cache-control"));
        Assert.Equal("application/javascript; charset=utf-8", (await H(locked, Req("/auth.js"))).Headers.Get("content-type"));
        Assert.Null(await HandleAsync(locked, Req("/somewhere")));
    }

    [Fact]
    public async Task Signing_in_and_out_never_leaves_the_app()
    {
        var web = await WebAsync();
        await Owner(web);
        var login = await H(web, Req("/login?next=%2Frunlight%2F%3Fsite%3Dx"));
        Assert.Equal(Pages.LoginPage(Base, Forgot, next: "/runlight/?site=x"), login.Text());

        var wrong = await H(web, Form("/login", ("email", "jon@example.com"), ("password", "a wrong password")));
        Assert.Equal(401, wrong.Status);
        Assert.Equal(Pages.LoginPage(Base, Forgot, "That email and password do not match an account.", "jon@example.com", "/runlight/"), wrong.Text());

        var back = await H(web, Form("/login", ("email", "JON@example.com"), ("password", "a long password"), ("next", "/runlight/?period=7d")));
        Assert.Equal(303, back.Status);
        Assert.Equal("/runlight/?period=7d", back.Headers.Get("location"));
        var cookies = back.Headers.GetSetCookie();
        Assert.Equal(2, cookies.Count);
        Assert.Matches(new Regex("^runlight_device=[a-f0-9]{24}\\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=31536000; Secure\\z"), cookies[1]);

        var signedOut = await H(web, Req("/logout"));
        Assert.Equal("/runlight/login", signedOut.Headers.Get("location"));
        Assert.Equal(["runlight_session=; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=0; Secure"], signedOut.Headers.GetSetCookie());

        foreach (string next in new[] { "//evil.example/", "/\\evil.example", "/\t/evil.example", "https://evil.example/", "", "runlight" })
        {
            Assert.Equal("/runlight/", web.SafeNext(next));
        }
        Assert.Equal("/runlight/", web.SafeNext(null));
        Assert.Equal("/runlight/x?y=1#z", web.SafeNext("/runlight/a/../x?y=1#z"));
        Assert.Equal("/%20a", web.SafeNext("/ a"));
    }

    [Fact]
    public async Task Invites_people_and_roles()
    {
        var web = await WebAsync();
        string owner = await OwnerCookie(web);
        var sent = await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "Mo@Example.com"), ("role", "member"))));
        Assert.Equal(201, sent.Status);
        var body = BodyOf(sent);
        Assert.Equal(["invite", "link", "emailed"], body.Keys);
        Assert.False(body.Bool("emailed"));
        var link = new Url(body.Str("link")!);
        Assert.Equal("https://example.com", link.Origin);
        Assert.Equal("/runlight/invite", link.Pathname);
        string code = link.SearchParams.Get("code")!;
        Assert.Contains("as a member", (await H(web, Req("/invite?code=" + code))).Text());
        Assert.Equal(410, (await H(web, Req("/invite?code=nope"))).Status);

        Assert.Equal(409, (await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "jon@example.com"), ("role", "admin"))))).Status);
        var noRole = await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "x@example.com"), ("role", "owner"))));
        Assert.Equal("{\"error\":\"Pick admin, member, or viewer\",\"code\":\"role_needed\"}", noRole.Text());
        Assert.Equal("nosniff", noRole.Headers.Get("x-content-type-options"));
        var badEmail = await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "nobody"), ("role", "admin"))));
        Assert.Equal("{\"error\":\"Enter an email address\",\"code\":\"email_invalid\",\"params\":{}}", badEmail.Text());
        var form = await H(web, Req("/api/people", "POST", new Dictionary<string, string> { ["cookie"] = owner, ["content-type"] = "text/plain" }, "{}"));
        Assert.Equal(415, form.Status);
        Assert.Equal("{\"error\":\"Sign in first\",\"code\":\"sign_in\"}", (await H(web, Req("/api/people"))).Text());

        var typo = await H(web, Form("/invite", ("code", code), ("password", "another long one"), ("again", "another long two")));
        Assert.Equal(400, typo.Status);
        var joined = await H(web, Form("/invite", ("code", code), ("password", "another long one"), ("again", "another long one")));
        Assert.Equal(303, joined.Status);
        Assert.Equal("/runlight/", joined.Headers.Get("location"));
        string member = CookieOf(joined);
        Assert.Equal("member", await web.AccessAsync(Signed(member)));
        Assert.Equal(403, (await H(web, JsonReq(member, "GET", "/api/people"))).Status);
        Assert.Equal(410, (await H(web, Form("/invite", ("code", code), ("password", "another long one"), ("again", "another long one")))).Status);

        // A member's tokens go when they become a viewer.
        var mo = (await web.Accounts.ByEmailAsync("mo@example.com"))!;
        string moId = mo.Str("id")!;
        var token = O(("id", new string('b', 24)), ("name", "Script"), ("site", ""), ("scope", "read"), ("hash", new string('c', 64)), ("hint", "abcd"), ("createdAt", Start), ("lastUsedAt", null));
        await _rl.Store.InsertTokenAsync(token);
        Assert.True(await web.TokenMadeAsync(token, moId));
        Assert.False(await web.TokenMadeAsync(token, new string('d', 24)));
        var changed = await H(web, JsonReq(owner, "PATCH", "/api/people/" + moId, O(("role", "viewer"))));
        Assert.Equal(
            Json.Stringify(O(("person", O(("id", moId), ("email", "mo@example.com"), ("role", "viewer"), ("createdAt", Start), ("twoFactor", false), ("recoveryLeft", 0L))))),
            changed.Text());
        Assert.Empty(await _rl.Store.TokensAsync());
        Assert.Equal("read", await web.AccessAsync(Signed(member)));
        Assert.False(await web.TokenMadeAsync(token, moId));

        string jonId = (await web.Accounts.ByEmailAsync("jon@example.com"))!.Str("id")!;
        var self = await H(web, JsonReq(owner, "PATCH", "/api/people/" + jonId, O(("role", "admin"))));
        Assert.Equal("{\"error\":\"Only the owner can change their own role, by handing ownership to an admin\",\"code\":\"owner_protected\",\"params\":{}}", self.Text());
        Assert.Equal(403, self.Status);
        Assert.Equal(404, (await H(web, JsonReq(owner, "PATCH", "/api/people/" + new string('a', 24), O(("role", "admin"))))).Status);
        Assert.Equal("remove_self", BodyOf(await H(web, JsonReq(owner, "DELETE", "/api/people/" + jonId))).Str("code"));

        // Invites listed, resent, and cancelled.
        await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "zed@example.com"), ("role", "viewer"))));
        var people = BodyOf(await H(web, JsonReq(owner, "GET", "/api/people")));
        Assert.Equal(["jon@example.com", "mo@example.com"], people.Arr("people")!.Cast<JsObject>().Select(p => p.Str("email")).Order(StringComparer.Ordinal));
        Assert.Equal(["zed@example.com"], people.Arr("invites")!.Cast<JsObject>().Select(p => p.Str("email")));
        string id = ((JsObject)people.Arr("invites")![0]!).Str("id")!;
        var resent = await H(web, JsonReq(owner, "POST", "/api/invites/" + id + "/resend"));
        Assert.Equal(200, resent.Status);
        string newId = BodyOf(resent).Obj("invite")!.Str("id")!;
        Assert.NotEqual(id, newId);
        Assert.Equal(404, (await H(web, JsonReq(owner, "DELETE", "/api/invites/" + id))).Status);
        Assert.Equal("{\"ok\":true}", (await H(web, JsonReq(owner, "DELETE", "/api/invites/" + newId))).Text());

        Assert.Equal("{\"ok\":true}", (await H(web, JsonReq(owner, "DELETE", "/api/people/" + moId))).Text());
        Assert.Null(await web.SignedInAsync(Signed(member)));
    }

    [Fact]
    public async Task Invites_are_emailed_when_there_is_a_mail_service()
    {
        var web = await WebAsync(FirstAccount.Token("app-token"), "https://stats.example.com");
        string owner = await OwnerCookie(web);
        _rl.Mail = O(("service", "smtp"), ("from", "runlight@example.com"));
        var body = BodyOf(await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "mo@example.com"), ("role", "viewer")))));
        Assert.True(body.Bool("emailed"));
        Assert.StartsWith("https://stats.example.com/runlight/invite?code=", body.Str("link"), StringComparison.Ordinal);
        Assert.Equal("jon@example.com invited you to Runlight", _rl.Sent[0].Str("subject"));
        Assert.Equal("jon@example.com invited you to the Runlight at stats.example.com as a viewer, who can read every site's stats.\n\nChoose a password to join:\n" + body.Str("link") + "\n\nThe link works for seven days.\n", _rl.Sent[0].Str("text"));

        _rl.MailFails = new CodedError("The server refused the password", "mail_auth", O(("host", "smtp.example.com")));
        var failed = BodyOf(await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "ada@example.com"), ("role", "admin")))));
        Assert.Equal(["invite", "link", "emailed", "mailError", "mailCode", "mailParams"], failed.Keys);
        Assert.Equal("mail_auth", failed.Str("mailCode"));
        Assert.Equal("{\"host\":\"smtp.example.com\"}", Json.Stringify(failed.Get("mailParams")));
        _rl.MailFails = new InvalidOperationException("Something else");
        var other = BodyOf(await H(web, JsonReq(owner, "POST", "/api/people", O(("email", "zed@example.com"), ("role", "admin")))));
        Assert.Equal(["invite", "link", "emailed", "mailError"], other.Keys);
    }

    [Fact]
    public async Task Two_factor_through_the_account_api_and_the_code_step()
    {
        var web = await WebAsync();
        string owner = await OwnerCookie(web);
        var wrong = await H(web, JsonReq(owner, "POST", "/api/account/2fa/start", O(("password", "a wrong password"))));
        Assert.Equal("{\"error\":\"Your password is not right\",\"code\":\"password_wrong\"}", wrong.Text());
        var start = BodyOf(await H(web, JsonReq(owner, "POST", "/api/account/2fa/start", O(("password", "a long password")))));
        string secret = start.Str("secret")!;
        Assert.Equal(Crypto.OtpauthUri(secret, "jon@example.com", "example.com"), start.Str("uri"));
        Assert.Equal("{\"error\":\"Turn on two-factor sign-in first\",\"code\":\"twofactor_off\"}", (await H(web, JsonReq(owner, "POST", "/api/account/2fa/recovery", O(("password", "a long password"))))).Text());

        string code = Crypto.Totp(secret, _now / 30_000);
        var confirmed = await H(web, JsonReq(owner, "POST", "/api/account/2fa/confirm", O(("code", code[..3] + " " + code[3..]))));
        Assert.Equal(200, confirmed.Status);
        Assert.Equal(10, BodyOf(confirmed).Arr("recovery")!.Count);
        Assert.Null(await web.SignedInAsync(Signed(owner)));
        owner = CookieOf(confirmed);
        Assert.True((await web.SignedInAsync(Signed(owner)))!.Bool("twoFactor"));

        // Signing in now earns only the code step.
        _now += 60_000;
        var step = await H(web, Form("/login", ("email", "jon@example.com"), ("password", "a long password"), ("next", "/runlight/?x=1")));
        Assert.Equal(200, step.Status);
        Assert.Empty(step.Headers.GetSetCookie());
        var m = Regex.Match(step.Text(), "name=\"pending\" value=\"([^\"]+)\"");
        Assert.True(m.Success);
        string pending = WebUtility.HtmlDecode(m.Groups[1].Value);
        var bad = await H(web, Form("/login/code", ("pending", pending), ("code", "12345x"), ("next", "/runlight/?x=1")));
        Assert.Equal(401, bad.Status);
        Assert.Equal(Pages.CodePage(Base, pending, "/runlight/?x=1", "That code is not right. Check the time on your phone, or use a recovery code."), bad.Text());
        var signedIn = await H(web, Form("/login/code", ("pending", pending), ("code", Crypto.Totp(secret, _now / 30_000)), ("next", "/runlight/?x=1")));
        Assert.Equal(303, signedIn.Status);
        Assert.Equal("/runlight/?x=1", signedIn.Headers.Get("location"));
        Assert.Equal("/runlight/login?next=%2Frunlight%2F", (await H(web, Form("/login/code", ("pending", "made.up.ticket"), ("code", "123456")))).Headers.Get("location"));

        // Turning it off keeps this browser signed in.
        var off = await H(web, JsonReq(CookieOf(signedIn), "POST", "/api/account/2fa/disable", O(("password", "a long password"))));
        Assert.Equal("{\"ok\":true}", off.Text());
        Assert.False((await web.SignedInAsync(Signed(CookieOf(off))))!.Bool("twoFactor"));
        Assert.Equal(404, (await H(web, JsonReq(CookieOf(off), "POST", "/api/account/2fa/other", O(("password", "a long password"))))).Status);
    }

    [Fact]
    public async Task Confirming_has_five_tries_and_then_starts_again()
    {
        var web = await WebAsync();
        string owner = await OwnerCookie(web);
        var start = BodyOf(await H(web, JsonReq(owner, "POST", "/api/account/2fa/start", O(("password", "a long password")))));
        string right = Crypto.Totp(start.Str("secret")!, _now / 30_000);
        string wrong = right == "000000" ? "111111" : "000000";
        for (int i = 0; i < 5; i++)
        {
            Assert.Equal("code_wrong", BodyOf(await H(web, JsonReq(owner, "POST", "/api/account/2fa/confirm", O(("code", wrong))))).Str("code"));
        }
        var restart = await H(web, JsonReq(owner, "POST", "/api/account/2fa/confirm", O(("code", right))));
        Assert.Equal(429, restart.Status);
        Assert.Equal("twofactor_restart", BodyOf(restart).Str("code"));
        string id = (await web.Accounts.ByEmailAsync("jon@example.com"))!.Str("id")!;
        Assert.Null(await web.Accounts.ConfirmTwoFactorAsync(id, right, _now));
        // Starting again with the password opens five more tries.
        var again = BodyOf(await H(web, JsonReq(owner, "POST", "/api/account/2fa/start", O(("password", "a long password")))));
        string code = Crypto.Totp(again.Str("secret")!, _now / 30_000);
        Assert.Equal(200, (await H(web, JsonReq(owner, "POST", "/api/account/2fa/confirm", O(("code", code))))).Status);
    }

    [Fact]
    public async Task Password_changes_end_other_sessions()
    {
        var web = await WebAsync();
        string owner = await OwnerCookie(web);
        Assert.Equal("{\"error\":\"Your current password is not right\",\"code\":\"password_current_wrong\"}", (await H(web, JsonReq(owner, "POST", "/api/account/password", O(("current", "nope"), ("next", "a newer long one"))))).Text());
        var shortOne = await H(web, JsonReq(owner, "POST", "/api/account/password", O(("current", "a long password"), ("next", "short"))));
        Assert.Equal("{\"error\":\"Use a password of at least 10 characters\",\"code\":\"password_short\",\"params\":{\"min\":\"10\"}}", shortOne.Text());
        var changed = await H(web, JsonReq(owner, "POST", "/api/account/password", O(("current", "a long password"), ("next", "a newer long one"))));
        Assert.Equal("{\"ok\":true}", changed.Text());
        Assert.Null(await web.SignedInAsync(Signed(owner)));
        Assert.NotNull(await web.SignedInAsync(Signed(CookieOf(changed))));
    }

    [Fact]
    public async Task Ten_wrong_passwords_from_one_address_wait()
    {
        var web = await WebAsync();
        await Owner(web);
        var headers = new Dictionary<string, string> { ["content-type"] = "application/x-www-form-urlencoded", ["x-forwarded-for"] = "203.0.113.9" };
        string body = FormBody(("email", "jon@example.com"), ("password", "a wrong password"));
        for (int i = 0; i < 10; i++)
        {
            Assert.Equal(401, (await H(web, Req("/login", "POST", headers, body))).Status);
        }
        var held = await H(web, Req("/login", "POST", headers, body));
        Assert.Equal(429, held.Status);
        Assert.Contains("Too many tries. Wait fifteen minutes and try again.", held.Text());
        string right = FormBody(("email", "jon@example.com"), ("password", "a long password"));
        Assert.Equal(429, (await H(web, Req("/login", "POST", headers, right))).Status);
        var elsewhere = new Dictionary<string, string>(headers) { ["x-forwarded-for"] = "203.0.113.10" };
        Assert.Equal(303, (await H(web, Req("/login", "POST", elsewhere, right))).Status);
        _now += 15 * 60_000;
        Assert.Equal(303, (await H(web, Req("/login", "POST", headers, right))).Status);
    }

    [Fact]
    public async Task An_account_held_up_by_others_gets_a_sign_in_link()
    {
        var web = await WebAsync(FirstAccount.Token("app-token"), "https://stats.example.com");
        await Owner(web);
        _rl.Mail = O(("service", "smtp"), ("from", "runlight@example.com"));
        var accounts = web.Accounts;
        // Fifty failures against the account from fifty addresses, counted as the throttle counts them.
        var throttle = new Throttle(_rl.Store, "account", 50);
        for (int i = 0; i < 50; i++)
        {
            await throttle.FailAsync("jon@example.com", _now);
        }
        var held = await H(web, Form("/login", ("email", "jon@example.com"), ("password", "a long password"), ("next", "/runlight/?a=1")));
        Assert.Equal(429, held.Status);
        Assert.Contains("a link to sign in is on its way", held.Text());
        Assert.Empty(_rl.Sent);
        await _rl.IdleAsync();
        Assert.Single(_rl.Sent);
        Assert.Equal("Sign in to Runlight", _rl.Sent[0].Str("subject"));
        var m = Regex.Match(_rl.Sent[0].Str("text")!, "(https://stats\\.example\\.com/runlight/login/link\\?[^\\s]+)");
        Assert.True(m.Success);
        var link = new Url(m.Groups[1].Value);
        Assert.Equal("/runlight/?a=1", link.SearchParams.Get("next"));
        await H(web, Form("/login", ("email", "jon@example.com"), ("password", "a long password")));
        await _rl.IdleAsync();
        Assert.Single(_rl.Sent);
        var wrongToo = await H(web, Form("/login", ("email", "jon@example.com"), ("password", "a wrong password")));
        Assert.Equal(429, wrongToo.Status);

        var signedIn = await H(web, Req("/login/link" + link.Search));
        Assert.Equal(303, signedIn.Status);
        Assert.Equal("/runlight/?a=1", signedIn.Headers.Get("location"));
        Assert.Equal(410, (await H(web, Req("/login/link" + link.Search))).Status);
        Assert.NotNull(await accounts.ByEmailAsync("jon@example.com"));
    }

    [Fact]
    public async Task A_broken_session_cookie_throws_as_decode_uri_component_does()
    {
        var web = await WebAsync();
        await Assert.ThrowsAsync<ArgumentException>(() => web.SignedInAsync(Req("/", "GET", new Dictionary<string, string> { ["cookie"] = "runlight_session=%E0%A4%A" })));
    }

    [Fact]
    public async Task The_session_cookie_is_read_among_others()
    {
        var web = await WebAsync();
        string owner = await OwnerCookie(web);
        Assert.NotNull(await web.SignedInAsync(Req("/", "GET", new Dictionary<string, string> { ["cookie"] = "a=b; " + owner + " ; c=d=e" })));
        Assert.Equal(AccountsStore.SessionCookie, owner.Split('=')[0]);
        var plain = new Request("http://example.com/runlight/login", "POST", new Headers { ["content-type"] = "application/x-www-form-urlencoded" }, FormBody(("email", "jon@example.com"), ("password", "a long password")));
        Assert.DoesNotContain("Secure", (await H(web, plain)).Headers.GetSetCookie()[0], StringComparison.Ordinal);
        var proxied = new Request("http://example.com/runlight/logout", "GET", new Headers { ["x-forwarded-proto"] = "https" });
        Assert.EndsWith("; Secure", (await H(web, proxied)).Headers.GetSetCookie()[0], StringComparison.Ordinal);
    }
}
