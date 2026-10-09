using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>
/// Dub. Links come from GET /links (cursor pages of up to 100, archived
/// included). Click history is per click from /events where the plan allows,
/// else daily counts from /analytics, else none; the first link decides.
/// What the account's plan lets us read rides in the cursor as <c>history</c>:
/// "events" (Business), "daily" (Pro), "none" (Free), or null before the first link.
///
/// https://dub.co/docs/api-reference
/// </summary>
/// <param name="http">Requests; a default <see cref="Http"/> when null.</param>
/// <param name="now">The clock, in milliseconds; the wall clock when null.</param>
public sealed class Dub(Http? http = null, Func<long>? now = null) : IImporter
{
    private const string Base = "https://api.dub.co";
    private const int Page = 10;

    private readonly Http _http = http ?? new Http();
    private readonly Func<long> _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    public async Task<JsObject> StepAsync(JsObject credentials, string? cursor, Func<string, string?, string?, Task<bool>> known, CancellationToken cancellationToken = default)
    {
        string key = Js.Trim(Js.String(credentials.Get("apiKey") ?? ""));
        if (key.Length == 0)
        {
            throw new ImportError("Enter a Dub API key", "import_key", new JsObject { ["service"] = "Dub" });
        }
        var headers = new JsObject { ["authorization"] = "Bearer " + key };
        var state = !string.IsNullOrEmpty(cursor) ? Json.Parse(cursor) : new JsObject { ["after"] = null, ["history"] = null };
        object? history = Http.Field(state, "history");
        object? afterValue = state is JsObject s ? s.Get("after") : null;
        string after = Js.Truthy(afterValue) ? "&startingAfter=" + Js.EncodeURIComponent(Js.String(afterValue)) : "";
        var list = (List<object?>)(await _http.GetJsonAsync(Base + "/links?pageSize=" + Js.Str(Page) + "&showArchived=true" + after, headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;

        var links = new List<object?>();
        foreach (var item in list)
        {
            var l = (JsObject)item!;
            string id = Js.String(l.Get("id"));
            if (await known(id, Js.String(l.Get("key")), Js.String(l.Get("url"))).ConfigureAwait(false))
            {
                links.Add(new JsObject
                {
                    ["link"] = new JsObject { ["sourceId"] = l.Get("id"), ["slug"] = l.Get("key"), ["domain"] = "", ["name"] = "", ["url"] = l.Get("url"), ["createdAt"] = 0L },
                    ["known"] = true,
                });
                continue;
            }
            List<object?>? clicks = null;
            List<object?>? daily = null;
            if (history is null or "events")
            {
                try
                {
                    clicks = [];
                    for (int page = 1; ; page++)
                    {
                        var events = (List<object?>)(await _http.GetJsonAsync(
                            Base + "/events?event=clicks&linkId=" + Js.EncodeURIComponent(id) + "&interval=all&sortOrder=asc&limit=1000&page=" + Js.Str(page),
                            headers,
                            cancellationToken: cancellationToken).ConfigureAwait(false))!;
                        foreach (var e in events)
                        {
                            object? click = Http.Field(e, "click");
                            object? referer = Http.Field(click, "referer");
                            object? refererUrl = Http.Field(click, "refererUrl");
                            object? device = Http.Field(click, "device");
                            clicks.Add(Http.Defined(new JsObject
                            {
                                ["ts"] = Http.ParseDate((e as JsObject)?.Get("timestamp")),
                                ["visit"] = Http.Field(click, "id"),
                                ["referrer"] = Js.Truthy(refererUrl) ? refererUrl : (Js.Truthy(referer) && !Equals(referer, "(direct)") ? "https://" + Js.String(referer) + "/" : ""),
                                ["country"] = Http.Field(click, "country"),
                                ["region"] = Http.Field(click, "region"),
                                ["city"] = Http.Field(click, "city"),
                                ["device"] = device is string d ? Js.Lower(d) : Undefined.Value,
                                ["browser"] = Http.Field(click, "browser"),
                                ["os"] = Http.Field(click, "os"),
                            }));
                        }
                        if (events.Count < 1000)
                        {
                            break;
                        }
                    }
                    history = "events";
                }
                catch (HttpError error)
                {
                    if (!PlanRefused(error))
                    {
                        throw;
                    }
                    clicks = null;
                    history = "daily";
                }
            }
            if (Equals(history, "daily"))
            {
                try
                {
                    var series = (List<object?>)(await _http.GetJsonAsync(
                        Base + "/analytics?event=clicks&groupBy=timeseries&interval=all&linkId=" + Js.EncodeURIComponent(id),
                        headers,
                        cancellationToken: cancellationToken).ConfigureAwait(false))!;
                    daily = [];
                    foreach (var p in series)
                    {
                        var point = (JsObject)p!;
                        if (Js.Num(point.Get("clicks")) > 0)
                        {
                            daily.Add(new JsObject { ["day"] = Js.Slice(Js.String(point.Get("start")), 0, 10), ["clicks"] = point.Get("clicks") });
                        }
                    }
                }
                catch (HttpError error)
                {
                    if (!PlanRefused(error))
                    {
                        throw;
                    }
                    history = "none";
                }
            }
            double created = Http.ParseDate(l.Get("createdAt"));
            var entry = new JsObject
            {
                ["link"] = new JsObject
                {
                    ["sourceId"] = l.Get("id"),
                    ["slug"] = l.Get("key"),
                    ["domain"] = l.Get("domain"),
                    ["name"] = Js.Truthy(l.Get("title")) ? l.Get("title") : "",
                    ["url"] = l.Get("url"),
                    ["createdAt"] = Js.Truthy(created) ? created : _now(),
                },
            };
            if (clicks != null)
            {
                entry["clicks"] = clicks;
            }
            if (daily != null)
            {
                entry["daily"] = daily;
            }
            links.Add(entry);
        }
        object? last = list.Count == 0 ? null : list[^1];
        return new JsObject
        {
            ["cursor"] = list.Count == Page && Js.Truthy(last) ? Json.Stringify(new JsObject { ["after"] = ((JsObject)last!).Get("id"), ["history"] = history }) : null,
            ["total"] = null,
            ["links"] = links,
        };
    }

    /// <summary>
    /// Whether Dub said the plan does not include what was asked (403, or 402).
    /// Any other failure (a server error that outlasts the retries, say) fails
    /// the step and leaves the history mode as it was.
    /// </summary>
    private static bool PlanRefused(HttpError error) => error.Status is 403 or 402;
}
