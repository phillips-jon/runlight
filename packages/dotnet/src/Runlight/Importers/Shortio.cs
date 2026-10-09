using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>
/// Short.io. Links are listed per domain. Daily click counts come from the
/// statistics API, paced to its limit of 60 requests a minute, so a step
/// holds only a few links.
///
/// https://developers.short.io/reference
/// </summary>
/// <param name="http">Requests; a default <see cref="Http"/> when null.</param>
/// <param name="now">The clock, in milliseconds; the wall clock when null.</param>
public sealed class Shortio(Http? http = null, Func<long>? now = null) : IImporter
{
    private const string Api = "https://api.short.io";
    private const string Stats = "https://statistics.short.io/statistics";
    private const int Page = 8;

    /// <summary>The statistics API allows 60 requests a minute.</summary>
    private const int StatsGapMs = 1050;

    private readonly Http _http = http ?? new Http();
    private readonly Func<long> _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    public async Task<JsObject> StepAsync(JsObject credentials, string? cursor, Func<string, string?, string?, Task<bool>> known, CancellationToken cancellationToken = default)
    {
        string key = Js.Trim(Js.String(credentials.Get("apiKey") ?? ""));
        if (key.Length == 0)
        {
            throw new ImportError("Enter a Short.io secret API key", "import_key", new JsObject { ["service"] = "Short.io" });
        }
        var headers = new JsObject { ["authorization"] = key };
        JsObject state;
        if (!string.IsNullOrEmpty(cursor))
        {
            state = (JsObject)Json.Parse(cursor)!;
        }
        else
        {
            var domains = (List<object?>)(await _http.GetJsonAsync(Api + "/api/domains?limit=300", headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;
            var kept = new List<object?>();
            foreach (var d in domains)
            {
                var domainRow = (JsObject)d!;
                kept.Add(new JsObject { ["id"] = domainRow.Get("id"), ["hostname"] = domainRow.Get("hostname") });
            }
            state = new JsObject { ["domains"] = kept, ["d"] = 0L, ["token"] = null, ["total"] = null };
        }
        double index = Js.Num(state.Get("d"));
        var domain = Http.Field(state.Get("domains"), (int)index) as JsObject;
        if (!Js.Truthy(domain))
        {
            return new JsObject { ["cursor"] = null, ["total"] = null, ["links"] = new List<object?>() };
        }

        string token = Js.Truthy(state.Get("token")) ? "&pageToken=" + Js.EncodeURIComponent(Js.String(state.Get("token"))) : "";
        var page = (JsObject)(await _http.GetJsonAsync(Api + "/api/links?domain_id=" + Js.String(domain!.Get("id")) + "&limit=" + Js.Str(Page) + token, headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;

        var links = new List<object?>();
        foreach (var item in page.Arr("links")!)
        {
            var l = (JsObject)item!;
            string id = Js.String(Http.Coalesce(Http.Field(l, "idString"), l.Get("id")));
            if (await known(id, Js.String(l.Get("path")), Js.String(l.Get("originalURL"))).ConfigureAwait(false))
            {
                links.Add(new JsObject
                {
                    ["link"] = new JsObject { ["sourceId"] = id, ["slug"] = l.Get("path"), ["domain"] = "", ["name"] = "", ["url"] = l.Get("originalURL"), ["createdAt"] = 0L },
                    ["known"] = true,
                });
                continue;
            }
            List<object?>? daily = null;
            try
            {
                await _http.PauseAsync(StatsGapMs, cancellationToken).ConfigureAwait(false);
                var statsHeaders = headers.Clone();
                statsHeaders["content-type"] = "application/json";
                var body = await _http.GetJsonAsync(
                    Stats + "/link/" + Js.EncodeURIComponent(id) + "/by_interval",
                    statsHeaders,
                    "POST",
                    Json.Stringify(new JsObject { ["period"] = "total", ["clicksChartInterval"] = "day", ["tz"] = "UTC" }),
                    cancellationToken).ConfigureAwait(false);
                object? raw = (body as JsObject)?.Get("clickStatistics");
                List<object?> points = raw switch
                {
                    List<object?> list => list,
                    JsObject o => Http.Field(Http.Field(Http.Field(o, "datasets"), 0), "data") as List<object?> ?? [],
                    _ => [],
                };
                daily = [];
                foreach (var p in points)
                {
                    var point = p as JsObject;
                    object? y = point?.Get("y");
                    if (Positive(y))
                    {
                        object? x = point!.Get("x");
                        double ms = Json.TryNumberOf(x, out double n) ? n : Http.ParseDate(x);
                        // A point whose date cannot be read is left out, not the link.
                        string day;
                        try
                        {
                            day = Http.IsoString(ms)[..10];
                        }
                        catch (ArgumentOutOfRangeException)
                        {
                            continue;
                        }
                        daily.Add(new JsObject { ["day"] = day, ["clicks"] = y });
                    }
                }
            }
            catch (HttpError error)
            {
                if (error.Status == 401)
                {
                    throw;
                }
            }
            double created = Http.ParseDate(l.Get("createdAt"));
            var entry = new JsObject
            {
                ["link"] = new JsObject
                {
                    ["sourceId"] = id,
                    ["slug"] = l.Get("path"),
                    ["domain"] = domain.Get("hostname"),
                    ["name"] = Js.Truthy(l.Get("title")) ? l.Get("title") : "",
                    ["url"] = l.Get("originalURL"),
                    ["createdAt"] = Js.Truthy(created) ? created : _now(),
                },
            };
            if (daily != null)
            {
                entry["daily"] = daily;
            }
            links.Add(entry);
        }

        object? next = page.Get("nextPageToken");
        JsObject? more = null;
        if (Js.Truthy(next))
        {
            more = state.Clone();
            more["token"] = next;
        }
        else if (index + 1 < state.Arr("domains")!.Count)
        {
            more = state.Clone();
            more["d"] = index + 1;
            more["token"] = null;
        }
        return new JsObject { ["cursor"] = more != null ? Json.Stringify(more) : null, ["total"] = null, ["links"] = links };
    }

    /// <summary><c>y &gt; 0</c> as JavaScript compares it.</summary>
    private static bool Positive(object? y) => y switch
    {
        string s => Js.Number(s) > 0,
        bool b => b,
        _ => Json.TryNumberOf(y, out double n) && n > 0,
    };
}
