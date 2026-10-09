using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>
/// Bitly. Links are listed per group (every group in the account), with
/// archived ones. Bitly only keeps daily click counts, and only as far back
/// as the account's plan allows. A custom back-half or branded domain wins
/// over the random bit.ly one.
///
/// https://dev.bitly.com/api-reference
/// </summary>
/// <param name="http">Requests; a default <see cref="Http"/> when null.</param>
/// <param name="now">The clock, in milliseconds; the wall clock when null.</param>
public sealed class Bitly(Http? http = null, Func<long>? now = null) : IImporter
{
    private const string Base = "https://api-ssl.bitly.com/v4";
    private const int Page = 20;

    private readonly Http _http = http ?? new Http();
    private readonly Func<long> _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    /// <summary>A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale".</summary>
    private static (string Domain, string Slug) Split(string value)
    {
        string bare = value.StartsWith("https://", StringComparison.Ordinal) ? value[8..] : value.StartsWith("http://", StringComparison.Ordinal) ? value[7..] : value;
        int at = bare.IndexOf('/', StringComparison.Ordinal);
        if (at < 0)
        {
            return (bare, "");
        }
        string slug = bare[(at + 1)..];
        return (bare[..at], slug.EndsWith('/') ? slug[..^1] : slug);
    }

    public async Task<JsObject> StepAsync(JsObject credentials, string? cursor, Func<string, string?, string?, Task<bool>> known, CancellationToken cancellationToken = default)
    {
        string token = Js.Trim(Js.String(credentials.Get("token") ?? ""));
        token = token.Length > 0 ? token : Js.Trim(Js.String(credentials.Get("apiKey") ?? ""));
        if (token.Length == 0)
        {
            throw new ImportError("Enter a Bitly access token", "import_key", new JsObject { ["service"] = "Bitly" });
        }
        var headers = new JsObject { ["authorization"] = "Bearer " + token };
        JsObject state;
        if (!string.IsNullOrEmpty(cursor))
        {
            state = (JsObject)Json.Parse(cursor)!;
        }
        else
        {
            var groups = (JsObject)(await _http.GetJsonAsync(Base + "/groups", headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;
            var guids = new List<object?>();
            foreach (var row in groups.Arr("groups")!)
            {
                guids.Add(((JsObject)row!).Get("guid"));
            }
            state = new JsObject { ["groups"] = guids, ["g"] = 0L, ["after"] = null };
        }
        var group = Http.Field(state.Get("groups"), (int)Js.Num(state.Get("g")));
        if (!Js.Truthy(group))
        {
            return new JsObject { ["cursor"] = null, ["total"] = null, ["links"] = new List<object?>() };
        }

        string after = Js.Truthy(state.Get("after")) ? "&search_after=" + Js.EncodeURIComponent(Js.String(state.Get("after"))) : "";
        var page = (JsObject)(await _http.GetJsonAsync(Base + "/groups/" + Js.String(group) + "/bitlinks?size=" + Js.Str(Page) + "&archived=both" + after, headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;

        var links = new List<object?>();
        var pageLinks = page.Arr("links")!;
        foreach (var item in pageLinks)
        {
            var b = (JsObject)item!;
            if (Js.Truthy(b.Get("is_deleted")))
            {
                continue;
            }
            string id = Js.String(b.Get("id"));
            var shortUrl = Split(Js.String(Http.Coalesce(Http.Field(b.Get("custom_bitlinks"), 0), b.Get("id"))));
            if (await known(id, shortUrl.Slug, Js.String(b.Get("long_url"))).ConfigureAwait(false))
            {
                links.Add(new JsObject
                {
                    ["link"] = new JsObject { ["sourceId"] = b.Get("id"), ["slug"] = "", ["domain"] = "", ["name"] = "", ["url"] = b.Get("long_url"), ["createdAt"] = 0L },
                    ["known"] = true,
                });
                continue;
            }
            List<object?>? daily = null;
            try
            {
                var clicks = (JsObject)(await _http.GetJsonAsync(Base + "/bitlinks/" + Js.EncodeURIComponent(id) + "/clicks?unit=day&units=-1", headers, cancellationToken: cancellationToken).ConfigureAwait(false))!;
                daily = [];
                foreach (var c in clicks.Arr("link_clicks")!)
                {
                    var click = (JsObject)c!;
                    if (Js.Num(click.Get("clicks")) > 0)
                    {
                        daily.Add(new JsObject { ["day"] = Js.Slice(Js.String(click.Get("date")), 0, 10), ["clicks"] = click.Get("clicks") });
                    }
                }
            }
            catch (HttpError error)
            {
                // Plans without analytics refuse this; the link still comes across.
                if (error.Status == 401)
                {
                    throw;
                }
            }
            double created = Http.ParseDate(b.Get("created_at"));
            var entry = new JsObject
            {
                ["link"] = new JsObject
                {
                    ["sourceId"] = b.Get("id"),
                    ["slug"] = shortUrl.Slug,
                    ["domain"] = shortUrl.Domain,
                    ["name"] = Js.Truthy(b.Get("title")) ? b.Get("title") : "",
                    ["url"] = b.Get("long_url"),
                    ["createdAt"] = Js.Truthy(created) ? created : _now(),
                },
            };
            if (daily != null)
            {
                entry["daily"] = daily;
            }
            links.Add(entry);
        }

        object? searchAfter = page.Obj("pagination")?.Get("search_after");
        object? next = Js.Truthy(searchAfter) && pageLinks.Count == Page ? searchAfter : null;
        JsObject? more = null;
        double g = Js.Num(state.Get("g"));
        if (next != null)
        {
            more = state.Clone();
            more["after"] = next;
        }
        else if (g + 1 < state.Arr("groups")!.Count)
        {
            more = state.Clone();
            more["g"] = g + 1;
            more["after"] = null;
        }
        return new JsObject { ["cursor"] = more != null ? Json.Stringify(more) : null, ["total"] = null, ["links"] = links };
    }
}
