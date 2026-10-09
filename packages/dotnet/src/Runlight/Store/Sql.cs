using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Runlight.Store;

/// <summary>A piece of SQL with its values.</summary>
public sealed record SqlPart(string Sql, List<object?> Params);

/// <summary>
/// The SQL that store.ts builds outside its class: the schema, filters as conditions, and the small
/// pieces every report shares. Each statement is the TypeScript one, for each dialect ("sqlite",
/// "postgres", "mysql"), so one database serves either implementation.
/// </summary>
/// <remarks>A filter is { dimension, op, value }.</remarks>
public static class Sql
{
    /// <summary>A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged.</summary>
    public const long BounceMs = 10_000;

    public const string Bounce = "(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < 10000))";

    public const string VisitKinds = "e.kind IN ('pageview', 'event')";

    /// <summary>
    /// Cloudflare D1 takes at most 100 bound parameters a statement, so lists that grow with the range
    /// (chart buckets, values) go in pieces, and built days are chosen by their dates.
    /// </summary>
    public const int BucketsPerQuery = 30;

    public const int ValuesPerQuery = 50;

    /// <summary>The most values one statement binds: D1's 100, less a little.</summary>
    public const int MaxParams = 96;

    /// <summary>The built days inside a range, as a subquery taking (site, from, to).</summary>
    public const string BuiltDays = "SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?";

    /// <summary>The most visits journeys reads, newest first.</summary>
    public const int JourneyVisits = 20_000;

    /// <summary>How long after a visit starts its events are looked for: far past any real visit.</summary>
    public const long EventTailMs = 2 * 86_400_000L;

    public const long PieceMs = 86_400_000;

    /// <summary>
    /// Pageviews that can report engaged time: the tracker's, which carry a pageview id. Imported
    /// history has none, so time on page is the mean over these, counting a view that reported
    /// nothing (under a second) as none.
    /// </summary>
    public const string LiveViews = "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)";

    /// <summary>A session that is a visit: a short link click alone opens one that is not.</summary>
    public const string IsVisit = "(s.pageviews > 0 OR s.events > 0)";

    /// <summary>Engaged time, or for imported visits with none, first to last request.</summary>
    public const string Duration = "COALESCE(s.engaged_ms, s.last_at - s.started_at)";

    public const int SchemaVersion = 11;

    /// <summary>
    /// MySQL's text collation: UTF-8 compared and sorted by code point, case and trailing spaces
    /// included, as SQLite and Postgres's "C" collation do. MariaDB has it too, from 11.4.
    /// </summary>
    public const string MysqlCollation = "utf8mb4_0900_bin";

    private static readonly string[] PathDimensions = ["page", "entry", "exit"];

    /// <summary>
    /// Orders text by code point, as SQLite and Postgres's "C" collation do (JavaScript's <c>&lt;</c>
    /// compares UTF-16 units). UTF-8 bytes sort in code point order, so the code points are compared.
    /// </summary>
    public static int CodeOrder(string a, string b)
    {
        int n = Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++)
        {
            char x = a[i];
            char y = b[i];
            if (x == y)
            {
                continue;
            }
            // A surrogate (an astral code point) sorts after every other BMP character.
            bool xs = char.IsSurrogate(x);
            bool ys = char.IsSurrogate(y);
            if (xs != ys)
            {
                return xs ? 1 : -1;
            }
            return x < y ? -1 : 1;
        }
        return a.Length.CompareTo(b.Length);
    }

    /// <summary>Runs a query over pieces of a list and joins the answers, in order.</summary>
    public static async System.Threading.Tasks.Task<List<TR>> InPiecesAsync<T, TR>(IReadOnlyList<T> items, int size, Func<List<T>, System.Threading.Tasks.Task<List<TR>>> run)
    {
        var output = new List<TR>();
        for (int i = 0; i < items.Count; i += size)
        {
            output.AddRange(await run(items.Skip(i).Take(size).ToList()).ConfigureAwait(false));
        }
        return output;
    }

    public static List<string> Schema(string dialect)
    {
        bool my = dialect == "mysql";
        string id = dialect == "postgres" ? "BIGSERIAL PRIMARY KEY" : (my ? "BIGINT AUTO_INCREMENT PRIMARY KEY" : "INTEGER PRIMARY KEY AUTOINCREMENT");
        // MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed,
        // grouped, or sorted is VARCHAR, sized past anything Runlight writes to it. Elsewhere text is text.
        string Str(int n) => my ? "VARCHAR(" + n + ")" : "TEXT";
        string Text(int n) => Str(n) + " NOT NULL DEFAULT ''";
        // Free text that is never keyed. MySQL takes a default for it only as an expression.
        string Long(string fallback) => my ? "MEDIUMTEXT NOT NULL DEFAULT ('" + fallback + "')" : "TEXT NOT NULL DEFAULT '" + fallback + "'";
        string table = my ? " DEFAULT CHARSET=utf8mb4 COLLATE=" + MysqlCollation : "";
        string site = Str(100);
        string key = Str(100);
        int path = 1000;
        string medium = my ? "MEDIUMTEXT" : "TEXT";
        return
        [
            $"CREATE TABLE IF NOT EXISTS rl_meta (\"key\" {Str(100)} PRIMARY KEY, value {medium} NOT NULL){table}",
            $"""
            CREATE TABLE IF NOT EXISTS rl_sites (
                  id {site} PRIMARY KEY, name {Text(200)}, hostnames {Long("[]")},
                  timezone {Str(64)} NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
                  overrides {Long("{}")}){table}
            """,
            $"CREATE TABLE IF NOT EXISTS rl_salts (day {Str(32)} PRIMARY KEY, salt {Str(255)} NOT NULL){table}",
            $"""
            CREATE TABLE IF NOT EXISTS rl_sessions (
                  id {key} PRIMARY KEY, site {site} NOT NULL, visitor {key} NOT NULL,
                  started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
                  entry_path {Text(path)}, exit_path {Text(path)},
                  pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
                  engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
                  hostname {Text(255)}, referrer_host {Text(255)}, referrer_path {Text(500)},
                  source {Text(200)}, channel {Text(100)},
                  utm_source {Text(200)}, utm_medium {Text(200)}, utm_campaign {Text(200)}, utm_term {Text(200)}, utm_content {Text(200)},
                  country {Text(16)}, region {Text(100)}, city {Text(100)},
                  browser {Text(100)}, browser_version {Text(100)}, os {Text(100)}, os_version {Text(100)},
                  device {Text(50)}, screen {Text(50)}, language {Text(50)}){table}
            """,
            "CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)",
            // MySQL takes an index that leads with the site as a way to read all of a site's rows, even
            // where a range of time would read far fewer, so there an index for looking a value up leads
            // with that value.
            "CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions (" + (my ? "visitor, site" : "site, visitor") + ", last_at)",
            $"""
            CREATE TABLE IF NOT EXISTS rl_events (
                  id {id}, site {site} NOT NULL, ts BIGINT NOT NULL, kind {Str(20)} NOT NULL,
                  visitor {Text(100)}, session {Text(100)}, pageview {Text(100)},
                  path {Text(path)}, hostname {Text(255)}, title {Text(500)}, name {Text(255)}, props {medium},
                  engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link {Text(100)}){table}
            """,
            "CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)",
            // Goals and events read one kind of row in a range; created on start for older databases too.
            "CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)",
            "CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events (" + (my ? "pageview, site" : "site, pageview") + ")",
            // Page and event filters find the visits they pick through these, rather than reading every
            // row in the range. MySQL indexes the first 255 characters of a path, which is enough to find it.
            "CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events (" + (my ? "path(255), site" : "site, path") + ", ts)",
            // MySQL has no partial index, so its index of event names holds the kind too.
            my
                ? "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)"
                : "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'",
            // Version 3: short links; "" is the app's own domain. Version 4: a slug is unique across
            // every domain, so a link whose domain is removed can fall back to the app's own link path
            // without colliding with another. MySQL has no partial index, so there a generated column
            // holds the slug of a live link only, and is unique.
            $"""
            CREATE TABLE IF NOT EXISTS rl_links (
                  id {key} PRIMARY KEY, site {site} NOT NULL, domain {Text(255)}, slug {Str(255)} NOT NULL,
                  name {Text(255)}, url {Str(4000)} NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
                  deleted_at BIGINT
            """ + (my ? ", live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL" : "") + ")" + table,
            my
                ? "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)"
                : "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL",
            "CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)",
            $"CREATE TABLE IF NOT EXISTS rl_link_domains (domain {Str(255)} PRIMARY KEY, site {site} NOT NULL, created_at BIGINT NOT NULL){table}",
            // Version 5: share links.
            $"CREATE TABLE IF NOT EXISTS rl_shares (id {key} PRIMARY KEY, site {site} NOT NULL, name {Text(255)}, created_at BIGINT NOT NULL){table}",
            // Version 6: goals.
            $"""
            CREATE TABLE IF NOT EXISTS rl_goals (
                  id {key} PRIMARY KEY, site {site} NOT NULL, name {Str(255)} NOT NULL, kind {Str(20)} NOT NULL, "match" {Str(1000)} NOT NULL,
                  click_by {Text(20)}, value_mode {Str(20)} NOT NULL DEFAULT 'none', value {(my ? "DOUBLE" : "REAL")} NOT NULL DEFAULT 0,
                  value_prop {Text(255)}, currency {Str(10)} NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL){table}
            """,
            // Version 7: install-wide settings (the mail service) and email report subscriptions.
            $"CREATE TABLE IF NOT EXISTS rl_settings (\"key\" {Str(255)} PRIMARY KEY, value {medium} NOT NULL){table}",
            $"""
            CREATE TABLE IF NOT EXISTS rl_reports (
                  id {key} PRIMARY KEY, site {site} NOT NULL, email {Str(320)} NOT NULL, frequency {Str(20)} NOT NULL,
                  lang {Str(20)} NOT NULL DEFAULT 'en', token {Str(128)} NOT NULL, origin {Text(500)},
                  last_period {Text(40)}, last_sent_at BIGINT, created_at BIGINT NOT NULL){table}
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)",
            // Version 8: read-only API tokens, for scripts and AI assistants over MCP.
            $"""
            CREATE TABLE IF NOT EXISTS rl_tokens (
                  id {key} PRIMARY KEY, name {Str(255)} NOT NULL, site {Text(100)}, hash {Str(128)} NOT NULL, hint {Text(20)},
                  created_at BIGINT NOT NULL, last_used_at BIGINT, scope {Str(20)} NOT NULL DEFAULT 'read'){table}
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)",
            // Version 9: funnels.
            $"CREATE TABLE IF NOT EXISTS rl_funnels (id {key} PRIMARY KEY, site {site} NOT NULL, name {Str(255)} NOT NULL, steps {medium} NOT NULL, created_at BIGINT NOT NULL){table}",
            // Version 11: daily rollups. A day is the site's own local day; rl_rollup_days says which
            // days are built and where they begin and end.
            $"CREATE TABLE IF NOT EXISTS rl_rollup_days (site {site} NOT NULL, day {Str(32)} NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day)){table}",
            "CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)",
            // A value can be a whole path, longer than MySQL's keys allow, so there the rows of a day are
            // found by an index without it; a day's rows are only ever written all at once.
            $"""
            CREATE TABLE IF NOT EXISTS rl_rollups (
                  site {site} NOT NULL, day {Str(32)} NOT NULL, dim {Str(32)} NOT NULL, value {Text(path)},
                  visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,
                  bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,
                  engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,
                  events BIGINT NOT NULL DEFAULT 0,
                  {(my ? "KEY rl_rollups_day (site, dim, day)" : "PRIMARY KEY (site, dim, day, value)")}){table}
            """,
        ];
    }

    /// <summary>Text, or "" for null, as String(value ?? "") gives.</summary>
    public static string S(object? v) => v is null or Undefined ? "" : Js.String(v);

    /// <summary>A GoalRow from a database row.</summary>
    public static JsObject GoalRow(JsObject r) => new()
    {
        ["id"] = S(r.Get("id")),
        ["site"] = S(r.Get("site")),
        ["name"] = S(r.Get("name")),
        ["kind"] = S(r.Get("kind")),
        ["match"] = S(r.Get("match")),
        ["clickBy"] = S(r.Get("click_by")),
        ["valueMode"] = S(r.Get("value_mode")),
        ["value"] = Js.Number(r.Get("value") ?? 0L),
        ["valueProp"] = S(r.Get("value_prop")),
        ["currency"] = r.Get("currency") == null ? "USD" : S(r.Get("currency")),
        ["createdAt"] = Js.Number(r.Get("created_at")),
    };

    /// <summary>A <c>*</c> pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own).</summary>
    public static string GlobPattern(string pattern) =>
        string.Join('*', pattern.Split('*').Select(part => Regex.Replace(part, "[\\[?]", "[$0]")));

    /// <summary>A <c>*</c> pattern as SQL LIKE, everything else taken literally.</summary>
    public static string LikePattern(string pattern) => string.Join('%', pattern.Split('*').Select(EscapeLike));

    /// <summary>
    /// An INSERT that updates the row already there with the same key, or with <paramref name="update"/>
    /// empty leaves it be. MySQL says it its own way, and has no other unique key on these tables to trip over.
    /// </summary>
    public static string Upsert(string dialect, string table, IReadOnlyList<string> columns, IReadOnlyList<string> key, IReadOnlyList<string> update)
    {
        string insert = "INSERT INTO " + table + " (" + string.Join(", ", columns) + ") VALUES (" + string.Join(", ", columns.Select(_ => "?")) + ")";
        if (dialect == "mysql")
        {
            var set = (update.Count > 0 ? update : [key[0]]).Select(c => c + " = " + (update.Count > 0 ? "VALUES(" + c + ")" : c));
            return insert + " ON DUPLICATE KEY UPDATE " + string.Join(", ", set);
        }
        return insert + " ON CONFLICT (" + string.Join(", ", key) + ") DO "
            + (update.Count > 0 ? "UPDATE SET " + string.Join(", ", update.Select(c => c + " = excluded." + c)) : "NOTHING");
    }

    /// <summary>Whole-number division, which MySQL's <c>/</c> is not.</summary>
    public static string Div(string dialect, string a, long b) => dialect == "mysql" ? "(" + a + " DIV " + b + ")" : "(" + a + " / " + b + ")";

    /// <summary>A value as text: MySQL casts to CHAR, and has no TEXT type to cast to.</summary>
    public static string AsText(string dialect, string value) => "CAST(" + value + " AS " + (dialect == "mysql" ? "CHAR" : "TEXT") + ")";

    /// <summary>
    /// A table of buckets (i, bs, be) for a WITH clause. Postgres is told the first row's types;
    /// MySQL and MariaDB write a table of values differently from each other, so they get a UNION of rows.
    /// </summary>
    public static string BucketTable(string dialect, int count)
    {
        if (dialect == "mysql")
        {
            return string.Join(" UNION ALL ", Enumerable.Range(0, count).Select(i => i == 0 ? "SELECT ? AS i, ? AS bs, ? AS be" : "SELECT ?, ?, ?"));
        }
        bool cast = dialect == "postgres";
        return "VALUES " + string.Join(", ", Enumerable.Range(0, count).Select(i => cast && i == 0 ? "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))" : "(?, ?, ?)"));
    }

    /// <summary>A LinkRow from a database row.</summary>
    public static JsObject LinkRow(JsObject row) => new()
    {
        ["id"] = S(row.Get("id")),
        ["site"] = S(row.Get("site")),
        ["domain"] = S(row.Get("domain")),
        ["slug"] = S(row.Get("slug")),
        ["name"] = S(row.Get("name")),
        ["url"] = S(row.Get("url")),
        ["createdAt"] = Js.Number(row.Get("created_at")),
        ["updatedAt"] = Js.Number(row.Get("updated_at")),
    };

    /// <summary>Number(value ?? 0), or 0 when that is not finite.</summary>
    public static double Num(object? value)
    {
        double n = Js.Number(value ?? 0L);
        return double.IsFinite(n) ? n : 0;
    }

    public static string EscapeLike(string value) => Regex.Replace(value, "[\\\\%_]", "\\$0");

    public static string Column(string dimension) =>
        Query.IsSessionDimension(dimension) ? "s." + Query.SessionDimensions[dimension] : "e." + Query.EventDimensions[dimension];

    /// <summary>Text in the form a recorded path holds it, percent-encoded, as part of a path or as a whole one.</summary>
    public static string AsRecorded(string value, bool whole)
    {
        string? path = Sources.RecordedPath(whole || value.StartsWith('/') ? value : "/" + value);
        if (path == null)
        {
            return value;
        }
        return whole || value.StartsWith('/') ? path : path[1..];
    }

    /// <summary>A GLOB pattern for text containing <paramref name="value"/> in any mix of upper and lower case, letter by letter.</summary>
    public static string AnyCase(string value)
    {
        var b = new StringBuilder("*");
        foreach (var rune in Js.WellFormed(value).EnumerateRunes())
        {
            string ch = rune.ToString();
            string lower = Js.Lower(ch);
            string upper = Js.Upper(ch);
            if (lower != upper && RuneCount(lower) == 1 && RuneCount(upper) == 1)
            {
                b.Append('[').Append(lower).Append(upper).Append(']');
            }
            else
            {
                b.Append(ch is "*" or "?" or "[" ? "[" + ch + "]" : ch);
            }
        }
        return b.Append('*').ToString();
    }

    private static int RuneCount(string s) => s.EnumerateRunes().Count();

    private static readonly Regex TitleStart = new("(^|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF\\-/_.])(\\p{L})", RegexOptions.CultureInvariant);

    /// <summary>One filter as a condition on its own column, with "is not" flipped to "is" when <paramref name="positive"/> asks.</summary>
    public static SqlPart Condition(JsObject filter, string dialect, bool positive = false)
    {
        string dimension = filter.Str("dimension")!;
        string col = Column(dimension);
        string op = positive && filter.Str("op") == "not" ? "is" : filter.Str("op")!;
        // Paths are recorded percent-encoded, as the browser's URL parser writes them, so "/café" is
        // matched as "/caf%C3%A9", just as a goal for it is.
        bool path = PathDimensions.Contains(dimension);
        string value = filter.Str("value")!;
        if (op is "is" or "not")
        {
            return new SqlPart(col + " " + (op == "is" ? "=" : "<>") + " ?", [path ? AsRecorded(value, true) : value]);
        }
        if (path)
        {
            // An encoded letter's case is in its bytes (%C3%9C is Ü, %C3%BC is ü), which no database
            // folds, so a path is also tried in lower, upper, and title case, encoded each way.
            string title = TitleStart.Replace(Js.Lower(value), m => m.Groups[1].Value + Js.Upper(m.Groups[2].Value));
            var forms = new[] { value, Js.Lower(value), Js.Upper(value), title }.Select(f => AsRecorded(f, false)).Distinct(StringComparer.Ordinal).ToList();
            bool lowered = dialect != "sqlite";
            string one = lowered ? "LOWER(" + col + ") LIKE ? ESCAPE '\\'" : col + " LIKE ? ESCAPE '\\'";
            return new SqlPart(
                "(" + string.Join(" OR ", forms.Select(_ => one)) + ")",
                [.. forms.Select(f => (object?)("%" + EscapeLike(lowered ? Js.Lower(f) : f) + "%"))]);
        }
        // Postgres and MySQL lower case any letter, so both sides lowered find any mix. Their LIKE then
        // compares exactly: Postgres's always, MySQL's under Runlight's binary collation.
        if (dialect != "sqlite")
        {
            return new SqlPart("LOWER(" + col + ") LIKE ? ESCAPE '\\'", ["%" + EscapeLike(Js.Lower(value)) + "%"]);
        }
        // SQLite's LIKE and LOWER ignore case for ASCII letters only, so "über" would never find
        // "Über". GLOB with both cases of every letter finds any mix, Unicode included.
        return new SqlPart(col + " GLOB ?", [AnyCase(value)]);
    }

    /// <summary>The filters of a query, as objects.</summary>
    public static List<JsObject> Filters(JsObject query) => query.Arr("filters")?.Cast<JsObject>().ToList() ?? [];

    /// <summary>
    /// The visits a query's filters pick, as conditions on <c>s</c>. A filter on the visit (source,
    /// country, entry page) applies to it directly. A filter on a page, hostname, or event picks the
    /// visits that had a matching row, or for "is not", that never had one. Every number then
    /// describes those whole visits, and a visit belongs to the range it started in, as it does with
    /// no filter. Rows count up to EventTailMs past the range, for a visit still going when it ends.
    /// </summary>
    public static SqlPart VisitScope(IReadOnlyList<JsObject> filters, string site, long from, long to, string dialect)
    {
        var parts = new List<string>();
        var parameters = new List<object?>();
        foreach (var filter in filters)
        {
            var c = Condition(filter, dialect, true);
            string dimension = filter.Str("dimension")!;
            if (Query.IsSessionDimension(dimension))
            {
                var own = Condition(filter, dialect);
                parts.Add(own.Sql);
                parameters.AddRange(own.Params);
            }
            else
            {
                // An event filter reads events only, which lets it use the index of event names.
                string kinds = dimension == "event" ? "e.kind = 'event'" : VisitKinds;
                string rows = "FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND " + kinds + " AND " + c.Sql;
                // Postgres plans NOT IN over a list too big for its memory as a scan of the list for
                // every visit, which runs for hours, so it gets NOT EXISTS, an anti join. SQLite reads
                // NOT IN through a temporary index, and runs NOT EXISTS once a visit.
                if (filter.Str("op") == "not" && dialect == "postgres")
                {
                    parts.Add("NOT EXISTS (SELECT 1 " + rows + " AND e.session = s.id)");
                }
                else
                {
                    parts.Add("s.id " + (filter.Str("op") == "not" ? "NOT IN" : "IN") + " (SELECT e.session " + rows + ")");
                }
                parameters.AddRange([site, from, to + EventTailMs]);
                parameters.AddRange(c.Params);
            }
        }
        return new SqlPart(string.Concat(parts.Select(p => " AND " + p)), parameters);
    }

    /// <summary>
    /// Conditions on <c>e</c> from the filters on the given row dimensions that keep rows (is,
    /// contains). With "page is /pricing", pageviews mean views of /pricing, as people expect, while
    /// the visits are whole. A row counts when it matches any filter on each of its dimensions.
    /// </summary>
    public static SqlPart RowScope(IReadOnlyList<JsObject> filters, IReadOnlyList<string> dimensions, string dialect)
    {
        string sql = "";
        var parameters = new List<object?>();
        foreach (string dimension in dimensions)
        {
            var kept = filters.Where(f => f.Str("dimension") == dimension && f.Str("op") != "not").Select(f => Condition(f, dialect)).ToList();
            if (kept.Count == 0)
            {
                continue;
            }
            sql += " AND (" + string.Join(" OR ", kept.Select(k => k.Sql)) + ")";
            foreach (var c in kept)
            {
                parameters.AddRange(c.Params);
            }
        }
        return new SqlPart(sql, parameters);
    }

    /// <summary>
    /// Pageviews for each visit a filter picks, as a table to LEFT JOIN on <c>pv.session = s.id</c>,
    /// when a page or hostname filter narrows what counts as a pageview. Null when every pageview of a
    /// visit counts.
    /// </summary>
    public static SqlPart? PageviewsOf(IReadOnlyList<JsObject> filters, string site, long from, long to, string dialect)
    {
        var rows = RowScope(filters, ["page", "hostname"], dialect);
        if (rows.Sql.Length == 0)
        {
            return null;
        }
        return new SqlPart(
            "(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'" + rows.Sql + " GROUP BY e.session)",
            [site, from, to + EventTailMs, .. rows.Params]);
    }

    /// <summary>
    /// For reports that count rows (goals, event properties, funnels): the rows of the visits a query
    /// picks, as a FROM list and conditions over <c>e</c> and <c>s</c>. Written as a CROSS JOIN so
    /// SQLite reads the events through their (site, kind, ts) index and looks each visit up by its
    /// id, whatever its statistics say.
    /// </summary>
    public static (string From, string Sql, List<object?> Params) VisitRows(IReadOnlyList<JsObject> filters, string site, long from, long to, string dialect)
    {
        var scope = VisitScope(filters, site, from, to, dialect);
        return (
            "rl_events e CROSS JOIN rl_sessions s",
            "e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + IsVisit + scope.Sql,
            [site, from, to + EventTailMs, site, from, to, .. scope.Params]);
    }
}
