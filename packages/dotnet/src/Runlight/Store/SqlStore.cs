using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Db;

namespace Runlight.Store;

/// <summary>
/// Runlight's tables, read and written with the same SQL as store.ts's SqlStore for each dialect,
/// so a database made by either implementation opens in the other. Rows are the TypeScript
/// interfaces as <see cref="JsObject"/>s with the same camelCase keys.
/// </summary>
/// <remarks>
/// SiteRow { id, name, hostnames, timezone }; GoalRow { id, site, name, kind, match, clickBy,
/// valueMode, value, valueProp, currency, createdAt }; ReportRow, ShareRow, FunnelRow, TokenRow,
/// LinkRow, SessionRow, and EventRow likewise; a Query is { site, from, to, filters }.
/// </remarks>
public sealed partial class SqlStore
{
    public const long BounceMs = Sql.BounceMs;
    public const int JourneyVisits = Sql.JourneyVisits;
    public const long EventTailMs = Sql.EventTailMs;
    public const string MysqlCollation = Sql.MysqlCollation;

    private bool _ready;
    private bool _checkedAll;
    private readonly SemaphoreSlim _migrating = new(1, 1);

    public SqlStore(IDb db)
    {
        Db = db;
    }

    public IDb Db { get; }

    private string Dialect => Db.Dialect;

    private static List<object?> A(params object?[] args) => [.. args];

    /// <summary>
    /// Creates the tables on first use. Safe to call any number of times. When the database already
    /// records the current schema version, that is taken as done; <paramref name="full"/> goes over
    /// everything anyway, as the scheduled check and <c>runlight migrate</c> do, which adds an index a
    /// database of this version may still lack.
    /// </summary>
    public async Task MigrateAsync(bool full = false, CancellationToken cancellationToken = default)
    {
        if (_checkedAll || (_ready && !full))
        {
            return;
        }
        await _migrating.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_checkedAll || (_ready && !full))
            {
                return;
            }
            if (!full && !_ready)
            {
                try
                {
                    var found = (await Db.FirstAsync("SELECT value FROM rl_meta WHERE \"key\" = 'schema'", null, cancellationToken).ConfigureAwait(false))?.Get("value");
                    if (found != null && Js.String(found) == Js.Str(Sql.SchemaVersion))
                    {
                        _ready = true;
                        return;
                    }
                }
                catch (Exception)
                {
                    // No rl_meta yet: a new database, made below.
                }
            }
            await Db.ExclusiveAsync(
                async db =>
                {
                    // On Postgres an index on a big table takes a while to build, so the build may run
                    // past the statement timeout, and goes CONCURRENTLY, so another process still
                    // serving keeps writing meanwhile.
                    bool postgres = db.Dialect == "postgres";
                    if (postgres)
                    {
                        await db.RunAsync("SET statement_timeout = 0", null, cancellationToken).ConfigureAwait(false);
                    }
                    try
                    {
                        await UpgradeAsync(db, postgres, cancellationToken).ConfigureAwait(false);
                    }
                    finally
                    {
                        if (postgres)
                        {
                            try
                            {
                                await db.RunAsync("RESET statement_timeout", null, CancellationToken.None).ConfigureAwait(false);
                            }
                            catch (Exception)
                            {
                            }
                        }
                    }
                    return true;
                },
                cancellationToken).ConfigureAwait(false);
            _ready = true;
            _checkedAll = true;
        }
        finally
        {
            _migrating.Release();
        }
    }

    private static readonly Regex IndexStatement = new("^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\\w+) ON (\\w+)", RegexOptions.CultureInvariant);
    private static readonly Regex IndexHead = new("^CREATE (UNIQUE )?INDEX IF NOT EXISTS", RegexOptions.CultureInvariant);

    private static async Task UpgradeAsync(IDb db, bool postgres, CancellationToken cancellationToken)
    {
        var statements = Sql.Schema(db.Dialect);
        await db.RunAsync(statements[0], null, cancellationToken).ConfigureAwait(false);
        var found = await db.FirstAsync("SELECT value FROM rl_meta WHERE \"key\" = 'schema'", null, cancellationToken).ConfigureAwait(false);
        double from = found != null ? Js.Number(found.Get("value")) : Sql.SchemaVersion;
        if (postgres)
        {
            // A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
            var broken = await db.AllAsync(
                """
                SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\_%' AND c.relnamespace = current_schema()::regnamespace
                """,
                null,
                cancellationToken).ConfigureAwait(false);
            foreach (var row in broken)
            {
                await db.RunAsync("DROP INDEX IF EXISTS \"" + Sql.S(row.Get("name")).Replace("\"", "", StringComparison.Ordinal) + "\"", null, cancellationToken).ConfigureAwait(false);
            }
        }
        foreach (string statement in statements)
        {
            Match index;
            if (db.Dialect == "mysql" && (index = IndexStatement.Match(statement)).Success)
            {
                // MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
                string unique = index.Groups[1].Value;
                var there = await db.AllAsync(
                    "SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1",
                    A(index.Groups[3].Value, index.Groups[2].Value),
                    cancellationToken).ConfigureAwait(false);
                if (there.Count == 0)
                {
                    await db.RunAsync(IndexHead.Replace(statement, "CREATE " + unique + "INDEX"), null, cancellationToken).ConfigureAwait(false);
                }
            }
            else
            {
                await db.RunAsync(postgres ? IndexHead.Replace(statement, "CREATE $1INDEX CONCURRENTLY IF NOT EXISTS") : statement, null, cancellationToken).ConfigureAwait(false);
            }
        }
        // A column added by an upgrade that stopped before it recorded the new version is already there.
        async Task AddColumn(string sql)
        {
            try
            {
                await db.RunAsync(sql, null, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (Regex.IsMatch(error.ToString(), "duplicate column|already exists", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
            }
        }
        // Version 2: settings changed in the dashboard, kept apart from the ones in code.
        if (from < 2)
        {
            await AddColumn("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'").ConfigureAwait(false);
        }
        if (from < 4)
        {
            await db.RunAsync("DROP INDEX IF EXISTS rl_links_slug", null, cancellationToken).ConfigureAwait(false);
        }
        // Version 10: tokens that may change one site's settings, for a hub.
        if (from >= 8 && from < 10)
        {
            await AddColumn("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'").ConfigureAwait(false);
        }
        // Written only when it changes, so a database opened read-only can still be read.
        if (found == null || Js.String(found.Get("value")) != Js.Str(Sql.SchemaVersion))
        {
            await db.RunAsync(Sql.Upsert(db.Dialect, "rl_meta", ["\"key\"", "value"], ["\"key\""], ["value"]), A("schema", Js.Str(Sql.SchemaVersion)), cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Keeps SQLite's planner statistics current, which it never gathers by itself. Without them it
    /// can choose a plan that reads a table once for every row of another. Postgres gathers its own.
    /// </summary>
    public async Task OptimizeAsync(bool onlyWhenMissing = false, CancellationToken cancellationToken = default)
    {
        if (Dialect != "sqlite")
        {
            return;
        }
        try
        {
            if (onlyWhenMissing && (await Db.AllAsync("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'", null, cancellationToken).ConfigureAwait(false)).Count > 0)
            {
                return;
            }
            await Db.RunAsync("PRAGMA analysis_limit = 1000", null, cancellationToken).ConfigureAwait(false);
            await Db.RunAsync("ANALYZE", null, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Some hosted SQLite services refuse these, and gather statistics themselves.
        }
    }

    public ValueTask CloseAsync() => Db.DisposeAsync();

    /// <summary>How many rows an UPDATE or DELETE of rows with an id matched. MySQL has no RETURNING, so its driver counts them.</summary>
    private async Task<long> ChangedAsync(string sql, List<object?> args, CancellationToken cancellationToken)
    {
        if (Dialect == "mysql")
        {
            return await Db.AffectedAsync(sql, args, cancellationToken).ConfigureAwait(false);
        }
        return (await Db.AllAsync(sql + " RETURNING id", args, cancellationToken).ConfigureAwait(false)).Count;
    }

    /// <summary>Runs <paramref name="fn"/> with a store whose every query is in one transaction.</summary>
    public Task<T> TransactionAsync<T>(Func<SqlStore, Task<T>> fn, CancellationToken cancellationToken = default) =>
        Db.TransactionAsync(db => fn(ReferenceEquals(db, Db) ? this : new SqlStore(db) { _ready = true, _checkedAll = true }), cancellationToken);

    public Task TransactionAsync(Func<SqlStore, Task> fn, CancellationToken cancellationToken = default) =>
        TransactionAsync<bool>(
            async s =>
            {
                await fn(s).ConfigureAwait(false);
                return true;
            },
            cancellationToken);

    // Sites

    /// <summary>A site's row written, or left alone when unchanged, so starting needs no write and a read-only database still opens.</summary>
    public async Task UpsertSiteAsync(JsObject site, long now, CancellationToken cancellationToken = default)
    {
        string hostnames = Json.Stringify(site.Get("hostnames"));
        var row = await Db.FirstAsync("SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?", A(site.Get("id")), cancellationToken).ConfigureAwait(false);
        if (row != null && Equals(row.Get("name"), site.Get("name")) && Equals(row.Get("hostnames"), hostnames) && Equals(row.Get("timezone"), site.Get("timezone")))
        {
            return;
        }
        await Db.RunAsync(
            Sql.Upsert(Dialect, "rl_sites", ["id", "name", "hostnames", "timezone", "created_at"], ["id"], ["name", "hostnames", "timezone"]),
            A(site.Get("id"), site.Get("name"), hostnames, site.Get("timezone"), now),
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Settings changed in the dashboard, by site. They win over the ones in code.</summary>
    public async Task<Dictionary<string, JsObject>> SiteOverridesAsync(CancellationToken cancellationToken = default)
    {
        var output = new Dictionary<string, JsObject>(StringComparer.Ordinal);
        foreach (var row in await Db.AllAsync("SELECT id, overrides FROM rl_sites", null, cancellationToken).ConfigureAwait(false))
        {
            output[Sql.S(row.Get("id"))] = Json.TryParse(Sql.S(row.Get("overrides"))) as JsObject ?? new JsObject();
        }
        return output;
    }

    /// <summary>
    /// Deletes a site and everything recorded for it. Its events and visits go a day at a time
    /// first, so a big site does not hold the database for minutes, and what is left goes in one
    /// transaction.
    /// </summary>
    public async Task DeleteSiteAsync(string id, CancellationToken cancellationToken = default)
    {
        long piece = Sql.PieceMs;
        foreach (var (table, col) in new[] { ("rl_events", "ts"), ("rl_sessions", "started_at") })
        {
            // A piece at a time from the oldest row, skipping straight over stretches with none.
            for (double? from = await OldestAsync(table, col, id, null, cancellationToken).ConfigureAwait(false); from != null; from = await OldestAsync(table, col, id, from + piece, cancellationToken).ConfigureAwait(false))
            {
                await Db.RunAsync("DELETE FROM " + table + " WHERE site = ? AND " + col + " < ?", A(id, from + piece), cancellationToken).ConfigureAwait(false);
            }
        }
        await TransactionAsync(
            async store =>
            {
                foreach (string table in new[] { "rl_events", "rl_sessions", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_funnels", "rl_reports", "rl_tokens", "rl_rollups", "rl_rollup_days", "rl_sites" })
                {
                    await store.Db.RunAsync("DELETE FROM " + table + " WHERE " + (table == "rl_sites" ? "id" : "site") + " = ?", A(id), cancellationToken).ConfigureAwait(false);
                }
            },
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>When a site's oldest row at or after <paramref name="from"/> is (null for no lower bound), or null when there is none.</summary>
    private async Task<double?> OldestAsync(string table, string col, string site, double? from, CancellationToken cancellationToken)
    {
        var row = await Db.FirstAsync(
            "SELECT MIN(" + col + ") AS t FROM " + table + " WHERE site = ?" + (from == null ? "" : " AND " + col + " >= ?"),
            from == null ? A(site) : A(site, from),
            cancellationToken).ConfigureAwait(false);
        return row == null || row.Get("t") == null ? null : Sql.Num(row.Get("t"));
    }

    /// <summary>Deletes a site's visits and events from before a time, for its retention setting.</summary>
    public async Task DropBeforeAsync(string site, long ts, CancellationToken cancellationToken = default)
    {
        // A day at a time from the oldest, each its own short transaction, so a long history goes
        // without holding the database for minutes. Stretches with nothing in them are skipped.
        long piece = Sql.PieceMs;
        async Task<double?> Next(double? at)
        {
            var found = new List<double>();
            foreach (var t in new[] { await OldestAsync("rl_sessions", "started_at", site, at, cancellationToken).ConfigureAwait(false), await OldestAsync("rl_events", "ts", site, at, cancellationToken).ConfigureAwait(false) })
            {
                if (t != null)
                {
                    found.Add(t.Value);
                }
            }
            if (found.Count == 0)
            {
                return null;
            }
            return at == null ? found.Min() : Math.Max(at.Value, found.Min());
        }
        for (double? from = await Next(null).ConfigureAwait(false); from != null && from < ts; from = await Next(Math.Min(from.Value + piece, ts)).ConfigureAwait(false))
        {
            double start = from.Value;
            double to = Math.Min(start + piece, ts);
            await TransactionAsync(
                async store =>
                {
                    // A visit's events go with it, even ones after the cutoff, so nothing is left
                    // without its visit. They come after it starts and within EventTailMs, so the time
                    // bounds let the (site, ts) index find them.
                    await store.Db.RunAsync(
                        "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)",
                        A(site, start, to + Sql.EventTailMs, site, start, to),
                        cancellationToken).ConfigureAwait(false);
                    await store.Db.RunAsync("DELETE FROM rl_events WHERE site = ? AND ts < ?", A(site, to), cancellationToken).ConfigureAwait(false);
                    await store.Db.RunAsync("DELETE FROM rl_sessions WHERE site = ? AND started_at < ?", A(site, to), cancellationToken).ConfigureAwait(false);
                },
                cancellationToken).ConfigureAwait(false);
        }
        // A day that lost any of its visits is built again later, from what is left.
        await ClearRollupsAsync(site, before: ts, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Deletes a site's events from <paramref name="from"/> on whose visit no longer exists, a day at a time.</summary>
    public async Task DropOrphansAsync(string site, long from, long until, CancellationToken cancellationToken = default)
    {
        long piece = Sql.PieceMs;
        for (double? at = await OldestAsync("rl_events", "ts", site, from, cancellationToken).ConfigureAwait(false); at != null && at < until; at = await OldestAsync("rl_events", "ts", site, at + piece, cancellationToken).ConfigureAwait(false))
        {
            await Db.RunAsync(
                "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
                A(site, at, at + piece),
                cancellationToken).ConfigureAwait(false);
        }
    }

    // Daily rollups

    /// <summary>
    /// Adds up one local day of a site: totals, each visit dimension, and pages. A visit belongs to
    /// the day it started. Visitor ids change every day, so the days of a range add up to exactly
    /// what counting the range would give.
    /// </summary>
    public async Task BuildRollupDayAsync(string site, string day, long start, long end, CancellationToken cancellationToken = default)
    {
        // A day with no visits still gets its row of zeros, so it counts as built.
        string bounce = Sql.Bounce;
        string sums = "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN " + bounce + " THEN 1 ELSE 0 END), 0), COALESCE(SUM(" + Sql.Duration + "), 0)";
        string cols = "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)";
        // Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
        string dialect = Dialect;
        string head = Sql.AsText(dialect, "?") + ", " + Sql.AsText(dialect, "?");
        string quarter = Sql.Div(dialect, "s.started_at", 900000);
        // The day's totals, each visit dimension, and the heatmap's quarter hours, in one statement
        // over the day's visits.
        var pieces = new List<string> { "SELECT " + head + ", '', '', " + sums + " FROM v s" };
        foreach (var (dim, col) in Query.SessionDimensions)
        {
            pieces.Add("SELECT " + head + ", '" + dim + "', s." + col + ", " + sums + " FROM v s WHERE s." + col + " <> '' GROUP BY s." + col);
        }
        pieces.Add("SELECT " + head + ", 'quarter', " + Sql.AsText(dialect, quarter) + ", COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN " + bounce + " THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY " + Sql.AsText(dialect, quarter));
        // Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts)
        // index find them; a visit's last row comes at most EventTailMs after it starts.
        string OfDay(string kind) => "FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n       WHERE e.site = ? AND e.kind = '" + kind + "' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit;
        object?[] window = [site, start, end + Sql.EventTailMs, start, end];
        await TransactionAsync(
            async store =>
            {
                var db = store.Db;
                await db.RunAsync("DELETE FROM rl_rollups WHERE site = ? AND day = ?", A(site, day), cancellationToken).ConfigureAwait(false);
                // The WITH goes after INSERT INTO, the one place every database takes it.
                var parameters = A(site, start, end);
                foreach (var _ in pieces)
                {
                    parameters.Add(site);
                    parameters.Add(day);
                }
                await db.RunAsync(
                    "INSERT INTO rl_rollups " + cols + "\n         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + Sql.IsVisit + ")\n         " + string.Join(" UNION ALL ", pieces),
                    parameters,
                    cancellationToken).ConfigureAwait(false);
                // A page's engaged time and scroll come per pageview first (its time added up, its
                // deepest scroll), as the raw report counts them.
                await db.RunAsync(
                    "INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)\n"
                    + "         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)\n"
                    + "         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, " + Sql.LiveViews + " AS views\n"
                    + "               " + OfDay("pageview") + " GROUP BY e.path) p\n"
                    + "         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (\n"
                    + "               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest " + OfDay("engagement") + " GROUP BY e.path, e.pageview) x\n"
                    + "               GROUP BY value) t ON t.value = p.value",
                    [site, day, .. window, .. window],
                    cancellationToken).ConfigureAwait(false);
                await db.RunAsync(
                    "INSERT INTO rl_rollups (site, day, dim, value, visitors, events)\n         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) " + OfDay("event") + " GROUP BY e.name",
                    [site, day, .. window],
                    cancellationToken).ConfigureAwait(false);
                await db.RunAsync("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", A(site, day), cancellationToken).ConfigureAwait(false);
                await db.RunAsync("INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)", A(site, day, start, end), cancellationToken).ConfigureAwait(false);
            },
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>The days of a site already built.</summary>
    public async Task<List<string>> RollupDaysAsync(string site, CancellationToken cancellationToken = default)
    {
        var days = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var r in await Db.AllAsync("SELECT day FROM rl_rollup_days WHERE site = ?", A(site), cancellationToken).ConfigureAwait(false))
        {
            string day = Sql.S(r.Get("day"));
            if (seen.Add(day))
            {
                days.Add(day);
            }
        }
        return days;
    }

    /// <summary>Forgets built days, all of a site's or those touching a stretch of time, so they are built again.</summary>
    public async Task ClearRollupsAsync(string site, double? before = null, double? from = null, double? to = null, CancellationToken cancellationToken = default)
    {
        string where = "site = ?";
        var parameters = A(site);
        if (before != null)
        {
            where += " AND start_at < ?";
            parameters.Add(before);
        }
        else if (from != null && to != null)
        {
            where += " AND start_at < ? AND end_at > ?";
            parameters.Add(to);
            parameters.Add(from);
        }
        var days = (await Db.AllAsync("SELECT day FROM rl_rollup_days WHERE " + where, parameters, cancellationToken).ConfigureAwait(false)).Select(r => Sql.S(r.Get("day"))).ToList();
        // The days stop counting as built first, so if this stops part way, no day is left marked
        // built without its rows. Another process may build a day between the two deletes, so its
        // mark goes again after its rows: the day is then simply built once more.
        await Db.RunAsync("DELETE FROM rl_rollup_days WHERE " + where, parameters, cancellationToken).ConfigureAwait(false);
        foreach (string day in days)
        {
            await Db.RunAsync("DELETE FROM rl_rollups WHERE site = ? AND day = ?", A(site, day), cancellationToken).ConfigureAwait(false);
            await Db.RunAsync("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", A(site, day), cancellationToken).ConfigureAwait(false);
        }
    }

    private sealed record Plan(List<(string Day, double Start, double End)> Days, List<(double From, double To)> Rest);

    /// <summary>
    /// How to answer a range from rollups: the built days that lie wholly inside it, and the
    /// stretches left over, which are read from the visits as usual. Null when no built day helps.
    /// </summary>
    private async Task<Plan?> RollupPlanAsync(JsObject query, double from, double to, CancellationToken cancellationToken)
    {
        if (Sql.Filters(query).Count > 0)
        {
            return null;
        }
        var rows = await Db.AllAsync("SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at", A(query.Get("site"), from, to), cancellationToken).ConfigureAwait(false);
        if (rows.Count == 0)
        {
            return null;
        }
        var days = rows.Select(r => (Sql.S(r.Get("day")), Sql.Num(r.Get("start_at")), Sql.Num(r.Get("end_at")))).ToList();
        var rest = new List<(double, double)>();
        double at = from;
        foreach (var d in days)
        {
            if (d.Item2 > at)
            {
                rest.Add((at, d.Item2));
            }
            at = Math.Max(at, d.Item3);
        }
        if (at < to)
        {
            rest.Add((at, to));
        }
        return new Plan(days, rest);
    }

    /// <summary>SQL for "a visit that started in one of these stretches".</summary>
    private static SqlPart Within(List<(double From, double To)> rest)
    {
        if (rest.Count == 0)
        {
            return new SqlPart("1 = 0", []);
        }
        return new SqlPart(
            "(" + string.Join(" OR ", rest.Select(_ => "(s.started_at >= ? AND s.started_at < ?)")) + ")",
            [.. rest.SelectMany(r => new object?[] { r.From, r.To })]);
    }

    private static readonly string[] SumKeys = ["visitors", "visits", "pageviews", "bounced", "duration", "engaged", "views", "scroll_sum", "scroll_n", "events"];

    /// <summary>
    /// A breakdown of a visit dimension or of pages from rollups and the visits left over, merged,
    /// then sorted and cut to the page asked for.
    /// </summary>
    private async Task<List<JsObject>?> RolledBreakdownAsync(JsObject query, string dimension, int limit, int offset, CancellationToken cancellationToken)
    {
        bool page = dimension == "page";
        bool evt = dimension == "event";
        if (!page && !evt && !Query.IsSessionDimension(dimension))
        {
            return null;
        }
        if (Sql.Filters(query).Count > 0)
        {
            return null;
        }
        string site = query.Str("site")!;
        double qFrom = query.Num("from");
        double qTo = query.Num("to");
        // Pages and events always go this way without filters, so a range gives the same answer
        // whether its days are built or not.
        var plan = await RollupPlanAsync(query, qFrom, qTo, cancellationToken).ConfigureAwait(false)
            ?? (page || evt ? new Plan([], [(qFrom, qTo)]) : null);
        if (plan == null)
        {
            return null;
        }
        // Keyed by value in the order first seen.
        var sums = new OrderedDictionary<string, Dictionary<string, double>>(StringComparer.Ordinal);
        void Bump(JsObject row)
        {
            string key = Sql.S(row.Get("value"));
            if (!sums.TryGetValue(key, out var into))
            {
                into = SumKeys.ToDictionary(k => k, _ => 0.0, StringComparer.Ordinal);
                sums[key] = into;
            }
            foreach (string k in SumKeys)
            {
                into[k] += Sql.Num(row.Get(k));
            }
        }
        if (plan.Days.Count > 0)
        {
            var rolled = await Db.AllAsync(
                "SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,\n           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events\n         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN (" + Sql.BuiltDays + ") GROUP BY value",
                A(site, dimension, site, qFrom, qTo),
                cancellationToken).ConfigureAwait(false);
            foreach (var row in rolled)
            {
                Bump(row);
            }
        }
        var w = Within(plan.Rest);
        if ((page || evt) && plan.Rest.Count > 0)
        {
            // A visit's pageviews and events belong to the day it started, as in the rollups. Bounded
            // by time as well, so the events index finds them (see BuildRollupDayAsync).
            double lo = plan.Rest.Min(r => r.From);
            double hi = plan.Rest.Max(r => r.To) + Sql.EventTailMs;
            string OfRest(string kind) => "FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '" + kind + "' AND e.ts >= ? AND e.ts < ? AND " + Sql.IsVisit + " AND " + w.Sql;
            List<object?> at = [site, lo, hi, .. w.Params];
            if (page)
            {
                foreach (var row in await Db.AllAsync("SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, " + Sql.LiveViews + " AS views " + OfRest("pageview") + " GROUP BY e.path", at, cancellationToken).ConfigureAwait(false))
                {
                    Bump(row);
                }
                foreach (var row in await Db.AllAsync(
                    "SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (\n             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest " + OfRest("engagement") + " GROUP BY e.path, e.pageview) t GROUP BY value",
                    at,
                    cancellationToken).ConfigureAwait(false))
                {
                    Bump(row);
                }
            }
            else
            {
                foreach (var row in await Db.AllAsync("SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events " + OfRest("event") + " GROUP BY e.name", at, cancellationToken).ConfigureAwait(false))
                {
                    Bump(row);
                }
            }
        }
        else if (page || evt)
        {
            // Every day of the range is built.
        }
        else
        {
            string col = "s." + Query.SessionDimensions[dimension];
            foreach (var row in await Db.AllAsync(
                "SELECT " + col + " AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,\n           SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced, SUM(" + Sql.Duration + ") AS duration\n         FROM rl_sessions s WHERE s.site = ? AND " + Sql.IsVisit + " AND " + w.Sql + " AND " + col + " <> '' GROUP BY " + col,
                [site, .. w.Params],
                cancellationToken).ConfigureAwait(false))
            {
                Bump(row);
            }
        }
        bool entryExit = dimension is "entry" or "exit";
        var rows = sums
            .Where(e => (evt || e.Key.Length > 0) && (page ? e.Value["pageviews"] > 0 : (evt ? e.Value["events"] > 0 : e.Value["visits"] > 0)))
            .ToList();
        rows.Sort((p, q) =>
        {
            var (x, y) = (p.Value, q.Value);
            double[] order = entryExit ? [y["visits"] - x["visits"]]
                : evt ? [y["visitors"] - x["visitors"], y["events"] - x["events"]]
                : page ? [y["visitors"] - x["visitors"], y["pageviews"] - x["pageviews"]]
                : [y["visitors"] - x["visitors"], y["visits"] - x["visits"]];
            foreach (double d in order)
            {
                if (d != 0)
                {
                    return d < 0 ? -1 : 1;
                }
            }
            return Sql.CodeOrder(p.Key, q.Key);
        });
        var output = new List<JsObject>();
        foreach (var (value, x) in rows.Skip(offset).Take(limit))
        {
            if (evt)
            {
                output.Add(new JsObject { ["value"] = value, ["visitors"] = x["visitors"], ["events"] = x["events"] });
                continue;
            }
            if (page)
            {
                output.Add(new JsObject
                {
                    ["value"] = value,
                    ["visitors"] = x["visitors"],
                    ["pageviews"] = x["pageviews"],
                    // Over every pageview that could report its time, counting those that sent none (under a second) as none.
                    ["timeOnPage"] = x["views"] > 0 ? Js.Round(x["engaged"] / x["views"]) : 0.0,
                    ["scrollDepth"] = x["scroll_n"] > 0 ? Js.Round(x["scroll_sum"] / x["scroll_n"]) : 0.0,
                });
                continue;
            }
            var row = new JsObject { ["value"] = value, ["visitors"] = x["visitors"], ["visits"] = x["visits"], ["bounceRate"] = x["visits"] > 0 ? x["bounced"] / x["visits"] : 0.0 };
            if (!entryExit)
            {
                row["pageviews"] = x["pageviews"];
                row["visitDuration"] = x["visits"] > 0 ? Js.Round(x["duration"] / x["visits"]) : 0.0;
            }
            output.Add(row);
        }
        return output;
    }

    private async Task<JsObject?> RolledStatsAsync(JsObject query, CancellationToken cancellationToken)
    {
        string site = query.Str("site")!;
        var plan = await RollupPlanAsync(query, query.Num("from"), query.Num("to"), cancellationToken).ConfigureAwait(false);
        if (plan == null)
        {
            return null;
        }
        var rolled = await Db.FirstAsync(
            "SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration\n       FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (" + Sql.BuiltDays + ")",
            A(site, site, query.Num("from"), query.Num("to")),
            cancellationToken).ConfigureAwait(false);
        var w = Within(plan.Rest);
        var raw = await Db.FirstAsync(
            "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,\n         SUM(CASE WHEN " + Sql.Bounce + " THEN 1 ELSE 0 END) AS bounced, SUM(" + Sql.Duration + ") AS duration\n       FROM rl_sessions s WHERE s.site = ? AND " + Sql.IsVisit + " AND " + w.Sql,
            [site, .. w.Params],
            cancellationToken).ConfigureAwait(false);
        double Add(string k) => Sql.Num(rolled?.Get(k)) + Sql.Num(raw?.Get(k));
        return StatsOf(Add("visitors"), Add("visits"), Add("pageviews"), Add("bounced"), Add("duration"));
    }

    private static JsObject StatsOf(double visitors, double visits, double pageviews, double bounced, double duration) => new()
    {
        ["visitors"] = visitors,
        ["visits"] = visits,
        ["pageviews"] = pageviews,
        ["viewsPerVisit"] = visits > 0 ? Js.Round(pageviews / visits * 100) / 100 : 0.0,
        ["bounceRate"] = visits > 0 ? bounced / visits : 0.0,
        ["visitDuration"] = visits > 0 ? Js.Round(duration / visits) : 0.0,
    };

    public Task SetSiteOverridesAsync(string id, JsObject overrides, CancellationToken cancellationToken = default) =>
        Db.RunAsync("UPDATE rl_sites SET overrides = ? WHERE id = ?", A(Json.Stringify(overrides), id), cancellationToken);

    /// <summary>When the site last recorded a visit, or null if it never has.</summary>
    public async Task<double?> LastSeenAsync(string site, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')", A(site), cancellationToken).ConfigureAwait(false);
        return row == null || row.Get("t") == null ? null : Sql.Num(row.Get("t"));
    }

    public async Task<List<JsObject>> SitesAsync(CancellationToken cancellationToken = default)
    {
        var rows = await Db.AllAsync("SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id", null, cancellationToken).ConfigureAwait(false);
        return rows.Select(row => new JsObject
        {
            ["id"] = Sql.S(row.Get("id")),
            ["name"] = Sql.S(row.Get("name")),
            ["hostnames"] = Json.Parse(Sql.S(row.Get("hostnames"))),
            ["timezone"] = Sql.S(row.Get("timezone")),
        }).ToList();
    }

    // Salts

    /// <summary>The salt for a day, made on first ask. Two racing callers agree on one.</summary>
    public async Task<string> SaltAsync(string day, string fresh, CancellationToken cancellationToken = default)
    {
        await Db.RunAsync(Sql.Upsert(Dialect, "rl_salts", ["day", "salt"], ["day"], []), A(day, fresh), cancellationToken).ConfigureAwait(false);
        var row = await Db.FirstAsync("SELECT salt FROM rl_salts WHERE day = ?", A(day), cancellationToken).ConfigureAwait(false);
        return row?.Get("salt") != null ? Sql.S(row.Get("salt")) : fresh;
    }

    public async Task<string?> SaltIfExistsAsync(string day, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT salt FROM rl_salts WHERE day = ?", A(day), cancellationToken).ConfigureAwait(false);
        return row?.Get("salt") != null ? Sql.S(row.Get("salt")) : null;
    }

    /// <summary>Deletes every salt older than <paramref name="day"/>, so old hashes can never be recomputed.</summary>
    public Task DropSaltsBeforeAsync(string day, CancellationToken cancellationToken = default) =>
        Db.RunAsync("DELETE FROM rl_salts WHERE day < ?", A(day), cancellationToken);

    // Ingest

    /// <summary>The visitor's open session: any of their hashes, active since <paramref name="since"/>; { id, visitor } or null.</summary>
    public async Task<JsObject?> OpenSessionAsync(string site, IReadOnlyList<string> visitors, long since, CancellationToken cancellationToken = default)
    {
        if (visitors.Count == 0)
        {
            return null;
        }
        var row = await Db.FirstAsync(
            "SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN (" + string.Join(", ", visitors.Select(_ => "?")) + ") AND last_at >= ?\n       ORDER BY last_at DESC, id LIMIT 1",
            [site, .. visitors, since],
            cancellationToken).ConfigureAwait(false);
        return row == null ? null : new JsObject { ["id"] = Sql.S(row.Get("id")), ["visitor"] = Sql.S(row.Get("visitor")) };
    }

    public Task InsertSessionAsync(JsObject row, CancellationToken cancellationToken = default) => Db.RunAsync(
        "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,\n        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,\n        browser, browser_version, os, os_version, device, screen, language)\n       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        A(row.Get("id"), row.Get("site"), row.Get("visitor"), row.Get("startedAt"), row.Get("startedAt"), row.Get("hostname"), row.Get("referrerHost"), row.Get("referrerPath"),
            row.Get("source"), row.Get("channel"), row.Get("utmSource"), row.Get("utmMedium"), row.Get("utmCampaign"), row.Get("utmTerm"), row.Get("utmContent"),
            row.Get("country"), row.Get("region"), row.Get("city"), row.Get("browser"), row.Get("browserVersion"), row.Get("os"), row.Get("osVersion"), row.Get("device"),
            row.Get("screen"), row.Get("language")),
        cancellationToken);

    /// <summary>
    /// Counts a row into its session. An event with <paramref name="reopen"/> false, one that joins
    /// a visit already ended, counts without moving the session's last activity.
    /// </summary>
    public Task TouchSessionAsync(string id, long ts, string kind, string path, bool reopen = true, CancellationToken cancellationToken = default)
    {
        if (kind == "click")
        {
            return Db.RunAsync("UPDATE rl_sessions SET last_at = ? WHERE id = ?", A(ts, id), cancellationToken);
        }
        if (kind == "pageview")
        {
            return Db.RunAsync(
                "UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,\n           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?",
                A(ts, path, path, id),
                cancellationToken);
        }
        if (reopen)
        {
            return Db.RunAsync("UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?", A(ts, id), cancellationToken);
        }
        return Db.RunAsync("UPDATE rl_sessions SET events = events + 1 WHERE id = ?", A(id), cancellationToken);
    }

    public Task AddEngagementAsync(string id, long ms, CancellationToken cancellationToken = default) =>
        Db.RunAsync("UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?", A(ms, id), cancellationToken);

    /// <summary>The pageview an engagement ping or event belongs to, with when its visit started and was last active.</summary>
    public async Task<JsObject?> PageviewAsync(string site, string pageview, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync(
            "SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at\n       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1",
            A(site, pageview),
            cancellationToken).ConfigureAwait(false);
        return row == null ? null : new JsObject
        {
            ["session"] = Sql.S(row.Get("session")),
            ["visitor"] = Sql.S(row.Get("visitor")),
            ["path"] = Sql.S(row.Get("path")),
            ["hostname"] = Sql.S(row.Get("hostname")),
            ["ts"] = Sql.Num(row.Get("ts")),
            ["startedAt"] = Sql.Num(row.Get("started_at")),
            ["lastAt"] = Sql.Num(row.Get("last_at")),
        };
    }

    /// <summary>
    /// After a late event or engagement ping joins an old visit (a tab left open overnight), the day
    /// that visit started may already be added up. Forget that day so the next check builds it again.
    /// </summary>
    public async Task TouchedOldVisitAsync(string site, long started, long before, CancellationToken cancellationToken = default)
    {
        if (started < before)
        {
            await ClearRollupsAsync(site, from: started, to: started + 1, cancellationToken: cancellationToken).ConfigureAwait(false);
        }
    }

    public Task InsertEventAsync(JsObject row, CancellationToken cancellationToken = default)
    {
        object? props = row.Get("props");
        return Db.RunAsync(
            "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)\n       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            A(row.Get("site"), row.Get("ts"), row.Get("kind"), row.Get("visitor"), row.Get("session"), row.Get("pageview"), row.Get("path"), row.Get("hostname"), row.Get("title"),
                row.Get("name"), props == null ? null : Json.Stringify(props), row.Get("engagedMs"), row.Get("scroll"), row.Get("link")),
            cancellationToken);
    }

    // Links

    /// <summary>The live link with a slug. Slugs are unique across every domain.</summary>
    public async Task<JsObject?> LinkBySlugAsync(string slug, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1", A(slug), cancellationToken).ConfigureAwait(false);
        return row == null ? null : Sql.LinkRow(row);
    }

    public async Task<JsObject?> LinkByIdAsync(string id, CancellationToken cancellationToken = default)
    {
        var row = await Db.FirstAsync("SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1", A(id), cancellationToken).ConfigureAwait(false);
        return row == null ? null : Sql.LinkRow(row);
    }

    public Task InsertLinkAsync(JsObject link, CancellationToken cancellationToken = default) => Db.RunAsync(
        "INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        A(link.Get("id"), link.Get("site"), link.Get("domain"), link.Get("slug"), link.Get("name"), link.Get("url"), link.Get("createdAt"), link.Get("updatedAt")),
        cancellationToken);

    public Task UpdateLinkAsync(JsObject link, CancellationToken cancellationToken = default) => Db.RunAsync(
        "UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?",
        A(link.Get("domain"), link.Get("slug"), link.Get("name"), link.Get("url"), link.Get("updatedAt"), link.Get("id")),
        cancellationToken);

    /// <summary>Hides a link and frees its slug; its clicks stay in the history.</summary>
    public Task DeleteLinkAsync(string id, long now, CancellationToken cancellationToken = default) =>
        Db.RunAsync("UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", A(now, id), cancellationToken);

    // Shares

    private static JsObject ShareRow(JsObject r) => new()
    {
        ["id"] = Sql.S(r.Get("id")),
        ["site"] = Sql.S(r.Get("site")),
        ["name"] = Sql.S(r.Get("name")),
        ["createdAt"] = Js.Number(r.Get("created_at")),
    };

    public async Task<List<JsObject>> SharesAsync(string site, CancellationToken cancellationToken = default) =>
        (await Db.AllAsync("SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id", A(site), cancellationToken).ConfigureAwait(false)).Select(ShareRow).ToList();

    public async Task<JsObject?> ShareByIdAsync(string id, CancellationToken cancellationToken = default)
    {
        var r = await Db.FirstAsync("SELECT id, site, name, created_at FROM rl_shares WHERE id = ?", A(id), cancellationToken).ConfigureAwait(false);
        return r == null ? null : ShareRow(r);
    }

    public Task InsertShareAsync(JsObject share, CancellationToken cancellationToken = default) =>
        Db.RunAsync("INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)", A(share.Get("id"), share.Get("site"), share.Get("name"), share.Get("createdAt")), cancellationToken);

    public Task RenameShareAsync(string id, string name, CancellationToken cancellationToken = default) =>
        Db.RunAsync("UPDATE rl_shares SET name = ? WHERE id = ?", A(name, id), cancellationToken);

    /// <summary>Deleting a share is how it is revoked: the link stops working at once.</summary>
    public Task DeleteShareAsync(string id, CancellationToken cancellationToken = default) =>
        Db.RunAsync("DELETE FROM rl_shares WHERE id = ?", A(id), cancellationToken);
}
