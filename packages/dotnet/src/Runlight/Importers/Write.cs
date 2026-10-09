using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Importers;

/// <summary>Writing an imported link and its history, and the names other tools use, in Runlight's spelling.</summary>
public static partial class Write
{
    /// <summary>Domains run by the shorteners themselves. Links there stay on Runlight's own path.</summary>
    private static readonly string[] ShortenerDomains = ["bit.ly", "bitly.com", "j.mp", "dub.sh", "dub.co", "dub.link", "short.gy", "rebrand.ly", "rebrandly.com", "rb.gy"];

    /// <summary>Browser names as other tools write them, in Runlight's spelling.</summary>
    public static readonly IReadOnlyDictionary<string, string> Browsers = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["chrome"] = "Chrome",
        ["crios"] = "Chrome",
        ["chromium-webview"] = "Android WebView",
        ["chrome webview"] = "Android WebView",
        ["safari"] = "Safari",
        ["ios"] = "Safari",
        ["ios-webview"] = "Safari",
        ["mobile safari"] = "Safari",
        ["firefox"] = "Firefox",
        ["fxios"] = "Firefox",
        ["edge"] = "Edge",
        ["edge-chromium"] = "Edge",
        ["edge-ios"] = "Edge",
        ["microsoft edge"] = "Edge",
        ["opera"] = "Opera",
        ["opera-mini"] = "Opera",
        ["samsung"] = "Samsung Internet",
        ["samsung internet"] = "Samsung Internet",
        ["yandexbrowser"] = "Yandex Browser",
        ["facebook"] = "Facebook",
        ["instagram"] = "Instagram",
        ["brave"] = "Brave",
        ["duckduckgo"] = "DuckDuckGo",
    };

    /// <summary>System names as other tools write them, in Runlight's spelling.</summary>
    public static readonly IReadOnlyDictionary<string, string> Systems = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["mac os"] = "macOS",
        ["mac os x"] = "macOS",
        ["macos"] = "macOS",
        ["ios"] = "iOS",
        ["android os"] = "Android",
        ["android"] = "Android",
        ["windows 10"] = "Windows",
        ["windows 11"] = "Windows",
        ["windows 7"] = "Windows",
        ["windows"] = "Windows",
        ["linux"] = "Linux",
        ["chrome os"] = "Chrome OS",
        ["chromium os"] = "Chrome OS",
    };

    public static readonly IReadOnlyDictionary<string, string> Devices = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["desktop"] = "desktop",
        ["laptop"] = "desktop",
        ["mobile"] = "mobile",
        ["smartphone"] = "mobile",
        ["phone"] = "mobile",
        ["tablet"] = "tablet",
    };

    [GeneratedRegex("/\\z", RegexOptions.CultureInvariant)]
    private static partial Regex TrailingSlash();

    [GeneratedRegex("^\\?", RegexOptions.CultureInvariant)]
    private static partial Regex LeadingQuestion();

    [GeneratedRegex("^[A-Z]{2}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex Country();

    public static string HexId(string value, int length = 24) => Hash.Sha256(value)[..length];

    /// <summary>The Runlight id an imported link gets, from its source and its id there.</summary>
    public static string ImportedLinkId(string source, string sourceId) => HexId(source + ":" + sourceId);

    /// <summary>Two destinations are the same link when they differ only by a trailing slash.</summary>
    public static bool SameUrl(string a, string b) => TrailingSlash().Replace(a, "", 1) == TrailingSlash().Replace(b, "", 1);

    /// <summary>The first letter in upper case, as TS's title() does.</summary>
    public static string Title(string v) => v.Length == 0 ? "" : Js.Upper(Js.Slice(v, 0, 1)) + Js.Slice(v, 1);

    /// <summary>A browser name in Runlight's spelling: a known one, or the name with a capital first letter.</summary>
    public static string Browser(string name) => Browsers.TryGetValue(Js.Lower(name), out string? known) ? known : Title(name);

    /// <summary>A system name in Runlight's spelling, or the name as given.</summary>
    public static string System(string name) => Systems.TryGetValue(Js.Lower(name), out string? known) ? known : name;

    public static string Device(string name) => Devices.TryGetValue(Js.Lower(name), out string? known) ? known : "";

    /// <summary>A query string without its leading "?".</summary>
    internal static string Query(string query) => LeadingQuestion().Replace(query, "", 1);

    internal static bool IsCountry(string code) => Country().IsMatch(code);

    /// <summary>A field of a foreign click as text, "" where it is missing, as <c>c.field || ""</c> reads it.</summary>
    private static string Str(JsObject c, string key)
    {
        object? value = c.Get(key);
        return Js.Truthy(value) ? Js.String(value) : "";
    }

    /// <summary>
    /// Writes one link and its history in a single transaction: the link (and its branded domain), then each
    /// click as a visit like a live one, or daily counts as clicks without visitors. Ids come from the
    /// source's own ids, so importing again skips what is already there.
    /// </summary>
    /// <param name="runlight">The Runlight.</param>
    /// <param name="site">The site the link goes to.</param>
    /// <param name="source">The importer's name.</param>
    /// <param name="foreign">A ForeignLink: sourceId, slug, domain, name, url, createdAt.</param>
    /// <param name="history">{ clicks?: ForeignClick[], daily?: DailyClicks[] }.</param>
    /// <param name="cancellationToken">Stops the work.</param>
    /// <returns>{ status ("created", "skipped", or "failed"), clicks, reason?, code?, params? }.</returns>
    public static async Task<JsObject> WriteLinkAsync(Runlight runlight, string site, string source, JsObject foreign, JsObject history, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(runlight);
        ArgumentNullException.ThrowIfNull(foreign);
        ArgumentNullException.ThrowIfNull(history);
        string sourceId = Js.String(foreign.Get("sourceId"));
        string id = ImportedLinkId(source, sourceId);
        if (await runlight.Store.LinkByIdAsync(id, cancellationToken).ConfigureAwait(false) != null)
        {
            return new JsObject { ["status"] = "skipped", ["clicks"] = 0L };
        }
        string slug = Js.String(foreign.Get("slug"));
        var taken = await runlight.Store.LinkBySlugAsync(slug, cancellationToken).ConfigureAwait(false);
        // The same slug to the same place is this link, brought in earlier some other way.
        if (taken != null && SameUrl(taken.Str("url")!, Js.String(foreign.Get("url"))))
        {
            return new JsObject { ["status"] = "skipped", ["clicks"] = 0L };
        }
        if (taken != null)
        {
            return new JsObject
            {
                ["status"] = "failed",
                ["clicks"] = 0L,
                ["reason"] = "/" + slug + " is already used by \"" + taken.Str("name") + "\"",
                ["code"] = "import_slug_taken",
                ["params"] = new JsObject { ["slug"] = slug, ["name"] = taken.Get("name") },
            };
        }
        if (!Links.SlugPattern.IsMatch(slug))
        {
            return new JsObject
            {
                ["status"] = "failed",
                ["clicks"] = 0L,
                ["reason"] = "/" + slug + " has characters Runlight slugs cannot use",
                ["code"] = "import_slug_bad",
                ["params"] = new JsObject { ["slug"] = slug },
            };
        }

        string domain = Sources.StripWww(Js.Truthy(foreign.Get("domain")) ? Js.String(foreign.Get("domain")) : "");
        if (ShortenerDomains.Contains(domain, StringComparer.Ordinal))
        {
            domain = "";
        }
        long now = runlight.Now();
        long clicks = 0;
        // Nothing in the transaction is one link's own problem (those are checked above),
        // so a failure in it is the database's, and it stops the import rather than marking the link.
        await runlight.Store.TransactionAsync(async store =>
        {
            // On a database without transactions (D1), a failed earlier try can have left
            // some of this link's clicks behind. Clear them, then write the link row last,
            // so a link only counts as imported once all of its history is in.
            await store.Db.RunAsync("DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')", [id], cancellationToken).ConfigureAwait(false);
            await store.Db.RunAsync("DELETE FROM rl_events WHERE link = ?", [id], cancellationToken).ConfigureAwait(false);

            var made = new HashSet<string>(StringComparer.Ordinal);
            foreach (var c in (history.Get("clicks") as List<object?> ?? []).OfType<JsObject>())
            {
                if (c.Get("ts") is not (long or double) || !double.IsFinite(c.Num("ts")))
                {
                    continue;
                }
                long ts = (long)Math.Truncate(c.Num("ts"));
                string visitKey = c.Get("visit") is not (null or Undefined) ? Js.String(c.Get("visit")) : Js.Str(ts) + ":" + Js.Str(clicks);
                string session = HexId(source + ":" + sourceId + ":" + visitKey);
                // A visitor id lasts one day at most, as every other visitor id does.
                string visitor = HexId(source + ":" + visitKey + ":" + Http.IsoString(ts)[..10], 16);
                string path = Str(c, "path");
                if (made.Add(session))
                {
                    await store.Db.RunAsync("DELETE FROM rl_sessions WHERE id = ?", [session], cancellationToken).ConfigureAwait(false);
                    string host = domain.Length > 0 ? domain : "link.invalid";
                    string query = Str(c, "query");
                    var url = Url.Parse("https://" + host + (path.Length > 0 ? path : "/" + slug) + (query.Length > 0 ? "?" + Query(query) : ""))
                        ?? new Url("https://" + host + "/" + slug);
                    var page = Sources.ParsePage(url);
                    var utm = page.Obj("utm")!;
                    string country = Js.Slice(Js.Upper(Str(c, "country")), 0, 2);
                    string rawRegion = Str(c, "region");
                    string region = rawRegion.Length > 0 ? Js.Slice(Js.Upper(rawRegion.Contains('-', StringComparison.Ordinal) ? rawRegion : country + "-" + rawRegion), 0, 10) : "";
                    var row = new JsObject
                    {
                        ["id"] = session,
                        ["site"] = site,
                        ["visitor"] = visitor,
                        ["startedAt"] = ts,
                        ["hostname"] = page.Get("hostname"),
                    }
                        .With(Sources.Attribute(page, Js.String(c.Get("referrer") ?? ""), []))
                        .With(new JsObject
                        {
                            ["utmSource"] = utm.Get("source"),
                            ["utmMedium"] = utm.Get("medium"),
                            ["utmCampaign"] = utm.Get("campaign"),
                            ["utmTerm"] = utm.Get("term"),
                            ["utmContent"] = utm.Get("content"),
                            ["country"] = IsCountry(country) ? country : "",
                            ["region"] = country.Length > 0 ? region : "",
                            ["city"] = Js.Slice(Str(c, "city"), 0, 100),
                            ["browser"] = Browser(Str(c, "browser")),
                            ["browserVersion"] = "",
                            ["os"] = Systems.TryGetValue(Js.Lower(Str(c, "os")), out string? os) ? os : Js.String(c.Get("os") ?? ""),
                            ["osVersion"] = "",
                            ["device"] = Device(Str(c, "device")),
                            ["screen"] = Js.String(c.Get("screen") ?? ""),
                            ["language"] = Js.String(c.Get("language") ?? ""),
                        });
                    await store.InsertSessionAsync(row, cancellationToken).ConfigureAwait(false);
                    await store.Db.RunAsync("UPDATE rl_sessions SET imported = 1 WHERE id = ?", [session], cancellationToken).ConfigureAwait(false);
                }
                string clickPath = path.Length > 0 ? path : "/" + slug;
                await store.TouchSessionAsync(session, ts, "click", clickPath, cancellationToken: cancellationToken).ConfigureAwait(false);
                await store.InsertEventAsync(new JsObject
                {
                    ["site"] = site,
                    ["ts"] = ts,
                    ["kind"] = "click",
                    ["visitor"] = visitor,
                    ["session"] = session,
                    ["pageview"] = "",
                    ["path"] = Js.Slice(clickPath, 0, 1000),
                    ["hostname"] = domain,
                    ["title"] = "",
                    ["name"] = slug,
                    ["props"] = null,
                    ["engagedMs"] = 0L,
                    ["scroll"] = null,
                    ["link"] = id,
                }, cancellationToken).ConfigureAwait(false);
                clicks++;
            }

            // Counts without detail: clicks spread through each day, with no visitor or visit.
            foreach (var d in (history.Get("daily") as List<object?> ?? []).OfType<JsObject>())
            {
                double start = Http.ParseDate(Js.String(d.Get("day")) + "T00:00:00Z");
                double count = d.Num("clicks");
                if (!double.IsFinite(start) || !(count > 0))
                {
                    continue;
                }
                double n = Math.Min(count, 1_000_000);
                for (long i = 0; i < n; i++)
                {
                    await store.InsertEventAsync(new JsObject
                    {
                        ["site"] = site,
                        ["ts"] = (long)start + (long)Math.Floor((i + 0.5) / n * 86_400_000),
                        ["kind"] = "click",
                        ["visitor"] = "",
                        ["session"] = "",
                        ["pageview"] = "",
                        ["path"] = "/" + slug,
                        ["hostname"] = domain,
                        ["title"] = "",
                        ["name"] = slug,
                        ["props"] = new JsObject { ["imported"] = "daily" },
                        ["engagedMs"] = 0L,
                        ["scroll"] = null,
                        ["link"] = id,
                    }, cancellationToken).ConfigureAwait(false);
                    clicks++;
                }
            }
            if (domain.Length > 0)
            {
                await store.AddLinkDomainAsync(domain, site, now, cancellationToken).ConfigureAwait(false);
            }
            string name = Js.Truthy(foreign.Get("name")) ? Js.String(foreign.Get("name")) : slug;
            long created = Js.Truthy(foreign.Get("createdAt")) ? (long)Math.Truncate(foreign.Num("createdAt")) : now;
            await store.InsertLinkAsync(new JsObject
            {
                ["id"] = id,
                ["site"] = site,
                ["domain"] = domain,
                ["slug"] = slug,
                ["name"] = Js.Slice(name, 0, 100),
                ["url"] = foreign.Get("url"),
                ["createdAt"] = created,
                ["updatedAt"] = created,
            }, cancellationToken).ConfigureAwait(false);
        }, cancellationToken).ConfigureAwait(false);
        if (domain.Length > 0)
        {
            runlight.ForgetLinkDomains();
        }
        return new JsObject { ["status"] = "created", ["clicks"] = clicks };
    }
}
