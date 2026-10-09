using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;

namespace Runlight.Importers;

/// <summary>
/// Visit history from Umami: pageviews and custom events with where each visit came from, its place, and its
/// device, written as imported visits so the dashboard's history does not start the day Runlight was installed.
/// </summary>
/// <remarks>
/// <para>
/// The dashboard drives it a few days at a time, oldest first, so it fits any host's time limit and shows
/// progress. It stops where Runlight's own visits begin, so nothing is counted twice, and it remembers how far
/// it got, so running it again carries on from there.
/// </para>
/// <para>
/// An ImportedHit, the shape every visit import writes, is a JsObject: <c>ts</c>, <c>key</c> (groups rows into
/// visitors, as Umami's session id does), <c>kind</c> ("pageview" or "event"), and the strings <c>hostname</c>,
/// <c>path</c>, <c>query</c>, <c>referrer</c>, <c>title</c>, <c>name</c>, <c>country</c>, <c>region</c>,
/// <c>city</c>, <c>browser</c>, <c>os</c>, <c>device</c>, <c>screen</c>, <c>language</c>.
/// </para>
/// </remarks>
public static partial class Visits
{
    private const long Day = 86_400_000;

    /// <summary>Each step reads at most this many days, or stops after this many events.</summary>
    private const long StepDays = 14;

    private const int StepEvents = 5_000;

    /// <summary>A single day with more than this is refused rather than read without end.</summary>
    private const int MaxDayEvents = 200_000;

    /// <summary>Umami's event types that are visits: a pageview, and a custom event.</summary>
    private const long Pageview = 1;

    private const long CustomEvent = 2;

    [GeneratedRegex("^[A-Za-z0-9-]{1,64}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex WebsiteId();

    private static string ProgressKey(string site, string website) => "import:umami-visits:" + site + ":" + website;

    /// <summary>The websites an Umami account can see ([{ id, name, domain }]), to pick which one becomes this site's history.</summary>
    public static async Task<List<JsObject>> UmamiWebsitesAsync(JsObject credentials, IFetcher? fetcher = null, CancellationToken cancellationToken = default)
    {
        var http = new Http(fetcher);
        var (baseUrl, token) = await Umami.UmamiSignInAsync(http, credentials, cancellationToken: cancellationToken).ConfigureAwait(false);
        var headers = new JsObject { ["authorization"] = "Bearer " + Js.String(token) };
        var output = new List<JsObject>();
        for (int page = 1; page < 100; page++)
        {
            var body = await http.GetJsonAsync(baseUrl + "/api/websites?page=" + Js.Str(page) + "&pageSize=100", headers, cancellationToken: cancellationToken).ConfigureAwait(false) as JsObject;
            var data = body?.Arr("data") ?? [];
            foreach (var w in data.OfType<JsObject>())
            {
                output.Add(new JsObject { ["id"] = w.Get("id"), ["name"] = w.Get("name"), ["domain"] = w.Get("domain") });
            }
            if (output.Count >= Count(body) || data.Count == 0)
            {
                break;
            }
        }
        return output;
    }

    /// <summary><c>body.count ?? Infinity</c>, as a number.</summary>
    private static double Count(JsObject? body)
    {
        object? count = body?.Get("count");
        return count is null or Undefined ? double.PositiveInfinity : Js.Number(count);
    }

    /// <summary>Every page of an Umami list for a time window.</summary>
    private static async Task<List<JsObject>> AllAsync(Http http, string baseUrl, string path, JsObject headers, int limit, CancellationToken cancellationToken)
    {
        var output = new List<JsObject>();
        for (int page = 1; ; page++)
        {
            var body = await http.GetJsonAsync(baseUrl + "/api" + path + "&page=" + Js.Str(page) + "&pageSize=1000", headers, cancellationToken: cancellationToken).ConfigureAwait(false) as JsObject;
            var data = body?.Arr("data") ?? [];
            output.AddRange(data.OfType<JsObject>());
            if (output.Count >= Count(body) || data.Count == 0)
            {
                return output;
            }
            if (output.Count > limit)
            {
                string text = limit.ToString("#,0", CultureInfo.InvariantCulture);
                throw new ImportError("One day has more than " + text + " events, more than an import step can read", "import_day_full", new JsObject { ["limit"] = Js.Str(limit) });
            }
        }
    }

    /// <summary>One step: read the next few days from Umami and write them as imported visits.</summary>
    /// <returns>{ cursor, done, total, pageviews, events, visits }.</returns>
    public static async Task<JsObject> ImportUmamiVisitsAsync(Runlight runlight, string siteId, JsObject credentials, string website, string? cursor, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(runlight);
        ArgumentNullException.ThrowIfNull(credentials);
        await runlight.InitAsync(cancellationToken).ConfigureAwait(false);
        if (runlight.Site(siteId) == null)
        {
            throw new ImportError("Unknown site", "unknown_site");
        }
        if (!WebsiteId().IsMatch(website))
        {
            throw new ImportError("Pick the Umami website to import", "import_website");
        }
        var http = new Http(runlight.Fetcher);

        var saved = !string.IsNullOrEmpty(cursor) ? Json.Parse(cursor) as JsObject : null;
        var (baseUrl, token) = await Umami.UmamiSignInAsync(http, credentials, saved?.Get("token"), cancellationToken).ConfigureAwait(false);
        var headers = new JsObject { ["authorization"] = "Bearer " + Js.String(token) };
        JsObject state;
        if (saved != null && saved.Get("website") is string w && w == website)
        {
            state = saved;
        }
        else
        {
            var info = await http.GetJsonAsync(baseUrl + "/api/websites/" + website, headers, cancellationToken: cancellationToken).ConfigureAwait(false);
            double created = Http.ParseDate(Http.Field(info, "createdAt"));
            created = Js.Truthy(created) ? created : runlight.Now();
            // Carry on where an earlier run stopped, and end where Runlight's own visits begin.
            // A saved place that does not read as a number is ignored, as if there were none.
            double stored = Js.Number(await runlight.Store.SettingAsync(ProgressKey(siteId, website), cancellationToken).ConfigureAwait(false) ?? (object)0L);
            double resumed = double.IsFinite(stored) ? stored : 0;
            // Never older than the site keeps, or the next scheduled check would delete it again.
            double cutoff = await runlight.RetentionCutoffAsync(siteId, cancellationToken).ConfigureAwait(false) ?? 0;
            long start = (long)Math.Max(Math.Max(Math.Floor(created / Day) * Day, resumed), Math.Ceiling(cutoff / Day) * Day);
            double? own = await runlight.Store.FirstOwnVisitAsync(siteId, cancellationToken).ConfigureAwait(false);
            state = new JsObject { ["website"] = website, ["day"] = start, ["start"] = start, ["end"] = (long)(own ?? runlight.Now()) };
        }
        bool usesKey = Js.Trim(Js.String(credentials.Get("apiKey") ?? "")).Length > 0;

        // Read whole days until the step has enough.
        var events = new List<JsObject>();
        long from = (long)state.Num("day");
        long to = from;
        long end = (long)state.Num("end");
        while (to < end && to - from < StepDays * Day && events.Count < StepEvents)
        {
            long next = Math.Min(to + Day, end);
            events.AddRange(await AllAsync(http, baseUrl, "/websites/" + website + "/events?startAt=" + Js.Str(to) + "&endAt=" + Js.Str(next - 1), headers, MaxDayEvents, cancellationToken).ConfigureAwait(false));
            to = next;
        }
        var sessions = events.Count > 0
            ? await AllAsync(http, baseUrl, "/websites/" + website + "/sessions?startAt=" + Js.Str(from) + "&endAt=" + Js.Str(to - 1), headers, MaxDayEvents * (int)StepDays, cancellationToken).ConfigureAwait(false)
            : [];
        var bySession = new Dictionary<string, JsObject>(StringComparer.Ordinal);
        foreach (var s in sessions)
        {
            bySession[Js.String(s.Prop("id"))] = s;
        }

        string ns = "umami-visits:" + website;
        var visits = new List<(long Ts, JsObject Event)>();
        foreach (var e in events)
        {
            double type = e.Get("eventType") is long or double ? e.Num("eventType") : double.NaN;
            if (!(type == Pageview || (type == CustomEvent && Js.Truthy(e.Get("eventName")))))
            {
                continue;
            }
            double ts = Http.ParseDate(e.Get("createdAt"));
            if (!double.IsFinite(ts) || ts >= end)
            {
                continue;
            }
            visits.Add(((long)ts, e));
        }
        var hits = visits.OrderBy(v => v.Ts)
            .Select(v => (ns, FromUmami(v.Event, v.Ts, bySession.GetValueOrDefault(Js.String(v.Event.Prop("sessionId"))))))
            .ToList();
        var counts = await WriteStepAsync(runlight, siteId, from, to, hits, store => store.SetSettingAsync(ProgressKey(siteId, website), Js.Str(to), cancellationToken), cancellationToken).ConfigureAwait(false);

        long start2 = (long)state.Num("start");
        long totalDays = (long)Math.Max(1, Math.Ceiling((end - start2) / (double)Day));
        long doneDays = (long)Math.Min(totalDays, Math.Ceiling((to - start2) / (double)Day));
        bool more = to < end;
        var nextState = state.With(new JsObject { ["day"] = to });
        if (!usesKey)
        {
            nextState["token"] = token;
        }
        return new JsObject
        {
            ["cursor"] = more ? Json.Stringify(nextState) : null,
            ["done"] = doneDays,
            ["total"] = totalDays,
        }.With(counts);
    }

    /// <summary>
    /// Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier import
    /// left in those times is cleared first, so a step can always run again, and a visit carried in from the step
    /// before is counted again from its rows. <paramref name="done"/> runs in the same transaction, to remember
    /// how far it got.
    /// </summary>
    private static async Task<JsObject> WriteStepAsync(Runlight runlight, string siteId, long from, long to, List<(string Ns, JsObject Hit)> hits, Func<SqlStore, Task>? done, CancellationToken cancellationToken)
    {
        var site = runlight.Site(siteId) ?? throw new ImportError("Unknown site", "unknown_site");
        long pageviews = 0;
        long events = 0;
        long visits = 0;
        await runlight.Store.TransactionAsync(async store =>
        {
            pageviews = 0;
            events = 0;
            visits = 0;
            // Days this step writes into are added up again later, with the imported visits in them.
            await store.ClearRollupsAsync(siteId, from: from, to: to, cancellationToken: cancellationToken).ConfigureAwait(false);
            // A failed earlier try at these days (on D1, which has no transactions) can
            // have left part of them behind. Clear it, so every step can safely run again.
            const string imported = "SELECT id FROM rl_sessions WHERE site = ? AND imported = 1";
            await store.Db.RunAsync("DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN (" + imported + ")", [siteId, from, to, siteId], cancellationToken).ConfigureAwait(false);
            // Visits of these days that kept no rows go too. Their rows would come within EVENT_TAIL_MS of the step,
            // so the time bounds let the (site, ts) index find them, with no scan of every event.
            await store.Db.RunAsync(
                "DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?\n         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
                [siteId, from, to, siteId, from, to + SqlStore.EventTailMs],
                cancellationToken).ConfigureAwait(false);
            foreach (var (ns, hit) in hits)
            {
                if (await WriteEventAsync(store, site, ns, hit, cancellationToken).ConfigureAwait(false))
                {
                    visits++;
                }
                if (hit.Str("kind") == "pageview")
                {
                    pageviews++;
                }
                else
                {
                    events++;
                }
            }
            // A visit that began in an earlier step and went on into this one is counted
            // again from its rows, so a repeated step cannot leave it with doubled totals.
            // The day it began may already be built, so that day is built again too.
            var carried = await store.Db.AllAsync(
                "SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s\n       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?\n         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
                [siteId, from, from - SqlStore.EventTailMs, siteId, from, to],
                cancellationToken).ConfigureAwait(false);
            if (carried.Count > 0)
            {
                long earliest = (long)carried.Min(c => Js.Number(c.Get("started_at")));
                await store.ClearRollupsAsync(siteId, from: earliest, to: from, cancellationToken: cancellationToken).ConfigureAwait(false);
                // Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
                // Ninety ids a statement, within Cloudflare D1's 100 values.
                var rows = new List<JsObject>();
                foreach (var chunk in carried.Chunk(90))
                {
                    var ids = chunk.Select(c => (object?)Sql.S(c.Get("id"))).ToList();
                    rows.AddRange(await store.Db.AllAsync(
                        "SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e\n             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN (" + string.Join(", ", ids.Select(_ => "?")) + ")\n             ORDER BY e.ts, e.id",
                        [siteId, earliest, to, .. ids],
                        cancellationToken).ConfigureAwait(false));
                }
                var totals = new Dictionary<string, (long Pageviews, long Events, double Last, string? Exit)>(StringComparer.Ordinal);
                var order = new List<string>();
                foreach (var r in rows)
                {
                    string session = Sql.S(r.Get("session"));
                    if (!totals.TryGetValue(session, out var t))
                    {
                        t = (0, 0, 0, null);
                        order.Add(session);
                    }
                    if (Sql.S(r.Get("kind")) == "pageview")
                    {
                        t.Pageviews++;
                        t.Exit = Sql.S(r.Get("path"));
                    }
                    else
                    {
                        t.Events++;
                    }
                    t.Last = Math.Max(t.Last, Js.Number(r.Get("ts")));
                    totals[session] = t;
                }
                foreach (string id in order)
                {
                    var t = totals[id];
                    await store.Db.RunAsync("UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?", [t.Pageviews, t.Events, (long)t.Last, t.Exit, id], cancellationToken).ConfigureAwait(false);
                }
            }
            if (done != null)
            {
                await done(store).ConfigureAwait(false);
            }
        }, cancellationToken).ConfigureAwait(false);
        return new JsObject { ["pageviews"] = pageviews, ["events"] = events, ["visits"] = visits };
    }

    private static string ReferrerOf(object? domain, object? path, object? query)
    {
        if (!Js.Truthy(domain))
        {
            return "";
        }
        string p = Js.Truthy(path) ? Js.String(path) : "/";
        string q = Js.Truthy(query) ? "?" + Write.Query(Js.String(query)) : "";
        return "https://" + Js.String(domain) + p + q;
    }

    private static JsObject FromUmami(JsObject e, long ts, JsObject? session)
    {
        static string Text(object? value) => value is null or Undefined ? "" : Js.String(value);
        object? s(string key) => session?.Get(key);
        object? region = Js.Truthy(s("subdivision1")) ? s("subdivision1") : Js.Truthy(s("region")) ? s("region") : "";
        return new JsObject
        {
            ["ts"] = ts,
            ["key"] = Js.String(e.Prop("sessionId")),
            ["kind"] = e.Num("eventType") == Pageview ? "pageview" : "event",
            ["hostname"] = Text(e.Get("hostname")),
            ["path"] = Text(e.Get("urlPath")),
            ["query"] = Text(e.Get("urlQuery")),
            ["referrer"] = ReferrerOf(e.Get("referrerDomain"), e.Get("referrerPath"), e.Get("referrerQuery")),
            ["title"] = Text(e.Get("pageTitle")),
            ["name"] = Text(e.Get("eventName")),
            ["country"] = Text(e.Get("country")),
            ["region"] = Js.String(region),
            ["city"] = Text(e.Get("city")),
            ["browser"] = Text(e.Get("browser")),
            ["os"] = Text(e.Get("os")),
            ["device"] = Text(e.Get("device")),
            ["screen"] = Text(s("screen")),
            ["language"] = Text(s("language")),
        };
    }

    /// <summary>
    /// Writes one imported pageview or event as part of a Runlight visit. Visitors are hashed per day from the
    /// hit's key, as live visitors are hashed per day, and a hit within thirty minutes of the visitor's last one
    /// joins that visit. Ids come from <paramref name="ns"/> and the key, so importing the same rows again makes
    /// the same ids. Returns whether it started a new visit.
    /// </summary>
    private static async Task<bool> WriteEventAsync(SqlStore store, JsObject site, string ns, JsObject e, CancellationToken cancellationToken)
    {
        long ts = e.Long("ts");
        string key = Js.String(e.Get("key"));
        string siteId = site.Str("id")!;
        string timezone = site.Str("timezone") ?? "UTC";
        var siteHosts = site.Arr("hostnames")?.OfType<string>().ToList() ?? [];
        // The site's own day, as live visitors are counted, so days add up the same way in rollups.
        string day = Time.LocalDate(ts, timezone);
        string visitor = Write.HexId(ns + ":" + key + ":" + day, 16);
        // A visit that runs past midnight keeps the id it started with, as a live one does.
        string yesterday = Write.HexId(ns + ":" + key + ":" + Time.AddDays(day, -1), 16);
        string hostname = e.Str("hostname") ?? "";
        string host = Js.Lower(hostname.Length > 0 ? hostname : (siteHosts.Count > 0 ? siteHosts[0] : "imported.invalid"));
        string path = e.Str("path") ?? "";
        string query = e.Str("query") ?? "";
        var url = Url.Parse("https://" + host + (path.Length > 0 ? path : "/") + (query.Length > 0 ? "?" + Write.Query(query) : ""))
            ?? new Url("https://" + host + "/");
        var page = Sources.ParsePage(url);
        var open = await store.OpenSessionAsync(siteId, [visitor, yesterday], ts - Runlight.SessionIdleMs, cancellationToken).ConfigureAwait(false);
        string? id = open?.Str("id");
        if (id == null)
        {
            id = Write.HexId(ns + ":" + key + ":" + Js.Str(ts));
            await store.Db.RunAsync("DELETE FROM rl_sessions WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
            string country = Js.Slice(Js.Upper(e.Str("country") ?? ""), 0, 2);
            string rawRegion = e.Str("region") ?? "";
            string region = rawRegion.Length > 0 ? Js.Slice(Js.Upper(rawRegion.Contains('-', StringComparison.Ordinal) ? rawRegion : country + "-" + rawRegion), 0, 10) : "";
            bool known = Write.IsCountry(country);
            var utm = page.Obj("utm")!;
            var row = new JsObject
            {
                ["id"] = id,
                ["site"] = siteId,
                ["visitor"] = visitor,
                ["startedAt"] = ts,
                ["hostname"] = page.Get("hostname"),
            }
                .With(Sources.Attribute(page, e.Str("referrer") ?? "", siteHosts))
                .With(new JsObject
                {
                    ["utmSource"] = utm.Get("source"),
                    ["utmMedium"] = utm.Get("medium"),
                    ["utmCampaign"] = utm.Get("campaign"),
                    ["utmTerm"] = utm.Get("term"),
                    ["utmContent"] = utm.Get("content"),
                    ["country"] = known ? country : "",
                    ["region"] = known ? region : "",
                    ["city"] = Js.Slice(e.Str("city") ?? "", 0, 100),
                    ["browser"] = Write.Browser(e.Str("browser") ?? ""),
                    ["browserVersion"] = "",
                    ["os"] = Write.System(e.Str("os") ?? ""),
                    ["osVersion"] = "",
                    ["device"] = Write.Device(e.Str("device") ?? ""),
                    ["screen"] = Js.Slice(e.Str("screen") ?? "", 0, 20),
                    ["language"] = Js.Slice(e.Str("language") ?? "", 0, 35),
                });
            await store.InsertSessionAsync(row, cancellationToken).ConfigureAwait(false);
            // No engaged time is known, so duration falls back to first-to-last pageview.
            await store.Db.RunAsync("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
        }
        string kind = e.Str("kind")!;
        await store.TouchSessionAsync(id, ts, kind, page.Str("path")!, cancellationToken: cancellationToken).ConfigureAwait(false);
        await store.InsertEventAsync(new JsObject
        {
            ["site"] = siteId,
            ["ts"] = ts,
            ["kind"] = kind,
            // The visit's own visitor, which for one running past midnight is the id of the day it started.
            ["visitor"] = open?.Str("visitor") ?? visitor,
            ["session"] = id,
            ["pageview"] = "",
            ["path"] = page.Get("path"),
            ["hostname"] = page.Get("hostname"),
            ["title"] = kind == "pageview" ? Js.Slice(e.Str("title") ?? "", 0, 300) : "",
            ["name"] = kind == "event" ? Js.Slice(e.Str("name") ?? "", 0, 120) : "",
            ["props"] = null,
            ["engagedMs"] = 0L,
            ["scroll"] = null,
            ["link"] = "",
        }, cancellationToken).ConfigureAwait(false);
        return open == null;
    }

    /// <summary>
    /// One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from before
    /// Runlight's own first visit, and within what the site keeps, are written. A batch can run again: its time
    /// span is cleared first, so batches must not share a moment, which the dashboard sees to.
    /// </summary>
    /// <param name="runlight">The Runlight.</param>
    /// <param name="siteId">The site.</param>
    /// <param name="rows">The rows, a list of objects keyed by column (as JSON parses them).</param>
    /// <param name="cancellationToken">Stops the work.</param>
    /// <returns>{ pageviews, events, visits, skipped }.</returns>
    public static async Task<JsObject> ImportCsvVisitsAsync(Runlight runlight, string siteId, object? rows, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(runlight);
        await runlight.InitAsync(cancellationToken).ConfigureAwait(false);
        if (runlight.Site(siteId) == null)
        {
            throw new ImportError("Unknown site", "unknown_site");
        }
        if (rows is not List<object?> list || list.Count > CsvVisits.CsvBatch)
        {
            throw new ImportError("Send at most " + Js.Str(CsvVisits.CsvBatch) + " rows at a time", "import_csv_batch", new JsObject { ["max"] = Js.Str(CsvVisits.CsvBatch) });
        }
        var clean = new List<JsObject>();
        foreach (object? r in list)
        {
            var row = new JsObject();
            if (r is JsObject o)
            {
                foreach (var (k, v) in o)
                {
                    row[Js.Lower(Js.Trim(k))] = v is null or Undefined ? "" : Js.String(v);
                }
            }
            clean.Add(row);
        }
        string? format = CsvVisits.CsvFormat(clean.Count > 0 ? [.. clean[0].Keys] : []) ?? throw new ImportError("This CSV is not an Umami export or Runlight's visit format", "import_csv_format");
        double cutoff = await runlight.RetentionCutoffAsync(siteId, cancellationToken).ConfigureAwait(false) ?? 0;
        double end = Math.Min(await runlight.Store.FirstOwnVisitAsync(siteId, cancellationToken).ConfigureAwait(false) ?? double.PositiveInfinity, runlight.Now());
        var hits = new List<(string Ns, JsObject Hit)>();
        foreach (var row in clean)
        {
            var h = CsvVisits.CsvHit(row, format);
            if (h != null && h.Value.Hit.Num("ts") >= cutoff && h.Value.Hit.Num("ts") < end)
            {
                h.Value.Hit["ts"] = (long)Math.Truncate(h.Value.Hit.Num("ts"));
                hits.Add(h.Value);
            }
        }
        hits = [.. hits.OrderBy(h => h.Hit.Long("ts"))];
        long skipped = clean.Count - hits.Count;
        if (hits.Count == 0)
        {
            return new JsObject { ["pageviews"] = 0L, ["events"] = 0L, ["visits"] = 0L, ["skipped"] = skipped };
        }
        var counts = await WriteStepAsync(runlight, siteId, hits[0].Hit.Long("ts"), hits[^1].Hit.Long("ts") + 1, hits, null, cancellationToken).ConfigureAwait(false);
        return counts.With(new JsObject { ["skipped"] = skipped });
    }
}
