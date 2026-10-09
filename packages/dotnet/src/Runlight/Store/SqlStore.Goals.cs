using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Db;

namespace Runlight.Store;

public sealed partial class SqlStore
{
    // Funnels

    public async Task<List<JsObject>> FunnelsAsync(string site, CancellationToken cancellationToken = default) =>
        (await Db.AllAsync("SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id", A(site), cancellationToken).ConfigureAwait(false))
            .Select(r => new JsObject
            {
                ["id"] = Sql.S(r.Get("id")),
                ["site"] = Sql.S(r.Get("site")),
                ["name"] = Sql.S(r.Get("name")),
                ["steps"] = Json.Parse(Sql.S(r.Get("steps"))),
                ["createdAt"] = Js.Number(r.Get("created_at")),
            }).ToList();

    public Task SaveFunnelAsync(JsObject f, CancellationToken cancellationToken = default) => Db.RunAsync(
        Sql.Upsert(Dialect, "rl_funnels", ["id", "site", "name", "steps", "created_at"], ["id"], ["name", "steps"]),
        A(f.Get("id"), f.Get("site"), f.Get("name"), Json.Stringify(f.Get("steps")), f.Get("createdAt")),
        cancellationToken);

    public Task DeleteFunnelAsync(string id, CancellationToken cancellationToken = default) =>
        Db.RunAsync("DELETE FROM rl_funnels WHERE id = ?", A(id), cancellationToken);

    /// <summary>
    /// How many visits reached each step, in order, within the same visit. Step one is the first
    /// matching row in the range; each later step must come after the step before it. Filters choose
    /// which visits enter the funnel.
    /// </summary>
    public async Task<List<double>> FunnelCountsAsync(JsObject query, JsObject funnel, CancellationToken cancellationToken = default)
    {
        // The rows of the picked visits that match any step, in order, read once and walked here: a
        // join from each step to the next is planned badly by Postgres, which cannot guess how many
        // visits go on.
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, query.Long("from"), query.Long("to"), Dialect);
        var steps = funnel.Arr("steps")!.Cast<JsObject>().ToList();
        var scopes = steps.Select(step => GoalScope(new JsObject { ["kind"] = step.Get("kind"), ["match"] = step.Get("match"), ["name"] = step.Get("match") })).ToList();
        var cases = new List<string>();
        var any = new List<string>();
        var scopeParams = new List<object?>();
        for (int i = 0; i < scopes.Count; i++)
        {
            cases.Add("CASE WHEN " + scopes[i].Sql + " THEN 1 ELSE 0 END AS m" + i);
            any.Add("(" + scopes[i].Sql + ")");
            scopeParams.AddRange(scopes[i].Params);
        }
        var rows = await Db.AllAsync(
            "SELECT e.session AS session, " + string.Join(", ", cases) + "\n       FROM " + v.From + " WHERE " + v.Sql + " AND (" + string.Join(" OR ", any) + ")\n       ORDER BY e.session, e.ts, e.id",
            [.. scopeParams, .. v.Params, .. scopeParams],
            cancellationToken).ConfigureAwait(false);
        var counts = new double[steps.Count];
        object? session = null;
        bool started = false;
        int reached = 0;
        void Close()
        {
            for (int i = 0; i < reached; i++)
            {
                counts[i]++;
            }
        }
        foreach (var row in rows)
        {
            if (!started || !Equals(row.Get("session"), session))
            {
                Close();
                session = row.Get("session");
                started = true;
                reached = 0;
            }
            // Each step is the first matching row after the step before, so two steps in the same
            // millisecond both count, and one row never counts as two steps.
            if (reached < counts.Length && Sql.Num(row.Get("m" + reached)) == 1)
            {
                reached++;
            }
        }
        Close();
        return [.. counts];
    }

    /// <summary>
    /// Each visit's pageviews in order, at most <paramref name="perVisit"/> of them, for journeys. A
    /// window function keeps the first ones of each visit, so a long visit cannot crowd the rest out.
    /// Visits belong to the range they started in. Gives { rows: [{ session, path }], sampled }.
    /// </summary>
    public async Task<(List<JsObject> Rows, bool Sampled)> JourneyPagesAsync(JsObject query, int perVisit, CancellationToken cancellationToken = default)
    {
        string site = query.Str("site")!;
        long qFrom = query.Long("from");
        long qTo = query.Long("to");
        var scope = Sql.VisitScope(Sql.Filters(query), site, qFrom, qTo, Dialect);
        // The newest visits the filters pick, JourneyVisits at most, so a long range stays quick and small in memory.
        string Newest(string columns, int limit) => "SELECT " + columns + " FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + scope.Sql + "\n         ORDER BY s.started_at DESC, s.id LIMIT " + limit;
        List<object?> visitParams = [site, qFrom, qTo, .. scope.Params];
        // How many there are, one past the cap telling whether it was reached, and when the oldest of
        // them began, so the rows are read from there on rather than from the start of a long range.
        var first = await Db.FirstAsync("SELECT COUNT(*) AS n, MIN(started_at) AS t FROM (" + Newest("s.started_at AS started_at", Sql.JourneyVisits + 1) + ") x", visitParams, cancellationToken).ConfigureAwait(false);
        if (Sql.Num(first?.Get("n")) == 0)
        {
            return ([], false);
        }
        double from = Math.Max(qFrom, Sql.Num(first!.Get("t")));
        // MySQL takes no LIMIT in an IN list, but does in a table inside one.
        string visits = Dialect == "mysql" ? "SELECT id FROM (" + Newest("s.id AS id", Sql.JourneyVisits) + ") x" : Newest("s.id", Sql.JourneyVisits);
        var rows = await Db.AllAsync(
            // The visits are read as an IN list, which every database probes from the events side, so
            // the plan does not depend on the planner's statistics. Refreshes (the same page twice in a
            // row) are dropped before counting, so they never use up the steps.
            "WITH raw AS (\n         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,\n           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev\n         FROM rl_events e\n         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN (" + visits + ")),\n       v AS (\n         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n\n         FROM raw WHERE prev IS NULL OR prev <> path)\n       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n",
            [site, from, qTo + Sql.EventTailMs, .. visitParams, perVisit],
            cancellationToken).ConfigureAwait(false);
        return (
            rows.Select(r => new JsObject { ["session"] = Sql.S(r.Get("session")), ["path"] = Sql.S(r.Get("path")) }).ToList(),
            Sql.Num(first.Get("n")) > Sql.JourneyVisits);
    }

    // API tokens

    private static JsObject TokenRow(JsObject r) => new()
    {
        ["id"] = Sql.S(r.Get("id")),
        ["name"] = Sql.S(r.Get("name")),
        ["site"] = Sql.S(r.Get("site")),
        ["scope"] = r.Str("scope") == "manage" ? "manage" : "read",
        ["hash"] = Sql.S(r.Get("hash")),
        ["hint"] = Sql.S(r.Get("hint")),
        ["createdAt"] = Js.Number(r.Get("created_at")),
        ["lastUsedAt"] = r.Get("last_used_at") == null ? null : Js.Number(r.Get("last_used_at")),
    };

    public async Task<List<JsObject>> TokensAsync(CancellationToken cancellationToken = default) =>
        (await Db.AllAsync("SELECT * FROM rl_tokens ORDER BY created_at DESC, id", null, cancellationToken).ConfigureAwait(false)).Select(TokenRow).ToList();

    public async Task<JsObject?> TokenByHashAsync(string hash, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT * FROM rl_tokens WHERE hash = ?", A(hash), cancellationToken).ConfigureAwait(false);
        return row == null ? null : TokenRow(row);
    }

    public Task InsertTokenAsync(JsObject t, CancellationToken cancellationToken = default) => Db.RunAsync(
        "INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        A(t.Get("id"), t.Get("name"), t.Get("site"), t.Get("scope"), t.Get("hash"), t.Get("hint"), t.Get("createdAt"), t.Get("lastUsedAt")),
        cancellationToken);

    public Task TouchTokenAsync(string id, long now, CancellationToken cancellationToken = default) =>
        Db.RunAsync("UPDATE rl_tokens SET last_used_at = ? WHERE id = ?", A(now, id), cancellationToken);

    /// <summary>Deleting a token is how it is revoked: it stops working at once.</summary>
    public async Task<bool> DeleteTokenAsync(string id, CancellationToken cancellationToken = default) =>
        await ChangedAsync("DELETE FROM rl_tokens WHERE id = ?", A(id), cancellationToken).ConfigureAwait(false) == 1;

    // Settings

    public async Task<string?> SettingAsync(string key, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT value FROM rl_settings WHERE \"key\" = ?", A(key), cancellationToken).ConfigureAwait(false);
        return row == null ? null : Sql.S(row.Get("value"));
    }

    /// <summary>Every setting whose key starts with a prefix, such as each connected install's: [{ key, value }].</summary>
    public async Task<List<JsObject>> SettingsStartingWithAsync(string prefix, CancellationToken cancellationToken = default) =>
        (await Db.AllAsync("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE ? ESCAPE '\\'", A(Sql.EscapeLike(prefix) + "%"), cancellationToken).ConfigureAwait(false))
            .Select(r => new JsObject { ["key"] = Sql.S(r.Get("key")), ["value"] = Sql.S(r.Get("value")) }).ToList();

    public Task SetSettingAsync(string key, string? value, CancellationToken cancellationToken = default) => value == null
        ? Db.RunAsync("DELETE FROM rl_settings WHERE \"key\" = ?", A(key), cancellationToken)
        : Db.RunAsync(Sql.Upsert(Dialect, "rl_settings", ["\"key\"", "value"], ["\"key\""], ["value"]), A(key, value), cancellationToken);

    // Email reports

    private static JsObject ReportRow(JsObject r) => new()
    {
        ["id"] = Sql.S(r.Get("id")),
        ["site"] = Sql.S(r.Get("site")),
        ["email"] = Sql.S(r.Get("email")),
        ["frequency"] = Sql.S(r.Get("frequency")),
        ["lang"] = r.Get("lang") == null ? "en" : Sql.S(r.Get("lang")),
        ["token"] = Sql.S(r.Get("token")),
        ["origin"] = Sql.S(r.Get("origin")),
        ["lastPeriod"] = Sql.S(r.Get("last_period")),
        ["lastSentAt"] = r.Get("last_sent_at") == null ? null : Js.Number(r.Get("last_sent_at")),
        ["createdAt"] = Js.Number(r.Get("created_at")),
    };

    public async Task<List<JsObject>> ReportsAsync(string? site = null, CancellationToken cancellationToken = default)
    {
        var rows = !string.IsNullOrEmpty(site)
            ? await Db.AllAsync("SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id", A(site), cancellationToken).ConfigureAwait(false)
            : await Db.AllAsync("SELECT * FROM rl_reports ORDER BY created_at, id", null, cancellationToken).ConfigureAwait(false);
        return rows.Select(ReportRow).ToList();
    }

    /// <summary>A report by its "id" or its "token".</summary>
    public async Task<JsObject?> ReportByAsync(string field, string value, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT * FROM rl_reports WHERE " + (field == "id" ? "id" : "token") + " = ?", A(value), cancellationToken).ConfigureAwait(false);
        return row == null ? null : ReportRow(row);
    }

    public Task InsertReportAsync(JsObject r, CancellationToken cancellationToken = default) => Db.RunAsync(
        "INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        A(r.Get("id"), r.Get("site"), r.Get("email"), r.Get("frequency"), r.Get("lang"), r.Get("token"), r.Get("origin"), r.Get("lastPeriod"), r.Get("lastSentAt"), r.Get("createdAt")),
        cancellationToken);

    /// <summary>Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it.</summary>
    public async Task<bool> ClaimReportAsync(string id, string period, long now, CancellationToken cancellationToken = default) =>
        await ChangedAsync("UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?", A(period, now, id, period), cancellationToken).ConfigureAwait(false) == 1;

    /// <summary>Puts a period back when its email failed, so the next run tries again.</summary>
    public Task ReleaseReportAsync(string id, string period, string previous, CancellationToken cancellationToken = default) =>
        Db.RunAsync("UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?", A(previous, id, period), cancellationToken);

    public Task DeleteReportAsync(string id, CancellationToken cancellationToken = default) =>
        Db.RunAsync("DELETE FROM rl_reports WHERE id = ?", A(id), cancellationToken);

    // Goals

    public async Task<List<JsObject>> GoalsAsync(string? site = null, CancellationToken cancellationToken = default)
    {
        var rows = !string.IsNullOrEmpty(site)
            ? await Db.AllAsync("SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id", A(site), cancellationToken).ConfigureAwait(false)
            : await Db.AllAsync("SELECT * FROM rl_goals ORDER BY created_at, id", null, cancellationToken).ConfigureAwait(false);
        return rows.Select(Sql.GoalRow).ToList();
    }

    public async Task<JsObject?> GoalByIdAsync(string id, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT * FROM rl_goals WHERE id = ?", A(id), cancellationToken).ConfigureAwait(false);
        return row == null ? null : Sql.GoalRow(row);
    }

    public async Task SaveGoalAsync(JsObject g, JsObject? before = null, CancellationToken cancellationToken = default)
    {
        // A click goal is counted by its name, which the tracker sends as the event name. Renaming one
        // renames its past clicks too, so its history stays.
        if (before != null && before.Str("kind") == "click" && g.Str("kind") == "click" && before.Str("name") != g.Str("name"))
        {
            await Db.RunAsync("UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?", A(g.Get("name"), g.Get("site"), before.Get("name")), cancellationToken).ConfigureAwait(false);
        }
        await Db.RunAsync(
            Sql.Upsert(
                Dialect,
                "rl_goals",
                ["id", "site", "name", "kind", "\"match\"", "click_by", "value_mode", "value", "value_prop", "currency", "created_at"],
                ["id"],
                ["name", "kind", "\"match\"", "click_by", "value_mode", "value", "value_prop", "currency"]),
            A(g.Get("id"), g.Get("site"), g.Get("name"), g.Get("kind"), g.Get("match"), g.Get("clickBy"), g.Get("valueMode"), g.Get("value"), g.Get("valueProp"), g.Get("currency"), g.Get("createdAt")),
            cancellationToken).ConfigureAwait(false);
    }

    public Task DeleteGoalAsync(string id, CancellationToken cancellationToken = default) =>
        Db.RunAsync("DELETE FROM rl_goals WHERE id = ?", A(id), cancellationToken);

    /// <summary>The events a goal counts, as a WHERE fragment over rl_events e.</summary>
    private SqlPart GoalScope(JsObject goal)
    {
        string match = goal.Str("match") ?? "";
        if (goal.Str("kind") == "page")
        {
            if (!match.Contains('*', StringComparison.Ordinal))
            {
                return new SqlPart("e.kind = 'pageview' AND e.path = ?", [match]);
            }
            return Dialect != "sqlite"
                // Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
                ? new SqlPart("e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'", [Sql.LikePattern(match)])
                // SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact matches.
                : new SqlPart("e.kind = 'pageview' AND e.path GLOB ?", [Sql.GlobPattern(match)]);
        }
        // Event goals count the named event; click goals count the event the tracker sends for them.
        return new SqlPart("e.kind = 'event' AND e.name = ?", [goal.Str("kind") == "click" ? goal.Get("name") : goal.Get("match")]);
    }

    /// <summary>A numeric event property for one row, as SQL (0 when it is not a number). Property names are checked before they get here.</summary>
    private SqlPart PropValue(string prop)
    {
        if (Dialect == "postgres")
        {
            return new SqlPart("(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)", [prop, prop]);
        }
        string path = "$.\"" + prop + "\"";
        if (Dialect == "mysql")
        {
            // As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal point.
            string value = "JSON_EXTRACT(e.props, ?)";
            return new SqlPart(
                "(CASE\n          WHEN JSON_TYPE(" + value + ") IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST(" + value + " AS DOUBLE)\n          WHEN JSON_TYPE(" + value + ") = 'STRING' AND JSON_UNQUOTE(" + value + ") REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE(" + value + ") AS DOUBLE)\n          ELSE 0 END)",
                [.. Enumerable.Repeat<object?>(path, 5)]);
        }
        // As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
        string text = "CAST(json_extract(e.props, ?) AS TEXT)";
        return new SqlPart(
            "(CASE\n        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)\n        WHEN json_type(e.props, ?) = 'text' AND " + text + " GLOB '[0-9]*' AND " + text + " NOT GLOB '*[^0-9.]*' AND " + text + " NOT GLOB '*.*.*' AND " + text + " NOT GLOB '*.' THEN CAST(" + text + " AS REAL)\n        WHEN json_type(e.props, ?) = 'text' AND " + text + " GLOB '-[0-9]*' AND substr(" + text + ", 2) NOT GLOB '*[^0-9.]*' AND " + text + " NOT GLOB '*.*.*' AND " + text + " NOT GLOB '*.' THEN CAST(" + text + " AS REAL)\n        ELSE 0 END)",
            [.. Enumerable.Repeat<object?>(path, 14)]);
    }

    /// <summary>The property names sent with an event in a query's range, most used first: [{ key, events }].</summary>
    public async Task<List<JsObject>> EventPropKeysAsync(JsObject query, string evt, CancellationToken cancellationToken = default)
    {
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, query.Long("from"), query.Long("to"), Dialect);
        string where = v.Sql + " AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL";
        List<object?> parameters = [.. v.Params, evt];
        var rows = Dialect switch
        {
            // Each key as a row of its own, compared and sorted by code point like every other value.
            "mysql" => await Db.AllAsync(
                "SELECT j.k AS \"key\", COUNT(*) AS events FROM " + v.From + "\n             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE " + Sql.MysqlCollation + " PATH '$')) j\n             WHERE " + where + " GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30",
                parameters,
                cancellationToken).ConfigureAwait(false),
            "postgres" => await Db.AllAsync(
                "SELECT k AS \"key\", COUNT(*) AS events FROM " + v.From + " CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k\n             WHERE " + where + " GROUP BY k ORDER BY events DESC, k" + TextOrder() + " LIMIT 30",
                parameters,
                cancellationToken).ConfigureAwait(false),
            _ => await Db.AllAsync(
                "SELECT j.key AS \"key\", COUNT(*) AS events FROM " + v.From + ", json_each(e.props) j\n             WHERE " + where + " AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key" + TextOrder() + " LIMIT 30",
                parameters,
                cancellationToken).ConfigureAwait(false),
        };
        return rows.Select(r => new JsObject { ["key"] = Sql.S(r.Get("key")), ["events"] = Sql.Num(r.Get("events")) }).ToList();
    }

    /// <summary>The values one property of an event took, with how often and by how many visitors: [{ value, events, visitors }].</summary>
    public async Task<List<JsObject>> EventPropValuesAsync(JsObject query, string evt, string key, int limit, CancellationToken cancellationToken = default)
    {
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, query.Long("from"), query.Long("to"), Dialect);
        string value = Dialect switch
        {
            "postgres" => "(e.props::jsonb ->> ?)",
            "mysql" => "(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE " + Sql.MysqlCollation + ")",
            _ => "CAST(json_extract(e.props, ?) AS TEXT)",
        };
        string path = Dialect == "postgres" ? key : "$.\"" + key + "\"";
        var rows = await Db.AllAsync(
            "SELECT * FROM (SELECT " + value + " AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM " + v.From + "\n         WHERE " + v.Sql + " AND e.kind = 'event' AND e.name = ? AND " + value + " IS NOT NULL GROUP BY 1) t\n       ORDER BY events DESC, value" + TextOrder() + " LIMIT ?",
            [path, .. v.Params, evt, path, limit],
            cancellationToken).ConfigureAwait(false);
        return rows.Select(r => new JsObject { ["value"] = Sql.S(r.Get("value")), ["events"] = Sql.Num(r.Get("events")), ["visitors"] = Sql.Num(r.Get("visitors")) }).ToList();
    }

    /// <summary>The floating point type to cast to, which MySQL names in one word.</summary>
    private string DoubleType() => Dialect == "mysql" ? "DOUBLE" : "DOUBLE PRECISION";

    /// <summary>A goal's worth for one converting row, as SQL.</summary>
    private SqlPart RevenueValue(JsObject goal)
    {
        if (goal.Str("valueMode") == "prop" && (goal.Str("valueProp") ?? "").Length > 0)
        {
            return PropValue(goal.Str("valueProp")!);
        }
        if (goal.Str("valueMode") == "fixed")
        {
            return new SqlPart("CAST(? AS " + DoubleType() + ")", [goal.Get("value")]);
        }
        return new SqlPart("0", []);
    }

    /// <summary>Math.round(n * 100) / 100, for money.</summary>
    private static double Cents(double n) => Js.Round(n * 100) / 100;

    /// <summary>
    /// Every goal's totals in one pass over the range's events, instead of a query per goal: each goal
    /// adds a conditional count, distinct count, and sum. Keyed by goal id: { conversions, visitors, revenue }.
    /// </summary>
    public async Task<Dictionary<string, JsObject>> GoalTotalsAllAsync(JsObject query, IReadOnlyList<JsObject> goals, CancellationToken cancellationToken = default)
    {
        var output = new Dictionary<string, JsObject>(StringComparer.Ordinal);
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, query.Long("from"), query.Long("to"), Dialect);
        // As many goals per query as keep it under D1's parameter limit.
        var chunks = new List<List<JsObject>> { new() };
        int count = v.Params.Count;
        foreach (var goal in goals)
        {
            int cost = GoalScope(goal).Params.Count * 4 + RevenueValue(goal).Params.Count;
            if (chunks[^1].Count > 0 && count + cost > Sql.MaxParams)
            {
                chunks.Add([]);
                count = v.Params.Count;
            }
            chunks[^1].Add(goal);
            count += cost;
        }
        foreach (var chunk in chunks)
        {
            if (chunk.Count == 0)
            {
                continue;
            }
            var columns = new List<string>();
            var parameters = new List<object?>();
            // Only rows some goal of the chunk counts are read.
            var any = new List<string>();
            var anyParams = new List<object?>();
            for (int i = 0; i < chunk.Count; i++)
            {
                var scope = GoalScope(chunk[i]);
                var value = RevenueValue(chunk[i]);
                columns.Add("SUM(CASE WHEN " + scope.Sql + " THEN 1 ELSE 0 END) AS c" + i);
                columns.Add("COUNT(DISTINCT CASE WHEN " + scope.Sql + " THEN e.visitor END) AS v" + i);
                columns.Add("SUM(CASE WHEN " + scope.Sql + " THEN " + value.Sql + " ELSE 0 END) AS r" + i);
                parameters.AddRange(scope.Params);
                parameters.AddRange(scope.Params);
                parameters.AddRange(scope.Params);
                parameters.AddRange(value.Params);
                any.Add("(" + scope.Sql + ")");
                anyParams.AddRange(scope.Params);
            }
            var row = await Db.FirstAsync(
                "SELECT " + string.Join(", ", columns) + " FROM " + v.From + "\n         WHERE " + v.Sql + " AND e.kind IN ('pageview', 'event') AND (" + string.Join(" OR ", any) + ")",
                [.. parameters, .. v.Params, .. anyParams],
                cancellationToken).ConfigureAwait(false);
            for (int i = 0; i < chunk.Count; i++)
            {
                output[chunk[i].Str("id")!] = new JsObject
                {
                    ["conversions"] = Sql.Num(row?.Get("c" + i)),
                    ["visitors"] = Sql.Num(row?.Get("v" + i)),
                    ["revenue"] = Cents(Sql.Num(row?.Get("r" + i))),
                };
            }
        }
        return output;
    }

    private SqlPart RevenueSql(JsObject goal)
    {
        if (goal.Str("valueMode") == "prop" && (goal.Str("valueProp") ?? "").Length > 0)
        {
            var value = PropValue(goal.Str("valueProp")!);
            return new SqlPart("SUM(" + value.Sql + ")", value.Params);
        }
        // Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
        if (goal.Str("valueMode") == "fixed")
        {
            return new SqlPart("COUNT(*) * CAST(? AS " + DoubleType() + ")", [goal.Get("value")]);
        }
        return new SqlPart("0", []);
    }

    /// <summary>One goal's conversions, converting visitors, and revenue for a query's range and filters.</summary>
    public async Task<JsObject> GoalTotalsAsync(JsObject query, JsObject goal, CancellationToken cancellationToken = default)
    {
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, query.Long("from"), query.Long("to"), Dialect);
        var scope = GoalScope(goal);
        var revenue = RevenueSql(goal);
        var row = await Db.FirstAsync(
            "SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, " + revenue.Sql + " AS revenue\n       FROM " + v.From + " WHERE " + v.Sql + " AND " + scope.Sql,
            [.. revenue.Params, .. v.Params, .. scope.Params],
            cancellationToken).ConfigureAwait(false);
        return new JsObject
        {
            ["conversions"] = Sql.Num(row?.Get("conversions")),
            ["visitors"] = Sql.Num(row?.Get("visitors")),
            ["revenue"] = Cents(Sql.Num(row?.Get("revenue"))),
        };
    }

    /// <summary>A goal's conversions split by where the visit came from ("source", "channel"), or by the page it happened on ("path").</summary>
    public async Task<List<JsObject>> GoalBreakdownAsync(JsObject query, JsObject goal, string by, int limit = 10, CancellationToken cancellationToken = default)
    {
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, query.Long("from"), query.Long("to"), Dialect);
        string col = by == "path" ? "e.path" : "s." + by;
        var scope = GoalScope(goal);
        var revenue = RevenueSql(goal);
        var rows = await Db.AllAsync(
            "SELECT " + col + " AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, " + revenue.Sql + " AS revenue\n       FROM " + v.From + " WHERE " + v.Sql + " AND " + scope.Sql + "\n       GROUP BY " + col + " ORDER BY conversions DESC, " + col + TextOrder() + " LIMIT ?",
            [.. revenue.Params, .. v.Params, .. scope.Params, limit],
            cancellationToken).ConfigureAwait(false);
        return rows.Select(r => new JsObject
        {
            ["value"] = Sql.S(r.Get("value")),
            ["conversions"] = Sql.Num(r.Get("conversions")),
            ["visitors"] = Sql.Num(r.Get("visitors")),
            ["revenue"] = Cents(Sql.Num(r.Get("revenue"))),
        }).ToList();
    }

    /// <summary>A goal's conversions and revenue in each bucket, by when each visit started: [{ start, conversions, revenue }].</summary>
    public async Task<List<JsObject>> GoalSeriesAsync(JsObject query, JsObject goal, IReadOnlyList<JsObject> buckets, CancellationToken cancellationToken = default)
    {
        if (buckets.Count == 0)
        {
            return [];
        }
        var scope = GoalScope(goal);
        var revenue = RevenueSql(goal);
        // Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
        int fixedCount = revenue.Params.Count + scope.Params.Count + Sql.VisitRows(Sql.Filters(query), query.Str("site")!, 0, 0, Dialect).Params.Count;
        int size = Math.Max(1, Math.Min(Sql.BucketsPerQuery, (Sql.MaxParams - fixedCount) / 3));
        if (buckets.Count > size)
        {
            return await Sql.InPiecesAsync(buckets, size, piece => GoalSeriesAsync(query, goal, piece, cancellationToken)).ConfigureAwait(false);
        }
        var last = buckets[^1];
        var v = Sql.VisitRows(Sql.Filters(query), query.Str("site")!, buckets[0].Long("start"), last.Long("end"), Dialect);
        var rows = await Db.AllAsync(
            "WITH b (i, bs, be) AS (" + Sql.BucketTable(Dialect, buckets.Count) + ")\n       SELECT b.i AS i, COUNT(*) AS conversions, " + revenue.Sql + " AS revenue\n       FROM " + v.From + " CROSS JOIN b\n       WHERE " + v.Sql + " AND s.started_at >= b.bs AND s.started_at < b.be AND " + scope.Sql + "\n       GROUP BY b.i",
            [.. BucketParams(buckets), .. revenue.Params, .. v.Params, .. scope.Params],
            cancellationToken).ConfigureAwait(false);
        var found = rows.ToDictionary(r => (long)Sql.Num(r.Get("i")));
        return buckets.Select((b, i) => new JsObject
        {
            ["start"] = b.Get("start"),
            ["conversions"] = Sql.Num(found.GetValueOrDefault(i)?.Get("conversions")),
            ["revenue"] = Cents(Sql.Num(found.GetValueOrDefault(i)?.Get("revenue"))),
        }).ToList();
    }

    private static List<object?> BucketParams(IReadOnlyList<JsObject> buckets)
    {
        var parameters = new List<object?>();
        for (int i = 0; i < buckets.Count; i++)
        {
            parameters.Add((long)i);
            parameters.Add(buckets[i].Get("start"));
            parameters.Add(buckets[i].Get("end"));
        }
        return parameters;
    }

    public async Task<List<JsObject>> LinkDomainsAsync(CancellationToken cancellationToken = default) =>
        (await Db.AllAsync("SELECT domain, site FROM rl_link_domains ORDER BY domain", null, cancellationToken).ConfigureAwait(false))
            .Select(r => new JsObject { ["domain"] = Sql.S(r.Get("domain")), ["site"] = Sql.S(r.Get("site")) }).ToList();

    public Task AddLinkDomainAsync(string domain, string site, long now, CancellationToken cancellationToken = default) =>
        Db.RunAsync(Sql.Upsert(Dialect, "rl_link_domains", ["domain", "site", "created_at"], ["domain"], []), A(domain, site, now), cancellationToken);

    /// <summary>Removes a domain. Its links keep it as their home and fall back to the app's own link path until the domain is added again.</summary>
    public Task RemoveLinkDomainAsync(string domain, CancellationToken cancellationToken = default) =>
        Db.RunAsync("DELETE FROM rl_link_domains WHERE domain = ?", A(domain), cancellationToken);

    /// <summary>
    /// A site's links, newest first, with their clicks in a range. Clicks imported as daily counts
    /// have no visitor, so they add to clicks only.
    /// </summary>
    public async Task<List<JsObject>> LinksAsync(string site, long from, long to, CancellationToken cancellationToken = default)
    {
        var rows = await Db.AllAsync(
            "SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors\n       FROM rl_links l LEFT JOIN (\n         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events\n         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link\n       ) c ON c.link = l.id\n       WHERE l.site = ? AND l.deleted_at IS NULL\n       ORDER BY l.created_at DESC, l.id",
            A(site, from, to, site),
            cancellationToken).ConfigureAwait(false);
        return rows.Select(row =>
        {
            var link = Sql.LinkRow(row);
            link["clicks"] = Sql.Num(row.Get("clicks"));
            link["visitors"] = Sql.Num(row.Get("visitors"));
            return link;
        }).ToList();
    }

    /// <summary>One link's clicks per bucket: [{ start, clicks, visitors }].</summary>
    public async Task<List<JsObject>> LinkSeriesAsync(string site, string link, IReadOnlyList<JsObject> buckets, CancellationToken cancellationToken = default)
    {
        if (buckets.Count == 0)
        {
            return [];
        }
        if (buckets.Count > Sql.BucketsPerQuery)
        {
            return await Sql.InPiecesAsync(buckets, Sql.BucketsPerQuery, piece => LinkSeriesAsync(site, link, piece, cancellationToken)).ConfigureAwait(false);
        }
        var rows = await Db.AllAsync(
            "WITH b (i, bs, be) AS (" + Sql.BucketTable(Dialect, buckets.Count) + ")\n       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors\n       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be\n       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i",
            [.. BucketParams(buckets), link, site],
            cancellationToken).ConfigureAwait(false);
        var found = rows.ToDictionary(r => (long)Sql.Num(r.Get("i")));
        return buckets.Select((b, i) => new JsObject
        {
            ["start"] = b.Get("start"),
            ["clicks"] = Sql.Num(found.GetValueOrDefault(i)?.Get("clicks")),
            ["visitors"] = Sql.Num(found.GetValueOrDefault(i)?.Get("visitors")),
        }).ToList();
    }

    /// <summary>One link's clicks by a visit dimension: [{ value, visitors, events }].</summary>
    public async Task<List<JsObject>> LinkBreakdownAsync(string site, string link, long from, long to, string dimension, int limit, CancellationToken cancellationToken = default)
    {
        string col = "s." + Query.SessionDimensions[dimension];
        var rows = await Db.AllAsync(
            "SELECT " + col + " AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors\n       FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND " + col + " <> ''\n       GROUP BY " + col + " ORDER BY clicks DESC, " + col + TextOrder() + " LIMIT ?",
            A(site, link, from, to, limit),
            cancellationToken).ConfigureAwait(false);
        return rows.Select(r => new JsObject { ["value"] = Sql.S(r.Get("value")), ["visitors"] = Sql.Num(r.Get("visitors")), ["events"] = Sql.Num(r.Get("clicks")) }).ToList();
    }

    /// <summary>
    /// Ties are broken by the value in code point order, the order the rolled-up path sorts in, so a
    /// report reads the same before and after its days are built. Postgres would otherwise use its
    /// locale's order. MySQL's columns already sort this way; a value worked out from JSON may not.
    /// </summary>
    private string TextOrder() => Dialect switch
    {
        "postgres" => " COLLATE \"C\"",
        "mysql" => " COLLATE " + Sql.MysqlCollation,
        _ => "",
    };
}
