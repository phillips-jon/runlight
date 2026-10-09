using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>
/// Umami v3 (and forks with custom link domains). Signs in with an API key,
/// or with a username and password (stock self-hosted Umami has no API keys).
/// In Umami a link's clicks are events stored under the link's id, with the
/// visitor's session holding place and device.
/// </summary>
/// <param name="http">Requests; a default <see cref="Http"/> when null.</param>
/// <param name="now">The clock, in milliseconds; the wall clock when null.</param>
public sealed partial class Umami(Http? http = null, Func<long>? now = null) : IImporter
{
    private const int Page = 5;

    private readonly Http _http = http ?? new Http();
    private readonly Func<long> _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    [GeneratedRegex("/+\\z", RegexOptions.CultureInvariant)]
    private static partial Regex TrailingSlashes();

    [GeneratedRegex("^https?://[^/]+", RegexOptions.CultureInvariant)]
    private static partial Regex Address();

    /// <summary>
    /// Signs in to an Umami: an API key, or a username and password (stock
    /// self-hosted Umami has no API keys). A token from an earlier step is reused.
    /// </summary>
    public static async Task<(string Base, object? Token)> UmamiSignInAsync(Http http, JsObject credentials, object? token = null, CancellationToken cancellationToken = default)
    {
        string baseUrl = TrailingSlashes().Replace(Js.Trim(Js.String(credentials.Get("url") ?? "")), "");
        if (!Address().IsMatch(baseUrl))
        {
            throw new ImportError("Enter your Umami address, like https://stats.example.com", "import_umami_address");
        }
        string key = Js.Trim(Js.String(credentials.Get("apiKey") ?? ""));
        if (key.Length > 0 || Js.Truthy(token))
        {
            return (baseUrl, key.Length > 0 ? key : token);
        }
        string username = Js.String(credentials.Get("username") ?? "");
        string password = Js.String(credentials.Get("password") ?? "");
        if (username.Length == 0 || password.Length == 0)
        {
            throw new ImportError("Enter an API key, or a username and password", "import_umami_login");
        }
        var login = await http.GetJsonAsync(
            baseUrl + "/api/auth/login",
            new JsObject { ["content-type"] = "application/json" },
            "POST",
            Json.Stringify(new JsObject { ["username"] = credentials.Get("username"), ["password"] = credentials.Get("password") }),
            cancellationToken).ConfigureAwait(false);
        // A sign-in that answers without a token was refused, whatever its status.
        object? signedIn = Http.Field(login, "token");
        if (signedIn is not string { Length: > 0 })
        {
            throw new ImportError("The key or sign-in was refused", "import_refused");
        }
        return (baseUrl, signedIn);
    }

    public async Task<JsObject> StepAsync(JsObject credentials, string? cursor, Func<string, string?, string?, Task<bool>> known, CancellationToken cancellationToken = default)
    {
        // A key comes with every step; only a sign-in token, which expires, rides in the cursor.
        object? saved = !string.IsNullOrEmpty(cursor) ? Json.Parse(cursor) : new JsObject { ["page"] = 1L };
        string key = Js.Trim(Js.String(credentials.Get("apiKey") ?? ""));
        var (baseUrl, token) = await UmamiSignInAsync(_http, credentials, Http.Field(saved, "token"), cancellationToken).ConfigureAwait(false);
        object? statePage = Http.Field(saved, "page");
        var headers = new JsObject { ["authorization"] = "Bearer " + Js.String(token) };
        var list = (JsObject)(await _http.GetJsonAsync(baseUrl + "/api/links?page=" + Js.String(statePage) + "&pageSize=" + Js.Str(Page), headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;

        async Task<List<object?>> All(string path)
        {
            var output = new List<object?>();
            for (int page = 1; ; page++)
            {
                var body = (JsObject)(await _http.GetJsonAsync(baseUrl + "/api" + path + "&page=" + Js.Str(page) + "&pageSize=1000", headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;
                var data = body.Arr("data")!;
                output.AddRange(data);
                double count = body.Get("count") is { } c ? Js.Num(c) : double.PositiveInfinity;
                if (output.Count >= count || data.Count == 0)
                {
                    return output;
                }
            }
        }

        var links = new List<object?>();
        var listData = list.Arr("data")!;
        foreach (var item in listData)
        {
            var l = (JsObject)item!;
            if (Js.Truthy(l.Get("deletedAt")))
            {
                continue;
            }
            if (await known(Js.String(l.Get("id")), Js.String(l.Get("slug")), Js.String(l.Get("url"))).ConfigureAwait(false))
            {
                links.Add(new JsObject
                {
                    ["link"] = new JsObject { ["sourceId"] = l.Get("id"), ["slug"] = l.Get("slug"), ["domain"] = "", ["name"] = l.Get("name"), ["url"] = l.Get("url"), ["createdAt"] = 0L },
                    ["known"] = true,
                });
                continue;
            }
            double parsed = Http.ParseDate(l.Get("createdAt"));
            double created = Js.Truthy(parsed) ? parsed : _now();
            string range = "startAt=" + Js.String(created - 86_400_000) + "&endAt=" + Js.String((double)(_now() + 60_000));
            // TS asks for both at once; here one follows the other.
            string id = Js.String(l.Get("id"));
            var events = await All("/websites/" + id + "/events?" + range).ConfigureAwait(false);
            var sessions = await All("/websites/" + id + "/sessions?" + range).ConfigureAwait(false);
            var info = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var s in sessions)
            {
                info[Js.String(Http.Field(s, "id"))] = s;
            }
            var clicks = new List<object?>();
            foreach (var e in events)
            {
                object? sessionId = (e as JsObject)?.Get("sessionId");
                object? s = info.TryGetValue(Js.String(sessionId ?? Undefined.Value), out var found) ? found : Undefined.Value;
                object? domain = Http.Field(e, "referrerDomain");
                object? path = Http.Field(e, "referrerPath");
                clicks.Add(Http.Defined(new JsObject
                {
                    ["ts"] = Http.ParseDate((e as JsObject)?.Get("createdAt")),
                    ["visit"] = Http.Field(e, "sessionId"),
                    ["referrer"] = Js.Truthy(domain) ? "https://" + Js.String(domain) + (Js.Truthy(path) ? Js.String(path) : "/") : "",
                    ["path"] = Http.Field(e, "urlPath"),
                    ["query"] = Http.Field(e, "urlQuery"),
                    ["country"] = Http.Field(e, "country"),
                    ["region"] = Http.Field(s, "region"),
                    ["city"] = Http.Field(e, "city"),
                    ["browser"] = Http.Field(e, "browser"),
                    ["os"] = Http.Field(e, "os"),
                    ["device"] = Http.Field(e, "device"),
                    ["screen"] = Http.Field(s, "screen"),
                    ["language"] = Http.Field(s, "language"),
                }));
            }
            links.Add(new JsObject
            {
                ["link"] = new JsObject
                {
                    ["sourceId"] = l.Get("id"),
                    ["slug"] = l.Get("slug"),
                    ["domain"] = Http.Coalesce(Http.Field(Http.Field(l, "customDomain"), "domain"), ""),
                    ["name"] = l.Get("name"),
                    ["url"] = l.Get("url"),
                    ["createdAt"] = created,
                },
                ["clicks"] = clicks,
            });
        }
        double pageNumber = Js.Number(statePage);
        // Without a count there is no total, and a full page may have more after it.
        object? count = Http.Field(list, "count");
        count = Json.TryNumberOf(count, out double total) && double.IsFinite(total) ? count : null;
        bool more = count == null ? listData.Count == Page : pageNumber * Page < total && listData.Count > 0;
        var next = key.Length > 0 ? new JsObject { ["page"] = pageNumber + 1 } : new JsObject { ["page"] = pageNumber + 1, ["token"] = token };
        return new JsObject { ["cursor"] = more ? Json.Stringify(next) : null, ["total"] = count, ["links"] = links };
    }
}
