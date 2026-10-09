using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Importers;
using Runlight.Mail;
using Runlight.Store;
using ImportHttp = Runlight.Importers.Http;

namespace Runlight;

/// <summary>The routes, made from a Runlight.</summary>
public sealed partial class Runlight
{
    /// <summary>The dashboard, its API, the tracker, the MCP server, and OAuth, under one base path.</summary>
    public global::Runlight.Routes Routes(RoutesOptions? options = null) => new(this, options ?? new RoutesOptions());
}

/// <summary>
/// The dashboard, its API, the tracker, the MCP server, and OAuth, under one base path, as routes.ts serves them.
/// See <see cref="RoutesOptions"/> for what they take.
/// </summary>
public sealed class Routes
{
    public const string Cookie = "runlight_token";

    /// <summary>Who answers /api, beside the name and versions.</summary>
    public static readonly JsObject Implementation = new() { ["library"] = "Runlight", ["language"] = "dotnet" };

    /// <summary>API tokens start with this, so they are told apart from the main token.</summary>
    public const string TokenPrefix = "rl_";

    /// <summary>The header a shared dashboard sends its share id in.</summary>
    public const string ShareHeader = "x-runlight-share";

    /// <summary>What a share can read: one site's reports, nothing that changes anything.</summary>
    public static readonly IReadOnlyList<string> SharedPaths = ["/api/sites", "/api/icon", "/api/realtime", "/api/stats", "/api/series", "/api/rhythm", "/api/breakdown", "/api/goals", "/api/event-props", "/api/export", "/api/funnels", "/api/journeys"];

    /// <summary>Where the tracker's click rules go; the script ships with this string in their place.</summary>
    private const string RulesPlaceholder = "\"__RUNLIGHT_RULES__\"";

    /// <summary>Where the picker's one allowed receiver goes, the dashboard origin its ticket names.</summary>
    private const string PickTargetPlaceholder = "\"__RUNLIGHT_PICK_TARGET__\"";

    /// <summary>Where the hostnames of the site its ticket names go, as JSON inside a string.</summary>
    private const string PickHostsPlaceholder = "\"__RUNLIGHT_PICK_HOSTS__\"";

    /// <summary>How long a picker ticket works: long enough to find the element, not to be kept.</summary>
    public const long PickTicketMs = 30 * 60_000;

    /// <summary>Questions one person may put to the assistant in an hour, and at once.</summary>
    public const int AskPerHour = 30;

    public const int AskAtOnce = 2;

    /// <summary>Questions each viewer may ask a day, until an owner sets another number.</summary>
    public const int ViewerDailyDefault = 50;

    public const string DashboardCsp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

    /// <summary>The JavaScript whitespace class, for a regex character class.</summary>
    private const string Space = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF";

    /// <summary>A domain name, such as go.example.com.</summary>
    public static readonly Regex DomainName = new("^(?=[^\\n]{1,253}\\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}\\z", RegexOptions.CultureInvariant);

    private static readonly Regex ShareId = R("^[a-f0-9]{32}\\z");
    private static readonly string[] PathDimensions = ["page", "entry", "exit", "ai_page"];

    /// <summary>runlight.ts's LINK_DOMAIN_CHECK: the path on every link domain that answers when the domain reaches this Runlight.</summary>
    private const string LinkDomainCheck = "/.well-known/runlight-link-domain";

    /// <summary>runlight.ts's RETENTION_MONTHS: the choices for how long a site keeps its visits.</summary>
    private static readonly long[] RetentionMonths = [6, 12, 24, 36, 60];

    private static readonly Regex PortEnd = R(":[0-9]*\\z");
    private static readonly Regex DotsEnd = R("\\.+\\z");
    private static readonly Regex Www = R("^www\\.");
    private static readonly Regex DottedQuad = R("(^|\\.)[0-9]{1,3}(\\.[0-9]{1,3}){3}(\\.|\\z)");
    private static readonly Regex PrivateSuffix = R("\\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\\.arpa|arpa|test|invalid|example)\\z");
    private static readonly Regex Email = R("^[^" + Space + "@<>\"]+@[^" + Space + "@<>\"]+\\.[^" + Space + "@<>\"]+\\z");
    private static readonly Regex OriginPattern = R("^https?://[^/?#" + Space + "]+\\z");
    private static readonly Regex HttpAddress = R("^https?://[^" + Space + "]+\\z");
    private static readonly Regex Filename = R("filename=\"([A-Za-z0-9._-]+)\"");
    private static readonly Regex ErrorCode = R("^[a-z_]{1,40}\\z");
    private static readonly Regex NotFileChar = R("[^A-Za-z0-9._-]");
    private static readonly Regex GoalPath = R("^/api/goals/[a-f0-9]{24}\\z");
    private static readonly Regex GoalIdPath = R("^/api/goals/([a-f0-9]{24})\\z");
    private static readonly Regex AnyGoalPath = R("^/api/goals/[^/]+\\z");
    private static readonly Regex ManageAreas = R("^/api/(links|link-domains|reports|goals|funnels|shares)(/|\\z)");
    private static readonly Regex SitePath = R("^/api/sites/([^/]+)\\z");
    private static readonly Regex HttpPrefix = R("^https?://");
    private static readonly Regex PathAfter = R("/[\\s\\S]*\\z");
    private static readonly Regex CheckPath = R("^/api/link-domains/([^/]+)/check\\z");
    private static readonly Regex DomainPath = R("^/api/link-domains/([^/]+)\\z");
    private static readonly Regex ImportPath = R("^/api/links/import/([a-z]+)\\z");
    private static readonly Regex LinkPath = R("^/api/links/([a-f0-9]+)\\z");
    private static readonly Regex Ticket = R("^([0-9]+)\\.([a-f0-9]{2,512})\\.([a-f0-9]{2,512})\\.([a-f0-9]{64})\\z");
    private static readonly Regex ReportPath = R("^/api/reports/([a-f0-9]{24})(/send)?\\z");
    private static readonly Regex Token32 = R("^[a-f0-9]{32}\\z");
    private static readonly Regex TokenPath = R("^/api/tokens/([a-f0-9]{24})\\z");
    private static readonly Regex FunnelPath = R("^/api/funnels/[a-f0-9]{24}\\z");
    private static readonly Regex TrailingSlashes = R("/+\\z");
    private static readonly Regex Language = R("^[a-z]{2}\\z");
    private static readonly Regex Through = R("^([0-9]+):([^\\n\\r\\u2028\\u2029]+)\\z");
    private static readonly Regex PropertyName = R("^[^\"\\\\]{1,64}\\z");
    private static readonly Regex LocalePath = R("^/assets/locale\\.([a-z]{2,3})\\.([a-f0-9]+)\\.json\\z");
    private static readonly Regex UnsubscribePath = R("^/unsubscribe/([^/]+)/?\\z");
    private static readonly Regex SharePagePath = R("^/share/([^/]+)/?\\z");
    private static readonly Regex BaseSlashes = R("^/+|/+\\z");

    private static JsObject? _locales;

    private readonly Runlight _rl;
    private readonly string _base;
    private readonly string? _token;
    private readonly string? _cronSecret;
    private readonly string? _observeKey;
    private readonly string? _origin;
    private readonly RoutesOptions _options;
    private bool _warned;
    private readonly Web? _web;
    private readonly string? _signIn;
    private readonly string? _signOut;
    private readonly Func<Request, CancellationToken, Task<string?>>? _accountOf;
    private readonly Func<JsObject, string, CancellationToken, Task<bool>>? _tokenMade;
    private readonly OAuthContext _oauth;

    /// <summary>Requests from a manage token, already checked against its one site, act as the owner's.</summary>
    private readonly ConditionalWeakTable<Request, JsObject> _managed = [];

    /// <summary>Requests from a member: full access apart from the install-wide controls.</summary>
    private readonly ConditionalWeakTable<Request, object> _members = [];

    /// <summary>Questions to the assistant being answered now, per person, in this process.</summary>
    private readonly Dictionary<string, int> _open = new(StringComparer.Ordinal);

    /// <summary>The tracker per site, rebuilt when goals change.</summary>
    private readonly Dictionary<string, TrackerScript> _trackers = new(StringComparer.Ordinal);

    private sealed record TrackerScript(string Body, string Etag, long At);

    private static Regex R(string pattern) => new(pattern, RegexOptions.CultureInvariant);

    public Routes(Runlight runlight, RoutesOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(runlight);
        options ??= new RoutesOptions();
        _rl = runlight;
        _options = options;
        _base = NormaliseBase(options.BasePath ?? "/runlight");
        // Null leaves the routes open on purpose; an unset RUNLIGHT_TOKEN is no token (""), never open.
        _token = options.TokenGiven ? options.Token : (Env.Get("RUNLIGHT_TOKEN") ?? "");
        _cronSecret = options.CronSecret ?? Env.Get("CRON_SECRET");
        _observeKey = options.ObserveKey ?? Env.Get("RUNLIGHT_OBSERVE_KEY");
        _origin = !string.IsNullOrEmpty(options.Origin) ? new Url(options.Origin).Origin : null;
        // A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
        runlight.AddRouteBase(_base.Length > 0 ? _base : "/");

        // Accounts: the standalone server passes its own, and an app turns them on with true. Sessions need a secret
        // that outlives the process; in development without one, a made-up one does, so a restart signs everyone out.
        // An app left open on purpose (token: null) is treated like development here.
        string? token = _token;
        bool openSetup = token == null || (token.Length == 0 && IsDevelopment());
        string? accountSecret = runlight.Secret ?? (openSetup ? Hash.RandomId(32) : null);
        if (options.AccountsWeb != null)
        {
            _web = options.AccountsWeb;
        }
        else if (options.Accounts && !string.IsNullOrEmpty(accountSecret))
        {
            string? home = !string.IsNullOrEmpty(options.Origin) ? new Url(options.Origin).Origin : null;
            _web = new Web(new WebOptions
            {
                Store = runlight.Store,
                Secret = accountSecret,
                Base = _base,
                Now = runlight.Now,
                // The app's token proves who may make the first account; in development without one, anyone may.
                FirstAccount = !string.IsNullOrEmpty(token) ? FirstAccount.Token(token) : (openSetup ? FirstAccount.Open : FirstAccount.Locked),
                Forgot = "https://runlight.sh/docs/configuration/#accounts",
                Home = home != null ? () => home : null,
                MailSettings = ct => runlight.MailSettingsAsync(ct),
                SendMail = (m, ct) => runlight.SendMailAsync(m, ct),
                ClientIp = runlight.ClientIp,
                Later = runlight.Later,
            });
        }

        var web = _web;
        _signIn = options.SignIn ?? (web != null ? _base + "/login" : null);
        _signOut = options.SignOut ?? (web != null ? _base + "/logout" : null);
        _accountOf = options.AccountOf ?? (web != null ? (r, ct) => web.AccountOfAsync(r, ct) : null);
        _tokenMade = options.TokenMade ?? (web != null ? (row, by, ct) => web.TokenMadeAsync(row, by, ct) : null);
        var authorize = options.Authorize;
        _oauth = new OAuthContext
        {
            Store = runlight.Store,
            Base = _base,
            Now = runlight.Now,
            Init = ct => runlight.InitAsync(ct),
            ClientIp = runlight.ClientIp,
            Sites = _ => Task.FromResult(runlight.Sites()),
            Site = (id, _) => Task.FromResult(runlight.Site(id)),
            IsRemote = (id, _) => Task.FromResult(runlight.Remote(id) != null),
            IsOwner = async (r, ct) => await CanReadAsync(r, ct).ConfigureAwait(false) is true,
            IsReader = async (r, ct) => authorize != null
                ? await authorize(r, ct).ConfigureAwait(false) is "read"
                : web != null && await web.AccessAsync(r, ct).ConfigureAwait(false) is "read",
            SignIn = string.IsNullOrEmpty(_signIn) ? null : _signIn,
            AccountOf = _accountOf,
            TokenMade = _tokenMade,
        };
    }

    // Helpers that need nothing of an instance.

    private static string EscapeHtml(string value) =>
        value.Replace("&", "&amp;", StringComparison.Ordinal).Replace("<", "&lt;", StringComparison.Ordinal).Replace(">", "&gt;", StringComparison.Ordinal)
            .Replace("\"", "&quot;", StringComparison.Ordinal).Replace("'", "&#39;", StringComparison.Ordinal);

    /// <summary>The discovery documents OAuth clients read: two of OAuth's own, and OpenID's, which some clients try first.</summary>
    private static bool IsOauthDocument(string path) =>
        path.StartsWith("/.well-known/oauth-", StringComparison.Ordinal) || path.StartsWith("/.well-known/openid-configuration", StringComparison.Ordinal);

    private static bool IsDevelopment() => Env.Get("NODE_ENV") == "development";

    private static Headers BaseHeaders(params (string Name, string Value)[] pairs)
    {
        var headers = new Headers();
        foreach (var (name, value) in pairs)
        {
            headers.Set(name, value);
        }
        return headers;
    }

    /// <summary>
    /// An error the dashboard can show in its own language: <paramref name="code"/> names it and
    /// <paramref name="parameters"/> fill its placeholders, while <c>error</c> stays the English message.
    /// </summary>
    public static Response Coded(string error, string code, int status, JsObject? parameters = null, Headers? headers = null)
    {
        var body = new JsObject { ["error"] = error, ["code"] = code };
        if (parameters != null)
        {
            body["params"] = parameters;
        }
        return JsonResponse(body, status, headers);
    }

    /// <summary>
    /// A refusal from a check elsewhere: its own code and params when the error
    /// carries them, or else <paramref name="fallback"/> with its English words as <c>detail</c>.
    /// </summary>
    private static Response Refused(Exception error, string fallback, int status = 400)
    {
        (string? Code, JsObject? Params) own = error switch
        {
            SettingsError e => (e.Code, e.Params),
            ConnectError e => (e.Code, e.Params),
            GoalError e => (e.Code, e.Params),
            FunnelError e => (e.Code, e.Params),
            AssistantError e => (e.Code, e.Params),
            ImportError e => (e.Code, e.Params),
            MailError e => (e.Code, e.Params),
            LinkError e => (e.Code, e.Params),
            AccountError e => (e.Code, e.ParamsObject()),
            _ => (null, null),
        };
        if (own.Code != null)
        {
            return Coded(error.Message, own.Code, status, own.Params);
        }
        return Coded(error.Message, fallback, status, new JsObject { ["detail"] = error.Message });
    }

    /// <summary>The errors TypeScript throws as a RangeError: a refused setting, connection, or account, or an unknown link.</summary>
    private static bool IsRange(Exception error) => error is SettingsError or ConnectError or AccountError or ArgumentOutOfRangeException;

    /// <summary>JSON, never cached or sniffed.</summary>
    public static Response JsonResponse(object? body, int status = 200, Headers? headers = null)
    {
        var all = BaseHeaders(("content-type", "application/json; charset=utf-8"), ("cache-control", "no-store"), ("x-content-type-options", "nosniff"));
        if (headers != null)
        {
            foreach (var (name, value) in headers)
            {
                all.Set(name, value);
            }
        }
        return new Response(global::Runlight.Json.Stringify(body), status, all);
    }

    /// <summary>
    /// Whether a request's body is JSON by its media type. A cross-site form or a
    /// no-cors fetch can only send text/plain, urlencoded, or multipart, so a JSON
    /// media type proves the request came from a page allowed to send it. A
    /// substring test would accept "text/plain; application/json", which can.
    /// </summary>
    public static bool IsJson(Request request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return Js.Lower(Js.Trim((request.Headers.Get("content-type") ?? "").Split(';')[0])) == "application/json";
    }

    /// <summary>A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www.</summary>
    public static string HostName(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        string first = Js.Lower(Js.Trim(value.Split(',')[0]));
        string name;
        if (first.StartsWith('['))
        {
            int close = first.IndexOf(']', StringComparison.Ordinal);
            name = close < 0 ? "" : first[..(close + 1)];
        }
        else
        {
            name = PortEnd.Replace(first, "");
        }
        return Www.Replace(DotsEnd.Replace(name, ""), "");
    }

    /// <summary>
    /// Whether a domain name is one kept for private networks or tests, or has
    /// an IPv4 address inside it (as nip.io answers). The link-domain check
    /// fetches from it, so a name inside the install's own network must never
    /// get that far; names that only resolve there are refused when fetched.
    /// </summary>
    private static bool PrivateName(string domain) => DottedQuad.IsMatch(domain) || PrivateSuffix.IsMatch(domain);

    /// <summary>What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets.</summary>
    private static bool IsEmail(string value) => Email.IsMatch(value);

    /// <summary>
    /// Answers a read for a site counted by another install by asking that install,
    /// with its token and its own id for the site, and handing back what it says.
    /// </summary>
    private async Task<Response> PassThroughAsync(JsObject remote, string path, Url url, Request? request, CancellationToken cancellationToken)
    {
        var target = new Url(remote.Str("url") + path);
        var query = target.SearchParams;
        foreach (var (key, value) in url.SearchParams)
        {
            query.Append(key, value);
        }
        query.Set("site", Js.String(remote.Get("site")));
        target.SetSearchParams(query);
        // A change made from the hub goes on to the install with its JSON body; reads carry none.
        bool write = request != null && request.Method != "GET" && request.Method != "HEAD";
        var headers = new Headers { ["authorization"] = "Bearer " + Js.String(remote.Get("token")) };
        if (write && !string.IsNullOrEmpty(request!.Headers.Get("content-type")))
        {
            headers.Set("content-type", request.Headers.Get("content-type")!);
        }
        string host = new Url(remote.Str("url") ?? "").Host;
        Response answer;
        try
        {
            var init = new FetchInit
            {
                Method = write ? request!.Method : "GET",
                Headers = headers,
                // An install that answers with a redirect gets no fetch of somewhere else on its behalf.
                Redirect = "manual",
                // A long report or an export is worked out in full before the install sends a byte, so reads get
                // two minutes.
                TimeoutMs = write ? 30_000 : 120_000,
            };
            if (write)
            {
                init.Body = request!.Bytes();
            }
            answer = await _rl.Fetcher.FetchAsync(target.Href, init, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            if (error is FetchException { TimedOut: true })
            {
                return Coded(host + " took too long to answer. Try a shorter range.", "remote_slow", 504, new JsObject { ["host"] = host });
            }
            return Coded("Could not reach " + host, "unreachable", 502, new JsObject { ["host"] = host });
        }
        // What comes back is shown from this server's origin, so it is never taken as a page:
        // JSON, or a download for exports, with sniffing off and nothing allowed to run.
        bool download = path == "/api/export" || (path == "/api/breakdown" && url.SearchParams.Get("format") == "csv");
        var back = new Headers
        {
            ["cache-control"] = "private, no-store",
            ["x-content-type-options"] = "nosniff",
            ["content-security-policy"] = "default-src 'none'; frame-ancestors 'none'",
            ["content-type"] = download ? ((answer.Headers.Get("content-type") ?? "").StartsWith("text/csv", StringComparison.Ordinal) ? "text/csv; charset=utf-8" : "application/zip") : "application/json; charset=utf-8",
        };
        if (download)
        {
            var m = Filename.Match(answer.Headers.Get("content-disposition") ?? "");
            string name = m.Success ? m.Groups[1].Value : "runlight-export";
            back.Set("content-disposition", "attachment; filename=\"" + name + "\"");
        }
        if (answer.Status >= 300 && answer.Status < 400)
        {
            return Coded(host + " answered with a redirect", "redirected", 502, new JsObject { ["host"] = host });
        }
        // The install's own errors say what went wrong there; a refused token is this server's problem to report.
        if (answer.Status == 401)
        {
            return Coded(host + " refused the token. Connect it again from the site's settings.", "token_refused", 502, new JsObject { ["host"] = host });
        }
        // An install's own error is shown here, so it says where it came from, keeps only short text, and
        // carries its code and params for the dashboard to put in its own words.
        if (answer.Status >= 400 && !download)
        {
            string text;
            try
            {
                text = Body.Utf8(await answer.BytesAsync(cancellationToken).ConfigureAwait(false));
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                text = "";
            }
            JsObject? body = null;
            if (text.Length <= 65_536 && Js.ParseJson(text, out object? value) && value is JsObject parsed)
            {
                body = parsed;
            }
            object? Read(string key) => body == null ? null : body.Prop(key);
            var parameters = new List<KeyValuePair<string, object?>>();
            object? given = Read("params");
            if (given is JsObject givenObject)
            {
                foreach (var (k, v) in givenObject)
                {
                    if (v is string s)
                    {
                        parameters.Add(new(Js.Slice(k, 0, 40), Js.Slice(s, 0, 200)));
                    }
                }
                parameters = [.. parameters.Take(10)];
            }
            object? said = Read("error");
            var output = new JsObject { ["error"] = host + ": " + (said is string e ? Js.Slice(e, 0, 300) : "answered " + Js.Str(answer.Status)) };
            if (Read("code") is string code && ErrorCode.IsMatch(code))
            {
                output["code"] = code;
                output["params"] = JsObject.From(parameters);
            }
            return JsonResponse(output, answer.Status, back);
        }
        return new Response(await answer.BytesAsync(cancellationToken).ConfigureAwait(false), answer.Status, back);
    }

    /// <summary>A plain page in a visitor's language, for unsubscribing and for a share link that is gone.</summary>
    private static Response SmallPage(string lang, string body, int status = 200) => new(
        "<!doctype html><html lang=\"" + lang + "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>Runlight</title>\n"
        + "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>"
        + body + "</main></body></html>",
        status,
        new Headers
        {
            ["content-type"] = "text/html; charset=utf-8",
            ["cache-control"] = "no-store",
            ["content-security-policy"] = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
            ["referrer-policy"] = "no-referrer",
        });

    /// <summary>The first language a browser asks for that the dashboard speaks, else English.</summary>
    private static string AcceptedLanguage(Request request)
    {
        foreach (string part in (request.Headers.Get("accept-language") ?? "").Split(','))
        {
            string code = Js.Lower(Js.Slice(Js.Trim(part.Split(';')[0]), 0, 2));
            if (Messages.Languages().Contains(code))
            {
                return code;
            }
        }
        return "en";
    }

    /// <summary>Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads.</summary>
    private static string RowsCsv(IReadOnlyList<JsObject> rows, string timezone, string? interval = null, string? dimension = null)
    {
        var readable = rows.Select(r => SheetRow(r, timezone, interval, dimension)).ToList();
        IReadOnlyList<string> header = readable.Count > 0 ? readable[0].Keys : ["value"];
        return Zip.Csv(header, readable.Select(r => header.Select(k => r.Has(k) ? r.Get(k) : null)));
    }

    /// <summary>
    /// One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents,
    /// durations in seconds, and paths as people write them.
    /// </summary>
    private static JsObject SheetRow(JsObject row, string timezone, string? interval = null, string? dimension = null)
    {
        var output = new JsObject();
        foreach (var (key, value) in row)
        {
            bool number = value is long or int or double;
            if (key == "start" && number)
            {
                string hour = interval == "hour" ? " " + Js.Pad(Time.LocalWeekdayHour((long)Js.Num(value), timezone).Hour, 2) + ":00" : "";
                output["date"] = Time.LocalDate((long)Js.Num(value), timezone) + hour;
            }
            else if (key == "bounceRate" && number)
            {
                output["bounceRatePercent"] = Js.Round(Js.Num(value) * 1000) / 10;
            }
            else if ((key == "visitDuration" || key == "timeOnPage") && number)
            {
                output[key + "Seconds"] = Js.Round(Js.Num(value) / 1000);
            }
            else if (key == "value" && value is string text && PathDimensions.Contains(dimension ?? ""))
            {
                output["value"] = Sources.ReadablePath(text);
            }
            else
            {
                output[key] = value;
            }
        }
        return output;
    }

    /// <summary>A file to save, never shown in the browser or kept in a shared cache.</summary>
    private static Response Download(string name, byte[] body, string type) => new(body, 200, new Headers
    {
        ["content-type"] = type,
        ["content-disposition"] = "attachment; filename=\"" + NotFileChar.Replace(name, "-") + "\"",
        ["cache-control"] = "private, no-store",
    });

    private static bool ConstantTimeEqual(string a, string b)
    {
        byte[] x = Js.Utf8(a);
        byte[] y = Js.Utf8(b);
        return x.Length == y.Length && CryptographicOperations.FixedTimeEquals(x, y);
    }

    public static string CookieValue(string token) => Hash.Sha256("runlight-cookie:" + token);

    public static string ReadCookie(Request request, string name)
    {
        ArgumentNullException.ThrowIfNull(request);
        foreach (string part in (request.Headers.Get("cookie") ?? "").Split(';'))
        {
            var pieces = Js.Trim(part).Split('=');
            if (pieces[0] == name)
            {
                return string.Join('=', pieces.Skip(1));
            }
        }
        return "";
    }

    public static string Bearer(Request request)
    {
        ArgumentNullException.ThrowIfNull(request);
        string header = request.Headers.Get("authorization") ?? "";
        return header.Length >= 7 && Js.Lower(header[..7]) == "bearer " ? Js.Trim(header[7..]) : "";
    }

    public static string NormaliseBase(string path)
    {
        string trimmed = "/" + BaseSlashes.Replace(path, "");
        return trimmed == "/" ? "" : trimmed;
    }

    private static string EscapeAttr(string value) =>
        value.Replace("&", "&#38;", StringComparison.Ordinal).Replace("\"", "&#34;", StringComparison.Ordinal).Replace("<", "&#60;", StringComparison.Ordinal).Replace(">", "&#62;", StringComparison.Ordinal);

    /// <summary>Each language but English, as the dashboard fetches them: code to the JSON text.</summary>
    private static JsObject Locales()
    {
        if (_locales == null)
        {
            var all = ((JsObject)global::Runlight.Json.Parse(Assets.Text("locales.json"))!).Clone();
            all.Remove("en");
            _locales = all;
        }
        return _locales;
    }

    private static string BuildHash(string name) => Js.String(Assets.Build.Get(name));

    private static string LocaleUrls(string @base)
    {
        var urls = new JsObject();
        foreach (string code in Locales().Keys)
        {
            urls[code] = @base + "/assets/locale." + code + "." + BuildHash("localesHash") + ".json";
        }
        return global::Runlight.Json.Stringify(urls);
    }

    /// <summary>The dashboard's page, which holds no data: the API it calls checks access.</summary>
    public static string Dashboard(string @base, string share = "", string signOut = "", bool geoCredit = false, bool accounts = false, string signIn = "")
    {
        ArgumentNullException.ThrowIfNull(@base);
        string b = EscapeAttr(@base);
        string hash = BuildHash("dashboardHash");
        string attributes = (share.Length > 0 ? " data-share=\"" + EscapeAttr(share) + "\"" : "")
            + (signOut.Length > 0 ? " data-sign-out=\"" + EscapeAttr(signOut) + "\"" : "")
            + (signIn.Length > 0 ? " data-sign-in=\"" + EscapeAttr(signIn) + "\"" : "")
            + (geoCredit ? " data-geo-credit=\"\"" : "")
            + (accounts ? " data-accounts=\"\"" : "");
        return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"robots\" content=\"noindex\">\n<title>Runlight</title>\n"
            + "<link rel=\"icon\" href=\"" + Brand.RunlightIcon + "\">\n"
            + "<link rel=\"stylesheet\" href=\"" + b + "/assets/app." + hash + ".css\">\n</head>\n<body>\n"
            + "<div id=\"app\" data-base=\"" + b + "\"" + attributes + " data-world=\"" + b + "/assets/world." + BuildHash("worldHash") + ".json\" data-locales=\"" + EscapeAttr(LocaleUrls(@base)) + "\"></div>\n"
            + "<script type=\"module\" src=\"" + b + "/assets/app." + hash + ".js\"></script>\n</body>\n</html>\n";
    }

    private static bool SharedPath(string path) => SharedPaths.Contains(path) || GoalPath.IsMatch(path);

    /// <summary>
    /// What a manage token, held by a Runlight hub, may read and change: one
    /// site's goals, funnels, short links, link domains, email reports, and share
    /// links, along with its name, timezone, and retention, and tickets for the
    /// element picker. It may read which mail service sends reports, through GET
    /// /api/mail, which hides the service's keys. Never people, tokens, changes to
    /// the mail service, imports, or other sites.
    /// </summary>
    public static bool ManagePath(string method, string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (path.StartsWith("/api/links/import", StringComparison.Ordinal))
        {
            return false;
        }
        if (ManageAreas.IsMatch(path))
        {
            return true;
        }
        if (path == "/api/pick")
        {
            return method == "POST";
        }
        if (path == "/api/mail")
        {
            return method == "GET";
        }
        if (SitePath.IsMatch(path))
        {
            return method == "PATCH";
        }
        return false;
    }

    /// <summary>A dashboard's origin, which a picker ticket names.</summary>
    private static bool IsOrigin(string value) => OriginPattern.IsMatch(value);

    /// <summary>decodeURIComponent, which throws on a broken escape, as the TypeScript does (an internal error there).</summary>
    private static string Decode(string text) => Js.DecodeURIComponent(text) ?? throw new UriFormatException("URI malformed");

    /// <summary><c>String(body[key] ?? fallback)</c>.</summary>
    private static string Text(JsObject body, string key, string fallback = "")
    {
        object? value = body.Prop(key);
        return value is null or Undefined ? fallback : Js.String(value);
    }

    private static bool Defined(JsObject body, string key) => body.Prop(key) is not Undefined;

    /// <summary><c>Object.fromEntries(Object.entries(value).map(([k, v]) => [k, String(v)]))</c> for an object, else nothing.</summary>
    private static JsObject Credentials(object? value)
    {
        var output = new JsObject();
        if (value is JsObject o)
        {
            foreach (var (k, v) in o)
            {
                output[k] = Js.String(v);
            }
        }
        else if (value is List<object?> list)
        {
            for (int i = 0; i < list.Count; i++)
            {
                output[Js.Str(i)] = Js.String(list[i]);
            }
        }
        return output;
    }

    /// <summary><c>Math.min(1000, Math.max(1, Number(value) || fallback))</c>.</summary>
    private static double Limit(string? value, double fallback)
    {
        double n = value == null ? 0 : Js.Number(value);
        if (double.IsNaN(n) || n == 0)
        {
            n = fallback;
        }
        return Math.Min(1000, Math.Max(1, n));
    }

    /// <summary>A number as a whole int, as PHP's (int) cast and a store's LIMIT read it, kept within int.</summary>
    private static int Whole(double n) => double.IsNaN(n) ? 0 : (int)Math.Clamp(Math.Truncate(n), int.MinValue, int.MaxValue);

    /// <summary>A value as a JSON object field reads it: null when absent.</summary>
    private static object? Or(JsObject? o, string key, object? fallback)
    {
        object? value = o?.Get(key);
        return value is null or Undefined ? fallback : value;
    }

    // The routes.

    private List<JsObject> Sites() => _rl.Sites();

    private SqlStore Store => _rl.Store;

    /// <summary>
    /// Whether this request acts as the owner: true, false, "read" (someone signed in who may only read, such as a
    /// viewer), or "unconfigured".
    /// </summary>
    private async Task<object> CanReadAsync(Request request, CancellationToken cancellationToken)
    {
        if (_managed.TryGetValue(request, out _))
        {
            return true;
        }
        var authorize = _options.Authorize;
        if (authorize != null || _web != null)
        {
            // A script's bearer token still has full access beside the sign-ins.
            string given = Bearer(request);
            if (authorize == null && !string.IsNullOrEmpty(_token) && given.Length > 0 && ConstantTimeEqual(given, _token))
            {
                return true;
            }
            object answer = authorize != null ? await authorize(request, cancellationToken).ConfigureAwait(false) : await _web!.AccessAsync(request, cancellationToken).ConfigureAwait(false);
            // A member changes things like an owner, apart from the few controls AdminOnly names.
            if (answer is "member")
            {
                _members.AddOrUpdate(request, true);
            }
            return answer is "read" ? "read" : (answer is true || answer is "member");
        }
        if (_token == null)
        {
            return true;
        }
        if (_token.Length == 0)
        {
            // Fails closed: only a process that says it is in development runs open.
            if (!IsDevelopment())
            {
                return "unconfigured";
            }
            if (!_warned)
            {
                _warned = true;
                await Console.Error.WriteLineAsync("Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.").ConfigureAwait(false);
            }
            return true;
        }
        string bearer = Bearer(request);
        if (bearer.Length > 0 && ConstantTimeEqual(bearer, _token))
        {
            return true;
        }
        string cookie = ReadCookie(request, Cookie);
        return cookie.Length > 0 && ConstantTimeEqual(cookie, CookieValue(_token));
    }

    private bool IsMember(Request request) => _members.TryGetValue(request, out _);

    /// <summary>The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site.</summary>
    private static bool AdminOnly(string path, string method) =>
        (path == "/api/mail" && (method == "PUT" || method == "DELETE"))
        || (path == "/api/assistant" && (method == "PUT" || method == "DELETE"))
        || (path == "/api/assistant/limits" && method == "PUT")
        || (path == "/api/assistant/models" && method == "POST")
        || (SitePath.IsMatch(path) && method == "DELETE");

    /// <summary>An API token from the bearer header: read-only, and maybe limited to one site.</summary>
    private async Task<JsObject?> ApiTokenAsync(Request request, CancellationToken cancellationToken)
    {
        string given = Bearer(request);
        if (!given.StartsWith(TokenPrefix, StringComparison.Ordinal))
        {
            return null;
        }
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        var row = await Store.TokenByHashAsync(Hash.Sha256(given), cancellationToken).ConfigureAwait(false);
        if (row == null)
        {
            return null;
        }
        long now = _rl.Now();
        // At most once a minute, so a busy assistant does not write on every call.
        object? lastUsed = row.Get("lastUsedAt");
        if (lastUsed == null || now - Js.Num(lastUsed) > 60_000)
        {
            await Store.TouchTokenAsync(row.Str("id")!, now, cancellationToken).ConfigureAwait(false);
        }
        return row;
    }

    /// <summary>Who may read stats: the owner (true), an API token or a read-only sign-in (a token row), or nobody (false or "unconfigured").</summary>
    private async Task<object> ReaderAsync(Request request, CancellationToken cancellationToken)
    {
        var token = await ApiTokenAsync(request, cancellationToken).ConfigureAwait(false);
        if (token != null)
        {
            return token;
        }
        object access;
        if (_options.Authorize != null || _web != null)
        {
            access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            // A read-only sign-in reads like an API token for every site.
            return access is "read"
                ? new JsObject { ["id"] = "", ["name"] = "", ["site"] = "", ["scope"] = "read", ["hash"] = "", ["hint"] = "", ["createdAt"] = 0L, ["lastUsedAt"] = null }
                : access is true;
        }
        access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
        return access is "read" ? false : access;
    }

    private static bool Refuses(object access) => access is false or "unconfigured";

    /// <summary>The refusal for a hub that asks for something only safe once this app knows its own address.</summary>
    private static Response OriginNeeded() =>
        Coded("Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.", "origin_needed", 400);

    private static Response Denied(object result)
    {
        if (result is "read")
        {
            return Coded("Only an owner can change this", "owner_only", 403);
        }
        return result is "unconfigured"
            ? Coded("Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.", "token_unset", 503)
            : Coded("Unauthorized", "unauthorized", 401);
    }

    /// <summary>The site the query names, or a refusal.</summary>
    private object QuerySite(Url url) => (object?)_rl.Site(url.SearchParams.Get("site")) ?? Coded("Unknown site", "unknown_site", 404);

    private sealed record Read(JsObject Query, JsObject Range, JsObject? Compared);

    private async Task<object> ReadQueryAsync(Url url, JsObject site, CancellationToken cancellationToken)
    {
        var parameters = url.SearchParams;
        var filters = new List<object?>();
        if (parameters.GetAll("filter").Count > Query.MaxFilters)
        {
            return Coded("Use at most " + Js.Str(Query.MaxFilters) + " filters at once.", "filters_max", 400, new JsObject { ["max"] = Js.Str(Query.MaxFilters) });
        }
        foreach (string raw in parameters.GetAll("filter"))
        {
            var filter = Query.ParseFilter(raw);
            if (filter == null)
            {
                return Coded("Bad filter \"" + raw + "\". Use dimension:is|not|contains:value.", "filter_bad", 400, new JsObject { ["filter"] = raw });
            }
            filters.Add(filter);
        }
        long now = _rl.Now();
        string timezone = site.Str("timezone")!;
        string? firstDate = null;
        if (parameters.Get("period") == "all")
        {
            double? first = await Store.FirstSeenAsync(site.Str("id")!, cancellationToken).ConfigureAwait(false);
            if (first != null)
            {
                firstDate = Time.LocalDate((long)first.Value, timezone);
            }
        }
        var range = Time.ResolveRange(parameters.Get("period"), parameters.Get("from"), parameters.Get("to"), parameters.Get("interval"), timezone, now, firstDate);
        if (range == null)
        {
            return Coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400);
        }
        var query = new JsObject { ["site"] = site.Get("id"), ["from"] = range.Get("from"), ["to"] = range.Get("to"), ["filters"] = filters };
        // compare=false is the older spelling of off.
        string raw2 = parameters.Get("compare") ?? "previous";
        string mode = raw2 == "false" ? "off" : raw2;
        if (!Time.CompareModes.Contains(mode))
        {
            return Coded("Bad compare \"" + raw2 + "\". Use previous, year, custom, or off.", "compare_bad", 400, new JsObject { ["compare"] = raw2 });
        }
        var compared = Time.CompareRange(range, mode, timezone, parameters.Get("compare_from"), parameters.Get("compare_to"));
        if (mode == "custom" && compared == null)
        {
            return Coded("Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.", "compare_range_bad", 400);
        }
        return new Read(query, range, compared);
    }

    /// <summary>The body as a JSON object, or a refusal.</summary>
    private static object ReadJson(Request request)
    {
        // A form posted from another site cannot carry this content type without CORS.
        if (!IsJson(request))
        {
            return Coded("Send JSON", "send_json", 415);
        }
        return Js.ParseJson(request.Text(), out object? body) && body is JsObject o ? o : Coded("Send a JSON object", "send_object", 400);
    }

    private async Task<List<string>> OwnDomainsAsync(string siteId, CancellationToken cancellationToken) =>
        [.. (await Store.LinkDomainsAsync(cancellationToken).ConfigureAwait(false)).Where(d => d.Str("site") == siteId).Select(d => d.Str("domain")!)];

    private async Task<Response> LinksApiAsync(Request request, string path, Url url, CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        object siteOrRefusal = QuerySite(url);
        if (siteOrRefusal is not JsObject site)
        {
            return (Response)siteOrRefusal;
        }
        string siteId = site.Str("id")!;
        var store = Store;
        try
        {
            if (path == "/api/link-domains")
            {
                if (request.Method == "GET")
                {
                    return JsonResponse(new JsObject { ["domains"] = ToList(await OwnDomainsAsync(siteId, cancellationToken).ConfigureAwait(false)) });
                }
                if (request.Method == "POST")
                {
                    object parsedBody = ReadJson(request);
                    if (parsedBody is not JsObject body)
                    {
                        return (Response)parsedBody;
                    }
                    string domain = Js.Lower(Js.Trim(Text(body, "domain")));
                    domain = HttpPrefix.Replace(domain, "");
                    domain = PathAfter.Replace(domain, "", 1);
                    domain = DotsEnd.Replace(domain, "");
                    domain = Www.Replace(domain, "");
                    if (!DomainName.IsMatch(domain))
                    {
                        return Coded("That is not a domain name", "domain_invalid", 400);
                    }
                    if (PrivateName(domain) || await Safefetch.ResolvesPrivatelyAsync(domain).ConfigureAwait(false))
                    {
                        return Coded(domain + " is not a public domain name. Use one that browsers anywhere can reach.", "domain_not_public", 400, new JsObject { ["domain"] = domain });
                    }
                    // A link domain answers every path on it, so it must never be where the dashboard or a counted site lives.
                    // The request's own Host is the caller's to choose, so the configured address and the names people
                    // signed in from count too. A hub cannot know every name this app answers on, so it adds none until
                    // the app knows its own address.
                    if (_managed.TryGetValue(request, out _) && _origin == null)
                    {
                        return OriginNeeded();
                    }
                    var own = new List<string>();
                    if (_origin != null)
                    {
                        own.Add(new Url(_origin).Host);
                    }
                    foreach (string? h in new[] { request.Headers.Get("host"), request.Headers.Get("x-forwarded-host"), url.Host })
                    {
                        if (!string.IsNullOrEmpty(h))
                        {
                            own.Add(h);
                        }
                    }
                    if (_options.OwnHosts != null)
                    {
                        own.AddRange(_options.OwnHosts());
                    }
                    var taken = own.Select(HostName).ToList();
                    foreach (var s in Sites())
                    {
                        taken.AddRange(s.Arr("hostnames")?.Select(Js.String) ?? []);
                        taken.AddRange(_rl.Remote(s.Str("id")!)?.Arr("hostnames")?.Select(Js.String) ?? []);
                    }
                    if (taken.Contains(domain))
                    {
                        return Coded(domain + " is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go." + domain + ".", "domain_in_use", 400, new JsObject { ["domain"] = domain });
                    }
                    foreach (var d in await store.LinkDomainsAsync(cancellationToken).ConfigureAwait(false))
                    {
                        if (d.Str("domain") == domain)
                        {
                            if (d.Str("site") != siteId)
                            {
                                return Coded(domain + " already belongs to another site", "domain_taken", 409, new JsObject { ["domain"] = domain });
                            }
                            break;
                        }
                    }
                    await store.AddLinkDomainAsync(domain, siteId, _rl.Now(), cancellationToken).ConfigureAwait(false);
                    _rl.ForgetLinkDomains();
                    return JsonResponse(new JsObject { ["domain"] = domain }, 201);
                }
            }
            var checkMatch = CheckPath.Match(path);
            if (checkMatch.Success && request.Method == "GET")
            {
                string domain = Decode(checkMatch.Groups[1].Value);
                if (!(await OwnDomainsAsync(siteId, cancellationToken).ConfigureAwait(false)).Contains(domain))
                {
                    return Coded("Unknown domain", "unknown_domain", 404);
                }
                // One added before names inside private networks were refused is never fetched.
                // What the check found, as a code the dashboard says in its own words, beside the English reason.
                // Where the domain should point, for the setup steps: this server's name, and its public addresses
                // for a bare domain, which takes an A record. A server reached by its address has no name to give.
                string ownHost = _origin != null ? new Url(_origin).Hostname : url.Hostname;
                var target = new JsObject { ["host"] = ownHost, ["addresses"] = ToList(await Safefetch.PublicAddressesAsync(ownHost).ConfigureAwait(false)) };
                Response Result(string code, string reason, JsObject? parameters = null)
                {
                    var output = new JsObject { ["domain"] = domain, ["working"] = code.Length == 0, ["reason"] = reason, ["target"] = target };
                    if (code.Length > 0)
                    {
                        output["code"] = code;
                        if (parameters != null)
                        {
                            output["params"] = parameters;
                        }
                    }
                    return JsonResponse(output);
                }
                if (!DomainName.IsMatch(domain) || PrivateName(domain))
                {
                    return Result("check_not_public", "is not a public domain name");
                }
                try
                {
                    // Only a public address is fetched, whatever the name resolves to now, so the check cannot be pointed
                    // into a private network.
                    var answer = await Safefetch.PublicFetchAsync("https://" + domain + LinkDomainCheck, new PublicFetchInit { TimeoutMs = 5000 }, _rl.Fetcher, cancellationToken).ConfigureAwait(false);
                    JsObject? body = null;
                    try
                    {
                        if (Js.ParseJson(await answer.BytesAsync(cancellationToken).ConfigureAwait(false), out object? parsed) && parsed is JsObject o)
                        {
                            body = o;
                        }
                    }
                    catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
                    {
                        body = null;
                    }
                    if (answer.Ok && body != null && body.Get("runlight") is true && body.Get("domain") is string named && named == domain)
                    {
                        return Result("", "");
                    }
                    return answer.Ok ? Result("check_not_runlight", "answered, but not from Runlight") : Result("check_status", "answered " + Js.Str(answer.Status), new JsObject { ["status"] = Js.Str(answer.Status) });
                }
                catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
                {
                    // A refused private address answers as a closed port does, so the check tells nothing about a private network.
                    return error is FetchException { TimedOut: true } ? Result("check_timeout", "timed out") : Result("check_https", "could not connect over HTTPS");
                }
            }

            var domainMatch = DomainPath.Match(path);
            if (domainMatch.Success && request.Method == "DELETE")
            {
                string domain = Decode(domainMatch.Groups[1].Value);
                if (!(await OwnDomainsAsync(siteId, cancellationToken).ConfigureAwait(false)).Contains(domain))
                {
                    return Coded("Unknown domain", "unknown_domain", 404);
                }
                await store.RemoveLinkDomainAsync(domain, cancellationToken).ConfigureAwait(false);
                _rl.ForgetLinkDomains();
                return JsonResponse(new JsObject { ["ok"] = true });
            }

            if (path == "/api/links")
            {
                if (request.Method == "GET")
                {
                    object readOrRefusal = await ReadQueryAsync(url, site, cancellationToken).ConfigureAwait(false);
                    if (readOrRefusal is not Read read)
                    {
                        return (Response)readOrRefusal;
                    }
                    var links = await store.LinksAsync(siteId, read.Range.Long("from"), read.Range.Long("to"), cancellationToken).ConfigureAwait(false);
                    // Links on a removed domain are served from the app's own path until it is added back.
                    return JsonResponse(new JsObject { ["prefix"] = url.Origin + _rl.LinkPath, ["domains"] = ToList(await OwnDomainsAsync(siteId, cancellationToken).ConfigureAwait(false)), ["links"] = ToList(links) });
                }
                if (request.Method == "POST")
                {
                    object parsedBody = ReadJson(request);
                    if (parsedBody is not JsObject body)
                    {
                        return (Response)parsedBody;
                    }
                    var input = new JsObject { ["url"] = Text(body, "url") };
                    foreach (string key in new[] { "name", "slug", "domain" })
                    {
                        if (Defined(body, key))
                        {
                            input[key] = Js.String(body.Get(key));
                        }
                    }
                    var link = await _rl.Links.CreateAsync(siteId, input, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["link"] = link }, 201);
                }
            }

            // One step of an import from another shortener; the page calls again with the cursor.
            var importMatch = ImportPath.Match(path);
            if (importMatch.Success && request.Method == "POST")
            {
                object parsedBody = ReadJson(request);
                if (parsedBody is not JsObject body)
                {
                    return (Response)parsedBody;
                }
                object? cursor = body.Prop("cursor");
                double done = Js.Number(body.Prop("done"));
                try
                {
                    var step = await Importers.Index.ImportStepAsync(_rl, siteId, importMatch.Groups[1].Value, Credentials(body.Prop("credentials")), cursor as string, double.IsNaN(done) ? 0 : done, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(step);
                }
                catch (ImportError error)
                {
                    return Refused(error, "import_failed");
                }
            }

            if (path == "/api/links/import" && request.Method == "POST")
            {
                object parsedBody = ReadJson(request);
                if (parsedBody is not JsObject body)
                {
                    return (Response)parsedBody;
                }
                // Rows that are not objects (null, a number) are dropped rather than failing the import.
                if (body.Prop("rows") is not List<object?> given)
                {
                    return Coded("Send rows as a list", "rows_needed", 400);
                }
                var rows = given.Where(row => row is JsObject).Take(5000).ToList();
                return JsonResponse(await _rl.Links.ImportAsync(siteId, rows, cancellationToken).ConfigureAwait(false));
            }

            var linkMatch = LinkPath.Match(path);
            if (linkMatch.Success)
            {
                string id = linkMatch.Groups[1].Value;
                if (request.Method == "GET")
                {
                    var link = await store.LinkByIdAsync(id, cancellationToken).ConfigureAwait(false);
                    if (link == null || link.Str("site") != siteId)
                    {
                        return Coded("Unknown link", "unknown_link", 404);
                    }
                    object readOrRefusal = await ReadQueryAsync(url, site, cancellationToken).ConfigureAwait(false);
                    if (readOrRefusal is not Read read)
                    {
                        return (Response)readOrRefusal;
                    }
                    var range = read.Range;
                    string timezone = site.Str("timezone")!;
                    async Task<List<object?>> By(string dimension) => Query.IsSessionDimension(dimension)
                        ? ToList(await store.LinkBreakdownAsync(siteId, id, range.Long("from"), range.Long("to"), dimension, 10, cancellationToken).ConfigureAwait(false))
                        : [];
                    var series = await store.LinkSeriesAsync(siteId, id, Time.Buckets(range, timezone), cancellationToken).ConfigureAwait(false);
                    double clicks = 0;
                    foreach (var p in series)
                    {
                        clicks += Js.Num(p.Get("clicks"));
                    }
                    return JsonResponse(new JsObject
                    {
                        ["link"] = link,
                        ["range"] = RangeOut(range, timezone),
                        ["clicks"] = clicks,
                        ["series"] = ToList(series),
                        ["sources"] = await By("source").ConfigureAwait(false),
                        ["referrers"] = await By("referrer").ConfigureAwait(false),
                        ["countries"] = await By("country").ConfigureAwait(false),
                        ["devices"] = await By("device").ConfigureAwait(false),
                        ["browsers"] = await By("browser").ConfigureAwait(false),
                    });
                }
                var owned = await store.LinkByIdAsync(id, cancellationToken).ConfigureAwait(false);
                if (owned == null || owned.Str("site") != siteId)
                {
                    return Coded("Unknown link", "unknown_link", 404);
                }
                if (request.Method == "PATCH")
                {
                    object parsedBody = ReadJson(request);
                    if (parsedBody is not JsObject body)
                    {
                        return (Response)parsedBody;
                    }
                    var patch = new JsObject();
                    foreach (string key in new[] { "url", "name", "slug", "domain" })
                    {
                        if (Defined(body, key))
                        {
                            patch[key] = Js.String(body.Get(key));
                        }
                    }
                    return JsonResponse(new JsObject { ["link"] = await _rl.Links.UpdateAsync(id, patch, cancellationToken).ConfigureAwait(false) });
                }
                if (request.Method == "DELETE")
                {
                    await _rl.Links.RemoveAsync(id, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["ok"] = true });
                }
            }
        }
        catch (LinkError error)
        {
            return Coded(error.Message, error.Code, 400, error.Params);
        }
        catch (ArgumentOutOfRangeException error)
        {
            return Coded(error.Message, "unknown_link", 404);
        }
        return Coded("Not found", "not_found", 404);
    }

    private static List<object?> ToList<T>(IEnumerable<T> items) => [.. items.Select(i => (object?)i)];

    private static JsObject RangeOut(JsObject range, string timezone) =>
        new() { ["from"] = range.Get("fromDate"), ["to"] = range.Get("toDate"), ["interval"] = range.Get("interval"), ["timezone"] = timezone };

    /// <summary>The key picker tickets are signed with, made on first use and kept in the database for every process.</summary>
    private async Task<string> PickKeyAsync(CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        string? saved = await Store.SettingAsync("pick-key", cancellationToken).ConfigureAwait(false);
        if (!string.IsNullOrEmpty(saved))
        {
            return saved;
        }
        string made = Hash.RandomId(32);
        await Store.SetSettingAsync("pick-key", made, cancellationToken).ConfigureAwait(false);
        return made;
    }

    private static string Hex(string text) => Convert.ToHexStringLower(Js.Utf8(text));

    private static string Unhex(string text) => Js.Decode(Convert.FromHexString(text[..(text.Length - (text.Length % 2))]));

    /// <summary>A ticket that lets the picker, on <paramref name="site"/>'s pages, send its choice to <paramref name="origin"/>, the dashboard that asked, for half an hour.</summary>
    private async Task<string> PickTicketAsync(string origin, string site, CancellationToken cancellationToken)
    {
        string payload = Js.Str(_rl.Now() + PickTicketMs) + "." + Hex(site) + "." + Hex(origin);
        return payload + "." + Hash.Hmac(await PickKeyAsync(cancellationToken).ConfigureAwait(false), payload);
    }

    /// <summary>The dashboard origin and site a picker ticket names, or null when it is not one this install signed or has run out.</summary>
    private async Task<(string Origin, string Site)?> PickTargetAsync(string ticket, CancellationToken cancellationToken)
    {
        var parts = Ticket.Match(ticket);
        if (!parts.Success || Js.Number(parts.Groups[1].Value) < _rl.Now())
        {
            return null;
        }
        if (!ConstantTimeEqual(parts.Groups[4].Value, Hash.Hmac(await PickKeyAsync(cancellationToken).ConfigureAwait(false), parts.Groups[1].Value + "." + parts.Groups[2].Value + "." + parts.Groups[3].Value)))
        {
            return null;
        }
        string origin = Unhex(parts.Groups[3].Value);
        return IsOrigin(origin) ? (origin, Unhex(parts.Groups[2].Value)) : null;
    }

    /// <summary>
    /// The tracker with click rules inside, rebuilt when goals change. With ?site= it carries only that site's rules,
    /// so one site's visitors never see another site's domains or goals. The standalone server's snippet always names
    /// the site; without a name it serves no rules, and an app's own install, whose sites all belong to one owner,
    /// serves every site's.
    /// </summary>
    private async Task<TrackerScript> TrackerScriptAsync(string? siteId, CancellationToken cancellationToken)
    {
        string key = siteId ?? "";
        lock (_trackers)
        {
            if (_trackers.TryGetValue(key, out var cached) && _rl.Now() - cached.At < 60_000)
            {
                return cached;
            }
        }
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        var sites = siteId != null ? Sites().Where(s => s.Str("id") == siteId).ToList() : (_rl.ManagedSites ? [] : Sites());
        string rules = global::Runlight.Json.Stringify(Goals.ClickRules(sites, await Store.GoalsAsync(null, cancellationToken).ConfigureAwait(false)));
        string body = ReplaceOnce(Assets.Text("tracker.js"), RulesPlaceholder, rules);
        var script = new TrackerScript(body, "\"" + BuildHash("trackerHash") + "-" + Hash.Sha256(rules)[..8] + "\"", _rl.Now());
        // One entry per site at most; a query naming no real site gets the empty script without filling the map.
        if (siteId == null || sites.Count > 0)
        {
            lock (_trackers)
            {
                _trackers[key] = script;
            }
        }
        return script;
    }

    private async Task<Response> GoalWritesAsync(Request request, string path, Url url, CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        object siteOrRefusal = QuerySite(url);
        if (siteOrRefusal is not JsObject site)
        {
            return (Response)siteOrRefusal;
        }
        var existing = await Store.GoalsAsync(site.Str("id"), cancellationToken).ConfigureAwait(false);
        string? id = path == "/api/goals" ? null : Decode(path["/api/goals/".Length..]);
        JsObject? before = null;
        foreach (var g in existing)
        {
            if (g.Str("id") == id)
            {
                before = g;
            }
        }
        if (id != null && before == null)
        {
            return Coded("Unknown goal", "unknown_goal", 404);
        }
        lock (_trackers)
        {
            _trackers.Clear();
        }
        if (request.Method == "DELETE")
        {
            await Store.DeleteGoalAsync(id!, cancellationToken).ConfigureAwait(false);
            return JsonResponse(new JsObject { ["ok"] = true });
        }
        object parsedBody = ReadJson(request);
        if (parsedBody is not JsObject body)
        {
            return (Response)parsedBody;
        }
        try
        {
            var goal = Goals.GoalFrom(body, site.Str("id")!, existing, _rl.Now(), id);
            await Store.SaveGoalAsync(goal, before, cancellationToken).ConfigureAwait(false);
            return JsonResponse(new JsObject { ["goal"] = goal }, !string.IsNullOrEmpty(id) ? 200 : 201);
        }
        catch (GoalError error)
        {
            return Refused(error, "goal_invalid");
        }
    }

    private static JsObject ReportView(JsObject r) => new()
    {
        ["id"] = r.Get("id"),
        ["site"] = r.Get("site"),
        ["email"] = r.Get("email"),
        ["frequency"] = r.Get("frequency"),
        ["lang"] = r.Get("lang"),
        ["lastSentAt"] = r.Get("lastSentAt"),
        ["createdAt"] = r.Get("createdAt"),
    };

    private async Task<Response> MailApiAsync(Request request, string path, Url url, CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (path == "/api/mail")
            {
                if (request.Method == "GET")
                {
                    var settings = await _rl.MailSettingsAsync(cancellationToken).ConfigureAwait(false);
                    object? serviceId = Or(settings, "service", null);
                    var service = Transports.Services.FirstOrDefault(s => serviceId is string sid && s.Str("id") == sid);
                    // Secret fields come back only as "saved", never as their value.
                    var fields = new JsObject();
                    var saved = new List<object?>();
                    foreach (var f in service?.Arr("fields")?.OfType<JsObject>() ?? [])
                    {
                        string name = f.Str("name")!;
                        if (Js.Truthy(f.Get("secret")))
                        {
                            if (Js.Truthy(Or(settings, name, null)))
                            {
                                saved.Add(name);
                            }
                        }
                        else
                        {
                            object? value = Or(settings, name, null);
                            fields[name] = value == null ? "" : Js.String(value);
                        }
                    }
                    // A hub with a manage token learns which service sends the reports and from where, nothing more.
                    bool viaManage = _managed.TryGetValue(request, out _);
                    return JsonResponse(new JsObject
                    {
                        ["source"] = Or(settings, "source", null),
                        ["service"] = Or(settings, "service", ""),
                        ["from"] = Or(settings, "from", ""),
                        ["fromName"] = Or(settings, "fromName", ""),
                        ["fields"] = viaManage ? new JsObject() : fields,
                        ["saved"] = viaManage ? new List<object?>() : saved,
                        ["encrypted"] = _rl.Secret != null,
                        ["services"] = ToList(Transports.Services),
                    });
                }
                if (request.Method == "PUT")
                {
                    object parsedBody = ReadJson(request);
                    if (parsedBody is not JsObject body)
                    {
                        return (Response)parsedBody;
                    }
                    await _rl.SaveMailSettingsAsync(body, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["ok"] = true });
                }
                if (request.Method == "DELETE")
                {
                    await _rl.SaveMailSettingsAsync(null, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["ok"] = true });
                }
                return Coded("Method not allowed", "method_not_allowed", 405);
            }

            if (path == "/api/mail/test" && request.Method == "POST")
            {
                object parsedBody = ReadJson(request);
                if (parsedBody is not JsObject body)
                {
                    return (Response)parsedBody;
                }
                string to = Js.Trim(Text(body, "to"));
                if (!IsEmail(to))
                {
                    return Coded("Enter an email address to send the test to", "test_email", 400);
                }
                var settings = await _rl.MailSettingsAsync(cancellationToken).ConfigureAwait(false);
                if (settings == null)
                {
                    return Coded("Set up a mail service first", "mail_unset", 400);
                }
                var t = Messages.Translator(Text(body, "lang", "en"));
                string name = "";
                foreach (var s in Transports.Services)
                {
                    if (Same(s.Get("id"), settings.Get("service")))
                    {
                        name = s.Str("name")!;
                        break;
                    }
                }
                await _rl.SendMailAsync(new JsObject
                {
                    ["to"] = to,
                    ["subject"] = t.T("email.test.subject"),
                    ["text"] = t.T("email.test.body", new JsObject { ["service"] = name }),
                    ["html"] = "<p style=\"font-family:sans-serif;font-size:15px\">" + EscapeHtml(t.T("email.test.body", new JsObject { ["service"] = name })) + "</p>",
                }, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["ok"] = true });
            }

            object siteOrRefusal = QuerySite(url);

            if (siteOrRefusal is not JsObject site)

            {

                return (Response)siteOrRefusal;

            }
            string siteId = site.Str("id")!;

            if (path == "/api/reports")
            {
                if (request.Method == "GET")
                {
                    var reports = await Store.ReportsAsync(siteId, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["reports"] = ToList(reports.Select(ReportView)), ["languages"] = ToList(Messages.Languages()) });
                }
                if (request.Method == "POST")
                {
                    object parsedBody = ReadJson(request);
                    if (parsedBody is not JsObject body)
                    {
                        return (Response)parsedBody;
                    }
                    string email = Js.Lower(Js.Trim(Text(body, "email")));
                    if (!IsEmail(email))
                    {
                        return Coded("Enter an email address", "email_invalid", 400);
                    }
                    string frequency = body.Get("frequency") is "monthly" ? "monthly" : "weekly";
                    var existing = await Store.ReportsAsync(siteId, cancellationToken).ConfigureAwait(false);
                    foreach (var r in existing)
                    {
                        if (r.Str("email") == email && r.Str("frequency") == frequency)
                        {
                            return Coded(email + " already gets the " + frequency + " report", "report_exists", 400, new JsObject { ["email"] = email });
                        }
                    }
                    if (existing.Count >= 50)
                    {
                        return Coded("A site can send to at most 50 addresses", "report_limit", 400);
                    }
                    // Links in the email point back to the configured address, or else to this dashboard as the
                    // browser sees it. A report made from a hub needs the configured address, where its unsubscribe
                    // link answers, since the Host its request names is the hub's to choose.
                    if (_managed.TryGetValue(request, out _) && _origin == null)
                    {
                        return OriginNeeded();
                    }
                    string given = _origin != null ? "" : Text(body, "origin");
                    string home = HttpAddress.IsMatch(given) ? TrailingSlashes.Replace(given, "") : (_origin ?? url.Origin) + _base;
                    // A period already due counts as sent, so a report added mid-week first goes out on the next Monday, as the form says.
                    long now = _rl.Now();
                    var due = Reports.LastPeriod(frequency, now, site.Str("timezone")!);
                    string lang = Js.String(body.Prop("lang"));
                    var report = new JsObject
                    {
                        ["id"] = Hash.RandomId(),
                        ["site"] = siteId,
                        ["email"] = email,
                        ["frequency"] = frequency,
                        ["lang"] = Messages.Languages().Contains(lang) ? lang : "en",
                        ["token"] = Hash.RandomId(16),
                        ["origin"] = home,
                        ["lastPeriod"] = now >= Js.Num(due.Get("dueAt")) ? due.Get("key") : "",
                        ["lastSentAt"] = null,
                        ["createdAt"] = now,
                    };
                    await Store.InsertReportAsync(report, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["report"] = ReportView(report) }, 201);
                }
                return Coded("Method not allowed", "method_not_allowed", 405);
            }

            var match = ReportPath.Match(path);
            var found = match.Success ? await Store.ReportByAsync("id", match.Groups[1].Value, cancellationToken).ConfigureAwait(false) : null;
            if (found == null || found.Str("site") != siteId)
            {
                return Coded("Unknown report", "unknown_report", 404);
            }
            bool send = match.Groups[2].Success && match.Groups[2].Value.Length > 0;
            if (send && request.Method == "POST")
            {
                // A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A hub
                // sends one every ten minutes for the whole site, so adding reports again does not start a new count.
                // When each went out is kept in the install's settings, so every process sees it.
                bool viaHub = _managed.TryGetValue(request, out _);
                string key = "sample-sent:" + (viaHub ? "site:" + siteId : found.Str("id"));
                long wait = viaHub ? 600_000 : 60_000;
                double last = Js.Number(await Store.SettingAsync(key, cancellationToken).ConfigureAwait(false) ?? "0");
                if (_rl.Now() - last < wait)
                {
                    return viaHub
                        ? Coded("A connected hub can send one sample every ten minutes. Wait a few minutes and try again.", "sample_soon_hub", 429)
                        : Coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429);
                }
                await Store.SetSettingAsync(key, Js.Str(_rl.Now()), cancellationToken).ConfigureAwait(false);
                await _rl.DeliverReportAsync(found, site, null, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["ok"] = true });
            }
            if (!send && request.Method == "DELETE")
            {
                await Store.DeleteReportAsync(found.Str("id")!, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["ok"] = true });
            }
            return Coded("Method not allowed", "method_not_allowed", 405);
        }
        catch (MailError error)
        {
            return Coded(error.Message, error.Code, 400, error.Params);
        }
    }

    private static bool Same(object? a, object? b) => a is string x && b is string y ? x == y : Equals(a, b);

    /// <summary>A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing.</summary>
    private async Task<Response> UnsubscribePageAsync(Request request, string token, CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        var report = Token32.IsMatch(token) ? await Store.ReportByAsync("token", token, cancellationToken).ConfigureAwait(false) : null;
        var site = report != null ? _rl.Site(report.Str("site")!) : null;
        var t = Messages.Translator(report?.Str("lang") ?? "en");
        Response Page(string body, int status = 200) => SmallPage(t.Lang, body, status);
        if (report == null || site == null)
        {
            return Page("<h1>" + EscapeHtml(t.T("email.unsub.goneTitle")) + "</h1><p>" + EscapeHtml(t.T("email.unsub.gone")) + "</p>", 404);
        }
        if (request.Method == "POST")
        {
            await Store.DeleteReportAsync(report.Str("id")!, cancellationToken).ConfigureAwait(false);
            return Page("<h1>" + EscapeHtml(t.T("email.unsub.doneTitle")) + "</h1><p>" + EscapeHtml(t.T("email.unsub.done", new JsObject { ["site"] = site.Get("name"), ["email"] = report.Get("email") })) + "</p>");
        }
        return Page(
            "<h1>" + EscapeHtml(t.T("email.unsub.title", new JsObject { ["site"] = site.Get("name") })) + "</h1><p>" + EscapeHtml(t.T("email.unsub.body", new JsObject { ["email"] = report.Get("email") })) + "</p><form method=\"post\"><button type=\"submit\">" + EscapeHtml(t.T("email.unsubscribe")) + "</button></form>");
    }

    private async Task<Response> SharesApiAsync(Request request, string path, Url url, CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        object siteOrRefusal = QuerySite(url);
        if (siteOrRefusal is not JsObject site)
        {
            return (Response)siteOrRefusal;
        }
        string siteId = site.Str("id")!;
        JsObject View(JsObject share) => share.With(new JsObject { ["path"] = _base + "/share/" + share.Str("id") });

        if (path == "/api/shares")
        {
            if (request.Method == "GET")
            {
                return JsonResponse(new JsObject { ["shares"] = ToList((await Store.SharesAsync(siteId, cancellationToken).ConfigureAwait(false)).Select(View)) });
            }
            if (request.Method == "POST")
            {
                object parsedBody = ReadJson(request);
                if (parsedBody is not JsObject body)
                {
                    return (Response)parsedBody;
                }
                var made = new JsObject { ["id"] = Hash.RandomId(16), ["site"] = siteId, ["name"] = Js.Slice(Js.Trim(Text(body, "name")), 0, 100), ["createdAt"] = _rl.Now() };
                await Store.InsertShareAsync(made, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["share"] = View(made) }, 201);
            }
            return Coded("Method not allowed", "method_not_allowed", 405);
        }

        string id = Decode(path["/api/shares/".Length..]);
        var share = ShareId.IsMatch(id) ? await Store.ShareByIdAsync(id, cancellationToken).ConfigureAwait(false) : null;
        if (share == null || share.Str("site") != siteId)
        {
            return Coded("Unknown share", "unknown_share", 404);
        }
        if (request.Method == "PATCH")
        {
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            string name = Js.Slice(Js.Trim(Text(body, "name")), 0, 100);
            await Store.RenameShareAsync(share.Str("id")!, name, cancellationToken).ConfigureAwait(false);
            share["name"] = name;
            return JsonResponse(new JsObject { ["share"] = View(share) });
        }
        if (request.Method == "DELETE")
        {
            await Store.DeleteShareAsync(share.Str("id")!, cancellationToken).ConfigureAwait(false);
            return JsonResponse(new JsObject { ["ok"] = true });
        }
        return Coded("Method not allowed", "method_not_allowed", 405);
    }

    /// <summary>How many questions each viewer may ask the assistant a day, as an owner set it.</summary>
    private async Task<double> ViewerDailyAsync(CancellationToken cancellationToken)
    {
        string? saved = await Store.SettingAsync("assistant-viewer-daily", cancellationToken).ConfigureAwait(false);
        return saved == null ? ViewerDailyDefault : Js.Number(saved);
    }

    /// <summary>
    /// Counts a question to the assistant, which spends the owner's AI credit, or refuses it: past thirty an
    /// hour or two at once for anyone, and past the owner's daily number for a viewer. Returns how to finish,
    /// or the refusal.
    ///
    /// The hour's questions are kept in the install's settings, so every process counts them;
    /// how many are being answered at once is counted in this process, where a request runs to its end.
    /// </summary>
    private async Task<object> AskTurnAsync(string who, bool owner, CancellationToken cancellationToken)
    {
        long now = _rl.Now();
        string hourKey = "assistant-hour:" + who;
        object? saved = global::Runlight.Json.TryParse(await Store.SettingAsync(hourKey, cancellationToken).ConfigureAwait(false) ?? "");
        var at = (saved as List<object?> ?? []).Where(t => t is long or int or double && now - Js.Num(t) < 3_600_000).ToList();
        int open;
        lock (_open)
        {
            open = _open.GetValueOrDefault(who);
        }
        if (at.Count >= AskPerHour || open >= AskAtOnce)
        {
            return Coded("You have asked a lot in a short time. Wait a little and ask again.", "assistant_soon", 429);
        }
        if (!owner)
        {
            double limit = await ViewerDailyAsync(cancellationToken).ConfigureAwait(false);
            string day = "assistant-asked:" + Js.IsoString(now)[..10];
            var counts = global::Runlight.Json.Parse(await Store.SettingAsync(day, cancellationToken).ConfigureAwait(false) ?? "{}") as JsObject ?? [];
            double asked = counts.Get(who) is { } n and not Undefined ? Js.Num(n) : 0;
            if (asked >= limit)
            {
                string said = Js.String(limit);
                return Coded("Viewers can ask " + said + " questions a day. Ask again tomorrow.", "assistant_daily", 429, new JsObject { ["limit"] = said });
            }
            counts[who] = asked + 1;
            await Store.SetSettingAsync(day, global::Runlight.Json.Stringify(counts), cancellationToken).ConfigureAwait(false);
            foreach (var entry in await Store.SettingsStartingWithAsync("assistant-asked:", cancellationToken).ConfigureAwait(false))
            {
                if (entry.Str("key") != day)
                {
                    await Store.SetSettingAsync(entry.Str("key")!, null, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        at.Add(now);
        await Store.SetSettingAsync(hourKey, global::Runlight.Json.Stringify(at), cancellationToken).ConfigureAwait(false);
        lock (_open)
        {
            _open[who] = _open.GetValueOrDefault(who) + 1;
        }
        return (Action)(() =>
        {
            lock (_open)
            {
                _open[who] = _open.GetValueOrDefault(who) - 1;
            }
        });
    }

    private async Task<Response> TokensApiAsync(Request request, string path, CancellationToken cancellationToken)
    {
        await _rl.InitAsync(cancellationToken).ConfigureAwait(false);
        static JsObject View(JsObject t) => new()
        {
            ["id"] = t.Get("id"),
            ["name"] = t.Get("name"),
            ["site"] = t.Get("site"),
            ["scope"] = t.Get("scope"),
            ["hint"] = t.Get("hint"),
            ["createdAt"] = t.Get("createdAt"),
            ["lastUsedAt"] = t.Get("lastUsedAt"),
        };
        if (path == "/api/tokens" && request.Method == "GET")
        {
            return JsonResponse(new JsObject { ["tokens"] = ToList((await Store.TokensAsync(cancellationToken).ConfigureAwait(false)).Select(View)) });
        }
        if (path == "/api/tokens" && request.Method == "POST")
        {
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            string name = Js.Slice(Js.Trim(Text(body, "name")), 0, 100);
            if (name.Length == 0)
            {
                return Coded("Name the token", "token_name", 400);
            }
            string site = Text(body, "site");
            if (site.Length > 0 && !Sites().Any(s => s.Str("id") == site))
            {
                return Coded("Unknown site", "unknown_site", 404);
            }
            string scope = body.Get("scope") is "manage" ? "manage" : "read";
            if (scope == "manage" && site.Length == 0)
            {
                return Coded("A token that changes settings is for one site. Pick the site.", "token_site", 400);
            }
            string secret = TokenPrefix + Hash.RandomId(20);
            var row = new JsObject
            {
                ["id"] = Hash.RandomId(),
                ["name"] = name,
                ["site"] = site,
                ["scope"] = scope,
                ["hash"] = Hash.Sha256(secret),
                ["hint"] = secret[^4..],
                ["createdAt"] = _rl.Now(),
                ["lastUsedAt"] = null,
            };
            await Store.InsertTokenAsync(row, cancellationToken).ConfigureAwait(false);
            string? by = _accountOf != null ? await _accountOf(request, cancellationToken).ConfigureAwait(false) : null;
            if (!string.IsNullOrEmpty(by) && _tokenMade != null && !await _tokenMade(row, by, cancellationToken).ConfigureAwait(false))
            {
                await Store.DeleteTokenAsync(row.Str("id")!, cancellationToken).ConfigureAwait(false);
                return Denied("read");
            }
            // The only time the token is ever shown.
            return JsonResponse(new JsObject { ["token"] = View(row), ["secret"] = secret }, 201);
        }
        var match = TokenPath.Match(path);
        if (match.Success && request.Method == "DELETE")
        {
            return await Store.DeleteTokenAsync(match.Groups[1].Value, cancellationToken).ConfigureAwait(false)
                ? JsonResponse(new JsObject { ["ok"] = true })
                : Coded("Unknown token", "unknown_token", 404);
        }
        return Coded("Not found", "not_found", 404);
    }

    /// <summary>A request for one API path, with the asker's own headers, as the MCP server and the assistant read it.</summary>
    private ApiRead ReadApi(Request request, Url url, string? defaultSite = null, CancellationToken cancellationToken = default)
    {
        var headers = new Headers(request.Headers);
        foreach (string name in new[] { "content-type", "content-length", ShareHeader })
        {
            headers.Delete(name);
        }
        return (apiPath, parameters) =>
        {
            var target = new Url(_base + apiPath, url.Origin);
            var query = target.SearchParams;
            foreach (var (key, value) in parameters)
            {
                query.Append(key, value);
            }
            // A tool that names no site reads the one on screen, not the install's first.
            if (defaultSite != null && apiPath != "/api/sites" && !query.Has("site"))
            {
                query.Set("site", defaultSite);
            }
            target.SetSearchParams(query);
            return ApiAsync(new Request(target.Href, "GET", headers, ""), apiPath, target, cancellationToken);
        };
    }

    private async Task<Response> ApiAsync(Request request, string path, Url url, CancellationToken cancellationToken)
    {
        var rl = _rl;
        string method = request.Method;
        // A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
        // That holds without a cookie too, since a browser also sends Basic credentials or comes from an
        // allowed address on its own. A bearer token is never sent by the browser on its own, so it needs no check.
        if (method is not ("GET" or "HEAD" or "OPTIONS" or "DELETE") && Bearer(request).Length == 0 && !IsJson(request))
        {
            return Coded("Send JSON", "send_json", 415);
        }
        if (path == "/api" && method == "GET")
        {
            return JsonResponse(new JsObject { ["name"] = "runlight", ["version"] = Version.Current, ["api"] = (long)Version.Api }.With(Implementation));
        }

        // A hub asks what its token may do before offering to change anything.
        if (path == "/api/token" && method == "GET")
        {
            var own = await ApiTokenAsync(request, cancellationToken).ConfigureAwait(false);
            if (own == null)
            {
                return Denied(false);
            }
            return JsonResponse(new JsObject { ["scope"] = own.Get("scope"), ["site"] = own.Get("site") });
        }
        // A token can delete itself, which a hub does when it disconnects a site or gets a new token.
        if (path == "/api/token" && method == "DELETE")
        {
            var own = await ApiTokenAsync(request, cancellationToken).ConfigureAwait(false);
            if (own == null)
            {
                return Denied(false);
            }
            await Store.DeleteTokenAsync(own.Str("id")!, cancellationToken).ConfigureAwait(false);
            return JsonResponse(new JsObject { ["ok"] = true });
        }

        // Connecting another Runlight through its consent page, so nobody copies a token.
        if (path == "/api/sites/connect" && method == "POST")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            if (!rl.ManagedSites)
            {
                return Coded("Sites are set in code", "sites_in_code", 400);
            }
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            object? site = body.Prop("site");
            object? given = body.Prop("url");
            try
            {
                string authorizeUrl = await Connect.StartConnectAsync(rl.Store, rl.Fetcher, rl.Now, given is Undefined ? null : given, url.Origin + _base + "/api/sites/connect/done", site as string ?? "", cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["authorize"] = authorizeUrl });
            }
            catch (ConnectError error)
            {
                return Coded(error.Message, error.Code == "unreachable" ? "unreachable" : "connect_" + error.Code, 400, error.Params);
            }
            catch (Exception error) when (IsRange(error))
            {
                return Refused(error, "connect_failed");
            }
        }
        if (path == "/api/sites/connect/done" && method == "GET")
        {
            string home = _base.Length > 0 ? _base : "/";
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return new Response("", 303, new Headers { ["location"] = home, ["cache-control"] = "no-store" });
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            string to;
            try
            {
                string id = await Connect.FinishConnectAsync(rl.Store, rl.Fetcher, rl.Now, input => rl.AddSiteAsync(input, cancellationToken), url.SearchParams, cancellationToken).ConfigureAwait(false);
                // The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
                to = home + "?site=" + Js.EncodeURIComponent(id) + "&settings=general&connected=1";
            }
            catch (Exception error) when (IsRange(error))
            {
                // A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
                to = home + "?connect_error=" + (error is ConnectError connect ? connect.Code : "failed");
            }
            return new Response("", 303, new Headers { ["location"] = to, ["cache-control"] = "no-store" });
        }

        var token = Bearer(request).StartsWith(TokenPrefix, StringComparison.Ordinal) ? await ApiTokenAsync(request, cancellationToken).ConfigureAwait(false) : null;
        if (token != null && token.Str("scope") == "manage" && ManagePath(method, path))
        {
            string? askedSite = url.SearchParams.Get("site");
            var siteMatch = SitePath.Match(path);
            if ((!string.IsNullOrEmpty(askedSite) && askedSite != token.Str("site")) || (siteMatch.Success && Decode(siteMatch.Groups[1].Value) != token.Str("site")))
            {
                return Coded("Unknown site", "unknown_site", 404);
            }
            if (siteMatch.Success && IsJson(request))
            {
                // Where a site lives stays with its owner: a hub may rename it, never move it.
                if (Js.ParseJson(request.Text(), out object? body) && Js.Truthy(body) && Js.IsObject(body) && Js.Get(body, "hostnames") is not Undefined)
                {
                    return Coded("A connected hub cannot change a site's domains", "hub_domains", 403);
                }
            }
            url = new Url(url.Href);
            var query = url.SearchParams;
            query.Set("site", Js.String(token.Get("site")));
            url.SetSearchParams(query);
            _managed.AddOrUpdate(request, token);
        }
        // A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
        if (token != null && !_managed.TryGetValue(request, out _) && method is not ("GET" or "HEAD" or "OPTIONS"))
        {
            return token.Str("scope") == "manage"
                ? Coded("A manage token changes only its own site's settings", "token_manage_only", 403)
                : Coded("API tokens can only read", "token_read_only", 403);
        }

        // A page another site served to an AI agent, reported by a CMS plugin.
        if (path == "/api/observe" && method == "POST")
        {
            return await ObserveApiAsync(request, cancellationToken).ConfigureAwait(false);
        }

        // GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
        if (path == "/api/check" && (method == "POST" || method == "GET"))
        {
            string given = Bearer(request);
            bool allowed = (!string.IsNullOrEmpty(_cronSecret) && given.Length > 0 && ConstantTimeEqual(given, _cronSecret))
                || await CanReadAsync(request, cancellationToken).ConfigureAwait(false) is true;
            if (!allowed)
            {
                return Coded("Unauthorized", "unauthorized", 401);
            }
            return JsonResponse(await rl.CheckAsync(cancellationToken).ConfigureAwait(false));
        }

        // A site counted by another install is read there. Its settings change there too,
        // through this server when the install gave a manage token, and only by an owner here.
        string? asked = url.SearchParams.Get("site");
        var connected = !string.IsNullOrEmpty(asked) ? rl.Remote(asked) : null;
        if (connected != null && connected.Str("scope") == "manage" && ManagePath(method, path) && !(method == "GET" && SharedPath(path)))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            if (method != "GET")
            {
                rl.ForgetRemoteInfo(asked!);
            }
            return await PassThroughAsync(connected, path, url, request, cancellationToken).ConfigureAwait(false);
        }
        if (connected != null && !(method == "GET" && (SharedPath(path) || path == "/api/links")))
        {
            return Coded("This site is counted by its own Runlight. Connect it again from its settings to change it from here.", "site_remote", 400);
        }

        // Visit history from Umami: list the account's websites, then import one a step at a time.
        if ((path == "/api/import/umami/websites" || path == "/api/import/umami/visits") && method == "POST")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            var credentials = Credentials(body.Prop("credentials"));
            try
            {
                if (path == "/api/import/umami/websites")
                {
                    return JsonResponse(new JsObject { ["websites"] = ToList(await Visits.UmamiWebsitesAsync(credentials, rl.Fetcher, cancellationToken).ConfigureAwait(false)) });
                }
                await rl.InitAsync(cancellationToken).ConfigureAwait(false);
                object siteOrRefusal = QuerySite(url);
                if (siteOrRefusal is not JsObject site)
                {
                    return (Response)siteOrRefusal;
                }
                return JsonResponse(await Visits.ImportUmamiVisitsAsync(rl, site.Str("id")!, credentials, Text(body, "website"), body.Prop("cursor") as string, cancellationToken).ConfigureAwait(false));
            }
            catch (ImportError error)
            {
                return Refused(error, "import_failed");
            }
        }

        // Visit history from a CSV file, a batch at a time.
        if (path == "/api/import/csv/visits" && method == "POST")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            object siteOrRefusal = QuerySite(url);
            if (siteOrRefusal is not JsObject site)
            {
                return (Response)siteOrRefusal;
            }
            try
            {
                object? rows = body.Prop("rows");
                return JsonResponse(await Visits.ImportCsvVisitsAsync(rl, site.Str("id")!, rows is Undefined ? null : rows, cancellationToken).ConfigureAwait(false));
            }
            catch (ImportError error)
            {
                return Refused(error, "import_failed");
            }
        }

        // Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
        if ((path == "/api/observe-key" && method == "GET") || (path == "/api/observe-key/new" && method == "POST"))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            object siteOrRefusal = QuerySite(url);
            if (siteOrRefusal is not JsObject site)
            {
                return (Response)siteOrRefusal;
            }
            string name = "observe-key:" + site.Str("id");
            string? key = path.EndsWith("/new", StringComparison.Ordinal) ? null : await Store.SettingAsync(name, cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrEmpty(key))
            {
                key = "rlo_" + Hash.RandomId(20);
                await Store.SetSettingAsync(name, key, cancellationToken).ConfigureAwait(false);
            }
            return JsonResponse(new JsObject { ["key"] = key });
        }

        // Making, changing, and deleting funnels; reading them is with the other reports.
        if ((path == "/api/funnels" && method == "POST") || (FunnelPath.IsMatch(path) && (method == "PATCH" || method == "DELETE")))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            object siteOrRefusal = QuerySite(url);
            if (siteOrRefusal is not JsObject site)
            {
                return (Response)siteOrRefusal;
            }
            var existing = await Store.FunnelsAsync(site.Str("id")!, cancellationToken).ConfigureAwait(false);
            string? id = path == "/api/funnels" ? null : path["/api/funnels/".Length..];
            if (id != null && !existing.Any(f => f.Str("id") == id))
            {
                return Coded("Unknown funnel", "unknown_funnel", 404);
            }
            if (method == "DELETE")
            {
                await Store.DeleteFunnelAsync(id!, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["ok"] = true });
            }
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            try
            {
                var funnel = Funnels.FunnelFrom(body, site.Str("id")!, existing, rl.Now(), id);
                await Store.SaveFunnelAsync(funnel, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["funnel"] = funnel }, id != null ? 200 : 201);
            }
            catch (FunnelError error)
            {
                return Refused(error, "funnel_invalid");
            }
        }

        // The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
        if (path == "/api/assistant")
        {
            object self = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            // A member uses the assistant like anyone else, but its settings are for owners and admins.
            bool owner = self is true && !IsMember(request);
            if (method == "GET")
            {
                object access = await ReaderAsync(request, cancellationToken).ConfigureAwait(false);
                if (Refuses(access))
                {
                    return Denied(access);
                }
                // Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
                if (access is JsObject reader && reader.Str("id") != "")
                {
                    return Coded("Only the dashboard can use the assistant", "assistant_dashboard", 403);
                }
                await rl.InitAsync(cancellationToken).ConfigureAwait(false);
                var settings = await rl.AssistantSettingsAsync(cancellationToken).ConfigureAwait(false);
                if (!owner)
                {
                    return JsonResponse(new JsObject { ["configured"] = settings != null });
                }
                return JsonResponse(new JsObject
                {
                    ["configured"] = settings != null,
                    ["viewerDaily"] = await ViewerDailyAsync(cancellationToken).ConfigureAwait(false),
                    ["provider"] = Or(settings, "provider", ""),
                    ["model"] = Or(settings, "model", ""),
                    ["baseUrl"] = Or(settings, "baseUrl", ""),
                    ["keySaved"] = Js.Truthy(Or(settings, "key", null)),
                    ["encrypted"] = rl.Secret != null,
                    ["providers"] = ToList(Assistant.Providers.Select(p => new JsObject { ["id"] = p.Id, ["name"] = p.Name, ["protocol"] = p.Protocol, ["baseUrl"] = p.BaseUrl, ["model"] = p.Model, ["key"] = p.Key })),
                });
            }
            if (!owner)
            {
                return self is true ? Coded("Only an owner or admin can change this", "admin_only", 403) : Denied(self);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            if (method == "DELETE")
            {
                await rl.SaveAssistantSettingsAsync(null, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["ok"] = true });
            }
            if (method == "PUT")
            {
                object parsedBody = ReadJson(request);
                if (parsedBody is not JsObject body)
                {
                    return (Response)parsedBody;
                }
                try
                {
                    await rl.SaveAssistantSettingsAsync(body, cancellationToken).ConfigureAwait(false);
                    return JsonResponse(new JsObject { ["ok"] = true });
                }
                catch (Exception error) when (IsRange(error))
                {
                    return Refused(error, "assistant_invalid");
                }
            }
            return Coded("Method not allowed", "method_not_allowed", 405);
        }
        // How many questions each viewer may ask a day; 0 keeps the assistant for owners.
        if (path == "/api/assistant/limits" && method == "PUT")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            double daily = Js.Number(body.Prop("viewerDaily"));
            if (!Js.IsInteger(daily) || daily < 0 || daily > 1000)
            {
                return Coded("Use a whole number from 0 to 1,000", "assistant_limit", 400);
            }
            await Store.SetSettingAsync("assistant-viewer-daily", Js.String(daily), cancellationToken).ConfigureAwait(false);
            return JsonResponse(new JsObject { ["viewerDaily"] = daily });
        }
        // The models a service offers, for the setup form's dropdown. The key can be the one already saved.
        if (path == "/api/assistant/models" && method == "POST")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            string provider = Text(body, "provider");
            var saved = await rl.AssistantSettingsAsync(cancellationToken).ConfigureAwait(false);
            string baseUrl = TrailingSlashes.Replace(Js.Trim(Text(body, "baseUrl")), "");
            // The saved key only for the address it was saved with.
            bool sameAddress = saved != null && Same(saved.Get("provider"), provider) && (Js.Truthy(saved.Get("baseUrl")) ? Js.String(saved.Get("baseUrl")) : "") == baseUrl;
            string key = Js.Trim(Text(body, "key"));
            if (key.Length == 0)
            {
                key = sameAddress ? Js.String(saved!.Get("key") ?? "") : "";
            }
            try
            {
                var models = await Assistant.ListModelsAsync(new JsObject { ["provider"] = provider, ["baseUrl"] = Js.Trim(Text(body, "baseUrl")), ["key"] = key }, rl.Fetcher, cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["models"] = models });
            }
            catch (AssistantError error)
            {
                return Refused(error, "assistant_failed");
            }
        }
        if (path == "/api/assistant/chat" && method == "POST")
        {
            return await ChatAsync(request, url, cancellationToken).ConfigureAwait(false);
        }

        // Only the owner manages tokens: an API token cannot make or revoke one.
        if (path == "/api/tokens" || path.StartsWith("/api/tokens/", StringComparison.Ordinal))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            return await TokensApiAsync(request, path, cancellationToken).ConfigureAwait(false);
        }

        if (connected != null && path == "/api/links")
        {
            object access = await ReaderAsync(request, cancellationToken).ConfigureAwait(false);
            if (Refuses(access))
            {
                return Denied(access);
            }
            // A token limited to one site reads only that site's links, here as everywhere else.
            if (access is JsObject reader && reader.Str("site") != "" && reader.Str("site") != asked)
            {
                return Coded("Unknown site", "unknown_site", 404);
            }
            return await PassThroughAsync(connected, path, url, null, cancellationToken).ConfigureAwait(false);
        }

        // An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
        if (method == "GET" && (path == "/api/links" || LinkPath.IsMatch(path)))
        {
            object access = await ReaderAsync(request, cancellationToken).ConfigureAwait(false);
            if (Refuses(access))
            {
                return Denied(access);
            }
            if (access is JsObject reader)
            {
                await rl.InitAsync(cancellationToken).ConfigureAwait(false);
                string readerSite = reader.Str("site") ?? "";
                var site = rl.Site(url.SearchParams.Get("site") ?? (readerSite.Length > 0 ? readerSite : null));
                if (site == null || (readerSite.Length > 0 && site.Str("id") != readerSite))
                {
                    return Coded("Unknown site", "unknown_site", 404);
                }
                var scoped = new Url(url.Href);
                var query = scoped.SearchParams;
                query.Set("site", site.Str("id")!);
                scoped.SetSearchParams(query);
                return await LinksApiAsync(request, path, scoped, cancellationToken).ConfigureAwait(false);
            }
        }

        if (path == "/api/links" || path.StartsWith("/api/links/", StringComparison.Ordinal) || path == "/api/link-domains" || path.StartsWith("/api/link-domains/", StringComparison.Ordinal))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            return await LinksApiAsync(request, path, url, cancellationToken).ConfigureAwait(false);
        }

        if (path == "/api/mail" || path == "/api/mail/test" || path == "/api/reports" || path.StartsWith("/api/reports/", StringComparison.Ordinal))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            return await MailApiAsync(request, path, url, cancellationToken).ConfigureAwait(false);
        }

        // A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks the install
        // that serves the site's script, with its own origin, since that install signs what the script will trust.
        if (path == "/api/pick" && method == "POST")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            object siteOrRefusal = QuerySite(url);
            if (siteOrRefusal is not JsObject site)
            {
                return (Response)siteOrRefusal;
            }
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            string origin = Text(body, "origin");
            if (!IsOrigin(origin))
            {
                return Coded("Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400);
            }
            // A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
            if (_managed.TryGetValue(request, out var hub) && await Store.SettingAsync("token-origin:" + hub.Str("id"), cancellationToken).ConfigureAwait(false) != origin)
            {
                return Coded("This hub's address is not the one it connected from. Connect the site again from here.", "pick_hub", 403);
            }
            return JsonResponse(new JsObject { ["ticket"] = await PickTicketAsync(origin, site.Str("id")!, cancellationToken).ConfigureAwait(false) });
        }

        if ((path == "/api/goals" && method == "POST") || (AnyGoalPath.IsMatch(path) && (method == "PATCH" || method == "DELETE")))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            return await GoalWritesAsync(request, path, url, cancellationToken).ConfigureAwait(false);
        }

        if (path == "/api/shares" || path.StartsWith("/api/shares/", StringComparison.Ordinal))
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            return await SharesApiAsync(request, path, url, cancellationToken).ConfigureAwait(false);
        }

        // Adding and deleting sites, when they are managed in the dashboard.
        if (path == "/api/sites" && method == "POST")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            object parsedBody = ReadJson(request);
            if (parsedBody is not JsObject body)
            {
                return (Response)parsedBody;
            }
            try
            {
                return JsonResponse(new JsObject { ["site"] = await rl.AddSiteAsync(body, cancellationToken).ConfigureAwait(false) }, 201);
            }
            catch (Exception error) when (IsRange(error))
            {
                return Refused(error, "site_invalid");
            }
        }

        var deleteMatch = SitePath.Match(path);
        if (deleteMatch.Success && method == "DELETE")
        {
            object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
            if (access is not true)
            {
                return Denied(access);
            }
            try
            {
                await rl.DeleteSiteAsync(Decode(deleteMatch.Groups[1].Value), cancellationToken).ConfigureAwait(false);
                return JsonResponse(new JsObject { ["ok"] = true });
            }
            catch (Exception error) when (IsRange(error))
            {
                return error.Message == "Unknown site" ? Coded(error.Message, "unknown_site", 404) : Refused(error, "site_invalid");
            }
        }
        if (deleteMatch.Success && method == "PATCH")
        {
            return await PatchSiteAsync(request, deleteMatch.Groups[1].Value, url, cancellationToken).ConfigureAwait(false);
        }

        if (method != "GET")
        {
            return Coded("Method not allowed", "method_not_allowed", 405);
        }
        return await ReportsAsync(request, path, url, cancellationToken).ConfigureAwait(false);
    }

    private async Task<Response> ObserveApiAsync(Request request, CancellationToken cancellationToken)
    {
        var rl = _rl;
        string given = Bearer(request);
        // The install-wide key and the owner's access can report for any site.
        bool anySite = (!string.IsNullOrEmpty(_observeKey) && given.Length > 0 && ConstantTimeEqual(given, _observeKey))
            || await CanReadAsync(request, cancellationToken).ConfigureAwait(false) is true;
        if (!anySite && given.Length == 0)
        {
            return Coded("Unauthorized", "unauthorized", 401);
        }
        object parsedBody = ReadJson(request);
        if (parsedBody is not JsObject body)
        {
            return (Response)parsedBody;
        }
        // One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
        bool batch = body.Prop("fetches") is List<object?>;
        var list = batch ? (List<object?>)body.Get("fetches")! : [body];
        if (list.Count > 500)
        {
            return Coded("Send at most 500 fetches at a time", "observe_many", 413);
        }
        var pages = new List<(Url Page, string UserAgent, double? At)>();
        foreach (object? item in list)
        {
            object? Read(string key) => item is JsObject o ? o.Prop(key) : Undefined.Value;
            object? raw = Read("url");
            var page = Url.Parse(raw is null or Undefined ? "" : Js.String(raw));
            if (page == null || (page.Protocol != "https:" && page.Protocol != "http:"))
            {
                return Coded("Send the page's url", "observe_url", 400);
            }
            object? at = Read("at");
            double? when = at is long or int or double ? Js.Num(at) : (at is string s ? ImportHttp.ParseDate(s) : (double?)null);
            object? agent = Read("userAgent");
            pages.Add((page, Js.Slice(agent is null or Undefined ? "" : Js.String(agent), 0, 500), when != null && double.IsFinite(when.Value) ? when : null));
        }
        await rl.InitAsync(cancellationToken).ConfigureAwait(false);
        var keep = pages;
        if (!anySite)
        {
            // A site's own key reports only pages on that site's domains. Pages elsewhere in a batch (another
            // host in the same log, say) are skipped, not a reason to refuse the rest.
            string? keySite = null;
            foreach (var site in Sites())
            {
                string? key = await Store.SettingAsync("observe-key:" + site.Str("id"), cancellationToken).ConfigureAwait(false);
                if (!string.IsNullOrEmpty(key) && ConstantTimeEqual(given, key))
                {
                    keySite = site.Str("id");
                }
            }
            if (keySite == null)
            {
                return Coded("Unauthorized", "unauthorized", 401);
            }
            keep = [.. pages.Where(p => rl.SiteFor(p.Page.Hostname)?.Str("id") == keySite)];
            // A single report for another site's page is a misconfigured plugin, which should hear about it.
            if (!batch && keep.Count == 0)
            {
                return Coded("Unauthorized", "unauthorized", 401);
            }
        }
        long recorded = 0;
        foreach (var p in keep)
        {
            if (await rl.ObserveAsync(new Request(p.Page.Href, "GET", new Headers { ["user-agent"] = p.UserAgent }), p.At, cancellationToken).ConfigureAwait(false))
            {
                recorded++;
            }
        }
        // A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
        if (!batch)
        {
            return new Response("", 204);
        }
        return JsonResponse(new JsObject { ["recorded"] = recorded, ["skipped"] = pages.Count - recorded });
    }

    private async Task<Response> ChatAsync(Request request, Url url, CancellationToken cancellationToken)
    {
        var rl = _rl;
        object access = await ReaderAsync(request, cancellationToken).ConfigureAwait(false);
        if (Refuses(access))
        {
            return Denied(access);
        }
        if (access is JsObject reader && reader.Str("id") != "")
        {
            return Coded("Only the dashboard can use the assistant", "assistant_dashboard", 403);
        }
        if (request.Headers.Get(ShareHeader) != null)
        {
            return Coded("Not available on a shared dashboard", "share_not_available", 403);
        }
        await rl.InitAsync(cancellationToken).ConfigureAwait(false);
        var settings = await rl.AssistantSettingsAsync(cancellationToken).ConfigureAwait(false);
        if (settings == null)
        {
            return Coded("The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.", "assistant_unset", 400);
        }
        object parsedBody = ReadJson(request);
        if (parsedBody is not JsObject body)
        {
            return (Response)parsedBody;
        }
        string siteId = Text(body, "site");
        var site = rl.Site(siteId.Length > 0 ? siteId : null);
        if (site == null)
        {
            return Coded("Unknown site", "unknown_site", 404);
        }
        var messages = new List<JsObject>();
        if (body.Prop("messages") is List<object?> given)
        {
            foreach (object? m in given)
            {
                if (m is JsObject message && message.Get("role") is "user" or "assistant" && message.Get("content") is string content)
                {
                    messages.Add(new JsObject { ["role"] = message.Get("role"), ["content"] = content });
                }
            }
        }
        if (messages.Count == 0 || messages[^1].Str("role") != "user")
        {
            return Coded("Ask a question", "question_needed", 400);
        }
        bool owner = access is true;
        string? who = _accountOf != null ? await _accountOf(request, cancellationToken).ConfigureAwait(false) : null;
        object turn = await AskTurnAsync(who ?? (owner ? "owner" : "viewer"), owner, cancellationToken).ConfigureAwait(false);
        if (turn is Response refused)
        {
            return refused;
        }
        string language = Js.String(body.Prop("language"));
        try
        {
            string timezone = site.Str("timezone")!;
            var answer = await Assistant.ChatAsync(
                settings,
                messages,
                new JsObject
                {
                    ["site"] = new JsObject { ["id"] = site.Get("id"), ["name"] = site.Get("name"), ["timezone"] = timezone },
                    ["today"] = Time.LocalDate(rl.Now(), timezone),
                    ["view"] = Js.Slice(Text(body, "view", "the last 30 days"), 0, 200),
                    ["language"] = Language.IsMatch(language) ? language : "en",
                },
                // Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
                ReadApi(request, url, site.Str("id"), cancellationToken),
                rl.Fetcher,
                rl.Now,
                cancellationToken).ConfigureAwait(false);
            return JsonResponse(answer);
        }
        catch (AssistantError error)
        {
            return Refused(error, "assistant_failed", 502);
        }
        finally
        {
            ((Action)turn)();
        }
    }

    private async Task<Response> PatchSiteAsync(Request request, string rawId, Url url, CancellationToken cancellationToken)
    {
        var rl = _rl;
        object access = await CanReadAsync(request, cancellationToken).ConfigureAwait(false);
        if (access is not true)
        {
            return Denied(access);
        }
        // A form posted from another site cannot carry this content type without CORS.
        object parsedBody = ReadJson(request);
        if (parsedBody is not JsObject body)
        {
            return (Response)parsedBody;
        }
        await rl.InitAsync(cancellationToken).ConfigureAwait(false);
        // Every field is checked before any changes, since a shorter retention deletes visits at once.
        if (Defined(body, "name"))
        {
            string name = Js.Trim(Js.String(body.Get("name")));
            if (!(name.Length > 0 && name.Length <= 80))
            {
                return Coded("A site name is 1 to 80 characters", "site_name", 400);
            }
        }
        if (Defined(body, "timezone") && !Time.IsTimezone(Js.String(body.Get("timezone"))))
        {
            string timezone = Js.String(body.Get("timezone"));
            return Coded("Unknown timezone \"" + timezone + "\"", "unknown_timezone", 400, new JsObject { ["timezone"] = timezone });
        }
        object? retention = body.Prop("retentionMonths");
        if (retention is not Undefined && retention != null && !RetentionMonths.Any(m => m == Js.Number(retention)))
        {
            string months = string.Join(", ", RetentionMonths.Select(Js.Str));
            return Coded("Keep visits for " + months + " months, or forever", "retention_bad", 400, new JsObject { ["months"] = months });
        }
        try
        {
            string id = Decode(rawId);
            var remote = rl.Remote(id);
            // How long a connected site keeps visits, and the timezone its days follow, are the install's
            // settings: this server passes them on, and changes its own row only once the install took them.
            var forward = new JsObject();
            if (retention is not Undefined)
            {
                forward["retentionMonths"] = retention;
            }
            if (Defined(body, "timezone") && Js.String(body.Get("timezone")) != rl.Site(id)?.Str("timezone"))
            {
                forward["timezone"] = Js.String(body.Get("timezone"));
            }
            if (remote != null && forward.Count > 0)
            {
                if (remote.Str("scope") != "manage")
                {
                    return Coded("Connect this site again to change it from here", "connect_again", 400);
                }
                var answer = await PassThroughAsync(
                    remote,
                    "/api/sites/" + Js.EncodeURIComponent(Js.String(remote.Get("site"))),
                    new Url(url.Href),
                    new Request(request.Url, "PATCH", new Headers { ["content-type"] = "application/json" }, global::Runlight.Json.Stringify(forward)),
                    cancellationToken).ConfigureAwait(false);
                if (!answer.Ok)
                {
                    return answer;
                }
                rl.ForgetRemoteInfo(id);
            }
            else if (remote == null && retention is not Undefined)
            {
                await rl.SetRetentionAsync(id, retention == null ? null : Js.Number(retention), cancellationToken).ConfigureAwait(false);
            }
            var patch = new JsObject();
            if (Defined(body, "name"))
            {
                patch["name"] = Js.String(body.Get("name"));
            }
            if (Defined(body, "timezone"))
            {
                patch["timezone"] = Js.String(body.Get("timezone"));
            }
            if (Defined(body, "hostnames") && rl.ManagedSites)
            {
                patch["hostnames"] = body.Get("hostnames");
            }
            var site = await rl.UpdateSiteAsync(Decode(rawId), patch, cancellationToken).ConfigureAwait(false);
            // A connected site answers as the list shows it, so the dashboard keeps its install and domains.
            if (remote != null)
            {
                site["remote"] = remote.Get("url");
                site["remoteSite"] = remote.Get("site");
                site["manage"] = remote.Str("scope") == "manage";
                site["hostnames"] = remote.Get("hostnames");
            }
            return JsonResponse(new JsObject { ["site"] = site });
        }
        catch (Exception error) when (IsRange(error))
        {
            return error.Message == "Unknown site" ? Coded(error.Message, "unknown_site", 404) : Refused(error, "site_invalid");
        }
    }

    /// <summary>The reads: sites, stats, and every report, for the owner, a token, a viewer, or a share.</summary>
    private async Task<Response> ReportsAsync(Request request, string path, Url url, CancellationToken cancellationToken)
    {
        var rl = _rl;
        var store = Store;
        var parameters = url.SearchParams;
        await rl.InitAsync(cancellationToken).ConfigureAwait(false);
        // A shared dashboard sees exactly what its visitors see, even for someone signed in.
        string? shareId = request.Headers.Get(ShareHeader);
        JsObject? shared = null;
        // The one site a share or a site's API token may read; null for every site.
        string? only = null;
        if (shareId != null)
        {
            shared = ShareId.IsMatch(shareId) ? await store.ShareByIdAsync(shareId, cancellationToken).ConfigureAwait(false) : null;
            if (shared == null)
            {
                return Coded("This share link no longer works", "share_gone", 404);
            }
            if (!SharedPath(path))
            {
                return Coded("Not available on a shared dashboard", "share_not_available", 403);
            }
            only = shared.Str("site");
        }
        else
        {
            object access = await ReaderAsync(request, cancellationToken).ConfigureAwait(false);
            if (Refuses(access))
            {
                return Denied(access);
            }
            if (access is JsObject reader)
            {
                if (!SharedPath(path))
                {
                    return Coded("API tokens can only read", "token_read_only", 403);
                }
                only = reader.Str("site") is { Length: > 0 } s ? s : null;
            }
        }

        if (path == "/api/sites")
        {
            var visible = only != null ? Sites().Where(s => s.Str("id") == only).ToList() : Sites();
            var sites = new List<object?>();
            foreach (var site in visible)
            {
                string id = site.Str("id")!;
                var remote = rl.Remote(id);
                var row = site.Clone();
                // A connected install's address, so the dashboard can say where the site is counted.
                // Its domains as the install reported them, for the goal picker; tracker hits never match them here.
                if (remote != null && shared == null)
                {
                    row["remote"] = remote.Get("url");
                    row["remoteSite"] = remote.Get("site");
                    row["manage"] = remote.Str("scope") == "manage";
                    row["hostnames"] = remote.Get("hostnames");
                }
                // Hostnames say where the site lives; a share shows only its name.
                if (shared != null)
                {
                    row["hostnames"] = new List<object?>();
                }
                row["lastSeen"] = remote != null ? await rl.RemoteLastSeenAsync(id, cancellationToken).ConfigureAwait(false) : await store.LastSeenAsync(id, cancellationToken).ConfigureAwait(false);
                // Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
                if (shared == null)
                {
                    row["retentionMonths"] = remote != null ? Field(await rl.RemoteInfoAsync(id, cancellationToken).ConfigureAwait(false), "retentionMonths") : await rl.RetentionAsync(id, cancellationToken).ConfigureAwait(false);
                }
                // Whether a connected install still takes this server's token, so the dashboard offers to connect it
                // again only when it no longer does.
                if (remote != null && shared == null)
                {
                    row["connection"] = Field(await rl.RemoteInfoAsync(id, cancellationToken).ConfigureAwait(false), "connection");
                }
                sites.Add(row);
            }
            // A share never learns how the install is run.
            return JsonResponse(shared != null ? new JsObject { ["sites"] = sites } : new JsObject { ["sites"] = sites, ["managed"] = rl.ManagedSites });
        }

        JsObject? found;
        if (shared != null)
        {
            found = rl.Site(shared.Str("site"));
        }
        else if (only != null)
        {
            found = rl.Site(parameters.Get("site") ?? only);
        }
        else
        {
            object siteOrRefusal = QuerySite(url);
            if (siteOrRefusal is not JsObject queried)
            {
                return (Response)siteOrRefusal;
            }
            found = queried;
        }
        if (found == null || (only != null && found.Str("id") != only))
        {
            return Coded("Unknown site", "unknown_site", 404);
        }
        var current = found;
        string siteId = current.Str("id")!;
        string timezone = current.Str("timezone")!;
        var connected = rl.Remote(siteId);
        if (connected != null)
        {
            return await PassThroughAsync(connected, path, url, request, cancellationToken).ConfigureAwait(false);
        }

        if (path == "/api/icon")
        {
            string? host = current.Arr("hostnames") is { Count: > 0 } hosts ? hosts[0] as string : null;
            // Only a site's own domain, never the request's Host header, which a caller can write.
            var icon = !string.IsNullOrEmpty(host) ? await Icon.FetchIconAsync("https://" + host, rl.Now(), rl.Fetcher).ConfigureAwait(false) : null;
            if (icon == null)
            {
                return Coded("No icon", "icon_none", 404, null, new Headers { ["cache-control"] = "private, max-age=3600" });
            }
            return new Response(icon.Body, 200, new Headers
            {
                ["content-type"] = icon.Type,
                ["cache-control"] = "private, max-age=86400",
                // An SVG served from this origin must never run script.
                ["content-security-policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox",
                ["x-content-type-options"] = "nosniff",
            });
        }

        if (path == "/api/realtime")
        {
            return JsonResponse(await store.RealtimeAsync(siteId, rl.Now(), cancellationToken).ConfigureAwait(false));
        }

        object readOrRefusal = await ReadQueryAsync(url, current, cancellationToken).ConfigureAwait(false);

        if (readOrRefusal is not Read read)

        {

            return (Response)readOrRefusal;

        }
        var (query, range, compared) = (read.Query, read.Range, read.Compared);
        var rangeOut = RangeOut(range, timezone);
        object? compareOut = compared != null ? new JsObject { ["from"] = compared.Get("fromDate"), ["to"] = compared.Get("toDate") } : Undefined.Value;
        var before = compared != null ? query.With(new JsObject { ["from"] = compared.Get("from"), ["to"] = compared.Get("to") }) : null;

        if (path == "/api/stats")
        {
            var stats = await store.StatsAsync(query, cancellationToken).ConfigureAwait(false);
            object? previous = before != null ? await store.StatsAsync(before, cancellationToken).ConfigureAwait(false) : Undefined.Value;
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["compare"] = compareOut, ["stats"] = stats, ["previous"] = previous });
        }

        if (path == "/api/goals")
        {
            var goals = await store.GoalsAsync(siteId, cancellationToken).ConfigureAwait(false);
            double visitors = await store.VisitorsAsync(query, cancellationToken).ConfigureAwait(false);
            double previousVisitors = before != null ? await store.VisitorsAsync(before, cancellationToken).ConfigureAwait(false) : 0;
            // Every goal in one pass for the range, and one more for the comparison.
            var nowAll = await store.GoalTotalsAllAsync(query, goals, cancellationToken).ConfigureAwait(false);
            var beforeAll = before != null ? await store.GoalTotalsAllAsync(before, goals, cancellationToken).ConfigureAwait(false) : null;
            var rows = new List<object?>();
            foreach (var goal in goals)
            {
                string goalId = goal.Str("id")!;
                var now = nowAll[goalId];
                JsObject? then = beforeAll != null && beforeAll.TryGetValue(goalId, out var t) ? t : null;
                var row = goal.With(now);
                row["rate"] = visitors != 0 ? Js.Num(now.Get("visitors")) / visitors : 0L;
                row["previous"] = then != null ? then.With(new JsObject { ["rate"] = previousVisitors != 0 ? Js.Num(then.Get("visitors")) / previousVisitors : 0L }) : Undefined.Value;
                rows.Add(row);
            }
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["compare"] = compareOut, ["visitors"] = visitors, ["goals"] = rows });
        }

        var goalMatch = GoalIdPath.Match(path);
        if (goalMatch.Success)
        {
            var goal = await store.GoalByIdAsync(goalMatch.Groups[1].Value, cancellationToken).ConfigureAwait(false);
            if (goal == null || goal.Str("site") != siteId)
            {
                return Coded("Unknown goal", "unknown_goal", 404);
            }
            double visitors = await store.VisitorsAsync(query, cancellationToken).ConfigureAwait(false);
            var totals = await store.GoalTotalsAsync(query, goal, cancellationToken).ConfigureAwait(false);
            var series = await store.GoalSeriesAsync(query, goal, Time.Buckets(range, timezone), cancellationToken).ConfigureAwait(false);
            var sources = await store.GoalBreakdownAsync(query, goal, "source", 10, cancellationToken).ConfigureAwait(false);
            var channels = await store.GoalBreakdownAsync(query, goal, "channel", 10, cancellationToken).ConfigureAwait(false);
            var pages = await store.GoalBreakdownAsync(query, goal, "path", 10, cancellationToken).ConfigureAwait(false);
            totals["rate"] = visitors != 0 ? Js.Num(totals.Get("visitors")) / visitors : 0L;
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["goal"] = goal, ["totals"] = totals, ["series"] = ToList(series), ["sources"] = ToList(sources), ["channels"] = ToList(channels), ["pages"] = ToList(pages) });
        }

        if (path == "/api/series")
        {
            var points = await store.SeriesAsync(query, Time.Buckets(range, timezone), cancellationToken).ConfigureAwait(false);
            // Comparison points line up with the main ones by position.
            object? previous = compared != null ? ToList((await store.SeriesAsync(query, Time.Buckets(compared, timezone), cancellationToken).ConfigureAwait(false)).Take(points.Count)) : Undefined.Value;
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["compare"] = compareOut, ["points"] = ToList(points), ["previous"] = previous });
        }

        if (path == "/api/rhythm")
        {
            // Visits per weekday and hour, plus each cell's details for its tooltip.
            // Visitors are summed over the hours folded into a cell, so someone who
            // came on two Tuesdays at 2pm counts twice there.
            var grid = new double[7, 24];
            var cells = new double[7, 24, 4];
            foreach (var row in await store.HourlyAsync(query, cancellationToken).ConfigureAwait(false))
            {
                var (weekday, h) = Time.LocalWeekdayHour((long)(Js.Num(row.Get("quarter")) * 900_000), timezone);
                grid[weekday, h] += Js.Num(row.Get("visits"));
                cells[weekday, h, 0] += Js.Num(row.Get("visits"));
                cells[weekday, h, 1] += Js.Num(row.Get("visitors"));
                cells[weekday, h, 2] += Js.Num(row.Get("pageviews"));
                cells[weekday, h, 3] += Js.Num(row.Get("bounced"));
            }
            var gridOut = new List<object?>();
            var details = new List<object?>();
            for (int d = 0; d < 7; d++)
            {
                var gridDay = new List<object?>();
                var day = new List<object?>();
                for (int h = 0; h < 24; h++)
                {
                    gridDay.Add(grid[d, h]);
                    double visits = cells[d, h, 0];
                    day.Add(new JsObject { ["visits"] = visits, ["visitors"] = cells[d, h, 1], ["pageviews"] = cells[d, h, 2], ["bounceRate"] = visits != 0 ? cells[d, h, 3] / visits : 0 });
                }
                gridOut.Add(gridDay);
                details.Add(day);
            }
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["grid"] = gridOut, ["cells"] = details });
        }

        if (path == "/api/journeys")
        {
            var through = Through.Match(parameters.Get("through") ?? "");
            // Journeys reads the newest visits up to a cap; say when it was reached.
            var (rows, sampled) = await store.JourneyPagesAsync(query, Journeys.PagesPerVisit, cancellationToken).ConfigureAwait(false);
            var options = new JsObject { ["steps"] = parameters.Get("steps") is string steps ? Js.Number(steps) : 5L };
            if (Js.Truthy(parameters.Get("start")))
            {
                options["start"] = parameters.Get("start");
            }
            if (Js.Truthy(parameters.Get("end")))
            {
                options["end"] = parameters.Get("end");
            }
            if (through.Success)
            {
                options["through"] = new JsObject { ["step"] = Js.Number(through.Groups[1].Value), ["value"] = through.Groups[2].Value };
            }
            var answer = new JsObject { ["site"] = siteId, ["range"] = rangeOut };
            foreach (var (k, v) in Journeys.Of(rows, options))
            {
                if (!answer.Has(k))
                {
                    answer[k] = v;
                }
            }
            if (sampled)
            {
                answer["sampled"] = (long)SqlStore.JourneyVisits;
            }
            return JsonResponse(answer);
        }

        if (path == "/api/funnels")
        {
            // One funnel at a time, so a page of funnels never takes every database connection at once.
            var rows = new List<object?>();
            foreach (var funnel in await store.FunnelsAsync(siteId, cancellationToken).ConfigureAwait(false))
            {
                var counts = await store.FunnelCountsAsync(query, funnel, cancellationToken).ConfigureAwait(false);
                var steps = funnel.Arr("steps") ?? [];
                var withVisits = new List<object?>();
                for (int i = 0; i < steps.Count; i++)
                {
                    withVisits.Add(((JsObject)steps[i]!).With(new JsObject { ["visits"] = i < counts.Count ? counts[i] : Undefined.Value }));
                }
                var copy = funnel.Clone();
                copy["steps"] = withVisits;
                rows.Add(copy);
            }
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["funnels"] = rows });
        }

        if (path == "/api/event-props")
        {
            string evt = parameters.Get("event") ?? "";
            if (evt.Length == 0)
            {
                return Coded("Name the event", "event_needed", 400);
            }
            var keys = await store.EventPropKeysAsync(query, evt, cancellationToken).ConfigureAwait(false);
            string? asked = parameters.Get("key");
            // A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
            if (asked != null && !PropertyName.IsMatch(asked))
            {
                return Coded("Bad property name", "property_bad", 400);
            }
            string? key = asked ?? (keys.Count > 0 ? keys[0].Str("key") : null);
            double limit = Limit(parameters.Get("limit"), 100);
            var rows = !string.IsNullOrEmpty(key) ? await store.EventPropValuesAsync(query, evt, key, Whole(limit), cancellationToken).ConfigureAwait(false) : [];
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["event"] = evt, ["keys"] = ToList(keys), ["key"] = key, ["rows"] = ToList(rows) });
        }

        if (path == "/api/breakdown")
        {
            string dimension = parameters.Get("dimension") ?? "";
            if (!Query.IsDimension(dimension))
            {
                return Coded("Unknown dimension \"" + dimension + "\"", "unknown_dimension", 400, new JsObject { ["dimension"] = dimension });
            }
            double limit = Limit(parameters.Get("limit"), 10);
            double page = parameters.Get("page") is string p ? Js.Number(p) : 0;
            page = Math.Max(1, double.IsNaN(page) || page == 0 ? 1 : page);
            var rows = await store.BreakdownAsync(query, dimension, Whole(limit), Whole((page - 1) * limit), cancellationToken).ConfigureAwait(false);
            if (parameters.Get("format") == "csv")
            {
                return Download(siteId + "-" + dimension + "-" + range.Str("fromDate") + "-" + range.Str("toDate") + ".csv", Js.Utf8(RowsCsv(rows, timezone, null, dimension)), "text/csv; charset=utf-8");
            }
            return JsonResponse(new JsObject { ["site"] = siteId, ["range"] = rangeOut, ["dimension"] = dimension, ["rows"] = ToList(rows) });
        }

        // Everything the dashboard shows for a view, as a ZIP of CSV files.
        if (path == "/api/export")
        {
            var files = new List<(string Name, string Text)>();
            var stats = await store.StatsAsync(query, cancellationToken).ConfigureAwait(false);
            var previous = before != null ? await store.StatsAsync(before, cancellationToken).ConfigureAwait(false) : null;
            var now = SheetRow(stats, timezone);
            var then = previous != null ? SheetRow(previous, timezone) : null;
            var overview = new List<IEnumerable<object?>>();
            foreach (var (m, value) in now)
            {
                overview.Add(then != null ? [m, value, then.Has(m) ? then.Get(m) : null] : [m, value]);
            }
            files.Add(("overview.csv", Zip.Csv(then != null ? ["metric", "value", "previous"] : ["metric", "value"], overview)));
            var points = await store.SeriesAsync(query, Time.Buckets(range, timezone), cancellationToken).ConfigureAwait(false);
            files.Add(("over-time.csv", RowsCsv(points, timezone, range.Str("interval"))));
            foreach (string dimension in Query.Dimensions)
            {
                var rows = await store.BreakdownAsync(query, dimension, 1000, 0, cancellationToken).ConfigureAwait(false);
                if (rows.Count > 0)
                {
                    files.Add((dimension + ".csv", RowsCsv(rows, timezone, null, dimension)));
                }
            }
            var goals = await store.GoalsAsync(siteId, cancellationToken).ConfigureAwait(false);
            if (goals.Count > 0)
            {
                var totals = await store.GoalTotalsAllAsync(query, goals, cancellationToken).ConfigureAwait(false);
                files.Add(("goals.csv", Zip.Csv(
                    ["goal", "conversions", "visitors", "revenue", "currency"],
                    goals.Select(g =>
                    {
                        var total = totals[g.Str("id")!];
                        return (IEnumerable<object?>)[g.Get("name"), total.Get("conversions"), total.Get("visitors"), total.Get("revenue"), g.Get("currency")];
                    }))));
            }
            return Download(siteId + "-" + range.Str("fromDate") + "-" + range.Str("toDate") + ".zip", Zip.Archive(files, rl.Now()), "application/zip");
        }

        return Coded("Not found", "not_found", 404);
    }

    /// <summary>A field of a remote's info, or undefined when there is none, which JSON leaves out.</summary>
    private static object? Field(JsObject? info, string key) => info != null ? info.Prop(key) : Undefined.Value;

    /// <summary>
    /// Answers one request under the base path: the dashboard and its assets, the tracker, the API, MCP,
    /// OAuth, accounts, and the small pages, as the TypeScript handler does. <paramref name="ip"/> is the
    /// connection's address (TypeScript's context.ip), when the adapter knows it.
    /// </summary>
    public async Task<Response> HandleAsync(Request request, string? ip = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var url = new Url(request.Url);
        string @base = _base;
        // OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
        if (@base.Length > 0 && IsOauthDocument(url.Pathname))
        {
            try
            {
                return await OAuth.OAuthResponseAsync(_oauth, request, url.Pathname, url, ip, cancellationToken).ConfigureAwait(false) ?? Coded("Not found", "not_found", 404);
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                await Console.Error.WriteLineAsync("Runlight: " + error).ConfigureAwait(false);
                return Coded("Internal error", "internal", 500);
            }
        }
        if (@base.Length > 0 && url.Pathname != @base && !url.Pathname.StartsWith(@base + "/", StringComparison.Ordinal))
        {
            return Coded("Not found", "not_found", 404);
        }
        string path = url.Pathname[@base.Length..];
        path = path.Length == 0 ? "/" : path;

        try
        {
            return await RouteAsync(request, path, url, ip, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            await Console.Error.WriteLineAsync("Runlight: " + error).ConfigureAwait(false);
            return Coded("Internal error", "internal", 500);
        }
    }

    /// <summary>The handler, as an adapter takes it.</summary>
    public RequestHandler Handler() => HandleAsync;

    private async Task<Response> RouteAsync(Request request, string path, Url url, string? ip, CancellationToken cancellationToken)
    {
        var rl = _rl;
        string @base = _base;
        string method = request.Method;
        // Checked before any route, so a connected site's pass-through to its install is held to it too.
        if (AdminOnly(path, method) && await CanReadAsync(request, cancellationToken).ConfigureAwait(false) is true && IsMember(request))
        {
            return Coded("Only an owner or admin can change this", "admin_only", 403);
        }
        // Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone signed out to sign in.
        if (_web != null)
        {
            var answered = await _web.HandleAsync(request, path, ip, cancellationToken).ConfigureAwait(false);
            if (answered != null)
            {
                return answered;
            }
        }
        if (path == "/s.js" && method == "GET")
        {
            var script = await TrackerScriptAsync(url.SearchParams.Get("site"), cancellationToken).ConfigureAwait(false);
            var headers = new Headers
            {
                ["content-type"] = "application/javascript; charset=utf-8",
                // Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
                ["cache-control"] = "public, max-age=300",
                ["etag"] = script.Etag,
            };
            if (request.Headers.Get("if-none-match") == script.Etag)
            {
                return new Response("", 304, headers);
            }
            return new Response(script.Body, 200, headers);
        }

        if (path == "/pick.js" && method == "GET")
        {
            // The picker sends what it picked only to the dashboard its ticket names; without a good ticket it does nothing.
            // It also runs only on the pages of the site the ticket names.
            var target = await PickTargetAsync(url.SearchParams.Get("runlight_ticket") ?? "", cancellationToken).ConfigureAwait(false);
            if (target != null)
            {
                await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            }
            object? hosts = target != null ? rl.Site(target.Value.Site)?.Get("hostnames") : new List<object?>();
            string script = ReplaceOnce(Assets.Text("picker.js"), PickTargetPlaceholder, global::Runlight.Json.Stringify(hosts != null ? (target?.Origin ?? "") : ""));
            script = ReplaceOnce(script, PickHostsPlaceholder, global::Runlight.Json.Stringify(global::Runlight.Json.Stringify(hosts ?? new List<object?>())));
            return new Response(script, 200, new Headers { ["content-type"] = "application/javascript; charset=utf-8", ["cache-control"] = "no-store" });
        }

        if (path == "/assets/world." + BuildHash("worldHash") + ".json" && method == "GET")
        {
            return new Response(Assets.Bytes("world.json"), 200, new Headers { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "public, max-age=31536000, immutable" });
        }

        var locale = LocalePath.Match(path);
        if (locale.Success && locale.Groups[2].Value == BuildHash("localesHash") && Js.Truthy(Locales().Get(locale.Groups[1].Value)) && method == "GET")
        {
            return new Response(Js.String(Locales().Get(locale.Groups[1].Value)), 200, new Headers { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "public, max-age=31536000, immutable" });
        }

        if (path.StartsWith("/assets/app.", StringComparison.Ordinal) && method == "GET")
        {
            string hash = BuildHash("dashboardHash");
            string? asset = path == "/assets/app." + hash + ".js" ? "dashboard.js" : (path == "/assets/app." + hash + ".css" ? "dashboard.css" : null);
            if (asset == null)
            {
                return Coded("Not found", "not_found", 404);
            }
            return new Response(Assets.Bytes(asset), 200, new Headers
            {
                ["content-type"] = path.EndsWith(".js", StringComparison.Ordinal) ? "application/javascript; charset=utf-8" : "text/css; charset=utf-8",
                ["cache-control"] = "public, max-age=31536000, immutable",
            });
        }

        if (path == "/e")
        {
            if (method == "OPTIONS")
            {
                return new Response("", 204, new Headers { ["access-control-allow-origin"] = "*", ["access-control-allow-methods"] = "POST", ["access-control-max-age"] = "86400" });
            }
            if (method != "POST")
            {
                return Coded("Method not allowed", "method_not_allowed", 405);
            }
            try
            {
                await rl.CollectAsync(request, ip, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                await Console.Error.WriteLineAsync("Runlight: could not record an event " + error).ConfigureAwait(false);
            }
            // The same answer whatever happened, so the endpoint reveals nothing.
            return new Response("", 202, new Headers { ["access-control-allow-origin"] = "*" });
        }

        if (path == "/api" || path.StartsWith("/api/", StringComparison.Ordinal))
        {
            return await ApiAsync(request, path, url, cancellationToken).ConfigureAwait(false);
        }

        if (path.StartsWith("/oauth/", StringComparison.Ordinal) || IsOauthDocument(path))
        {
            var answer = await OAuth.OAuthResponseAsync(_oauth, request, path, url, ip, cancellationToken).ConfigureAwait(false);
            if (answer != null)
            {
                return answer;
            }
        }

        if (path == "/mcp")
        {
            // No server-sent stream and no sessions: every message is one POST.
            if (method != "POST")
            {
                return Coded("Method not allowed", "method_not_allowed", 405, null, new Headers { ["allow"] = "POST" });
            }
            object access = await ReaderAsync(request, cancellationToken).ConfigureAwait(false);
            if (Refuses(access))
            {
                var refused = Denied(access);
                // Points an OAuth client at the metadata that starts the sign-in.
                refused.Headers.Set("www-authenticate", "Bearer realm=\"runlight\", resource_metadata=\"" + OAuth.ResourceMetadataUrl(url.Origin, @base) + "\"");
                return refused;
            }
            // Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
            return await Mcp.McpResponseAsync(request, ReadApi(request, url, null, cancellationToken)).ConfigureAwait(false);
        }

        var unsubscribe = UnsubscribePath.Match(path);
        if (unsubscribe.Success && (method == "GET" || method == "POST"))
        {
            return await UnsubscribePageAsync(request, unsubscribe.Groups[1].Value, cancellationToken).ConfigureAwait(false);
        }

        var sharePage = SharePagePath.Match(path);
        if (sharePage.Success && method == "GET")
        {
            await rl.InitAsync(cancellationToken).ConfigureAwait(false);
            string id = sharePage.Groups[1].Value;
            var share = ShareId.IsMatch(id) ? await Store.ShareByIdAsync(id, cancellationToken).ConfigureAwait(false) : null;
            if (share == null)
            {
                var t = Messages.Translator(AcceptedLanguage(request));
                return SmallPage(t.Lang, "<h1>" + EscapeHtml(t.T("share.goneTitle")) + "</h1><p>" + EscapeHtml(t.T("share.gone")) + "</p>", 404);
            }
            return new Response(Dashboard(@base, share.Str("id")!, "", _options.GeoCredit), 200, new Headers
            {
                ["content-type"] = "text/html; charset=utf-8",
                ["cache-control"] = "no-store",
                ["content-security-policy"] = DashboardCsp,
                ["x-frame-options"] = "DENY",
                // The share id is the key; never send it on to another site.
                ["referrer-policy"] = "no-referrer",
                ["x-robots-tag"] = "noindex",
            });
        }

        if ((path == "/" || path.Length == 0) && method == "GET")
        {
            string? given = url.SearchParams.Get("token");
            if (!string.IsNullOrEmpty(given) && !string.IsNullOrEmpty(_token) && ConstantTimeEqual(given, _token))
            {
                var query = url.SearchParams;
                query.Delete("token");
                url.SetSearchParams(query);
                string secure = url.Protocol == "https:" ? "; Secure" : "";
                return new Response("", 303, new Headers
                {
                    ["location"] = url.Pathname + url.Search,
                    ["set-cookie"] = Cookie + "=" + CookieValue(_token) + "; Path=" + (@base.Length > 0 ? @base : "/") + "; HttpOnly; SameSite=Lax; Max-Age=2592000" + secure,
                });
            }
            // The page itself holds no data; the API it calls checks access and
            // the page explains how to sign in when it is refused.
            return new Response(Dashboard(@base, "", _signOut ?? "", _options.GeoCredit, _web != null, _signIn ?? ""), 200, new Headers
            {
                ["content-type"] = "text/html; charset=utf-8",
                ["cache-control"] = "no-store",
                ["content-security-policy"] = DashboardCsp,
                ["x-frame-options"] = "DENY",
                ["referrer-policy"] = "same-origin",
            });
        }

        return Coded("Not found", "not_found", 404);
    }

    /// <summary><c>text.replace(search, () =&gt; value)</c>: the first match only, with nothing in <paramref name="value"/> read as a pattern.</summary>
    private static string ReplaceOnce(string text, string search, string value)
    {
        int at = text.IndexOf(search, StringComparison.Ordinal);
        return at < 0 ? text : string.Concat(text.AsSpan(0, at), value, text.AsSpan(at + search.Length));
    }
}
