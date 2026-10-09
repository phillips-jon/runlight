//! The SQL every dialect shares, and where they differ: the schema, upserts,
//! and the conditions reports are built from (store.ts's free functions).

use super::db::{Dialect, Param};
use crate::query::{EVENT_DIMENSIONS, Filter, SESSION_DIMENSIONS, is_session_dimension};
use crate::sources::recorded_path;
use crate::time::Bucket;

/// A piece of SQL and the values its placeholders take.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Frag {
    /// The SQL.
    pub sql: String,
    /// Its values, in order.
    pub params: Vec<Param>,
}

/// A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged.
pub const BOUNCE_MS: i64 = 10_000;
pub(crate) const BOUNCE: &str = "(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < 10000))";
pub(crate) const VISIT_KINDS: &str = "e.kind IN ('pageview', 'event')";
/// Cloudflare D1 takes at most 100 bound parameters a statement, so lists that grow with the range
/// (chart buckets, values) go in pieces, and built days are chosen by their dates.
pub(crate) const BUCKETS_PER_QUERY: usize = 30;
pub(crate) const VALUES_PER_QUERY: usize = 50;
/// The most values one statement binds: D1's 100, less a little.
pub(crate) const MAX_PARAMS: usize = 96;
/// The built days inside a range, as a subquery taking (site, from, to).
pub(crate) const BUILT_DAYS: &str = "SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?";
/// The most visits journeys reads, newest first.
pub const JOURNEY_VISITS: i64 = 20_000;
/// How long after a visit starts its events are looked for: far past any real visit.
pub const EVENT_TAIL_MS: i64 = 2 * 86_400_000;
pub(crate) const PIECE_MS: i64 = 86_400_000;
/// Pageviews that can report engaged time: the tracker's, which carry a pageview id.
pub(crate) const LIVE_VIEWS: &str = "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)";
/// A session that is a visit: a short link click alone opens one that is not.
pub(crate) const IS_VISIT: &str = "(s.pageviews > 0 OR s.events > 0)";
/// Engaged time, or for imported visits with none, first to last request.
pub(crate) const DURATION: &str = "COALESCE(s.engaged_ms, s.last_at - s.started_at)";
pub(crate) const SCHEMA_VERSION: i64 = 11;

/// MySQL's text collation: UTF-8 compared and sorted by code point, case and trailing spaces
/// included, as SQLite and Postgres's "C" collation do. MariaDB has it too, from 11.4.
pub const MYSQL_COLLATION: &str = "utf8mb4_0900_bin";

/// The tables and indexes, in the order they are made.
pub(crate) fn schema(dialect: Dialect) -> Vec<String> {
    let my = dialect == Dialect::Mysql;
    let id = match dialect {
        Dialect::Postgres => "BIGSERIAL PRIMARY KEY",
        Dialect::Mysql => "BIGINT AUTO_INCREMENT PRIMARY KEY",
        Dialect::Sqlite => "INTEGER PRIMARY KEY AUTOINCREMENT",
    };
    // MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed, grouped, or
    // sorted is VARCHAR, sized past anything Runlight writes to it. Elsewhere text is text.
    let str_ = |n: u32| if my { format!("VARCHAR({n})") } else { "TEXT".to_string() };
    let text = |n: u32| format!("{} NOT NULL DEFAULT ''", str_(n));
    // Free text that is never keyed. MySQL takes a default for it only as an expression.
    let long = |fallback: &str| {
        if my {
            format!("MEDIUMTEXT NOT NULL DEFAULT ('{fallback}')")
        } else {
            format!("TEXT NOT NULL DEFAULT '{fallback}'")
        }
    };
    let table = if my { format!(" DEFAULT CHARSET=utf8mb4 COLLATE={MYSQL_COLLATION}") } else { String::new() };
    let site = str_(100);
    let key = str_(100);
    let path = 1000;
    let medium = if my { "MEDIUMTEXT" } else { "TEXT" };
    vec![
        format!("CREATE TABLE IF NOT EXISTS rl_meta (\"key\" {} PRIMARY KEY, value {medium} NOT NULL){table}", str_(100)),
        format!(
            "CREATE TABLE IF NOT EXISTS rl_sites (
      id {site} PRIMARY KEY, name {}, hostnames {},
      timezone {} NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
      overrides {}){table}",
            text(200),
            long("[]"),
            str_(64),
            long("{}")
        ),
        format!("CREATE TABLE IF NOT EXISTS rl_salts (day {} PRIMARY KEY, salt {} NOT NULL){table}", str_(32), str_(255)),
        format!(
            "CREATE TABLE IF NOT EXISTS rl_sessions (
      id {key} PRIMARY KEY, site {site} NOT NULL, visitor {key} NOT NULL,
      started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
      entry_path {}, exit_path {},
      pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
      engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
      hostname {}, referrer_host {}, referrer_path {},
      source {}, channel {},
      utm_source {}, utm_medium {}, utm_campaign {}, utm_term {}, utm_content {},
      country {}, region {}, city {},
      browser {}, browser_version {}, os {}, os_version {},
      device {}, screen {}, language {}){table}",
            text(path),
            text(path),
            text(255),
            text(255),
            text(500),
            text(200),
            text(100),
            text(200),
            text(200),
            text(200),
            text(200),
            text(200),
            text(16),
            text(100),
            text(100),
            text(100),
            text(100),
            text(100),
            text(100),
            text(50),
            text(50),
            text(50)
        ),
        "CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)".to_string(),
        // MySQL takes an index that leads with the site as a way to read all of a site's rows, even where a
        // range of time would read far fewer, so there an index for looking a value up leads with that value.
        format!(
            "CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions ({}, last_at)",
            if my { "visitor, site" } else { "site, visitor" }
        ),
        format!(
            "CREATE TABLE IF NOT EXISTS rl_events (
      id {id}, site {site} NOT NULL, ts BIGINT NOT NULL, kind {} NOT NULL,
      visitor {}, session {}, pageview {},
      path {}, hostname {}, title {}, name {}, props {medium},
      engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link {}){table}",
            str_(20),
            text(100),
            text(100),
            text(100),
            text(path),
            text(255),
            text(500),
            text(255),
            text(100)
        ),
        "CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)".to_string(),
        // Goals and events read one kind of row in a range; created on start for older databases too.
        "CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)".to_string(),
        format!("CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events ({})", if my { "pageview, site" } else { "site, pageview" }),
        // Page and event filters find the visits they pick through these, rather than reading every row in the range.
        // MySQL indexes the first 255 characters of a path, which is enough to find it.
        format!("CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events ({}, ts)", if my { "path(255), site" } else { "site, path" }),
        // MySQL has no partial index, so its index of event names holds the kind too.
        if my {
            "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)".to_string()
        } else {
            "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'".to_string()
        },
        // Version 3: short links; "" is the app's own domain. Version 4: a slug is unique
        // across every domain, so a link whose domain is removed can fall back to the
        // app's own link path without colliding with another. MySQL has no partial index,
        // so there a generated column holds the slug of a live link only, and is unique.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_links (
      id {key} PRIMARY KEY, site {site} NOT NULL, domain {}, slug {} NOT NULL,
      name {}, url {} NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
      deleted_at BIGINT{}){table}",
            text(255),
            str_(255),
            text(255),
            str_(4000),
            if my { ", live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL" } else { "" }
        ),
        if my {
            "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)".to_string()
        } else {
            "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL".to_string()
        },
        "CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)".to_string(),
        format!(
            "CREATE TABLE IF NOT EXISTS rl_link_domains (domain {} PRIMARY KEY, site {site} NOT NULL, created_at BIGINT NOT NULL){table}",
            str_(255)
        ),
        // Version 5: share links.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_shares (id {key} PRIMARY KEY, site {site} NOT NULL, name {}, created_at BIGINT NOT NULL){table}",
            text(255)
        ),
        // Version 6: goals.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_goals (
      id {key} PRIMARY KEY, site {site} NOT NULL, name {} NOT NULL, kind {} NOT NULL, \"match\" {} NOT NULL,
      click_by {}, value_mode {} NOT NULL DEFAULT 'none', value {} NOT NULL DEFAULT 0,
      value_prop {}, currency {} NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL){table}",
            str_(255),
            str_(20),
            str_(1000),
            text(20),
            str_(20),
            if my { "DOUBLE" } else { "REAL" },
            text(255),
            str_(10)
        ),
        // Version 7: install-wide settings (the mail service) and email report subscriptions.
        format!("CREATE TABLE IF NOT EXISTS rl_settings (\"key\" {} PRIMARY KEY, value {medium} NOT NULL){table}", str_(255)),
        format!(
            "CREATE TABLE IF NOT EXISTS rl_reports (
      id {key} PRIMARY KEY, site {site} NOT NULL, email {} NOT NULL, frequency {} NOT NULL,
      lang {} NOT NULL DEFAULT 'en', token {} NOT NULL, origin {},
      last_period {}, last_sent_at BIGINT, created_at BIGINT NOT NULL){table}",
            str_(320),
            str_(20),
            str_(20),
            str_(128),
            text(500),
            text(40)
        ),
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)".to_string(),
        // Version 8: read-only API tokens, for scripts and AI assistants over MCP.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_tokens (
      id {key} PRIMARY KEY, name {} NOT NULL, site {}, hash {} NOT NULL, hint {},
      created_at BIGINT NOT NULL, last_used_at BIGINT, scope {} NOT NULL DEFAULT 'read'){table}",
            str_(255),
            text(100),
            str_(128),
            text(20),
            str_(20)
        ),
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)".to_string(),
        // Version 9: funnels.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_funnels (id {key} PRIMARY KEY, site {site} NOT NULL, name {} NOT NULL, steps {medium} NOT NULL, created_at BIGINT NOT NULL){table}",
            str_(255)
        ),
        // Version 11: daily rollups. A day is the site's own local day; rl_rollup_days
        // says which days are built and where they begin and end.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_rollup_days (site {site} NOT NULL, day {} NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day)){table}",
            str_(32)
        ),
        "CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)".to_string(),
        // A value can be a whole path, longer than MySQL's keys allow, so there the rows of a day are
        // found by an index without it; a day's rows are only ever written all at once.
        format!(
            "CREATE TABLE IF NOT EXISTS rl_rollups (
      site {site} NOT NULL, day {} NOT NULL, dim {} NOT NULL, value {},
      visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,
      bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,
      engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,
      events BIGINT NOT NULL DEFAULT 0,
      {}){table}",
            str_(32),
            str_(32),
            text(path),
            if my { "KEY rl_rollups_day (site, dim, day)" } else { "PRIMARY KEY (site, dim, day, value)" }
        ),
    ]
}

/// Orders text by code point, as SQLite and Postgres's "C" collation do (JavaScript's `<` compares
/// UTF-16 units). Rust compares strings by their UTF-8 bytes, which is code point order.
pub(crate) fn code_order(a: &str, b: &str) -> std::cmp::Ordering {
    a.cmp(b)
}

/// Compares as JavaScript's `<` does: by UTF-16 code units.
pub fn js_order(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// A `*` pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own).
pub(crate) fn glob_pattern(pattern: &str) -> String {
    pattern
        .split('*')
        .map(|part| {
            let mut out = String::new();
            for c in part.chars() {
                if c == '[' || c == '?' {
                    out.push('[');
                    out.push(c);
                    out.push(']');
                } else {
                    out.push(c);
                }
            }
            out
        })
        .collect::<Vec<_>>()
        .join("*")
}

/// A `*` pattern as SQL LIKE, everything else taken literally.
pub(crate) fn like_pattern(pattern: &str) -> String {
    pattern.split('*').map(escape_like).collect::<Vec<_>>().join("%")
}

/// LIKE's own characters escaped with a backslash.
pub(crate) fn escape_like(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        if matches!(c, '\\' | '%' | '_') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// An INSERT that updates the row already there with the same key, or with `update` empty leaves it
/// be. MySQL says it its own way, and has no other unique key on these tables to trip over.
pub(crate) fn upsert(dialect: Dialect, table: &str, columns: &[&str], key: &[&str], update: &[&str]) -> String {
    let insert = format!(
        "INSERT INTO {table} ({}) VALUES ({})",
        columns.join(", "),
        columns.iter().map(|_| "?").collect::<Vec<_>>().join(", ")
    );
    if dialect == Dialect::Mysql {
        let sets: Vec<String> = if update.is_empty() {
            vec![format!("{} = {}", key[0], key[0])]
        } else {
            update.iter().map(|c| format!("{c} = VALUES({c})")).collect()
        };
        return format!("{insert} ON DUPLICATE KEY UPDATE {}", sets.join(", "));
    }
    let action = if update.is_empty() {
        "NOTHING".to_string()
    } else {
        format!("UPDATE SET {}", update.iter().map(|c| format!("{c} = excluded.{c}")).collect::<Vec<_>>().join(", "))
    };
    format!("{insert} ON CONFLICT ({}) DO {action}", key.join(", "))
}

/// Whole-number division, which MySQL's `/` is not.
pub(crate) fn div(dialect: Dialect, a: &str, b: i64) -> String {
    if dialect == Dialect::Mysql { format!("({a} DIV {b})") } else { format!("({a} / {b})") }
}

/// A value as text: MySQL casts to CHAR, and has no TEXT type to cast to.
pub(crate) fn as_text(dialect: Dialect, value: &str) -> String {
    format!("CAST({value} AS {})", if dialect == Dialect::Mysql { "CHAR" } else { "TEXT" })
}

/// A table of buckets (i, bs, be) for a WITH clause. Postgres is told the first row's types; MySQL
/// and MariaDB write a table of values differently from each other, so they get a UNION of rows.
pub(crate) fn bucket_table(dialect: Dialect, buckets: &[Bucket]) -> String {
    if dialect == Dialect::Mysql {
        return buckets
            .iter()
            .enumerate()
            .map(|(i, _)| if i == 0 { "SELECT ? AS i, ? AS bs, ? AS be" } else { "SELECT ?, ?, ?" })
            .collect::<Vec<_>>()
            .join(" UNION ALL ");
    }
    let cast = dialect == Dialect::Postgres;
    format!(
        "VALUES {}",
        buckets
            .iter()
            .enumerate()
            .map(|(i, _)| if cast && i == 0 {
                "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))"
            } else {
                "(?, ?, ?)"
            })
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// The parameters of a bucket table: index, start, end for each.
pub(crate) fn bucket_params(buckets: &[Bucket]) -> Vec<Param> {
    buckets
        .iter()
        .enumerate()
        .flat_map(|(i, b)| [Param::Int(i as i64), Param::Int(b.start), Param::Int(b.end)])
        .collect()
}

fn column(dimension: &str) -> String {
    if is_session_dimension(dimension) {
        format!("s.{}", SESSION_DIMENSIONS.iter().find(|d| d.0 == dimension).map_or("", |d| d.1))
    } else {
        format!("e.{}", EVENT_DIMENSIONS.iter().find(|d| d.0 == dimension).map_or("", |d| d.1))
    }
}

const PATH_DIMENSIONS: [&str; 3] = ["page", "entry", "exit"];

/// Text in the form a recorded path holds it, percent-encoded, as part of a path or as a whole one.
fn as_recorded(value: &str, whole: bool) -> String {
    let path = recorded_path(&if whole || value.starts_with('/') { value.to_string() } else { format!("/{value}") });
    match path {
        None => value.to_string(),
        Some(path) if whole || value.starts_with('/') => path,
        Some(path) => crate::js::slice16(&path, 1, i64::MAX),
    }
}

/// A GLOB pattern for text containing `value` in any mix of upper and lower case, letter by letter.
fn any_case(value: &str) -> String {
    let mut out = String::from("*");
    for ch in value.chars() {
        let lower: String = ch.to_lowercase().collect();
        let upper: String = ch.to_uppercase().collect();
        if lower != upper && lower.chars().count() == 1 && upper.chars().count() == 1 {
            out.push('[');
            out.push_str(&lower);
            out.push_str(&upper);
            out.push(']');
        } else if ch == '*' || ch == '?' || ch == '[' {
            out.push('[');
            out.push(ch);
            out.push(']');
        } else {
            out.push(ch);
        }
    }
    out.push('*');
    out
}

/// The text in title case, as the SDK writes it: lower case, with each letter after the start, a
/// space, a dash, a slash, an underscore, or a dot upper case.
fn title_case(value: &str) -> String {
    let lower = value.to_lowercase();
    let mut out = String::with_capacity(lower.len());
    let mut after_gap = true;
    for c in lower.chars() {
        if after_gap && c.is_alphabetic() {
            out.extend(c.to_uppercase());
        } else {
            out.push(c);
        }
        after_gap = crate::js::is_space(c) || matches!(c, '-' | '/' | '_' | '.');
    }
    out
}

/// One filter as a condition on its own column, with "is not" flipped to "is" when `positive` asks.
pub(crate) fn condition(filter: &Filter, dialect: Dialect, positive: bool) -> Frag {
    let col = column(&filter.dimension);
    let op = if positive && filter.op == "not" { "is" } else { filter.op.as_str() };
    // Paths are recorded percent-encoded, as the browser's URL parser writes them, so "/café" is matched as
    // "/caf%C3%A9", just as a goal for it is.
    let path = PATH_DIMENSIONS.contains(&filter.dimension.as_str());
    if op == "is" || op == "not" {
        let value = if path { as_recorded(&filter.value, true) } else { filter.value.clone() };
        return Frag {
            sql: format!("{col} {} ?", if op == "is" { "=" } else { "<>" }),
            params: vec![Param::Text(value)],
        };
    }
    if path {
        // An encoded letter's case is in its bytes (%C3%9C is Ü, %C3%BC is ü), which no database folds, so a
        // path is also tried in lower, upper, and title case, encoded each way.
        let v = &filter.value;
        let mut forms: Vec<String> = Vec::new();
        for f in [v.clone(), v.to_lowercase(), v.to_uppercase(), title_case(v)] {
            let recorded = as_recorded(&f, false);
            if !forms.contains(&recorded) {
                forms.push(recorded);
            }
        }
        let lower = dialect != Dialect::Sqlite;
        let one = if lower { format!("LOWER({col}) LIKE ? ESCAPE '\\'") } else { format!("{col} LIKE ? ESCAPE '\\'") };
        return Frag {
            sql: format!("({})", forms.iter().map(|_| one.clone()).collect::<Vec<_>>().join(" OR ")),
            params: forms
                .iter()
                .map(|f| Param::Text(format!("%{}%", escape_like(&if lower { f.to_lowercase() } else { f.clone() }))))
                .collect(),
        };
    }
    // Postgres and MySQL lower case any letter, so both sides lowered find any mix. Their LIKE then
    // compares exactly: Postgres's always, MySQL's under Runlight's binary collation.
    if dialect != Dialect::Sqlite {
        return Frag {
            sql: format!("LOWER({col}) LIKE ? ESCAPE '\\'"),
            params: vec![Param::Text(format!("%{}%", escape_like(&filter.value.to_lowercase())))],
        };
    }
    // SQLite's LIKE and LOWER ignore case for ASCII letters only, so "über" would never find "Über". GLOB with
    // both cases of every letter finds any mix, Unicode included.
    Frag { sql: format!("{col} GLOB ?"), params: vec![Param::Text(any_case(&filter.value))] }
}

/// The visits a query's filters pick, as conditions on `s`. A filter on the visit (source, country,
/// entry page) applies to it directly. A filter on a page, hostname, or event picks the visits that
/// had a matching row, or for "is not", that never had one. Every number then describes those whole
/// visits, and a visit belongs to the range it started in, as it does with no filter. Rows count up to
/// EVENT_TAIL_MS past the range, for a visit still going when it ends.
pub(crate) fn visit_scope(filters: &[Filter], site: &str, from: i64, to: i64, dialect: Dialect) -> Frag {
    let mut parts = Vec::new();
    let mut params = Vec::new();
    for filter in filters {
        let c = condition(filter, dialect, true);
        if is_session_dimension(&filter.dimension) {
            let own = condition(filter, dialect, false);
            parts.push(own.sql);
            params.extend(own.params);
        } else {
            // An event filter reads events only, which lets it use the index of event names.
            let kinds = if filter.dimension == "event" { "e.kind = 'event'" } else { VISIT_KINDS };
            let rows =
                format!("FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND {kinds} AND {}", c.sql);
            // Postgres plans NOT IN over a list too big for its memory as a scan of the list for every visit,
            // which runs for hours, so it gets NOT EXISTS, an anti join. SQLite reads NOT IN through a
            // temporary index, and runs NOT EXISTS once a visit.
            if filter.op == "not" && dialect == Dialect::Postgres {
                parts.push(format!("NOT EXISTS (SELECT 1 {rows} AND e.session = s.id)"));
            } else {
                parts.push(format!(
                    "s.id {} (SELECT e.session {rows})",
                    if filter.op == "not" { "NOT IN" } else { "IN" }
                ));
            }
            params.push(Param::Text(site.to_string()));
            params.push(Param::Int(from));
            params.push(Param::Int(to + EVENT_TAIL_MS));
            params.extend(c.params);
        }
    }
    Frag { sql: parts.iter().map(|p| format!(" AND {p}")).collect(), params }
}

/// Conditions on `e` from the filters on the given row dimensions that keep rows (is, contains). With
/// "page is /pricing", pageviews mean views of /pricing, as people expect, while the visits are whole.
/// A row counts when it matches any filter on each of its dimensions.
pub(crate) fn row_scope(filters: &[Filter], dimensions: &[&str], dialect: Dialect) -> Frag {
    let mut sql = String::new();
    let mut params = Vec::new();
    for dimension in dimensions {
        let kept: Vec<Frag> = filters
            .iter()
            .filter(|f| f.dimension == *dimension && f.op != "not")
            .map(|f| condition(f, dialect, false))
            .collect();
        if kept.is_empty() {
            continue;
        }
        sql.push_str(&format!(" AND ({})", kept.iter().map(|c| c.sql.clone()).collect::<Vec<_>>().join(" OR ")));
        for c in kept {
            params.extend(c.params);
        }
    }
    Frag { sql, params }
}

/// Pageviews for each visit a filter picks, as a table to LEFT JOIN on `pv.session = s.id`, when a
/// page or hostname filter narrows what counts as a pageview. `None` when every pageview counts.
pub(crate) fn pageviews_of(filters: &[Filter], site: &str, from: i64, to: i64, dialect: Dialect) -> Option<Frag> {
    let rows = row_scope(filters, &["page", "hostname"], dialect);
    if rows.sql.is_empty() {
        return None;
    }
    let mut params = vec![Param::Text(site.to_string()), Param::Int(from), Param::Int(to + EVENT_TAIL_MS)];
    params.extend(rows.params);
    Some(Frag {
        sql: format!(
            "(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'{} GROUP BY e.session)",
            rows.sql
        ),
        params,
    })
}

/// For reports that count rows (goals, event properties, funnels): the rows of the visits a query
/// picks, as a FROM list and conditions over `e` and `s`. Written as a CROSS JOIN so SQLite reads the
/// events through their (site, kind, ts) index and looks each visit up by its id.
pub(crate) struct VisitRows {
    pub from: &'static str,
    pub sql: String,
    pub params: Vec<Param>,
}

pub(crate) fn visit_rows(filters: &[Filter], site: &str, from: i64, to: i64, dialect: Dialect) -> VisitRows {
    let scope = visit_scope(filters, site, from, to, dialect);
    let mut params = vec![
        Param::Text(site.to_string()),
        Param::Int(from),
        Param::Int(to + EVENT_TAIL_MS),
        Param::Text(site.to_string()),
        Param::Int(from),
        Param::Int(to),
    ];
    params.extend(scope.params);
    VisitRows {
        from: "rl_events e CROSS JOIN rl_sessions s",
        sql: format!(
            "e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{}",
            scope.sql
        ),
        params,
    }
}

/// `Math.round(x * 100) / 100`.
pub(crate) fn cents(x: f64) -> f64 {
    crate::js::round(x * 100.0) / 100.0
}
