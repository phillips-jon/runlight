using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>
/// Rebrandly. Its API gives only total clicks, with no dates, so links come
/// across with their slugs and domains and start their history fresh.
///
/// https://developers.rebrandly.com/docs
/// </summary>
/// <param name="http">Requests; a default <see cref="Http"/> when null.</param>
/// <param name="now">The clock, in milliseconds; the wall clock when null.</param>
public sealed class Rebrandly(Http? http = null, Func<long>? now = null) : IImporter
{
    private const string Base = "https://api.rebrandly.com/v1";
    private const int Page = 25;

    private readonly Http _http = http ?? new Http();
    private readonly Func<long> _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    public async Task<JsObject> StepAsync(JsObject credentials, string? cursor, Func<string, string?, string?, Task<bool>> known, CancellationToken cancellationToken = default)
    {
        string key = Js.Trim(Js.String(credentials.Get("apiKey") ?? ""));
        if (key.Length == 0)
        {
            throw new ImportError("Enter a Rebrandly API key", "import_key", new JsObject { ["service"] = "Rebrandly" });
        }
        var headers = new JsObject { ["apikey"] = key };
        string workspace = Js.Trim(Js.String(credentials.Get("workspace") ?? ""));
        if (workspace.Length > 0)
        {
            headers["workspace"] = workspace;
        }
        string last = !string.IsNullOrEmpty(cursor) ? "&last=" + Js.EncodeURIComponent(cursor) : "";
        var list = (List<object?>)(await _http.GetJsonAsync(Base + "/links?orderBy=createdAt&orderDir=desc&limit=" + Js.Str(Page) + last, headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;
        var links = new List<object?>();
        foreach (var item in list)
        {
            var l = (JsObject)item!;
            double created = Http.ParseDate(l.Get("createdAt"));
            links.Add(new JsObject
            {
                ["link"] = new JsObject
                {
                    ["sourceId"] = l.Get("id"),
                    ["slug"] = l.Get("slashtag"),
                    ["domain"] = Http.Coalesce(Http.Field(Http.Field(l, "domain"), "fullName"), ""),
                    ["name"] = Js.Truthy(l.Get("title")) ? l.Get("title") : "",
                    ["url"] = l.Get("destination"),
                    ["createdAt"] = Js.Truthy(created) ? created : _now(),
                },
            });
        }
        object? end = list.Count == 0 ? null : list[^1];
        return new JsObject
        {
            ["cursor"] = list.Count == Page && Js.Truthy(end) ? Js.String(((JsObject)end!).Get("id")) : null,
            ["total"] = null,
            ["links"] = links,
        };
    }
}
