using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;

namespace Runlight.Accounts;

/// <summary>
/// Who may create the first account: the server's printed one-time code (<see cref="Code"/>), the app's token
/// (<see cref="Token"/>), anyone (<see cref="Open"/>, for development), or nobody yet (<see cref="Locked"/>).
/// </summary>
public sealed class FirstAccount
{
    private FirstAccount(string kind, string value)
    {
        Kind = kind;
        Value = value;
    }

    /// <summary>"open", "locked", "code", or "token".</summary>
    public string Kind { get; }

    /// <summary>The code or token the setup form must carry; "" for open and locked.</summary>
    public string Value { get; }

    public static FirstAccount Open { get; } = new("open", "");

    public static FirstAccount Locked { get; } = new("locked", "");

    public static FirstAccount Code(string code) => new("code", code);

    public static FirstAccount Token(string token) => new("token", token);
}

/// <summary>
/// What accounts on the web need: the install's store, secret, base path, and clock, who may make the first
/// account, and the few things of the Runlight core it reaches for, as delegates the core supplies.
/// </summary>
public sealed class WebOptions
{
    public required SqlStore Store { get; init; }

    public required string Secret { get; init; }

    /// <summary>The base path the routes answer at: "" on the standalone server, "/runlight" in an app.</summary>
    public required string Base { get; init; }

    /// <summary>The clock, in epoch milliseconds (the Runlight's now).</summary>
    public required Func<long> Now { get; init; }

    public required FirstAccount FirstAccount { get; init; }

    /// <summary>The install's own origin, for links in emails, when one is known (the Runlight's home origin).</summary>
    public Func<string?>? Home { get; init; }

    /// <summary>Where the docs say how to set a new password.</summary>
    public required string Forgot { get; init; }

    /// <summary>Where to find the setup link with the one-time code, when it is not in a log (HTML).</summary>
    public string? SetupWhere { get; init; }

    /// <summary>The Runlight's mailSettings(): the mail service's settings, or null when there is none.</summary>
    public required Func<CancellationToken, Task<JsObject?>> MailSettings { get; init; }

    /// <summary>The Runlight's sendMail(message): sends { to, subject, text, html }, and throws when it cannot.</summary>
    public required Func<JsObject, CancellationToken, Task> SendMail { get; init; }

    /// <summary>The Runlight's clientIp(request, context): the client's address, given the connection's (the context's ip, or null).</summary>
    public required Func<Request, string?, string> ClientIp { get; init; }

    /// <summary>The Runlight's later(work): runs work once the answer is out, as TypeScript's waitUntil does.</summary>
    public required Action<Func<Task>> Later { get; init; }
}

/// <summary>
/// Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People APIs, under
/// the base path the routes answer at. The standalone server and an app with routes accounts: true share it.
/// </summary>
public sealed class Web
{
    private static readonly KeyValuePair<string, string>[] HtmlHeaders =
    [
        new("content-type", "text/html; charset=utf-8"),
        new("cache-control", "no-store"),
        new("content-security-policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"),
        new("x-frame-options", "DENY"),
        new("referrer-policy", "same-origin"),
    ];

    private const string DeviceCookie = "runlight_device";

    /// <summary>Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them.</summary>
    private const string MadeBy = "token-by:";

    /// <summary>When each account was last sent a sign-in link, at most one a minute; a setting, shared by every process.</summary>
    private const string LinkSent = "login-link-sent:";

    private static readonly Regex Unsafe = new("[\\x00-\\x1f\\x7f\\\\]", RegexOptions.CultureInvariant);
    private static readonly Regex ResetPath = new("^/api/people/([a-f0-9]{24})/2fa\\z", RegexOptions.CultureInvariant);
    private static readonly Regex OwnerPath = new("^/api/people/([a-f0-9]{24})/owner\\z", RegexOptions.CultureInvariant);
    private static readonly Regex InvitePath = new("^/api/invites/([a-f0-9]{24})(/resend)?\\z", RegexOptions.CultureInvariant);
    private static readonly Regex PersonPath = new("^/api/people/([a-f0-9]{24})\\z", RegexOptions.CultureInvariant);

    private readonly WebOptions _o;
    private readonly SqlStore _store;
    private readonly string _base;
    private readonly FirstAccount _first;
    private readonly string _cookiePath;
    private readonly string _homePath;
    private readonly bool _asksForToken;
    private bool _existing;

    // Wrong passwords are counted twice. Per account and address, ten tries;
    // per account from anywhere, fifty, so a caller who invents a new address
    // for every try still cannot guess on and on. Addresses come from
    // forwarding headers a client can write, so they never stand alone.
    // Each try counts before the password is checked, and a right one is taken back.
    private readonly Throttle _perAddress;
    private readonly Throttle _perAccount;

    // Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the first one.
    // Password re-checks in Account: ten.
    private readonly Throttle _codeTries;
    private readonly Throttle _confirmTries;
    private readonly Throttle _rechecks;

    public Web(WebOptions options)
    {
        _o = options;
        _store = options.Store;
        _base = options.Base;
        _first = options.FirstAccount;
        Accounts = new Accounts(_store, options.Secret);
        _cookiePath = _base.Length > 0 ? _base : "/";
        _homePath = _base + "/";
        _asksForToken = _first.Kind == "token";
        _perAddress = new Throttle(_store, "address", 10);
        _perAccount = new Throttle(_store, "account", 50);
        _codeTries = new Throttle(_store, "code", 5);
        _confirmTries = new Throttle(_store, "confirm", 5);
        _rechecks = new Throttle(_store, "recheck", 10);
    }

    public Accounts Accounts { get; }

    /// <summary>A random one-time code, such as the one a server prints to unlock its first account.</summary>
    public static string SetupCode() => Crypto.Base64url(Crypto.RandomBytes(9));

    private long Now() => _o.Now();

    private string? HomeOrigin() => _o.Home?.Invoke();

    private async Task<bool> HasMailAsync(CancellationToken cancellationToken) =>
        await _o.MailSettings(cancellationToken).ConfigureAwait(false) != null;

    public async Task<bool> HasAccountAsync(CancellationToken cancellationToken = default) =>
        _existing = _existing || await Accounts.CountAsync(cancellationToken).ConfigureAwait(false) > 0;

    private static string ReadCookie(Request request, string name)
    {
        foreach (string part in (request.Headers.Get("cookie") ?? "").Split(';'))
        {
            string[] pieces = Js.Trim(part).Split('=');
            if (pieces[0] == name)
            {
                return string.Join('=', pieces.Skip(1));
            }
        }
        return "";
    }

    private static bool IsSecure(Request request) =>
        new Url(request.Url).Protocol == "https:" || request.Headers.Get("x-forwarded-proto") == "https";

    /// <summary>An error the dashboard words in its own language, as the routes send them.</summary>
    private static Response Coded(string error, string code, int status, JsObject? parameters = null)
    {
        var body = new JsObject { ["error"] = error, ["code"] = code };
        if (parameters != null)
        {
            body.Set("params", parameters);
        }
        return new Response(Json.Stringify(body), status, new Headers
        {
            ["content-type"] = "application/json; charset=utf-8",
            ["cache-control"] = "no-store",
            ["x-content-type-options"] = "nosniff",
        });
    }

    private static Response Coded(AccountError error, int status) => Coded(error.Message, error.Code, status, error.ParamsObject());

    private static string Esc(string s) => Pages.Esc(s);

    /// <summary>
    /// Only a path on this install, so a sign-in can never send someone elsewhere. Browsers drop tabs and
    /// newlines from a URL and read a backslash as a slash, so "/\t/evil.example" would leave; anything with
    /// those is refused outright, and what is left must resolve to this origin.
    /// </summary>
    public string SafeNext(string? value)
    {
        if (string.IsNullOrEmpty(value) || !value.StartsWith('/') || Unsafe.IsMatch(value))
        {
            return _homePath;
        }
        var url = Url.Parse(value, "http://runlight.invalid");
        return url != null && url.Origin == "http://runlight.invalid" ? url.Pathname + url.Search + url.Hash : _homePath;
    }

    /// <summary>The signed-in user, or null.</summary>
    /// <exception cref="ArgumentException">for a session cookie decodeURIComponent cannot read, as it throws a URIError in TypeScript</exception>
    public async Task<JsObject?> SignedInAsync(Request request, CancellationToken cancellationToken = default)
    {
        string value = ReadCookie(request, Accounts.SessionCookie);
        if (value.Length == 0)
        {
            return null;
        }
        string decoded = Js.DecodeURIComponent(value) ?? throw new ArgumentException("URI malformed");
        return await Accounts.FromSessionAsync(decoded, Now(), cancellationToken).ConfigureAwait(false);
    }

    private async Task DropTokensOfAsync(string id, CancellationToken cancellationToken)
    {
        foreach (var row in await _store.SettingsStartingWithAsync(MadeBy, cancellationToken).ConfigureAwait(false))
        {
            if (row.Str("value") != id)
            {
                continue;
            }
            string key = row.Str("key")!;
            await _store.DeleteTokenAsync(key[MadeBy.Length..], cancellationToken).ConfigureAwait(false);
            await _store.SetSettingAsync(key, null, cancellationToken).ConfigureAwait(false);
        }
    }

    private string SessionCookie(Request request, string value, long maxAge) =>
        Accounts.SessionCookie + "=" + Js.EncodeURIComponent(value) + "; Path=" + _cookiePath + "; HttpOnly; SameSite=Lax; Max-Age=" + Js.Str(maxAge) + (IsSecure(request) ? "; Secure" : "");

    private string FreshSession(Request request, JsObject user) =>
        SessionCookie(request, Accounts.SessionFor(user, Now()), Accounts.SessionMs / 1000);

    /// <summary>The redirect after signing in: a session, and the mark that this browser has signed in to the account.</summary>
    private Response SignedInTo(Request request, JsObject user, string next)
    {
        var headers = new Headers { ["location"] = next, ["cache-control"] = "no-store" };
        headers.Append("set-cookie", FreshSession(request, user));
        headers.Append("set-cookie", DeviceCookie + "=" + Js.EncodeURIComponent(Accounts.DeviceFor(user)) + "; Path=" + _cookiePath + "; HttpOnly; SameSite=Lax; Max-Age=" + Js.Str(365 * 86_400) + (IsSecure(request) ? "; Secure" : ""));
        return new Response("", 303, headers);
    }

    private static Response Html(string body, int status = 200)
    {
        return new Response(body, status, new Headers(HtmlHeaders));
    }

    private static Response Redirect(string location, string? setCookie = null)
    {
        var headers = new Headers { ["location"] = location, ["cache-control"] = "no-store" };
        if (setCookie != null)
        {
            headers.Set("set-cookie", setCookie);
        }
        return new Response("", 303, headers);
    }

    private static Response Reply(object? body, int status = 200, string? setCookie = null)
    {
        var headers = new Headers { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "no-store" };
        if (setCookie != null)
        {
            headers.Set("set-cookie", setCookie);
        }
        return new Response(Json.Stringify(body), status, headers);
    }

    private static JsObject Person(JsObject u) => new()
    {
        ["id"] = u.Get("id"),
        ["email"] = u.Get("email"),
        ["role"] = u.Get("role"),
        ["createdAt"] = u.Get("createdAt"),
        ["twoFactor"] = u.Get("twoFactor"),
        ["recoveryLeft"] = u.Get("recoveryLeft"),
    };

    private static JsObject InviteView(JsObject i) => new()
    {
        ["id"] = i.Get("id"),
        ["email"] = i.Get("email"),
        ["role"] = i.Get("role"),
        ["invitedBy"] = i.Get("invitedBy"),
        ["createdAt"] = i.Get("createdAt"),
        ["expiresAt"] = i.Get("expiresAt"),
    };

    private static List<object?> People(IEnumerable<JsObject> users) => [.. users.Select(u => (object?)Person(u))];

    /// <summary>The media type of a request's body, as a cross-site form cannot send application/json.</summary>
    private static string MediaType(Request request) =>
        Js.Lower(Js.Trim((request.Headers.Get("content-type") ?? "").Split(';')[0]));

    /// <summary>A JSON body by its media type, which a cross-site form cannot send.</summary>
    private static JsObject? Body(Request request)
    {
        if (MediaType(request) != "application/json")
        {
            return null;
        }
        return Js.ParseJson(request.Text(), out object? value) && value is JsObject o ? o : null;
    }

    /// <summary><c>String(input[field] ?? "")</c>.</summary>
    private static string Field(JsObject input, string field)
    {
        object? value = Js.Get(input, field);
        return value is null or Undefined ? "" : Js.String(value);
    }

    /// <summary>The first account's gate: what the setup form must carry.</summary>
    private bool SetupOk(string given)
    {
        if (_first.Kind == "open")
        {
            return true;
        }
        if (_first.Kind == "locked")
        {
            return false;
        }
        return Crypto.SameText(given, _first.Value);
    }

    /// <summary>Why there is no setup form.</summary>
    private Response SetupLocked() =>
        Html(_first.Kind == "locked" ? Pages.SetupNeedsTokenPage(_base) : Pages.SetupLockedPage(_base, _o.SetupWhere), 403);

    /// <summary>
    /// Emails an invite through the mail service when there is one. The link always comes back too, for the
    /// inviter to pass on another way. The answer starts with the invite's view, then link, emailed, and any mail error.
    /// </summary>
    private async Task<JsObject> SendInviteAsync(Request request, JsObject invite, string code, CancellationToken cancellationToken)
    {
        string origin = HomeOrigin() ?? new Url(request.Url).Origin;
        string link = origin + _base + "/invite?code=" + code;
        string host = new Url(origin).Host;
        string what = Pages.RoleText(invite.Str("role")!);
        string invitedBy = invite.Str("invitedBy")!;
        var answer = new JsObject { ["invite"] = InviteView(invite), ["link"] = link };
        if (!await HasMailAsync(cancellationToken).ConfigureAwait(false))
        {
            answer.Set("emailed", false);
            return answer;
        }
        try
        {
            await _o.SendMail(
                new JsObject
                {
                    ["to"] = invite.Str("email"),
                    ["subject"] = invitedBy + " invited you to Runlight",
                    ["text"] = invitedBy + " invited you to the Runlight at " + host + " as " + what + ".\n\nChoose a password to join:\n" + link + "\n\nThe link works for seven days.\n",
                    ["html"] = "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>" + Esc(invitedBy) + " invited you to the Runlight at " + Esc(host) + " as " + what + ".</p><p><a href=\"" + Esc(link) + "\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">Choose a password and join</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>",
                },
                cancellationToken).ConfigureAwait(false);
            answer.Set("emailed", true);
            return answer;
        }
        catch (Exception error)
        {
            // The mail service's code and its details too, so the dashboard can say what went wrong in its own language.
            // Only a public string Code counts, as TypeScript reads `typeof failed.code === "string"`.
            answer.Set("emailed", false);
            answer.Set("mailError", error.Message);
            if (CodeOf(error) is string mailCode)
            {
                answer.Set("mailCode", mailCode);
                answer.Set("mailParams", ParamsOf(error));
            }
            return answer;
        }
    }

    /// <summary>An error's public string Code property, as MailError and AccountError have, or null.</summary>
    private static string? CodeOf(Exception error) =>
        error.GetType().GetProperty("Code")?.GetValue(error) as string;

    /// <summary>An error's Params as a JSON object: a JsObject, or a dictionary of strings, else {}.</summary>
    private static JsObject ParamsOf(Exception error)
    {
        object? value = error.GetType().GetProperty("Params")?.GetValue(error);
        switch (value)
        {
            case JsObject o:
                return o;
            case IEnumerable<KeyValuePair<string, string>> pairs:
                {
                    var o = new JsObject();
                    foreach (var e in pairs)
                    {
                        o.Set(e.Key, e.Value);
                    }
                    return o;
                }
            case IDictionary dictionary:
                {
                    var o = new JsObject();
                    foreach (DictionaryEntry e in dictionary)
                    {
                        o.Set(Js.String(e.Key), e.Value);
                    }
                    return o;
                }
            default:
                return new JsObject();
        }
    }

    /// <summary>
    /// Emails a sign-in link to an account held up by others' failed tries, at most once a minute. Only to the
    /// install's own address, never the Host of the request, so without one known there is no link.
    /// </summary>
    private async Task<bool> SendLinkAsync(JsObject user, string next, CancellationToken cancellationToken)
    {
        string? origin = HomeOrigin();
        if (string.IsNullOrEmpty(origin))
        {
            return false;
        }
        string key = LinkSent + user.Str("id");
        string? sent = await _store.SettingAsync(key, cancellationToken).ConfigureAwait(false);
        if (Now() - (sent == null ? 0 : Js.Number(sent)) < 60_000)
        {
            return true;
        }
        await _store.SetSettingAsync(key, Js.Str(Now()), cancellationToken).ConfigureAwait(false);
        string link = origin + _base + "/login/link?" + new SearchParams([new("ticket", Accounts.LinkFor(user, Now())), new("next", next)]).ToString();
        string host = new Url(origin).Host;
        await _o.SendMail(
            new JsObject
            {
                ["to"] = user.Str("email"),
                ["subject"] = "Sign in to Runlight",
                ["text"] = "Someone, most likely you, signed in to Runlight at " + host + " with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n" + link + "\n\nIf this was not you, change your password, since someone knows it.\n",
                ["html"] = "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>Someone, most likely you, signed in to Runlight at " + Esc(host) + " with your password while your account was held up by too many failed tries.</p><p><a href=\"" + Esc(link) + "\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">Sign in</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>",
            },
            cancellationToken).ConfigureAwait(false);
        return true;
    }

    private async Task<Response?> PagesAsync(Request request, string path, string? ip, CancellationToken cancellationToken)
    {
        var url = new Url(request.Url);
        var query = url.SearchParams;
        string method = request.Method;
        string b = _base;
        if (path == "/auth.css")
        {
            return new Response(Pages.AuthCss, 200, new Headers { ["content-type"] = "text/css; charset=utf-8", ["cache-control"] = "public, max-age=3600" });
        }
        if (path == "/auth.js")
        {
            return new Response(Pages.AuthJs, 200, new Headers { ["content-type"] = "application/javascript; charset=utf-8", ["cache-control"] = "public, max-age=3600" });
        }

        if (path == "/setup")
        {
            if (await HasAccountAsync(cancellationToken).ConfigureAwait(false))
            {
                return Redirect(b + "/login");
            }
            if (method == "GET")
            {
                string code = query.Get("code") ?? "";
                if (_first.Kind == "locked")
                {
                    return SetupLocked();
                }
                // The app's token is typed in; the server's code comes in the link it printed.
                if (_asksForToken || _first.Kind == "open")
                {
                    return Html(Pages.SetupPage(b, "", askCode: _asksForToken));
                }
                return SetupOk(code) ? Html(Pages.SetupPage(b, code)) : SetupLocked();
            }
            if (method == "POST")
            {
                var form = new SearchParams(request.Text());
                string code = form.Get("code") ?? "";
                string email = form.Get("email") ?? "";
                if (!SetupOk(code))
                {
                    if (_asksForToken)
                    {
                        return Html(Pages.SetupPage(b, "", "That is not this app's RUNLIGHT_TOKEN.", email, askCode: true), 403);
                    }
                    return SetupLocked();
                }
                string Again(string error) => Pages.SetupPage(b, _asksForToken ? "" : code, error, email, _asksForToken);
                // Asked twice, since a typo here would lock the first owner out.
                if ((form.Get("password") ?? "") != (form.Get("again") ?? ""))
                {
                    return Html(Again("The two passwords are not the same."), 400);
                }
                try
                {
                    var user = await Accounts.SetPasswordAsync(email, form.Get("password") ?? "", Now(), null, cancellationToken).ConfigureAwait(false);
                    _existing = true;
                    return Redirect(_homePath, FreshSession(request, user));
                }
                catch (AccountError error)
                {
                    return Html(Again(error.Message), 400);
                }
            }
        }

        if (path == "/login")
        {
            if (!await HasAccountAsync(cancellationToken).ConfigureAwait(false))
            {
                if (_first.Kind == "locked")
                {
                    return SetupLocked();
                }
                return _first.Kind == "open" || _asksForToken ? Redirect(b + "/setup") : SetupLocked();
            }
            if (method == "GET")
            {
                return Html(Pages.LoginPage(b, _o.Forgot, next: SafeNext(query.Get("next"))));
            }
            if (method == "POST")
            {
                return await LoginAsync(request, ip, cancellationToken).ConfigureAwait(false);
            }
        }

        // The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
        if (path == "/login/link" && method == "GET")
        {
            string next = SafeNext(query.Get("next"));
            var user = await Accounts.FromLinkAsync(query.Get("ticket") ?? "", Now(), cancellationToken).ConfigureAwait(false);
            if (user == null)
            {
                return Html(Pages.LoginPage(b, _o.Forgot, "That sign-in link has run out. Sign in again.", next: next), 410);
            }
            if (user.Bool("twoFactor"))
            {
                return Html(Pages.CodePage(b, Accounts.PendingFor(user, Now()), next));
            }
            return SignedInTo(request, user, next);
        }

        if (path == "/login/code" && method == "POST")
        {
            var form = new SearchParams(request.Text());
            string next = SafeNext(form.Get("next"));
            var pending = await Accounts.FromPendingAsync(form.Get("pending") ?? "", Now(), cancellationToken).ConfigureAwait(false);
            if (pending == null)
            {
                return Redirect(b + "/login?next=" + Js.EncodeURIComponent(next));
            }
            var (user, real) = pending.Value;
            string id = user.Str("id")!;
            // Counted before the check, so a burst cannot get past five.
            if (!await _codeTries.TakeAsync(id, Now(), cancellationToken).ConfigureAwait(false))
            {
                return Html(Pages.CodePage(b, form.Get("pending") ?? "", next, "Too many tries. Wait fifteen minutes and try again."), 429);
            }
            if (!real || !await Accounts.CheckSecondFactorAsync(id, form.Get("code") ?? "", Now(), cancellationToken).ConfigureAwait(false))
            {
                return Html(Pages.CodePage(b, form.Get("pending") ?? "", next, "That code is not right. Check the time on your phone, or use a recovery code."), 401);
            }
            await _codeTries.ClearAsync(id, cancellationToken).ConfigureAwait(false);
            return SignedInTo(request, user, next);
        }

        if (path == "/logout")
        {
            return Redirect(b + "/login", SessionCookie(request, "", 0));
        }

        if (path == "/invite")
        {
            if (method == "GET")
            {
                string code = query.Get("code") ?? "";
                var invite = await Accounts.InviteByCodeAsync(code, Now(), cancellationToken).ConfigureAwait(false);
                return invite != null
                    ? Html(Pages.InvitePage(b, code, invite.Str("email")!, invite.Str("role")!, url.Host))
                    : Html(Pages.InviteGonePage(b), 410);
            }
            if (method == "POST")
            {
                var form = new SearchParams(request.Text());
                string code = form.Get("code") ?? "";
                var invite = await Accounts.InviteByCodeAsync(code, Now(), cancellationToken).ConfigureAwait(false);
                if (invite == null)
                {
                    return Html(Pages.InviteGonePage(b), 410);
                }
                Response Again(string error) => Html(Pages.InvitePage(b, code, invite.Str("email")!, invite.Str("role")!, url.Host, error), 400);
                if ((form.Get("password") ?? "") != (form.Get("again") ?? ""))
                {
                    return Again("The two passwords are not the same.");
                }
                try
                {
                    var user = await Accounts.AcceptInviteAsync(code, form.Get("password") ?? "", Now(), cancellationToken).ConfigureAwait(false);
                    _existing = true;
                    return Redirect(_homePath, FreshSession(request, user));
                }
                catch (AccountError error)
                {
                    return Again(error.Message);
                }
            }
        }
        return null;
    }

    private async Task<Response> LoginAsync(Request request, string? ip, CancellationToken cancellationToken)
    {
        string b = _base;
        var form = new SearchParams(request.Text());
        string email = form.Get("email") ?? "";
        string password = form.Get("password") ?? "";
        string next = SafeNext(form.Get("next"));
        string account = Js.Lower(Js.Trim(email));
        string address = _o.ClientIp(request, ip);
        string pair = account + "\n" + (address.Length > 0 ? address : "unknown");
        Response TooMany() => Html(Pages.LoginPage(b, _o.Forgot, "Too many tries. Wait fifteen minutes and try again.", email, next), 429);
        if (!await _perAddress.TakeAsync(pair, Now(), cancellationToken).ConfigureAwait(false))
        {
            return TooMany();
        }
        // A browser that signed in to the account before is never held up by others' failures.
        var known = await Accounts.ByEmailAsync(account, cancellationToken).ConfigureAwait(false);
        bool trusted = known != null && Accounts.TrustsDevice(ReadCookie(request, DeviceCookie), known);
        bool over = !trusted && !await _perAccount.TakeAsync(account, Now(), cancellationToken).ConfigureAwait(false);
        // Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
        // addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
        // where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
        if (over && !(known?.Bool("twoFactor") ?? false))
        {
            string? home = HomeOrigin();
            if (!await HasMailAsync(cancellationToken).ConfigureAwait(false) || string.IsNullOrEmpty(home))
            {
                return TooMany();
            }
            var right = await Accounts.SignInAsync(email, password, cancellationToken).ConfigureAwait(false);
            if (right != null)
            {
                // Sent once the answer is out, as TypeScript does, so a right password takes no longer to answer than a wrong one.
                _o.Later(async () =>
                {
                    try
                    {
                        await SendLinkAsync(right, next, CancellationToken.None).ConfigureAwait(false);
                    }
                    catch (Exception error)
                    {
                        await Console.Error.WriteLineAsync("Runlight: could not send a sign-in link " + error.Message).ConfigureAwait(false);
                    }
                });
            }
            return Html(Pages.LoginPage(b, _o.Forgot, "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.", email, next), 429);
        }
        var user = await Accounts.SignInAsync(email, password, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            if (over && known != null)
            {
                return Html(Pages.CodePage(b, Accounts.DecoyFor(known, Now()), next));
            }
            return Html(Pages.LoginPage(b, _o.Forgot, "That email and password do not match an account.", email, next), 401);
        }
        await _perAddress.ClearAsync(pair, cancellationToken).ConfigureAwait(false);
        if (!over && !trusted)
        {
            await _perAccount.ForgiveAsync(account, cancellationToken).ConfigureAwait(false);
        }
        // With two-factor on, the password only earns the second step.
        if (user.Bool("twoFactor"))
        {
            return Html(Pages.CodePage(b, Accounts.PendingFor(user, Now()), next));
        }
        return SignedInTo(request, user, next);
    }

    /// <summary>Your own account, and for the owner and admins, everyone else's.</summary>
    private async Task<Response> ApiAsync(Request request, string path, CancellationToken cancellationToken)
    {
        var user = await SignedInAsync(request, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            return Coded("Sign in first", "sign_in", 401);
        }
        long now = Now();
        string method = request.Method;
        string userId = user.Str("id")!;
        string role = user.Str("role")!;
        // Writes must be JSON, which a form on another page cannot send, even those with no body.
        if (method == "POST" && MediaType(request) != "application/json")
        {
            return Coded("Send JSON", "send_json", 415);
        }
        if (path == "/api/account" && method == "GET")
        {
            return Reply(new JsObject { ["account"] = Person(user) });
        }
        async Task<Response?> RecheckAsync(JsObject input, string field, string wrong, string wrongCode)
        {
            if (!await _rechecks.TakeAsync(userId, now, cancellationToken).ConfigureAwait(false))
            {
                return Coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429);
            }
            if (await Accounts.SignInAsync(user.Str("email")!, Field(input, field), cancellationToken).ConfigureAwait(false) == null)
            {
                return Coded(wrong, wrongCode, 400);
            }
            await _rechecks.ForgiveAsync(userId, cancellationToken).ConfigureAwait(false);
            return null;
        }
        string Fresh(JsObject updated) => SessionCookie(request, Accounts.SessionFor(updated, now), Accounts.SessionMs / 1000);
        if (path == "/api/account/password" && method == "POST")
        {
            var input = Body(request);
            if (input == null)
            {
                return Coded("Send JSON", "send_json", 415);
            }
            var refused = await RecheckAsync(input, "current", "Your current password is not right", "password_current_wrong").ConfigureAwait(false);
            if (refused != null)
            {
                return refused;
            }
            try
            {
                var updated = await Accounts.SetPasswordAsync(user.Str("email")!, Field(input, "next"), now, null, cancellationToken).ConfigureAwait(false);
                // The new password ends every other sign-in; this browser gets a fresh one.
                return Reply(new JsObject { ["ok"] = true }, 200, Fresh(updated));
            }
            catch (AccountError error)
            {
                return Coded(error, 400);
            }
        }
        // Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off.
        // Each change asks for the password again, so a browser left signed in cannot quietly change it.
        if (path.StartsWith("/api/account/2fa", StringComparison.Ordinal) && method == "POST")
        {
            var input = Body(request);
            if (input == null)
            {
                return Coded("Send JSON", "send_json", 415);
            }
            string action = path["/api/account/2fa".Length..];
            // Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
            if (action == "/confirm")
            {
                if (!await _confirmTries.TakeAsync(userId, now, cancellationToken).ConfigureAwait(false))
                {
                    await Accounts.CancelTwoFactorSetupAsync(userId, cancellationToken).ConfigureAwait(false);
                    return Coded("Too many wrong codes. Start turning on two-factor sign-in again.", "twofactor_restart", 429);
                }
                string code = string.Concat(Field(input, "code").Where(c => !Js.IsSpace(c)));
                var codes = await Accounts.ConfirmTwoFactorAsync(userId, code, now, cancellationToken).ConfigureAwait(false);
                if (codes == null)
                {
                    return Coded("That code is not right. Check the time on your phone and try the next one.", "code_wrong", 400);
                }
                await _confirmTries.ClearAsync(userId, cancellationToken).ConfigureAwait(false);
                // Turning it on signs out every other browser; this one gets a new session.
                var updated = (await Accounts.ByIdAsync(userId, cancellationToken).ConfigureAwait(false))!;
                return Reply(new JsObject { ["recovery"] = codes.Select(c => (object?)c).ToList() }, 200, Fresh(updated));
            }
            var refused = await RecheckAsync(input, "password", "Your password is not right", "password_wrong").ConfigureAwait(false);
            if (refused != null)
            {
                return refused;
            }
            if (action == "/start")
            {
                await _confirmTries.ClearAsync(userId, cancellationToken).ConfigureAwait(false);
                string secret = await Accounts.StartTwoFactorAsync(userId, cancellationToken).ConfigureAwait(false);
                return Reply(new JsObject { ["secret"] = secret, ["uri"] = Crypto.OtpauthUri(secret, user.Str("email")!, new Url(request.Url).Host) });
            }
            if (action == "/recovery")
            {
                if (!user.Bool("twoFactor"))
                {
                    return Coded("Turn on two-factor sign-in first", "twofactor_off", 400);
                }
                var fresh = await Accounts.NewRecoveryCodesAsync(userId, cancellationToken).ConfigureAwait(false);
                return Reply(new JsObject { ["recovery"] = fresh.Select(c => (object?)c).ToList() });
            }
            if (action == "/disable")
            {
                await Accounts.DisableTwoFactorAsync(userId, cancellationToken).ConfigureAwait(false);
                // Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
                var updated = (await Accounts.ByIdAsync(userId, cancellationToken).ConfigureAwait(false))!;
                return Reply(new JsObject { ["ok"] = true }, 200, Fresh(updated));
            }
            return Coded("Not found", "not_found", 404);
        }
        if (role != "owner" && role != "admin")
        {
            return Coded("Only the owner or an admin can manage people", "people_owner", 403);
        }
        // The owner or an admin can turn off someone else's two-factor, for a coworker who lost both phone and recovery
        // codes, though never the owner's. It asks for their password like every other two-factor change, and their own
        // goes through Account.
        var reset = ResetPath.Match(path);
        if (reset.Success && method == "DELETE")
        {
            string target = reset.Groups[1].Value;
            if (target == userId)
            {
                return Coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400);
            }
            var input = Body(request);
            if (input == null)
            {
                return Coded("Send JSON", "send_json", 415);
            }
            var refused = await RecheckAsync(input, "password", "Your password is not right", "password_wrong").ConfigureAwait(false);
            if (refused != null)
            {
                return refused;
            }
            var person = await Accounts.ByIdAsync(target, cancellationToken).ConfigureAwait(false);
            if (person == null)
            {
                return Coded("Unknown account", "unknown_account", 404);
            }
            if (person.Str("role") == "owner")
            {
                return Coded("Only the owner can change the owner's account", "owner_protected", 403);
            }
            await Accounts.DisableTwoFactorAsync(target, cancellationToken).ConfigureAwait(false);
            return Reply(new JsObject { ["ok"] = true });
        }
        // The owner hands ownership to an admin and becomes an admin, after typing their password again.
        var handOver = OwnerPath.Match(path);
        if (handOver.Success && method == "POST")
        {
            if (role != "owner")
            {
                return Coded("Only the owner can hand over ownership", "owner_hand_over", 403);
            }
            var input = Body(request);
            if (input == null)
            {
                return Coded("Send JSON", "send_json", 415);
            }
            var refused = await RecheckAsync(input, "password", "Your password is not right", "password_wrong").ConfigureAwait(false);
            if (refused != null)
            {
                return refused;
            }
            try
            {
                await Accounts.HandOverAsync(userId, handOver.Groups[1].Value, cancellationToken).ConfigureAwait(false);
                return Reply(new JsObject { ["people"] = People(await Accounts.ListAsync(cancellationToken).ConfigureAwait(false)) });
            }
            catch (AccountError error)
            {
                return Coded(error, error.Code == "unknown_account" ? 404 : 400);
            }
        }
        // Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
        static string? RoleOf(object? value) => value is "admin" or "member" or "viewer" ? (string)value : null;
        if (path == "/api/people" && method == "GET")
        {
            var invites = await Accounts.InvitesAsync(now, cancellationToken).ConfigureAwait(false);
            return Reply(new JsObject
            {
                ["people"] = People(await Accounts.ListAsync(cancellationToken).ConfigureAwait(false)),
                ["invites"] = invites.Select(i => (object?)InviteView(i)).ToList(),
            });
        }
        if (path == "/api/people" && method == "POST")
        {
            var input = Body(request);
            if (input == null)
            {
                return Coded("Send JSON", "send_json", 415);
            }
            string? asRole = RoleOf(Js.Get(input, "role"));
            if (asRole == null)
            {
                return Coded("Pick admin, member, or viewer", "role_needed", 400);
            }
            string email = Js.Lower(Js.Trim(Field(input, "email")));
            if (await Accounts.ByEmailAsync(email, cancellationToken).ConfigureAwait(false) != null)
            {
                return Coded(email + " already has an account", "account_exists", 409, new JsObject { ["email"] = email });
            }
            try
            {
                var (invite, code) = await Accounts.InviteAsync(email, asRole, user.Str("email")!, now, cancellationToken).ConfigureAwait(false);
                return Reply(await SendInviteAsync(request, invite, code, cancellationToken).ConfigureAwait(false), 201);
            }
            catch (AccountError error)
            {
                return Coded(error, 400);
            }
        }
        var inviteMatch = InvitePath.Match(path);
        if (inviteMatch.Success)
        {
            string inviteId = inviteMatch.Groups[1].Value;
            bool resend = inviteMatch.Groups[2].Value.Length > 0;
            if (method == "DELETE" && !resend)
            {
                return await Accounts.CancelInviteAsync(inviteId, cancellationToken).ConfigureAwait(false)
                    ? Reply(new JsObject { ["ok"] = true })
                    : Coded("Unknown invite", "unknown_invite", 404);
            }
            if (method == "POST" && resend)
            {
                var old = (await Accounts.InvitesAsync(now, cancellationToken).ConfigureAwait(false)).FirstOrDefault(i => i.Str("id") == inviteId);
                if (old == null)
                {
                    return Coded("Unknown invite", "unknown_invite", 404);
                }
                // A new link replaces the old one, which stops working.
                var (invite, code) = await Accounts.InviteAsync(old.Str("email")!, old.Str("role")!, user.Str("email")!, now, cancellationToken).ConfigureAwait(false);
                return Reply(await SendInviteAsync(request, invite, code, cancellationToken).ConfigureAwait(false));
            }
        }
        var match = PersonPath.Match(path);
        if (match.Success && (method == "PATCH" || method == "DELETE"))
        {
            string target = match.Groups[1].Value;
            try
            {
                if (method == "DELETE")
                {
                    if (target == userId)
                    {
                        return Coded("You cannot remove yourself", "remove_self", 400);
                    }
                    await Accounts.RemoveAsync(target, cancellationToken).ConfigureAwait(false);
                    // The tokens they made, and the apps they connected, stop working with them.
                    await DropTokensOfAsync(target, cancellationToken).ConfigureAwait(false);
                    return Reply(new JsObject { ["ok"] = true });
                }
                var input = Body(request);
                if (input == null)
                {
                    return Coded("Send JSON", "send_json", 415);
                }
                string? newRole = RoleOf(Js.Get(input, "role"));
                if (newRole == null)
                {
                    return Coded("Pick admin, member, or viewer", "role_needed", 400);
                }
                var changed = await Accounts.SetRoleAsync(target, newRole, cancellationToken).ConfigureAwait(false);
                // A viewer changes nothing, so the tokens they made before go too.
                if (newRole == "viewer")
                {
                    await DropTokensOfAsync(target, cancellationToken).ConfigureAwait(false);
                }
                return Reply(new JsObject { ["person"] = Person(changed) });
            }
            catch (AccountError error)
            {
                int status = error.Code == "unknown_account" ? 404 : (error.Code == "owner_protected" ? 403 : 400);
                return Coded(error, status);
            }
        }
        return Coded("Not found", "not_found", 404);
    }

    /// <summary>
    /// What a signed-in person may do: everything (owner and admin, true), "member", "read" (viewer), or nothing
    /// (false), as the routes' authorize answers.
    /// </summary>
    public async Task<object> AccessAsync(Request request, CancellationToken cancellationToken = default)
    {
        var user = await SignedInAsync(request, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            return false;
        }
        // A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
        string role = user.Str("role")!;
        return role == "owner" || role == "admin" ? true : (role == "member" ? "member" : "read");
    }

    public async Task<string?> AccountOfAsync(Request request, CancellationToken cancellationToken = default) =>
        (await SignedInAsync(request, cancellationToken).ConfigureAwait(false))?.Str("id");

    /// <summary>
    /// Notes who made a token. A viewer makes no tokens; someone removed or made a viewer since allowing an app
    /// gets none for it, and false takes the token back.
    /// </summary>
    public async Task<bool> TokenMadeAsync(JsObject token, string by, CancellationToken cancellationToken = default)
    {
        string? role = (await Accounts.ByIdAsync(by, cancellationToken).ConfigureAwait(false))?.Str("role");
        if (role == null || role == "viewer")
        {
            return false;
        }
        await _store.SetSettingAsync(MadeBy + token.Str("id"), by, cancellationToken).ConfigureAwait(false);
        return true;
    }

    /// <summary>
    /// Answers an account page or API request at a path under the base, or null for anything else.
    /// <paramref name="ip"/> is the context's address (the connection's), handed to the Runlight's clientIp.
    /// </summary>
    public async Task<Response?> HandleAsync(Request request, string path, string? ip = null, CancellationToken cancellationToken = default)
    {
        if (path == "/api/account" || path.StartsWith("/api/account/", StringComparison.Ordinal) || path == "/api/people" || path.StartsWith("/api/people/", StringComparison.Ordinal) || path.StartsWith("/api/invites/", StringComparison.Ordinal))
        {
            return await ApiAsync(request, path, cancellationToken).ConfigureAwait(false);
        }
        var page = await PagesAsync(request, path, ip, cancellationToken).ConfigureAwait(false);
        if (page != null)
        {
            return page;
        }
        // The dashboard itself: straight to sign-in, or to setting up the first account.
        if ((path == "/" || path.Length == 0) && request.Method == "GET" && await SignedInAsync(request, cancellationToken).ConfigureAwait(false) == null)
        {
            if (!await HasAccountAsync(cancellationToken).ConfigureAwait(false))
            {
                return _first.Kind == "open" || _asksForToken ? Redirect(_base + "/setup") : SetupLocked();
            }
            string search = new Url(request.Url).Search;
            return Redirect(_base + "/login" + (search.Length > 0 ? "?next=" + Js.EncodeURIComponent(_homePath + search) : ""));
        }
        return null;
    }
}
