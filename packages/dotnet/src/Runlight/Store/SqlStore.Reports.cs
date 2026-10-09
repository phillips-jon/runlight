using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Db;

namespace Runlight.Store;

public sealed partial class SqlStore
{
    /// <summary>When Runlight itself first counted a visit, leaving out imported history.</summary>
    public async Task<double?> FirstOwnVisitAsync(string site, CancellationToken cancellationToken = default)
    {
        // A session opened only by a short link click is not a visit, so it does not count as the first.
        var row = await Db.FirstAsync("SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND " + Sql.IsVisit, A(site), cancellationToken).ConfigureAwait(false);
        return row == null || row.Get("t") == null ? null : Sql.Num(row.Get("t"));
    }

    /// <summary>When the site's first visit was recorded, or null with no data yet.</summary>
    public async Task<double?> FirstSeenAsync(string site, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?", A(site), cancellationToken).ConfigureAwait(false);
        return row == null || row.Get("t") == null ? null : Sql.Num(row.Get("t"));
    }

    /// <summary>Just the visitor count from stats, in one query, for conversion rates.</summary>
    public async Task<double> VisitorsAsync(JsObject query, CancellationToken cancellationToken = default)
    {
        string site = query.Str("site")!;
        var scope = Sql.VisitScope(Sql.Filters(query), site, query.Long("from"), query.Long("to"), Dialect);
        var row = await Db.FirstAsync(
            "SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + scope.Sql,
            [site, query.Get("from"), query.Get("to"), .. scope.Params],
            cancellationToken).ConfigureAwait(false);
        return Sql.Num(row?.Get("visitors"));
    }

    /// <summary>{ visitors, visits, pageviews, viewsPerVisit, bounceRate, visitDuration }.</summary>
    public async Task<JsObject> StatsAsync(JsObject query, CancellationToken cancellationToken = default)
    {
        var rolled = await RolledStatsAsync(query, cancellationToken).ConfigureAwait(false);
        if (rolled != null)
        {
            return rolled;
        }
        string site = query.Str("site")!;
        long from = query.Long("from");
        long to = query.Long("to");
        var filters = Sql.Filters(query);
        // Filtered or not, the numbers describe visits that started in the range (see VisitScope).
        var scope = Sql.VisitScope(filters, site, from, to, Dialect);
        var pv = Sql.PageviewsOf(filters, site, from, to, Dialect);
        var row = await Db.FirstAsync(
            "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(" + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews") + ") AS pageviews,\n         SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced, SUM(" + Sql.Duration + ") AS duration\n       FROM rl_sessions s " + (pv != null ? "LEFT JOIN " + pv.Sql + " pv ON pv.session = s.id" : "") + "\n       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + scope.Sql,
            [.. pv?.Params ?? [], site, from, to, .. scope.Params],
            cancellationToken).ConfigureAwait(false);
        return StatsOf(Sql.Num(row?.Get("visitors")), Sql.Num(row?.Get("visits")), Sql.Num(row?.Get("pageviews")), Sql.Num(row?.Get("bounced")), Sql.Num(row?.Get("duration")));
    }

    /// <summary>Each bucket's { start, visitors, visits, pageviews, viewsPerVisit, bounceRate, visitDuration }.</summary>
    public async Task<List<JsObject>> SeriesAsync(JsObject query, IReadOnlyList<JsObject> buckets, CancellationToken cancellationToken = default)
    {
        if (buckets.Count == 0)
        {
            return [];
        }
        if (buckets.Count > Sql.BucketsPerQuery)
        {
            return await Sql.InPiecesAsync(buckets, Sql.BucketsPerQuery, piece => SeriesAsync(query, piece, cancellationToken)).ConfigureAwait(false);
        }
        string site = query.Str("site")!;
        var filters = Sql.Filters(query);
        var parameters = BucketParams(buckets);
        long first = buckets[0].Long("start");
        long last = buckets[^1].Long("end");
        string dialect = Dialect;
        // Filtered or not, each bucket counts the visits that started in it (see VisitScope).
        var scope = Sql.VisitScope(filters, site, first, last, dialect);
        var pv = Sql.PageviewsOf(filters, site, first, last, dialect);
        // Built days that fit inside one bucket come from rollups; the rest from the visits.
        var plan = await RollupPlanAsync(query, first, last, cancellationToken).ConfigureAwait(false);
        int InBucket((string Day, double Start, double End) d)
        {
            for (int i = 0; i < buckets.Count; i++)
            {
                if (buckets[i].Num("start") <= d.Start && d.End <= buckets[i].Num("end"))
                {
                    return i;
                }
            }
            return -1;
        }
        var used = plan != null ? plan.Days.Where(d => InBucket(d) >= 0).ToList() : [];
        List<(double, double)>? rest = null;
        if (used.Count > 0)
        {
            rest = [];
            double from = first;
            foreach (var d in used)
            {
                if (d.Start > from)
                {
                    rest.Add((from, d.Start));
                }
                from = Math.Max(from, d.End);
            }
            if (from < last)
            {
                rest.Add((from, last));
            }
        }
        // MySQL joins the buckets to every visit of the site unless told the whole range as well.
        var w = rest != null ? Within(rest) : (dialect == "mysql" ? Within([(first, last)]) : new SqlPart("1 = 1", []));
        // Filters and scattered unbuilt days add values of their own; when they would pass D1's 100,
        // the buckets go in halves.
        if (parameters.Count + 1 + w.Params.Count + scope.Params.Count + (pv?.Params.Count ?? 0) > Sql.MaxParams && buckets.Count > 1)
        {
            int half = (buckets.Count + 1) / 2;
            return
            [
                .. await SeriesAsync(query, buckets.Take(half).ToList(), cancellationToken).ConfigureAwait(false),
                .. await SeriesAsync(query, buckets.Skip(half).ToList(), cancellationToken).ConfigureAwait(false),
            ];
        }
        var sums = new Dictionary<int, Dictionary<string, double>>();
        void Bump(int i, JsObject row)
        {
            if (!sums.TryGetValue(i, out var into))
            {
                into = new Dictionary<string, double>(StringComparer.Ordinal) { ["visitors"] = 0, ["n"] = 0, ["views"] = 0, ["bounced"] = 0, ["duration"] = 0 };
                sums[i] = into;
            }
            foreach (string k in into.Keys.ToList())
            {
                into[k] += Sql.Num(row.Get(k));
            }
        }
        if (used.Count > 0)
        {
            var rolled = await Db.AllAsync(
                "SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (" + Sql.BuiltDays + ")",
                A(site, site, first, last),
                cancellationToken).ConfigureAwait(false);
            var at = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var d in used)
            {
                at[d.Day] = InBucket(d);
            }
            foreach (var row in rolled)
            {
                if (at.TryGetValue(Sql.S(row.Get("day")), out int i))
                {
                    Bump(i, row);
                }
            }
        }
        var rows = await Db.AllAsync(
            "WITH b (i, bs, be) AS (" + Sql.BucketTable(dialect, buckets.Count) + ")\n       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM(" + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews") + ") AS views,\n         SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced, SUM(" + Sql.Duration + ") AS duration\n       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be\n       " + (pv != null ? "LEFT JOIN " + pv.Sql + " pv ON pv.session = s.id" : "") + "\n       WHERE " + Sql.IsVisit + scope.Sql + " AND " + w.Sql + "\n       GROUP BY b.i",
            [.. parameters, site, .. pv?.Params ?? [], .. scope.Params, .. w.Params],
            cancellationToken).ConfigureAwait(false);
        foreach (var row in rows)
        {
            Bump((int)Sql.Num(row.Get("i")), row);
        }
        var output = new List<JsObject>();
        for (int i = 0; i < buckets.Count; i++)
        {
            sums.TryGetValue(i, out var row);
            double n = row?["n"] ?? 0;
            double views = row?["views"] ?? 0;
            output.Add(new JsObject
            {
                ["start"] = buckets[i].Get("start"),
                ["visitors"] = row?["visitors"] ?? 0,
                ["visits"] = n,
                ["pageviews"] = views,
                ["viewsPerVisit"] = n > 0 ? Js.Round(views / n * 100) / 100 : 0.0,
                ["bounceRate"] = n > 0 ? (row?["bounced"] ?? 0) / n : 0.0,
                ["visitDuration"] = n > 0 ? Js.Round((row?["duration"] ?? 0) / n) : 0.0,
            });
        }
        return output;
    }

    /// <summary>A BreakdownRow for each value of a dimension, a page of them.</summary>
    public async Task<List<JsObject>> BreakdownAsync(JsObject query, string dimension, int limit, int offset, CancellationToken cancellationToken = default)
    {
        string site = query.Str("site")!;
        long qFrom = query.Long("from");
        long qTo = query.Long("to");
        var filters = Sql.Filters(query);
        string dialect = Dialect;
        if (dimension is "ai_agent" or "ai_page")
        {
            string col = dimension == "ai_agent" ? "e.name" : "e.path";
            var fetched = await Db.AllAsync(
                "SELECT " + col + " AS value, COUNT(*) AS fetches FROM rl_events e\n         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'\n         GROUP BY " + col + " ORDER BY fetches DESC, " + col + TextOrder() + " LIMIT ? OFFSET ?",
                A(site, qFrom, qTo, limit, offset),
                cancellationToken).ConfigureAwait(false);
            return fetched.Select(row => new JsObject { ["value"] = Sql.S(row.Get("value")), ["visitors"] = 0L, ["fetches"] = Sql.Num(row.Get("fetches")) }).ToList();
        }

        var rolled = await RolledBreakdownAsync(query, dimension, limit, offset, cancellationToken).ConfigureAwait(false);
        if (rolled != null)
        {
            return rolled;
        }

        // Filtered or not, the visits are those that started in the range (see VisitScope).
        var scope = Sql.VisitScope(filters, site, qFrom, qTo, dialect);
        if (Query.IsSessionDimension(dimension))
        {
            var pv = Sql.PageviewsOf(filters, site, qFrom, qTo, dialect);
            string col = "s." + Query.SessionDimensions[dimension];
            bool entryExit = dimension is "entry" or "exit";
            var rows = await Db.AllAsync(
                "SELECT " + col + " AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(" + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews") + ") AS pageviews,\n           SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced, SUM(" + Sql.Duration + ") AS duration\n         FROM rl_sessions s " + (pv != null ? "LEFT JOIN " + pv.Sql + " pv ON pv.session = s.id" : "") + "\n         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + scope.Sql + " AND " + col + " <> ''\n         GROUP BY " + col + " ORDER BY " + (entryExit ? "visits DESC" : "visitors DESC, visits DESC") + ", " + col + TextOrder() + " LIMIT ? OFFSET ?",
                [.. pv?.Params ?? [], site, qFrom, qTo, .. scope.Params, limit, offset],
                cancellationToken).ConfigureAwait(false);
            return rows.Select(row =>
            {
                double visits = Sql.Num(row.Get("visits"));
                var output = new JsObject
                {
                    ["value"] = Sql.S(row.Get("value")),
                    ["visitors"] = Sql.Num(row.Get("visitors")),
                    ["visits"] = visits,
                    ["bounceRate"] = visits > 0 ? Sql.Num(row.Get("bounced")) / visits : 0.0,
                };
                if (!entryExit)
                {
                    output["pageviews"] = Sql.Num(row.Get("pageviews"));
                    output["visitDuration"] = visits > 0 ? Js.Round(Sql.Num(row.Get("duration")) / visits) : 0.0;
                }
                return output;
            }).ToList();
        }

        // Rows from the visits that started in the range and that the filters pick, narrowed by any
        // filter on the same kind of row ("page is /pricing" on pages), as the rollups count them.
        (string Sql, List<object?> Params, long To) InVisits(string[] dimensions)
        {
            var rowScope = Sql.RowScope(filters, dimensions, dialect);
            return (
                " AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + scope.Sql + ")" + rowScope.Sql,
                [site, qFrom, qTo, .. scope.Params, .. rowScope.Params],
                qTo + Sql.EventTailMs);
        }

        if (dimension is "page" or "hostname")
        {
            string col = "e." + Query.EventDimensions[dimension];
            var w = InVisits(["page", "hostname"]);
            var rows = await Db.AllAsync(
                "SELECT " + col + " AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, " + Sql.LiveViews + " AS views\n         FROM rl_events e\n         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'" + w.Sql + "\n         GROUP BY " + col + " ORDER BY visitors DESC, pageviews DESC, " + col + TextOrder() + " LIMIT ? OFFSET ?",
                [site, qFrom, w.To, .. w.Params, limit, offset],
                cancellationToken).ConfigureAwait(false);
            var output = rows.Select(row => new JsObject { ["value"] = Sql.S(row.Get("value")), ["visitors"] = Sql.Num(row.Get("visitors")), ["pageviews"] = Sql.Num(row.Get("pageviews")) }).ToList();
            var live = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var row in rows)
            {
                live[Sql.S(row.Get("value"))] = Sql.Num(row.Get("views"));
            }
            if (dimension == "page" && output.Count > 0)
            {
                // Each pageview's engaged time added up and its deepest scroll, then the mean over
                // pageviews. Filters add values of their own, so fewer paths go in each statement.
                int size = Math.Max(1, Math.Min(Sql.ValuesPerQuery, Sql.MaxParams - 3 - w.Params.Count));
                var times = await Sql.InPiecesAsync(output, size, piece => Db.AllAsync(
                    "SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (\n               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest\n               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'" + w.Sql + "\n               AND e.path IN (" + string.Join(", ", piece.Select(_ => "?")) + ") GROUP BY e.path, e.pageview) t GROUP BY value",
                    [site, qFrom, w.To, .. w.Params, .. piece.Select(p => p.Get("value"))],
                    cancellationToken)).ConfigureAwait(false);
                var byPath = new Dictionary<string, JsObject>(StringComparer.Ordinal);
                foreach (var t in times)
                {
                    byPath[Sql.S(t.Get("value"))] = t;
                }
                foreach (var row in output)
                {
                    string value = row.Str("value")!;
                    byPath.TryGetValue(value, out var time);
                    double views = live.GetValueOrDefault(value);
                    row["timeOnPage"] = time != null && views != 0 ? Js.Round(Sql.Num(time.Get("total")) / views) : 0.0;
                    row["scrollDepth"] = time == null || time.Get("scroll") == null ? 0.0 : Js.Round(Sql.Num(time.Get("scroll")));
                }
            }
            return output;
        }

        if (dimension == "event")
        {
            var w = InVisits(["event"]);
            var rows = await Db.AllAsync(
                "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events\n         FROM rl_events e\n         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'" + w.Sql + "\n         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name" + TextOrder() + " LIMIT ? OFFSET ?",
                [site, qFrom, w.To, .. w.Params, limit, offset],
                cancellationToken).ConfigureAwait(false);
            return rows.Select(row => new JsObject { ["value"] = Sql.S(row.Get("value")), ["visitors"] = Sql.Num(row.Get("visitors")), ["events"] = Sql.Num(row.Get("events")) }).ToList();
        }

        return [];
    }

    /// <summary>
    /// Visits by quarter hour since the epoch, which the caller folds into local weekdays and hours,
    /// keeping time zones (DST included) out of SQL: [{ quarter, visits, visitors, pageviews, bounced }].
    /// </summary>
    public async Task<List<JsObject>> HourlyAsync(JsObject query, CancellationToken cancellationToken = default)
    {
        string dialect = Dialect;
        string site = query.Str("site")!;
        long qFrom = query.Long("from");
        long qTo = query.Long("to");
        var plan = await RollupPlanAsync(query, qFrom, qTo, cancellationToken).ConfigureAwait(false);
        if (plan != null)
        {
            var sums = new OrderedDictionary<string, JsObject>(StringComparer.Ordinal);
            void Bump(double quarter, JsObject row)
            {
                string key = Js.String(quarter);
                if (!sums.TryGetValue(key, out var into))
                {
                    into = new JsObject { ["quarter"] = quarter, ["visits"] = 0.0, ["visitors"] = 0.0, ["pageviews"] = 0.0, ["bounced"] = 0.0 };
                    sums[key] = into;
                }
                foreach (string k in new[] { "visits", "visitors", "pageviews", "bounced" })
                {
                    into[k] = into.Num(k) + Sql.Num(row.Get(k));
                }
            }
            var rolled = await Db.AllAsync(
                "SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN (" + Sql.BuiltDays + ")",
                A(site, site, qFrom, qTo),
                cancellationToken).ConfigureAwait(false);
            foreach (var row in rolled)
            {
                Bump(Js.Number(Sql.S(row.Get("value"))), row);
            }
            var w = Within(plan.Rest);
            var raw = await Db.AllAsync(
                "SELECT " + Sql.Div(dialect, "s.started_at", 900000) + " AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,\n           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced\n         FROM rl_sessions s WHERE s.site = ? AND " + w.Sql + " AND " + Sql.IsVisit + " GROUP BY 1",
                [site, .. w.Params],
                cancellationToken).ConfigureAwait(false);
            foreach (var row in raw)
            {
                Bump(Math.Floor(Sql.Num(row.Get("quarter"))), row);
            }
            return [.. sums.Values];
        }
        var filters = Sql.Filters(query);
        var matching = Sql.VisitScope(filters, site, qFrom, qTo, dialect);
        // A page filter counts that page's views as pageviews here too, as the cards do.
        var pv = Sql.PageviewsOf(filters, site, qFrom, qTo, dialect);
        var rows = await Db.AllAsync(
            "SELECT " + Sql.Div(dialect, "s.started_at", 900000) + " AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,\n         SUM(" + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews") + ") AS pageviews, SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced\n       FROM rl_sessions s " + (pv != null ? "LEFT JOIN " + pv.Sql + " pv ON pv.session = s.id" : "") + "\n       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + matching.Sql + "\n       GROUP BY 1",
            [.. pv?.Params ?? [], site, qFrom, qTo, .. matching.Params],
            cancellationToken).ConfigureAwait(false);
        return rows.Select(row => new JsObject
        {
            ["quarter"] = Math.Floor(Sql.Num(row.Get("quarter"))),
            ["visits"] = Sql.Num(row.Get("visits")),
            ["visitors"] = Sql.Num(row.Get("visitors")),
            ["pageviews"] = Sql.Num(row.Get("pageviews")),
            ["bounced"] = Sql.Num(row.Get("bounced")),
        }).ToList();
    }

    /// <summary>{ visitors, pages, sources, countries, minutes, recent }.</summary>
    public async Task<JsObject> RealtimeAsync(string site, long now, CancellationToken cancellationToken = default)
    {
        long since = now - 5 * 60_000;
        var active = await Db.FirstAsync(
            "SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')",
            A(site, since),
            cancellationToken).ConfigureAwait(false);
        var pages = await Db.AllAsync(
            "SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events\n       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path" + TextOrder() + " LIMIT 10",
            A(site, since),
            cancellationToken).ConfigureAwait(false);
        var sources = await Db.AllAsync(
            "SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''\n       GROUP BY s.source ORDER BY visitors DESC, s.source" + TextOrder() + " LIMIT 10",
            A(site, since),
            cancellationToken).ConfigureAwait(false);
        long start = (long)Math.Floor(now / 60_000.0) * 60_000 - 29 * 60_000;
        var perMinute = await Db.AllAsync(
            "SELECT " + Sql.Div(Dialect, "(ts - ?)", 60000) + " AS m, COUNT(*) AS n FROM rl_events\n       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1",
            A(start, site, start),
            cancellationToken).ConfigureAwait(false);
        var minutes = new double[30];
        foreach (var row in perMinute)
        {
            int index = (int)Math.Floor(Sql.Num(row.Get("m")));
            if (index >= 0 && index < 30)
            {
                minutes[index] += Sql.Num(row.Get("n"));
            }
        }
        var countries = await Db.AllAsync(
            "SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''\n       GROUP BY s.country ORDER BY visitors DESC, s.country" + TextOrder() + " LIMIT 10",
            A(site, since),
            cancellationToken).ConfigureAwait(false);
        var recent = await Db.AllAsync(
            "SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20",
            A(site, start),
            cancellationToken).ConfigureAwait(false);
        static List<object?> Pairs(List<JsObject> rows) => [.. rows.Select(row => (object?)new JsObject { ["value"] = Sql.S(row.Get("value")), ["visitors"] = Sql.Num(row.Get("visitors")) })];
        return new JsObject
        {
            ["visitors"] = Sql.Num(active?.Get("n")),
            ["pages"] = Pairs(pages),
            ["sources"] = Pairs(sources),
            ["countries"] = Pairs(countries),
            ["minutes"] = minutes.Select(m => (object?)m).ToList(),
            ["recent"] = recent.Select(r => (object?)new JsObject
            {
                ["ts"] = Sql.Num(r.Get("ts")),
                ["kind"] = Sql.S(r.Get("kind")),
                ["path"] = Sql.S(r.Get("path")),
                ["name"] = Sql.S(r.Get("name")),
                ["country"] = Sql.S(r.Get("country")),
                ["city"] = Sql.S(r.Get("city")),
                ["source"] = Sql.S(r.Get("source")),
                ["device"] = Sql.S(r.Get("device")),
            }).ToList(),
        };
    }
}
