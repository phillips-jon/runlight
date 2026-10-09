//! Runlight's tables, on any database a `Db` reaches: store.ts's `SqlStore`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::sync::Arc;

use super::db::{Db, DbError, Dialect, Hold, Param, Row};
use super::rows::*;
use super::sql::*;
use crate::js::{self, Object, Value};
use crate::query::{EVENT_DIMENSIONS, Query, SESSION_DIMENSIONS, is_session_dimension};
use crate::re::{js_re, test};
use crate::time::Bucket;
use crate::{obj, params};

type R<T> = Result<T, DbError>;

/// Lets other work run between the pieces of a long job.
async fn pause() {
    tokio::task::yield_now().await;
}

/// Runlight's tables in a database: everything recorded, and every report read from it.
#[derive(Clone)]
pub struct SqlStore {
    db: Arc<dyn Db>,
    ready: Arc<tokio::sync::Mutex<bool>>,
}

/// How to answer a range from rollups: the built days inside it, and the stretches left over.
struct Plan {
    days: Vec<(String, i64, i64)>,
    rest: Vec<(i64, i64)>,
}

/// The rows sums are added into, by value.
#[derive(Clone, Copy, Default)]
struct Sums {
    visitors: f64,
    visits: f64,
    pageviews: f64,
    bounced: f64,
    duration: f64,
    engaged: f64,
    views: f64,
    scroll_sum: f64,
    scroll_n: f64,
    events: f64,
}

impl Sums {
    fn bump(&mut self, row: &Row) {
        self.visitors += row.num("visitors");
        self.visits += row.num("visits");
        self.pageviews += row.num("pageviews");
        self.bounced += row.num("bounced");
        self.duration += row.num("duration");
        self.engaged += row.num("engaged");
        self.views += row.num("views");
        self.scroll_sum += row.num("scroll_sum");
        self.scroll_n += row.num("scroll_n");
        self.events += row.num("events");
    }
}

fn goal_row(r: &Row) -> GoalRow {
    GoalRow {
        id: r.text("id"),
        site: r.text("site"),
        name: r.text("name"),
        kind: r.text("kind"),
        match_: r.text("match"),
        click_by: r.text_or("click_by", ""),
        value_mode: r.text("value_mode"),
        value: if r.is_null("value") { 0.0 } else { r.num("value") },
        value_prop: r.text_or("value_prop", ""),
        currency: r.text_or("currency", "USD"),
        created_at: r.int("created_at"),
    }
}

fn link_row(r: &Row) -> LinkRow {
    LinkRow {
        id: r.text("id"),
        site: r.text("site"),
        domain: r.text_or("domain", ""),
        slug: r.text("slug"),
        name: r.text_or("name", ""),
        url: r.text("url"),
        created_at: r.int("created_at"),
        updated_at: r.int("updated_at"),
    }
}

fn token_row(r: &Row) -> TokenRow {
    TokenRow {
        id: r.text("id"),
        name: r.text("name"),
        site: r.text_or("site", ""),
        scope: if r.text("scope") == "manage" { "manage".into() } else { "read".into() },
        hash: r.text("hash"),
        hint: r.text_or("hint", ""),
        created_at: r.int("created_at"),
        last_used_at: r.opt_int("last_used_at"),
    }
}

fn report_row(r: &Row) -> ReportRow {
    ReportRow {
        id: r.text("id"),
        site: r.text("site"),
        email: r.text("email"),
        frequency: r.text("frequency"),
        lang: r.text_or("lang", "en"),
        token: r.text("token"),
        origin: r.text_or("origin", ""),
        last_period: r.text_or("last_period", ""),
        last_sent_at: r.opt_int("last_sent_at"),
        created_at: r.int("created_at"),
    }
}

fn share_row(r: &Row) -> ShareRow {
    ShareRow { id: r.text("id"), site: r.text("site"), name: r.text_or("name", ""), created_at: r.int("created_at") }
}

/// Funnel steps as stored, read as the SDK reads them.
pub(crate) fn funnel_steps(text: &str) -> Vec<FunnelStep> {
    let Ok(Value::Array(items)) = js::parse(text) else { return Vec::new() };
    items
        .iter()
        .map(|s| FunnelStep { kind: js::str_or_empty(s.get("kind")), match_: js::str_or_empty(s.get("match")) })
        .collect()
}

/// Runs `run` over pieces of a list and joins the answers, in order.
async fn in_pieces<T: Clone, O, F, Fut>(items: &[T], size: usize, mut run: F) -> R<Vec<O>>
where
    F: FnMut(Vec<T>) -> Fut,
    Fut: Future<Output = R<Vec<O>>>,
{
    let mut out = Vec::new();
    for piece in items.chunks(size.max(1)) {
        out.extend(run(piece.to_vec()).await?);
    }
    Ok(out)
}

fn within(rest: &[(i64, i64)]) -> Frag {
    if rest.is_empty() {
        return Frag { sql: "1 = 0".into(), params: vec![] };
    }
    Frag {
        sql: format!(
            "({})",
            rest.iter().map(|_| "(s.started_at >= ? AND s.started_at < ?)").collect::<Vec<_>>().join(" OR ")
        ),
        params: rest.iter().flat_map(|(a, b)| [Param::Int(*a), Param::Int(*b)]).collect(),
    }
}

fn concat(parts: Vec<Vec<Param>>) -> Vec<Param> {
    parts.into_iter().flatten().collect()
}

impl SqlStore {
    /// A store over a database.
    pub fn new(db: Arc<dyn Db>) -> SqlStore {
        SqlStore { db, ready: Arc::new(tokio::sync::Mutex::new(false)) }
    }

    /// The database.
    pub fn db(&self) -> &Arc<dyn Db> {
        &self.db
    }

    fn dialect(&self) -> Dialect {
        self.db.dialect()
    }

    /// A store on another connection (one held for a transaction), sharing nothing else.
    fn on(&self, db: Arc<dyn Db>) -> SqlStore {
        SqlStore { db, ready: self.ready.clone() }
    }

    async fn all(&self, sql: &str, params: Vec<Param>) -> R<Vec<Row>> {
        self.db.all(sql, params).await
    }

    async fn first(&self, sql: &str, params: Vec<Param>) -> R<Option<Row>> {
        Ok(self.db.all(sql, params).await?.into_iter().next())
    }

    async fn run(&self, sql: &str, params: Vec<Param>) -> R<u64> {
        self.db.run(sql, params).await
    }

    /// Creates the tables on first use. Safe to call any number of times.
    pub async fn migrate(&self) -> R<()> {
        let mut ready = self.ready.lock().await;
        if *ready {
            return Ok(());
        }
        let held = self.db.hold(Hold::Exclusive).await?;
        let result = create(&*held).await;
        let finished = held.finish(result.is_ok()).await;
        result?;
        finished?;
        *ready = true;
        Ok(())
    }

    /// Keeps SQLite's planner statistics current, which it never gathers by itself. Postgres gathers
    /// its own.
    pub async fn optimize(&self, only_when_missing: bool) {
        if self.dialect() != Dialect::Sqlite {
            return;
        }
        let run = async {
            if only_when_missing
                && !self.all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'", vec![]).await?.is_empty()
            {
                return Ok::<(), DbError>(());
            }
            self.run("PRAGMA analysis_limit = 1000", vec![]).await?;
            self.run("ANALYZE", vec![]).await?;
            Ok(())
        };
        // Some hosted SQLite services refuse these, and gather statistics themselves.
        let _ = run.await;
    }

    /// Lets the database's connections go.
    pub async fn close(&self) {
        self.db.close().await;
    }

    /// How many rows an UPDATE or DELETE matched.
    async fn changed(&self, sql: &str, params: Vec<Param>) -> R<u64> {
        self.run(sql, params).await
    }

    /// Runs `f` with a store whose every query is in one transaction.
    pub async fn transaction<T, F, Fut>(&self, f: F) -> R<T>
    where
        F: FnOnce(SqlStore) -> Fut,
        Fut: Future<Output = R<T>>,
    {
        let held = self.db.hold(Hold::Transaction).await?;
        let result = f(self.on(held.clone())).await;
        match result {
            Ok(value) => {
                held.finish(true).await?;
                Ok(value)
            }
            Err(error) => {
                let _ = held.finish(false).await;
                Err(error)
            }
        }
    }

    // Sites

    /// Records a site, leaving an unchanged one alone, so starting needs no write.
    pub async fn upsert_site(&self, site: &SiteRow, now: i64) -> R<()> {
        let hostnames = js::stringify(&SiteRow::hostnames_value(&site.hostnames));
        if let Some(row) =
            self.first("SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?", params![&site.id]).await?
            && row.text("name") == site.name
            && row.text("hostnames") == hostnames
            && row.text("timezone") == site.timezone
        {
            return Ok(());
        }
        self.run(
            &upsert(
                self.dialect(),
                "rl_sites",
                &["id", "name", "hostnames", "timezone", "created_at"],
                &["id"],
                &["name", "hostnames", "timezone"],
            ),
            params![&site.id, &site.name, hostnames, &site.timezone, now],
        )
        .await?;
        Ok(())
    }

    /// Settings changed in the dashboard, by site. They win over the ones in code.
    pub async fn site_overrides(&self) -> R<HashMap<String, SiteOverrides>> {
        let mut out = HashMap::new();
        for row in self.all("SELECT id, overrides FROM rl_sites", vec![]).await? {
            let parsed = match js::parse(&row.text("overrides")) {
                Ok(Value::Object(o)) => o,
                _ => Object::new(),
            };
            out.insert(row.text("id"), parsed);
        }
        Ok(out)
    }

    /// Deletes a site and everything recorded for it. Its events and visits go a day at a time first,
    /// so a big site does not hold the database for minutes, and what is left goes in one transaction.
    pub async fn delete_site(&self, id: &str) -> R<()> {
        let piece = if self.db.metered() { 30 * PIECE_MS } else { PIECE_MS };
        for (table, col) in [("rl_events", "ts"), ("rl_sessions", "started_at")] {
            let mut from = self.oldest(table, col, id, None).await?;
            while let Some(f) = from {
                self.run(&format!("DELETE FROM {table} WHERE site = ? AND {col} < ?"), params![id, f + piece]).await?;
                pause().await;
                from = self.oldest(table, col, id, Some(f + piece)).await?;
            }
        }
        let id = id.to_string();
        self.transaction(|store| async move {
            for table in [
                "rl_events",
                "rl_sessions",
                "rl_links",
                "rl_link_domains",
                "rl_shares",
                "rl_goals",
                "rl_funnels",
                "rl_reports",
                "rl_tokens",
                "rl_rollups",
                "rl_rollup_days",
                "rl_sites",
            ] {
                store
                    .run(
                        &format!("DELETE FROM {table} WHERE {} = ?", if table == "rl_sites" { "id" } else { "site" }),
                        params![&id],
                    )
                    .await?;
            }
            Ok(())
        })
        .await
    }

    /// When a site's oldest row at or after `from` is, or `None` when there is none.
    async fn oldest(&self, table: &str, col: &str, site: &str, from: Option<i64>) -> R<Option<i64>> {
        let row = match from {
            None => self.first(&format!("SELECT MIN({col}) AS t FROM {table} WHERE site = ?"), params![site]).await?,
            Some(f) => {
                self.first(
                    &format!("SELECT MIN({col}) AS t FROM {table} WHERE site = ? AND {col} >= ?"),
                    params![site, f],
                )
                .await?
            }
        };
        Ok(row.and_then(|r| r.opt_int("t")))
    }

    /// Deletes a site's visits and events from before a time, for its retention setting.
    pub async fn drop_before(&self, site: &str, ts: i64) -> R<()> {
        // A day at a time from the oldest, each its own short transaction, with a pause between, so a long
        // history goes without holding the database for minutes. Stretches with nothing in them are
        // skipped, so one stray old row does not cost a piece for every day since.
        let piece = if self.db.metered() { 30 * PIECE_MS } else { PIECE_MS };
        let next = |at: Option<i64>| async move {
            let found: Vec<i64> = [
                self.oldest("rl_sessions", "started_at", site, at).await?,
                self.oldest("rl_events", "ts", site, at).await?,
            ]
            .into_iter()
            .flatten()
            .collect();
            Ok::<Option<i64>, DbError>(found.iter().min().map(|m| at.map_or(*m, |a| a.max(*m))))
        };
        let mut from = next(None).await?;
        while let Some(f) = from {
            if f >= ts {
                break;
            }
            let to = (f + piece).min(ts);
            let s = site.to_string();
            self.transaction(|store| async move {
                // A visit's events go with it, even ones after the cutoff, so nothing is left without its visit.
                store
                    .run(
                        "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)",
                        params![&s, f, to + EVENT_TAIL_MS, &s, f, to],
                    )
                    .await?;
                store.run("DELETE FROM rl_events WHERE site = ? AND ts < ?", params![&s, to]).await?;
                store.run("DELETE FROM rl_sessions WHERE site = ? AND started_at < ?", params![&s, to]).await?;
                Ok(())
            })
            .await?;
            pause().await;
            from = next(Some((f + piece).min(ts))).await?;
        }
        // A day that lost any of its visits is built again later, from what is left.
        self.clear_rollups(site, Some(ts), None).await
    }

    /// Deletes a site's events from `from` on whose visit no longer exists, a day at a time.
    pub async fn drop_orphans(&self, site: &str, from: i64, until: i64) -> R<()> {
        let piece = if self.db.metered() { 30 * PIECE_MS } else { PIECE_MS };
        let mut at = self.oldest("rl_events", "ts", site, Some(from)).await?;
        while let Some(a) = at {
            if a >= until {
                break;
            }
            self.run(
                "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
                params![site, a, a + piece],
            )
            .await?;
            pause().await;
            at = self.oldest("rl_events", "ts", site, Some(a + piece)).await?;
        }
        Ok(())
    }

    // Daily rollups

    /// Adds up one local day of a site: totals, each visit dimension, and pages. A visit belongs to the
    /// day it started. Visitor ids change every day, so the days of a range add up to exactly what
    /// counting the range would give.
    pub async fn build_rollup_day(&self, site: &str, day: &str, start: i64, end: i64) -> R<()> {
        // A day with no visits still gets its row of zeros, so it counts as built.
        let sums = format!(
            "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END), 0), COALESCE(SUM({DURATION}), 0)"
        );
        let cols = "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)";
        // Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
        let dialect = self.dialect();
        let head = format!("{}, {}", as_text(dialect, "?"), as_text(dialect, "?"));
        let quarter = div(dialect, "s.started_at", 900_000);
        let mut pieces = vec![format!("SELECT {head}, '', '', {sums} FROM v s")];
        for (dim, col) in SESSION_DIMENSIONS {
            pieces
                .push(format!("SELECT {head}, '{dim}', s.{col}, {sums} FROM v s WHERE s.{col} <> '' GROUP BY s.{col}"));
        }
        pieces.push(format!(
            "SELECT {head}, 'quarter', {}, COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY {}",
            as_text(dialect, &quarter),
            as_text(dialect, &quarter)
        ));
        // Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts) index
        // find them; a visit's last row comes at most EVENT_TAIL_MS after it starts.
        let of_day = |kind: &str| {
            format!(
                "FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.kind = '{kind}' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}"
            )
        };
        let window = params![site, start, end + EVENT_TAIL_MS, start, end];
        let mut first = params![site, start, end];
        for _ in &pieces {
            first.extend(params![site, day]);
        }
        let insert = format!(
            "INSERT INTO rl_rollups {cols}
         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT})
         {}",
            pieces.join(" UNION ALL ")
        );
        let pages = format!(
            "INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)
         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)
         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, {LIVE_VIEWS} AS views
               {} GROUP BY e.path) p
         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest {} GROUP BY e.path, e.pageview) x
               GROUP BY value) t ON t.value = p.value",
            of_day("pageview"),
            of_day("engagement")
        );
        let events = format!(
            "INSERT INTO rl_rollups (site, day, dim, value, visitors, events)
         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) {} GROUP BY e.name",
            of_day("event")
        );
        let (site, day) = (site.to_string(), day.to_string());
        self.transaction(|store| async move {
            store.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", params![&site, &day]).await?;
            // The WITH goes after INSERT INTO, the one place every database takes it.
            store.run(&insert, first).await?;
            // A page's engaged time and scroll come per pageview first (its time added up, its deepest scroll),
            // as the raw report counts them.
            store.run(&pages, concat(vec![params![&site, &day], window.clone(), window.clone()])).await?;
            store.run(&events, concat(vec![params![&site, &day], window])).await?;
            store.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", params![&site, &day]).await?;
            store
                .run(
                    "INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)",
                    params![&site, &day, start, end],
                )
                .await?;
            Ok(())
        })
        .await
    }

    /// The days of a site already built.
    pub async fn rollup_days(&self, site: &str) -> R<HashSet<String>> {
        Ok(self
            .all("SELECT day FROM rl_rollup_days WHERE site = ?", params![site])
            .await?
            .iter()
            .map(|r| r.text("day"))
            .collect())
    }

    /// Forgets built days, all of a site's (`before` and `between` both `None`), those starting before
    /// a time, or those touching a stretch of time, so they are built again.
    pub async fn clear_rollups(&self, site: &str, before: Option<i64>, between: Option<(i64, i64)>) -> R<()> {
        let mut where_ = "site = ?".to_string();
        let mut p = params![site];
        if let Some(b) = before {
            where_.push_str(" AND start_at < ?");
            p.push(Param::Int(b));
        } else if let Some((from, to)) = between {
            where_.push_str(" AND start_at < ? AND end_at > ?");
            p.push(Param::Int(to));
            p.push(Param::Int(from));
        }
        let days: Vec<String> = self
            .all(&format!("SELECT day FROM rl_rollup_days WHERE {where_}"), p.clone())
            .await?
            .iter()
            .map(|r| r.text("day"))
            .collect();
        // The days stop counting as built first, so if this stops part way, no day is left marked built
        // without its rows. Another process may build a day between the two deletes, so its mark goes
        // again after its rows: the day is then simply built once more.
        self.run(&format!("DELETE FROM rl_rollup_days WHERE {where_}"), p).await?;
        for day in days {
            self.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", params![site, &day]).await?;
            self.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", params![site, &day]).await?;
        }
        Ok(())
    }

    /// How to answer a range from rollups: the built days that lie wholly inside it, and the
    /// stretches left over, which are read from the visits as usual. `None` when no built day helps.
    async fn rollup_plan(&self, site: &str, filtered: bool, from: i64, to: i64) -> R<Option<Plan>> {
        if filtered {
            return Ok(None);
        }
        let rows = self
            .all("SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at", params![site, from, to])
            .await?;
        if rows.is_empty() {
            return Ok(None);
        }
        let days: Vec<(String, i64, i64)> =
            rows.iter().map(|r| (r.text("day"), r.int("start_at"), r.int("end_at"))).collect();
        let mut rest = Vec::new();
        let mut at = from;
        for (_, start, end) in &days {
            if *start > at {
                rest.push((at, *start));
            }
            at = at.max(*end);
        }
        if at < to {
            rest.push((at, to));
        }
        Ok(Some(Plan { days, rest }))
    }

    /// A breakdown of a visit dimension or of pages from rollups and the visits left over, merged,
    /// then sorted and cut to the page asked for.
    async fn rolled_breakdown(&self, query: &Query, dimension: &str, limit: i64, offset: i64) -> R<Option<Vec<Value>>> {
        let page = dimension == "page";
        let event = dimension == "event";
        if !page && !event && !is_session_dimension(dimension) {
            return Ok(None);
        }
        if !query.filters.is_empty() {
            return Ok(None);
        }
        // Pages and events always go this way without filters, so a range gives the same answer whether its days are built or not.
        let plan = match self.rollup_plan(&query.site, false, query.from, query.to).await? {
            Some(p) => p,
            None if page || event => Plan { days: vec![], rest: vec![(query.from, query.to)] },
            None => return Ok(None),
        };
        let mut sums: BTreeMap<String, Sums> = BTreeMap::new();
        let mut order: Vec<String> = Vec::new();
        let mut bump = |row: &Row| {
            let key = row.text("value");
            if !sums.contains_key(&key) {
                order.push(key.clone());
            }
            sums.entry(key).or_default().bump(row);
        };
        if !plan.days.is_empty() {
            let rolled = self
                .all(
                    &format!(
                        "SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,
           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events
         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN ({BUILT_DAYS}) GROUP BY value"
                    ),
                    params![&query.site, dimension, &query.site, query.from, query.to],
                )
                .await?;
            for row in &rolled {
                bump(row);
            }
        }
        let w = within(&plan.rest);
        if (page || event) && !plan.rest.is_empty() {
            // A visit's pageviews and events belong to the day it started, as in the rollups.
            let lo = plan.rest.iter().map(|r| r.0).min().unwrap_or(0);
            let hi = plan.rest.iter().map(|r| r.1).max().unwrap_or(0) + EVENT_TAIL_MS;
            let of_rest = |kind: &str| {
                format!(
                    "FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '{kind}' AND e.ts >= ? AND e.ts < ? AND {IS_VISIT} AND {}",
                    w.sql
                )
            };
            let at = concat(vec![params![&query.site, lo, hi], w.params.clone()]);
            if page {
                for row in self
                    .all(
                        &format!(
                            "SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, {LIVE_VIEWS} AS views {} GROUP BY e.path",
                            of_rest("pageview")
                        ),
                        at.clone(),
                    )
                    .await?
                {
                    bump(&row);
                }
                for row in self
                    .all(
                        &format!(
                            "SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest {} GROUP BY e.path, e.pageview) t GROUP BY value",
                            of_rest("engagement")
                        ),
                        at,
                    )
                    .await?
                {
                    bump(&row);
                }
            } else {
                for row in self
                    .all(
                        &format!(
                            "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events {} GROUP BY e.name",
                            of_rest("event")
                        ),
                        at,
                    )
                    .await?
                {
                    bump(&row);
                }
            }
        } else if page || event {
            // Every day of the range is built.
        } else {
            let col = format!("s.{}", SESSION_DIMENSIONS.iter().find(|d| d.0 == dimension).map_or("", |d| d.1));
            for row in self
                .all(
                    &format!(
                        "SELECT {col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
           SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
         FROM rl_sessions s WHERE s.site = ? AND {IS_VISIT} AND {} AND {col} <> '' GROUP BY {col}",
                        w.sql
                    ),
                    concat(vec![params![&query.site], w.params.clone()]),
                )
                .await?
            {
                bump(&row);
            }
        }
        let entry_exit = dimension == "entry" || dimension == "exit";
        let mut rows: Vec<(String, Sums)> = order
            .into_iter()
            .map(|k| {
                let s = sums[&k];
                (k, s)
            })
            .filter(|(value, x)| {
                (event || !value.is_empty())
                    && if page {
                        x.pageviews > 0.0
                    } else if event {
                        x.events > 0.0
                    } else {
                        x.visits > 0.0
                    }
            })
            .collect();
        let desc = |a: f64, b: f64| b.partial_cmp(&a).unwrap_or(std::cmp::Ordering::Equal);
        rows.sort_by(|(a, x), (b, y)| {
            if entry_exit {
                desc(x.visits, y.visits).then_with(|| code_order(a, b))
            } else if event {
                desc(x.visitors, y.visitors).then(desc(x.events, y.events)).then_with(|| code_order(a, b))
            } else if page {
                desc(x.visitors, y.visitors).then(desc(x.pageviews, y.pageviews)).then_with(|| code_order(a, b))
            } else {
                desc(x.visitors, y.visitors).then(desc(x.visits, y.visits)).then_with(|| code_order(a, b))
            }
        });
        let start = offset.max(0) as usize;
        let end = (offset + limit).max(0) as usize;
        Ok(Some(
            rows.into_iter()
                .skip(start)
                .take(end.saturating_sub(start))
                .map(|(value, x)| {
                    if event {
                        return obj! { "value" => value, "visitors" => x.visitors, "events" => x.events };
                    }
                    if page {
                        return obj! {
                            "value" => value,
                            "visitors" => x.visitors,
                            "pageviews" => x.pageviews,
                            // Over every pageview that could report its time, counting those that sent none (under a second) as none.
                            "timeOnPage" => if x.views > 0.0 { js::round(x.engaged / x.views) } else { 0.0 },
                            "scrollDepth" => if x.scroll_n > 0.0 { js::round(x.scroll_sum / x.scroll_n) } else { 0.0 },
                        };
                    }
                    let mut out = obj! {
                        "value" => value,
                        "visitors" => x.visitors,
                        "visits" => x.visits,
                        "bounceRate" => if x.visits > 0.0 { x.bounced / x.visits } else { 0.0 },
                    };
                    if !entry_exit {
                        let o = out.as_object_mut().expect("an object");
                        o.set("pageviews", x.pageviews);
                        o.set("visitDuration", if x.visits > 0.0 { js::round(x.duration / x.visits) } else { 0.0 });
                    }
                    out
                })
                .collect(),
        ))
    }

    async fn rolled_stats(&self, query: &Query) -> R<Option<Stats>> {
        let Some(plan) = self.rollup_plan(&query.site, !query.filters.is_empty(), query.from, query.to).await? else {
            return Ok(None);
        };
        let rolled = self
            .first(
                &format!(
                    "SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration
       FROM rl_rollups WHERE site = ? AND dim = '' AND day IN ({BUILT_DAYS})"
                ),
                params![&query.site, &query.site, query.from, query.to],
            )
            .await?
            .unwrap_or_default();
        let w = within(&plan.rest);
        let raw = self
            .first(
                &format!(
                    "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
         SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
       FROM rl_sessions s WHERE s.site = ? AND {IS_VISIT} AND {}",
                    w.sql
                ),
                concat(vec![params![&query.site], w.params]),
            )
            .await?
            .unwrap_or_default();
        let add = |k: &str| rolled.num(k) + raw.num(k);
        let visits = add("visits");
        let pageviews = add("pageviews");
        Ok(Some(Stats {
            visitors: add("visitors"),
            visits,
            pageviews,
            views_per_visit: if visits > 0.0 { cents(pageviews / visits) } else { 0.0 },
            bounce_rate: if visits > 0.0 { add("bounced") / visits } else { 0.0 },
            visit_duration: if visits > 0.0 { js::round(add("duration") / visits) } else { 0.0 },
        }))
    }

    /// Saves the settings changed in the dashboard for a site.
    pub async fn set_site_overrides(&self, id: &str, overrides: &SiteOverrides) -> R<()> {
        self.run("UPDATE rl_sites SET overrides = ? WHERE id = ?", params![overrides.to_json(), id]).await?;
        Ok(())
    }

    /// When the site last recorded a visit, or `None` if it never has.
    pub async fn last_seen(&self, site: &str) -> R<Option<i64>> {
        let row = self
            .first("SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')", params![site])
            .await?;
        Ok(row.and_then(|r| r.opt_int("t")))
    }

    /// Every site, by name.
    pub async fn sites(&self) -> R<Vec<SiteRow>> {
        Ok(self
            .all("SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id", vec![])
            .await?
            .iter()
            .map(|row| SiteRow {
                id: row.text("id"),
                name: row.text("name"),
                hostnames: match js::parse(&row.text("hostnames")) {
                    Ok(Value::Array(a)) => a.iter().map(js::js_string).collect(),
                    _ => Vec::new(),
                },
                timezone: row.text("timezone"),
            })
            .collect())
    }

    // Salts

    /// The salt for a day, made on first ask. Two racing callers agree on one.
    pub async fn salt(&self, day: &str, fresh: &str) -> R<String> {
        self.run(&upsert(self.dialect(), "rl_salts", &["day", "salt"], &["day"], &[]), params![day, fresh]).await?;
        Ok(self
            .first("SELECT salt FROM rl_salts WHERE day = ?", params![day])
            .await?
            .map_or_else(|| fresh.to_string(), |r| r.text("salt")))
    }

    /// The salt for a day, if there is one.
    pub async fn salt_if_exists(&self, day: &str) -> R<Option<String>> {
        Ok(self.first("SELECT salt FROM rl_salts WHERE day = ?", params![day]).await?.map(|r| r.text("salt")))
    }

    /// Deletes every salt older than `day`, so old hashes can never be recomputed.
    pub async fn drop_salts_before(&self, day: &str) -> R<()> {
        self.run("DELETE FROM rl_salts WHERE day < ?", params![day]).await?;
        Ok(())
    }

    // Ingest

    /// The visitor's open session: any of their hashes, active since `since`.
    pub async fn open_session(&self, site: &str, visitors: &[String], since: i64) -> R<Option<(String, String)>> {
        if visitors.is_empty() {
            return Ok(None);
        }
        let mut p = params![site];
        p.extend(visitors.iter().map(Param::from));
        p.push(Param::Int(since));
        let row = self
            .first(
                &format!(
                    "SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN ({}) AND last_at >= ?
       ORDER BY last_at DESC, id LIMIT 1",
                    visitors.iter().map(|_| "?").collect::<Vec<_>>().join(", ")
                ),
                p,
            )
            .await?;
        Ok(row.map(|r| (r.text("id"), r.text("visitor"))))
    }

    /// Records a new visit.
    pub async fn insert_session(&self, row: &SessionRow) -> R<()> {
        self.run(
            "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
        browser, browser_version, os, os_version, device, screen, language)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                &row.id,
                &row.site,
                &row.visitor,
                row.started_at,
                row.started_at,
                &row.hostname,
                &row.referrer_host,
                &row.referrer_path,
                &row.source,
                &row.channel,
                &row.utm_source,
                &row.utm_medium,
                &row.utm_campaign,
                &row.utm_term,
                &row.utm_content,
                &row.country,
                &row.region,
                &row.city,
                &row.browser,
                &row.browser_version,
                &row.os,
                &row.os_version,
                &row.device,
                &row.screen,
                &row.language,
            ],
        )
        .await?;
        Ok(())
    }

    /// Counts a row into its session. An event with `reopen` false, one that joins a visit already
    /// ended, counts without moving the session's last activity.
    pub async fn touch_session(&self, id: &str, ts: i64, kind: &str, path: &str, reopen: bool) -> R<()> {
        if kind == "click" {
            self.run("UPDATE rl_sessions SET last_at = ? WHERE id = ?", params![ts, id]).await?;
        } else if kind == "pageview" {
            self.run(
                "UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?",
                params![ts, path, path, id],
            )
            .await?;
        } else if reopen {
            self.run("UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?", params![ts, id]).await?;
        } else {
            self.run("UPDATE rl_sessions SET events = events + 1 WHERE id = ?", params![id]).await?;
        }
        Ok(())
    }

    /// Adds engaged time to a visit.
    pub async fn add_engagement(&self, id: &str, ms: i64) -> R<()> {
        self.run("UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?", params![ms, id])
            .await?;
        Ok(())
    }

    /// The pageview an engagement ping or event belongs to, with when its visit started and was last active.
    pub async fn pageview(&self, site: &str, pageview: &str) -> R<Option<PageviewInfo>> {
        let row = self
            .first(
                "SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1",
                params![site, pageview],
            )
            .await?;
        Ok(row.map(|r| PageviewInfo {
            session: r.text("session"),
            visitor: r.text("visitor"),
            path: r.text("path"),
            hostname: r.text("hostname"),
            ts: r.int("ts"),
            started_at: r.int("started_at"),
            last_at: r.int("last_at"),
        }))
    }

    /// After a late event or engagement ping joins an old visit, the day that visit started may
    /// already be added up. Forget that day so the next check builds it again.
    pub async fn touched_old_visit(&self, site: &str, started: i64, before: i64) -> R<()> {
        if started < before {
            self.clear_rollups(site, None, Some((started, started + 1))).await?;
        }
        Ok(())
    }

    /// Records a row.
    pub async fn insert_event(&self, row: &EventRow) -> R<()> {
        self.run(
            "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                &row.site,
                row.ts,
                &row.kind,
                &row.visitor,
                &row.session,
                &row.pageview,
                &row.path,
                &row.hostname,
                &row.title,
                &row.name,
                row.props.as_ref().map(Object::to_json),
                row.engaged_ms,
                row.scroll,
                &row.link,
            ],
        )
        .await?;
        Ok(())
    }

    // Links

    /// The live link with a slug. Slugs are unique across every domain.
    pub async fn link_by_slug(&self, slug: &str) -> R<Option<LinkRow>> {
        Ok(self
            .first("SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1", params![slug])
            .await?
            .map(|r| link_row(&r)))
    }

    /// The live link with an id.
    pub async fn link_by_id(&self, id: &str) -> R<Option<LinkRow>> {
        Ok(self
            .first("SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1", params![id])
            .await?
            .map(|r| link_row(&r)))
    }

    /// Records a link.
    pub async fn insert_link(&self, link: &LinkRow) -> R<()> {
        self.run(
            "INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![&link.id, &link.site, &link.domain, &link.slug, &link.name, &link.url, link.created_at, link.updated_at],
        )
        .await?;
        Ok(())
    }

    /// Saves a link's changes.
    pub async fn update_link(&self, link: &LinkRow) -> R<()> {
        self.run(
            "UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?",
            params![&link.domain, &link.slug, &link.name, &link.url, link.updated_at, &link.id],
        )
        .await?;
        Ok(())
    }

    /// Hides a link and frees its slug; its clicks stay in the history.
    pub async fn delete_link(&self, id: &str, now: i64) -> R<()> {
        self.run("UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", params![now, id]).await?;
        Ok(())
    }

    // Shares

    /// A site's share links, newest first.
    pub async fn shares(&self, site: &str) -> R<Vec<ShareRow>> {
        Ok(self
            .all(
                "SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id",
                params![site],
            )
            .await?
            .iter()
            .map(share_row)
            .collect())
    }

    /// A share link by its id.
    pub async fn share_by_id(&self, id: &str) -> R<Option<ShareRow>> {
        Ok(self
            .first("SELECT id, site, name, created_at FROM rl_shares WHERE id = ?", params![id])
            .await?
            .map(|r| share_row(&r)))
    }

    /// Records a share link.
    pub async fn insert_share(&self, share: &ShareRow) -> R<()> {
        self.run(
            "INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)",
            params![&share.id, &share.site, &share.name, share.created_at],
        )
        .await?;
        Ok(())
    }

    /// Renames a share link.
    pub async fn rename_share(&self, id: &str, name: &str) -> R<()> {
        self.run("UPDATE rl_shares SET name = ? WHERE id = ?", params![name, id]).await?;
        Ok(())
    }

    /// Deleting a share is how it is revoked: the link stops working at once.
    pub async fn delete_share(&self, id: &str) -> R<()> {
        self.run("DELETE FROM rl_shares WHERE id = ?", params![id]).await?;
        Ok(())
    }

    // Funnels

    /// A site's funnels, oldest first.
    pub async fn funnels(&self, site: &str) -> R<Vec<FunnelRow>> {
        Ok(self
            .all("SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id", params![site])
            .await?
            .iter()
            .map(|r| FunnelRow {
                id: r.text("id"),
                site: r.text("site"),
                name: r.text("name"),
                steps: funnel_steps(&r.text("steps")),
                created_at: r.int("created_at"),
            })
            .collect())
    }

    /// Records or changes a funnel.
    pub async fn save_funnel(&self, f: &FunnelRow) -> R<()> {
        self.run(
            &upsert(
                self.dialect(),
                "rl_funnels",
                &["id", "site", "name", "steps", "created_at"],
                &["id"],
                &["name", "steps"],
            ),
            params![&f.id, &f.site, &f.name, f.steps_value().to_json(), f.created_at],
        )
        .await?;
        Ok(())
    }

    /// Deletes a funnel.
    pub async fn delete_funnel(&self, id: &str) -> R<()> {
        self.run("DELETE FROM rl_funnels WHERE id = ?", params![id]).await?;
        Ok(())
    }

    /// How many visits reached each step, in order, within the same visit. Step one is the first
    /// matching row in the range; each later step must come after the step before it.
    pub async fn funnel_counts(&self, query: &Query, funnel: &FunnelRow) -> R<Vec<f64>> {
        let v = visit_rows(&query.filters, &query.site, query.from, query.to, self.dialect());
        let scopes: Vec<Frag> =
            funnel.steps.iter().map(|step| self.goal_scope(&step.kind, &step.match_, &step.match_)).collect();
        let sql = format!(
            "SELECT e.session AS session, {}
       FROM {} WHERE {} AND ({})
       ORDER BY e.session, e.ts, e.id",
            scopes
                .iter()
                .enumerate()
                .map(|(i, s)| format!("CASE WHEN {} THEN 1 ELSE 0 END AS m{i}", s.sql))
                .collect::<Vec<_>>()
                .join(", "),
            v.from,
            v.sql,
            scopes.iter().map(|s| format!("({})", s.sql)).collect::<Vec<_>>().join(" OR ")
        );
        let mut p: Vec<Param> = scopes.iter().flat_map(|s| s.params.clone()).collect();
        p.extend(v.params);
        p.extend(scopes.iter().flat_map(|s| s.params.clone()));
        let rows = self.all(&sql, p).await?;
        let mut counts = vec![0.0; funnel.steps.len()];
        let mut session: Option<String> = None;
        let mut reached = 0;
        for row in &rows {
            let id = row.text("session");
            if session.as_deref() != Some(&id) {
                for c in counts.iter_mut().take(reached) {
                    *c += 1.0;
                }
                session = Some(id);
                reached = 0;
            }
            // Each step is the first matching row after the step before, so two steps in the same millisecond
            // both count, and one row never counts as two steps.
            if reached < counts.len() && row.num(&format!("m{reached}")) == 1.0 {
                reached += 1;
            }
        }
        for c in counts.iter_mut().take(reached) {
            *c += 1.0;
        }
        Ok(counts)
    }

    /// Each visit's pageviews in order, at most `per_visit` of them, for journeys. A window function
    /// keeps the first ones of each visit, so a long visit cannot crowd the rest out.
    pub async fn journey_pages(&self, query: &Query, per_visit: i64) -> R<(Vec<(String, String)>, bool)> {
        let scope = visit_scope(&query.filters, &query.site, query.from, query.to, self.dialect());
        // The newest visits the filters pick, JOURNEY_VISITS at most, so a long range stays quick and small in memory.
        let newest = |columns: &str, limit: i64| {
            format!(
                "SELECT {columns} FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{}
         ORDER BY s.started_at DESC, s.id LIMIT {limit}",
                scope.sql
            )
        };
        let visit_params = concat(vec![params![&query.site, query.from, query.to], scope.params.clone()]);
        let first = self
            .first(
                &format!(
                    "SELECT COUNT(*) AS n, MIN(started_at) AS t FROM ({}) x",
                    newest("s.started_at AS started_at", JOURNEY_VISITS + 1)
                ),
                visit_params.clone(),
            )
            .await?
            .unwrap_or_default();
        if first.num("n") == 0.0 {
            return Ok((vec![], false));
        }
        let from = query.from.max(first.int("t"));
        // MySQL takes no LIMIT in an IN list, but does in a table inside one.
        let visits = if self.dialect() == Dialect::Mysql {
            format!("SELECT id FROM ({}) x", newest("s.id AS id", JOURNEY_VISITS))
        } else {
            newest("s.id", JOURNEY_VISITS)
        };
        let rows = self
            .all(
                // The visits are read as an IN list, which every database probes from the events side. Refreshes
                // (the same page twice in a row) are dropped before counting, so they never use up the steps.
                &format!(
                    "WITH raw AS (
         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,
           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev
         FROM rl_events e
         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN ({visits})),
       v AS (
         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n
         FROM raw WHERE prev IS NULL OR prev <> path)
       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n"
                ),
                concat(vec![params![&query.site, from, query.to + EVENT_TAIL_MS], visit_params, params![per_visit]]),
            )
            .await?;
        Ok((rows.iter().map(|r| (r.text("session"), r.text("path"))).collect(), first.num("n") > JOURNEY_VISITS as f64))
    }

    // API tokens

    /// Every API token, newest first.
    pub async fn tokens(&self) -> R<Vec<TokenRow>> {
        Ok(self
            .all("SELECT * FROM rl_tokens ORDER BY created_at DESC, id", vec![])
            .await?
            .iter()
            .map(token_row)
            .collect())
    }

    /// The token with this hash.
    pub async fn token_by_hash(&self, hash: &str) -> R<Option<TokenRow>> {
        Ok(self.first("SELECT * FROM rl_tokens WHERE hash = ?", params![hash]).await?.map(|r| token_row(&r)))
    }

    /// Records a token.
    pub async fn insert_token(&self, t: &TokenRow) -> R<()> {
        self.run(
            "INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![&t.id, &t.name, &t.site, &t.scope, &t.hash, &t.hint, t.created_at, t.last_used_at],
        )
        .await?;
        Ok(())
    }

    /// Notes when a token was last used.
    pub async fn touch_token(&self, id: &str, now: i64) -> R<()> {
        self.run("UPDATE rl_tokens SET last_used_at = ? WHERE id = ?", params![now, id]).await?;
        Ok(())
    }

    /// Deleting a token is how it is revoked: it stops working at once.
    pub async fn delete_token(&self, id: &str) -> R<bool> {
        Ok(self.changed("DELETE FROM rl_tokens WHERE id = ?", params![id]).await? == 1)
    }

    // Settings

    /// A setting.
    pub async fn setting(&self, key: &str) -> R<Option<String>> {
        Ok(self.first("SELECT value FROM rl_settings WHERE \"key\" = ?", params![key]).await?.map(|r| r.text("value")))
    }

    /// Every setting whose key starts with a prefix, such as each connected install's.
    pub async fn settings_starting_with(&self, prefix: &str) -> R<Vec<(String, String)>> {
        Ok(self
            .all(
                "SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE ? ESCAPE '\\'",
                params![format!("{}%", escape_like(prefix))],
            )
            .await?
            .iter()
            .map(|r| (r.text("key"), r.text("value")))
            .collect())
    }

    /// Saves a setting, or deletes it with `None`.
    pub async fn set_setting(&self, key: &str, value: Option<&str>) -> R<()> {
        match value {
            None => self.run("DELETE FROM rl_settings WHERE \"key\" = ?", params![key]).await?,
            Some(v) => {
                self.run(
                    &upsert(self.dialect(), "rl_settings", &["\"key\"", "value"], &["\"key\""], &["value"]),
                    params![key, v],
                )
                .await?
            }
        };
        Ok(())
    }

    // Email reports

    /// Email reports, a site's or all.
    pub async fn reports(&self, site: Option<&str>) -> R<Vec<ReportRow>> {
        let rows = match site {
            Some(s) if !s.is_empty() => {
                self.all("SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id", params![s]).await?
            }
            _ => self.all("SELECT * FROM rl_reports ORDER BY created_at, id", vec![]).await?,
        };
        Ok(rows.iter().map(report_row).collect())
    }

    /// A report by its id, or by its unsubscribe token.
    pub async fn report_by(&self, by_token: bool, value: &str) -> R<Option<ReportRow>> {
        let sql =
            if by_token { "SELECT * FROM rl_reports WHERE token = ?" } else { "SELECT * FROM rl_reports WHERE id = ?" };
        Ok(self.first(sql, params![value]).await?.map(|r| report_row(&r)))
    }

    /// Records a report.
    pub async fn insert_report(&self, r: &ReportRow) -> R<()> {
        self.run(
            "INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![&r.id, &r.site, &r.email, &r.frequency, &r.lang, &r.token, &r.origin, &r.last_period, r.last_sent_at, r.created_at],
        )
        .await?;
        Ok(())
    }

    /// Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it.
    pub async fn claim_report(&self, id: &str, period: &str, now: i64) -> R<bool> {
        Ok(self
            .changed(
                "UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?",
                params![period, now, id, period],
            )
            .await?
            == 1)
    }

    /// Puts a period back when its email failed, so the next run tries again.
    pub async fn release_report(&self, id: &str, period: &str, previous: &str) -> R<()> {
        self.run(
            "UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?",
            params![previous, id, period],
        )
        .await?;
        Ok(())
    }

    /// Deletes a report.
    pub async fn delete_report(&self, id: &str) -> R<()> {
        self.run("DELETE FROM rl_reports WHERE id = ?", params![id]).await?;
        Ok(())
    }

    // Goals

    /// Goals, a site's or all, oldest first.
    pub async fn goals(&self, site: Option<&str>) -> R<Vec<GoalRow>> {
        let rows = match site {
            Some(s) if !s.is_empty() => {
                self.all("SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id", params![s]).await?
            }
            _ => self.all("SELECT * FROM rl_goals ORDER BY created_at, id", vec![]).await?,
        };
        Ok(rows.iter().map(goal_row).collect())
    }

    /// A goal by its id.
    pub async fn goal_by_id(&self, id: &str) -> R<Option<GoalRow>> {
        Ok(self.first("SELECT * FROM rl_goals WHERE id = ?", params![id]).await?.map(|r| goal_row(&r)))
    }

    /// Records or changes a goal.
    pub async fn save_goal(&self, g: &GoalRow, before: Option<&GoalRow>) -> R<()> {
        // A click goal is counted by its name, which the tracker sends as the event
        // name. Renaming one renames its past clicks too, so its history stays.
        if let Some(b) = before
            && b.kind == "click"
            && g.kind == "click"
            && b.name != g.name
        {
            self.run(
                "UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?",
                params![&g.name, &g.site, &b.name],
            )
            .await?;
        }
        self.run(
            &upsert(
                self.dialect(),
                "rl_goals",
                &[
                    "id",
                    "site",
                    "name",
                    "kind",
                    "\"match\"",
                    "click_by",
                    "value_mode",
                    "value",
                    "value_prop",
                    "currency",
                    "created_at",
                ],
                &["id"],
                &["name", "kind", "\"match\"", "click_by", "value_mode", "value", "value_prop", "currency"],
            ),
            params![
                &g.id,
                &g.site,
                &g.name,
                &g.kind,
                &g.match_,
                &g.click_by,
                &g.value_mode,
                g.value,
                &g.value_prop,
                &g.currency,
                g.created_at
            ],
        )
        .await?;
        Ok(())
    }

    /// Deletes a goal.
    pub async fn delete_goal(&self, id: &str) -> R<()> {
        self.run("DELETE FROM rl_goals WHERE id = ?", params![id]).await?;
        Ok(())
    }

    /// The events a goal counts, as a WHERE fragment over rl_events e.
    fn goal_scope(&self, kind: &str, match_: &str, name: &str) -> Frag {
        if kind == "page" {
            if match_.contains('*') {
                return if self.dialect() != Dialect::Sqlite {
                    // Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
                    Frag {
                        sql: "e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'".into(),
                        params: params![like_pattern(match_)],
                    }
                } else {
                    // SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact matches.
                    Frag { sql: "e.kind = 'pageview' AND e.path GLOB ?".into(), params: params![glob_pattern(match_)] }
                };
            }
            return Frag { sql: "e.kind = 'pageview' AND e.path = ?".into(), params: params![match_] };
        }
        // Event goals count the named event; click goals count the event the tracker sends for them.
        Frag {
            sql: "e.kind = 'event' AND e.name = ?".into(),
            params: params![if kind == "click" { name } else { match_ }],
        }
    }

    fn scope_of(&self, goal: &GoalRow) -> Frag {
        self.goal_scope(&goal.kind, &goal.match_, &goal.name)
    }

    /// A numeric event property for one row, as SQL (0 when it is not a number).
    fn prop_value(&self, prop: &str) -> Frag {
        match self.dialect() {
            Dialect::Postgres => Frag {
                sql: "(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)".into(),
                params: params![prop, prop],
            },
            Dialect::Mysql => {
                let path = format!("$.\"{prop}\"");
                // As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal point.
                let value = "JSON_EXTRACT(e.props, ?)";
                Frag {
                    sql: format!(
                        "(CASE
          WHEN JSON_TYPE({value}) IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST({value} AS DOUBLE)
          WHEN JSON_TYPE({value}) = 'STRING' AND JSON_UNQUOTE({value}) REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE({value}) AS DOUBLE)
          ELSE 0 END)"
                    ),
                    params: vec![Param::Text(path); 5],
                }
            }
            Dialect::Sqlite => {
                let path = format!("$.\"{prop}\"");
                // As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
                let text = "CAST(json_extract(e.props, ?) AS TEXT)";
                Frag {
                    sql: format!(
                        "(CASE
        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
        WHEN json_type(e.props, ?) = 'text' AND {text} GLOB '[0-9]*' AND {text} NOT GLOB '*[^0-9.]*' AND {text} NOT GLOB '*.*.*' AND {text} NOT GLOB '*.' THEN CAST({text} AS REAL)
        WHEN json_type(e.props, ?) = 'text' AND {text} GLOB '-[0-9]*' AND substr({text}, 2) NOT GLOB '*[^0-9.]*' AND {text} NOT GLOB '*.*.*' AND {text} NOT GLOB '*.' THEN CAST({text} AS REAL)
        ELSE 0 END)"
                    ),
                    params: vec![Param::Text(path); 14],
                }
            }
        }
    }

    /// The property names sent with an event in a query's range, most used first.
    pub async fn event_prop_keys(&self, query: &Query, event: &str) -> R<Vec<(String, f64)>> {
        let v = visit_rows(&query.filters, &query.site, query.from, query.to, self.dialect());
        let where_ = format!("{} AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL", v.sql);
        let mut p = v.params;
        p.push(Param::from(event));
        let sql = match self.dialect() {
            // Each key as a row of its own, compared and sorted by code point like every other value.
            Dialect::Mysql => format!(
                "SELECT j.k AS \"key\", COUNT(*) AS events FROM {}
             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{{}}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE {MYSQL_COLLATION} PATH '$')) j
             WHERE {where_} GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30",
                v.from
            ),
            Dialect::Postgres => format!(
                "SELECT k AS \"key\", COUNT(*) AS events FROM {} CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{{}}'::jsonb END) AS k
             WHERE {where_} GROUP BY k ORDER BY events DESC, k{} LIMIT 30",
                v.from,
                self.text_order()
            ),
            Dialect::Sqlite => format!(
                "SELECT j.key AS \"key\", COUNT(*) AS events FROM {}, json_each(e.props) j
             WHERE {where_} AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key{} LIMIT 30",
                v.from,
                self.text_order()
            ),
        };
        Ok(self.all(&sql, p).await?.iter().map(|r| (r.text("key"), r.num("events"))).collect())
    }

    /// The values one property of an event took, with how often and by how many visitors.
    pub async fn event_prop_values(
        &self,
        query: &Query,
        event: &str,
        key: &str,
        limit: i64,
    ) -> R<Vec<(String, f64, f64)>> {
        let v = visit_rows(&query.filters, &query.site, query.from, query.to, self.dialect());
        let value = match self.dialect() {
            Dialect::Postgres => "(e.props::jsonb ->> ?)".to_string(),
            Dialect::Mysql => format!("(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE {MYSQL_COLLATION})"),
            Dialect::Sqlite => "CAST(json_extract(e.props, ?) AS TEXT)".to_string(),
        };
        let path = if self.dialect() == Dialect::Postgres { key.to_string() } else { format!("$.\"{key}\"") };
        let sql = format!(
            "SELECT * FROM (SELECT {value} AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM {}
         WHERE {} AND e.kind = 'event' AND e.name = ? AND {value} IS NOT NULL GROUP BY 1) t
       ORDER BY events DESC, value{} LIMIT ?",
            v.from,
            v.sql,
            self.text_order()
        );
        let p = concat(vec![params![&path], v.params, params![event, &path, limit]]);
        Ok(self.all(&sql, p).await?.iter().map(|r| (r.text("value"), r.num("events"), r.num("visitors"))).collect())
    }

    /// The floating point type to cast to, which MySQL names in one word.
    fn double(&self) -> &'static str {
        if self.dialect() == Dialect::Mysql { "DOUBLE" } else { "DOUBLE PRECISION" }
    }

    /// A goal's worth for one converting row, as SQL.
    fn revenue_value(&self, goal: &GoalRow) -> Frag {
        if goal.value_mode == "prop" && !goal.value_prop.is_empty() {
            return self.prop_value(&goal.value_prop);
        }
        if goal.value_mode == "fixed" {
            return Frag { sql: format!("CAST(? AS {})", self.double()), params: params![goal.value] };
        }
        Frag { sql: "0".into(), params: vec![] }
    }

    /// Every goal's totals in one pass over the range's events, instead of a query per goal.
    pub async fn goal_totals_all(&self, query: &Query, goals: &[GoalRow]) -> R<HashMap<String, GoalTotals>> {
        let mut out = HashMap::new();
        let v = visit_rows(&query.filters, &query.site, query.from, query.to, self.dialect());
        // As many goals per query as keep it under D1's parameter limit.
        let mut chunks: Vec<Vec<&GoalRow>> = vec![vec![]];
        let mut count = v.params.len();
        for goal in goals {
            let cost = self.scope_of(goal).params.len() * 4 + self.revenue_value(goal).params.len();
            if !chunks.last().expect("a chunk").is_empty() && count + cost > MAX_PARAMS {
                chunks.push(vec![]);
                count = v.params.len();
            }
            chunks.last_mut().expect("a chunk").push(goal);
            count += cost;
        }
        for chunk in chunks {
            if chunk.is_empty() {
                continue;
            }
            let mut columns = Vec::new();
            let mut p = Vec::new();
            // Only rows some goal of the chunk counts are read.
            let mut any = Vec::new();
            let mut any_params = Vec::new();
            for (i, goal) in chunk.iter().enumerate() {
                let scope = self.scope_of(goal);
                let value = self.revenue_value(goal);
                columns.push(format!("SUM(CASE WHEN {} THEN 1 ELSE 0 END) AS c{i}", scope.sql));
                columns.push(format!("COUNT(DISTINCT CASE WHEN {} THEN e.visitor END) AS v{i}", scope.sql));
                columns.push(format!("SUM(CASE WHEN {} THEN {} ELSE 0 END) AS r{i}", scope.sql, value.sql));
                for _ in 0..3 {
                    p.extend(scope.params.clone());
                }
                p.extend(value.params);
                any.push(format!("({})", scope.sql));
                any_params.extend(scope.params);
            }
            let row = self
                .first(
                    &format!(
                        "SELECT {} FROM {}
         WHERE {} AND e.kind IN ('pageview', 'event') AND ({})",
                        columns.join(", "),
                        v.from,
                        v.sql,
                        any.join(" OR ")
                    ),
                    concat(vec![p, v.params.clone(), any_params]),
                )
                .await?
                .unwrap_or_default();
            for (i, goal) in chunk.iter().enumerate() {
                out.insert(
                    goal.id.clone(),
                    GoalTotals {
                        conversions: row.num(&format!("c{i}")),
                        visitors: row.num(&format!("v{i}")),
                        revenue: cents(row.num(&format!("r{i}"))),
                    },
                );
            }
        }
        Ok(out)
    }

    fn revenue_sql(&self, goal: &GoalRow) -> Frag {
        if goal.value_mode == "prop" && !goal.value_prop.is_empty() {
            let value = self.prop_value(&goal.value_prop);
            return Frag { sql: format!("SUM({})", value.sql), params: value.params };
        }
        // Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
        if goal.value_mode == "fixed" {
            return Frag { sql: format!("COUNT(*) * CAST(? AS {})", self.double()), params: params![goal.value] };
        }
        Frag { sql: "0".into(), params: vec![] }
    }

    /// One goal's conversions, converting visitors, and revenue for a query's range and filters.
    pub async fn goal_totals(&self, query: &Query, goal: &GoalRow) -> R<GoalTotals> {
        let v = visit_rows(&query.filters, &query.site, query.from, query.to, self.dialect());
        let scope = self.scope_of(goal);
        let revenue = self.revenue_sql(goal);
        let row = self
            .first(
                &format!(
                    "SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, {} AS revenue
       FROM {} WHERE {} AND {}",
                    revenue.sql, v.from, v.sql, scope.sql
                ),
                concat(vec![revenue.params, v.params, scope.params]),
            )
            .await?
            .unwrap_or_default();
        Ok(GoalTotals {
            conversions: row.num("conversions"),
            visitors: row.num("visitors"),
            revenue: cents(row.num("revenue")),
        })
    }

    /// A goal's conversions split by where the visit came from, or by the page it happened on.
    pub async fn goal_breakdown(
        &self,
        query: &Query,
        goal: &GoalRow,
        by: &str,
        limit: i64,
    ) -> R<Vec<(String, GoalTotals)>> {
        let v = visit_rows(&query.filters, &query.site, query.from, query.to, self.dialect());
        let col = if by == "path" { "e.path".to_string() } else { format!("s.{by}") };
        let scope = self.scope_of(goal);
        let revenue = self.revenue_sql(goal);
        let rows = self
            .all(
                &format!(
                    "SELECT {col} AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, {} AS revenue
       FROM {} WHERE {} AND {}
       GROUP BY {col} ORDER BY conversions DESC, {col}{} LIMIT ?",
                    revenue.sql,
                    v.from,
                    v.sql,
                    scope.sql,
                    self.text_order()
                ),
                concat(vec![revenue.params, v.params, scope.params, params![limit]]),
            )
            .await?;
        Ok(rows
            .iter()
            .map(|r| {
                (
                    r.text_or("value", ""),
                    GoalTotals {
                        conversions: r.num("conversions"),
                        visitors: r.num("visitors"),
                        revenue: cents(r.num("revenue")),
                    },
                )
            })
            .collect())
    }

    /// A goal's conversions and revenue in each bucket, by when each visit started.
    pub async fn goal_series(
        &self,
        site: &str,
        filters: &[crate::query::Filter],
        goal: &GoalRow,
        buckets: &[Bucket],
    ) -> R<Vec<(i64, f64, f64)>> {
        if buckets.is_empty() {
            return Ok(vec![]);
        }
        let scope = self.scope_of(goal);
        let revenue = self.revenue_sql(goal);
        // Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
        let fixed =
            revenue.params.len() + scope.params.len() + visit_rows(filters, site, 0, 0, self.dialect()).params.len();
        let size = (BUCKETS_PER_QUERY.min(MAX_PARAMS.saturating_sub(fixed) / 3)).max(1);
        if buckets.len() > size {
            let mut out = Vec::new();
            for piece in buckets.chunks(size) {
                out.extend(Box::pin(self.goal_series(site, filters, goal, piece)).await?);
            }
            return Ok(out);
        }
        let v = visit_rows(filters, site, buckets[0].start, buckets[buckets.len() - 1].end, self.dialect());
        let rows = self
            .all(
                &format!(
                    "WITH b (i, bs, be) AS ({})
       SELECT b.i AS i, COUNT(*) AS conversions, {} AS revenue
       FROM {} CROSS JOIN b
       WHERE {} AND s.started_at >= b.bs AND s.started_at < b.be AND {}
       GROUP BY b.i",
                    bucket_table(self.dialect(), buckets),
                    revenue.sql,
                    v.from,
                    v.sql,
                    scope.sql
                ),
                concat(vec![bucket_params(buckets), revenue.params, v.params, scope.params]),
            )
            .await?;
        let found: HashMap<i64, &Row> = rows.iter().map(|r| (r.int("i"), r)).collect();
        Ok(buckets
            .iter()
            .enumerate()
            .map(|(i, b)| {
                let r = found.get(&(i as i64));
                (b.start, r.map_or(0.0, |r| r.num("conversions")), cents(r.map_or(0.0, |r| r.num("revenue"))))
            })
            .collect())
    }

    /// Every link domain and its site.
    pub async fn link_domains(&self) -> R<Vec<(String, String)>> {
        Ok(self
            .all("SELECT domain, site FROM rl_link_domains ORDER BY domain", vec![])
            .await?
            .iter()
            .map(|r| (r.text("domain"), r.text("site")))
            .collect())
    }

    /// Adds a link domain.
    pub async fn add_link_domain(&self, domain: &str, site: &str, now: i64) -> R<()> {
        self.run(
            &upsert(self.dialect(), "rl_link_domains", &["domain", "site", "created_at"], &["domain"], &[]),
            params![domain, site, now],
        )
        .await?;
        Ok(())
    }

    /// Removes a domain. Its links keep it as their home and fall back to the app's own link path
    /// until the domain is added again.
    pub async fn remove_link_domain(&self, domain: &str) -> R<()> {
        self.run("DELETE FROM rl_link_domains WHERE domain = ?", params![domain]).await?;
        Ok(())
    }

    /// A site's links, newest first, with their clicks in a range. Clicks imported as daily counts
    /// have no visitor, so they add to clicks only.
    pub async fn links(&self, site: &str, from: i64, to: i64) -> R<Vec<(LinkRow, f64, f64)>> {
        let rows = self
            .all(
                "SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
       FROM rl_links l LEFT JOIN (
         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
       ) c ON c.link = l.id
       WHERE l.site = ? AND l.deleted_at IS NULL
       ORDER BY l.created_at DESC, l.id",
                params![site, from, to, site],
            )
            .await?;
        Ok(rows.iter().map(|r| (link_row(r), r.num("clicks"), r.num("visitors"))).collect())
    }

    /// One link's clicks per bucket.
    pub async fn link_series(&self, site: &str, link: &str, buckets: &[Bucket]) -> R<Vec<(i64, f64, f64)>> {
        if buckets.is_empty() {
            return Ok(vec![]);
        }
        if buckets.len() > BUCKETS_PER_QUERY {
            return in_pieces(buckets, BUCKETS_PER_QUERY, |piece| async move {
                Box::pin(self.link_series(site, link, &piece)).await
            })
            .await;
        }
        let rows = self
            .all(
                &format!(
                    "WITH b (i, bs, be) AS ({})
       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i",
                    bucket_table(self.dialect(), buckets)
                ),
                concat(vec![bucket_params(buckets), params![link, site]]),
            )
            .await?;
        let found: HashMap<i64, &Row> = rows.iter().map(|r| (r.int("i"), r)).collect();
        Ok(buckets
            .iter()
            .enumerate()
            .map(|(i, b)| {
                let r = found.get(&(i as i64));
                (b.start, r.map_or(0.0, |r| r.num("clicks")), r.map_or(0.0, |r| r.num("visitors")))
            })
            .collect())
    }

    /// One link's clicks by a visit dimension.
    pub async fn link_breakdown(
        &self,
        site: &str,
        link: &str,
        from: i64,
        to: i64,
        dimension: &str,
        limit: i64,
    ) -> R<Vec<Value>> {
        let col = format!("s.{}", SESSION_DIMENSIONS.iter().find(|d| d.0 == dimension).map_or("", |d| d.1));
        let rows = self
            .all(
                &format!(
                    "SELECT {col} AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND {col} <> ''
       GROUP BY {col} ORDER BY clicks DESC, {col}{} LIMIT ?",
                    self.text_order()
                ),
                params![site, link, from, to, limit],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|r| obj! { "value" => r.text("value"), "visitors" => r.num("visitors"), "events" => r.num("clicks") })
            .collect())
    }

    // Reports

    /// Ties are broken by the value in code point order, the order the rolled-up path sorts in.
    fn text_order(&self) -> String {
        match self.dialect() {
            Dialect::Postgres => " COLLATE \"C\"".into(),
            Dialect::Mysql => format!(" COLLATE {MYSQL_COLLATION}"),
            Dialect::Sqlite => String::new(),
        }
    }

    /// When Runlight itself first counted a visit, leaving out imported history.
    pub async fn first_own_visit(&self, site: &str) -> R<Option<i64>> {
        // A session opened only by a short link click is not a visit, so it does not count as the first.
        let row = self
            .first(
                &format!(
                    "SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND {IS_VISIT}"
                ),
                params![site],
            )
            .await?;
        Ok(row.and_then(|r| r.opt_int("t")))
    }

    /// When the site's first visit was recorded, or `None` with no data yet.
    pub async fn first_seen(&self, site: &str) -> R<Option<i64>> {
        let row = self.first("SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?", params![site]).await?;
        Ok(row.and_then(|r| r.opt_int("t")))
    }

    /// Just the visitor count from stats(), in one query, for conversion rates.
    pub async fn visitors(&self, query: &Query) -> R<f64> {
        let scope = visit_scope(&query.filters, &query.site, query.from, query.to, self.dialect());
        let row = self
            .first(
                &format!(
                    "SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{}",
                    scope.sql
                ),
                concat(vec![params![&query.site, query.from, query.to], scope.params]),
            )
            .await?;
        Ok(row.map_or(0.0, |r| r.num("visitors")))
    }

    /// A range's totals.
    pub async fn stats(&self, query: &Query) -> R<Stats> {
        if let Some(rolled) = self.rolled_stats(query).await? {
            return Ok(rolled);
        }
        // Filtered or not, the numbers describe visits that started in the range (see visit_scope).
        let scope = visit_scope(&query.filters, &query.site, query.from, query.to, self.dialect());
        let pv = pageviews_of(&query.filters, &query.site, query.from, query.to, self.dialect());
        let row = self
            .first(
                &format!(
                    "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM({}) AS pageviews,
         SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
       FROM rl_sessions s {}
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{}",
                    if pv.is_some() { "COALESCE(pv.n, 0)" } else { "s.pageviews" },
                    pv.as_ref().map_or(String::new(), |pv| format!("LEFT JOIN {} pv ON pv.session = s.id", pv.sql)),
                    scope.sql
                ),
                concat(vec![
                    pv.map(|p| p.params).unwrap_or_default(),
                    params![&query.site, query.from, query.to],
                    scope.params,
                ]),
            )
            .await?
            .unwrap_or_default();
        let visits = row.num("visits");
        let pageviews = row.num("pageviews");
        Ok(Stats {
            visitors: row.num("visitors"),
            visits,
            pageviews,
            views_per_visit: if visits > 0.0 { cents(pageviews / visits) } else { 0.0 },
            bounce_rate: if visits > 0.0 { row.num("bounced") / visits } else { 0.0 },
            visit_duration: if visits > 0.0 { js::round(row.num("duration") / visits) } else { 0.0 },
        })
    }

    /// The chart: each bucket's visitors, visits, pageviews, and the rest.
    pub async fn series(&self, site: &str, filters: &[crate::query::Filter], buckets: &[Bucket]) -> R<Vec<Value>> {
        if buckets.is_empty() {
            return Ok(vec![]);
        }
        if buckets.len() > BUCKETS_PER_QUERY {
            let mut out = Vec::new();
            for piece in buckets.chunks(BUCKETS_PER_QUERY) {
                out.extend(Box::pin(self.series(site, filters, piece)).await?);
            }
            return Ok(out);
        }
        let dialect = self.dialect();
        let first_start = buckets[0].start;
        let last_end = buckets[buckets.len() - 1].end;
        let p = bucket_params(buckets);
        // Filtered or not, each bucket counts the visits that started in it (see visit_scope).
        let scope = visit_scope(filters, site, first_start, last_end, dialect);
        let pv = pageviews_of(filters, site, first_start, last_end, dialect);
        // Built days that fit inside one bucket come from rollups; the rest from the visits.
        let plan = self.rollup_plan(site, !filters.is_empty(), first_start, last_end).await?;
        let in_bucket = |start: i64, end: i64| buckets.iter().position(|b| b.start <= start && end <= b.end);
        let used: Vec<(String, i64, i64)> =
            plan.map(|p| p.days.into_iter().filter(|d| in_bucket(d.1, d.2).is_some()).collect()).unwrap_or_default();
        let mut rest: Option<Vec<(i64, i64)>> = None;
        if !used.is_empty() {
            let mut r = Vec::new();
            let mut from = first_start;
            for d in &used {
                if d.1 > from {
                    r.push((from, d.1));
                }
                from = from.max(d.2);
            }
            if from < last_end {
                r.push((from, last_end));
            }
            rest = Some(r);
        }
        // MySQL joins the buckets to every visit of the site unless told the whole range as well.
        let w = match &rest {
            Some(r) => within(r),
            None if dialect == Dialect::Mysql => within(&[(first_start, last_end)]),
            None => Frag { sql: "1 = 1".into(), params: vec![] },
        };
        // Filters and scattered unbuilt days add values of their own; when they would pass D1's 100, the
        // buckets go in halves.
        if p.len() + 1 + w.params.len() + scope.params.len() + pv.as_ref().map_or(0, |pv| pv.params.len()) > MAX_PARAMS
            && buckets.len() > 1
        {
            let half = buckets.len().div_ceil(2);
            let mut out = Box::pin(self.series(site, filters, &buckets[..half])).await?;
            out.extend(Box::pin(self.series(site, filters, &buckets[half..])).await?);
            return Ok(out);
        }
        let mut sums: HashMap<usize, [f64; 5]> = HashMap::new();
        let mut bump = |i: usize, row: &Row| {
            let into = sums.entry(i).or_insert([0.0; 5]);
            into[0] += row.num("visitors");
            into[1] += row.num("n");
            into[2] += row.num("views");
            into[3] += row.num("bounced");
            into[4] += row.num("duration");
        };
        if !used.is_empty() {
            let rolled = self
                .all(
                    &format!("SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN ({BUILT_DAYS})"),
                    params![site, site, first_start, last_end],
                )
                .await?;
            let at: HashMap<&str, usize> =
                used.iter().filter_map(|d| in_bucket(d.1, d.2).map(|i| (d.0.as_str(), i))).collect();
            for row in &rolled {
                if let Some(i) = at.get(row.text("day").as_str()) {
                    bump(*i, row);
                }
            }
        }
        let rows = self
            .all(
                &format!(
                    "WITH b (i, bs, be) AS ({})
       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM({}) AS views,
         SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
       {}
       WHERE {IS_VISIT}{} AND {}
       GROUP BY b.i",
                    bucket_table(dialect, buckets),
                    if pv.is_some() { "COALESCE(pv.n, 0)" } else { "s.pageviews" },
                    pv.as_ref().map_or(String::new(), |pv| format!("LEFT JOIN {} pv ON pv.session = s.id", pv.sql)),
                    scope.sql,
                    w.sql
                ),
                concat(vec![p, params![site], pv.map(|p| p.params).unwrap_or_default(), scope.params, w.params]),
            )
            .await?;
        for row in &rows {
            bump(row.int("i") as usize, row);
        }
        Ok(buckets
            .iter()
            .enumerate()
            .map(|(i, bucket)| {
                let [visitors, n, views, bounced, duration] = sums.get(&i).copied().unwrap_or([0.0; 5]);
                obj! {
                    "start" => bucket.start,
                    "visitors" => visitors,
                    "visits" => n,
                    "pageviews" => views,
                    "viewsPerVisit" => if n > 0.0 { cents(views / n) } else { 0.0 },
                    "bounceRate" => if n > 0.0 { bounced / n } else { 0.0 },
                    "visitDuration" => if n > 0.0 { js::round(duration / n) } else { 0.0 },
                }
            })
            .collect())
    }

    /// A breakdown of a range by a dimension, a page of rows at a time.
    pub async fn breakdown(&self, query: &Query, dimension: &str, limit: i64, offset: i64) -> R<Vec<Value>> {
        let dialect = self.dialect();
        if dimension == "ai_agent" || dimension == "ai_page" {
            let col = if dimension == "ai_agent" { "e.name" } else { "e.path" };
            let rows = self
                .all(
                    &format!(
                        "SELECT {col} AS value, COUNT(*) AS fetches FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
         GROUP BY {col} ORDER BY fetches DESC, {col}{} LIMIT ? OFFSET ?",
                        self.text_order()
                    ),
                    params![&query.site, query.from, query.to, limit, offset],
                )
                .await?;
            return Ok(rows
                .iter()
                .map(|r| obj! { "value" => r.text("value"), "visitors" => 0, "fetches" => r.num("fetches") })
                .collect());
        }

        if let Some(rolled) = self.rolled_breakdown(query, dimension, limit, offset).await? {
            return Ok(rolled);
        }

        // Filtered or not, the visits are those that started in the range (see visit_scope).
        let scope = visit_scope(&query.filters, &query.site, query.from, query.to, dialect);
        if is_session_dimension(dimension) {
            let pv = pageviews_of(&query.filters, &query.site, query.from, query.to, dialect);
            let col = format!("s.{}", SESSION_DIMENSIONS.iter().find(|d| d.0 == dimension).map_or("", |d| d.1));
            let entry_exit = dimension == "entry" || dimension == "exit";
            let rows = self
                .all(
                    &format!(
                        "SELECT {col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM({}) AS pageviews,
           SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
         FROM rl_sessions s {}
         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{} AND {col} <> ''
         GROUP BY {col} ORDER BY {}, {col}{} LIMIT ? OFFSET ?",
                        if pv.is_some() { "COALESCE(pv.n, 0)" } else { "s.pageviews" },
                        pv.as_ref().map_or(String::new(), |pv| format!("LEFT JOIN {} pv ON pv.session = s.id", pv.sql)),
                        scope.sql,
                        if entry_exit { "visits DESC" } else { "visitors DESC, visits DESC" },
                        self.text_order()
                    ),
                    concat(vec![pv.map(|p| p.params).unwrap_or_default(), params![&query.site, query.from, query.to], scope.params, params![limit, offset]]),
                )
                .await?;
            return Ok(rows
                .iter()
                .map(|row| {
                    let visits = row.num("visits");
                    let mut out = obj! {
                        "value" => row.text("value"),
                        "visitors" => row.num("visitors"),
                        "visits" => visits,
                        "bounceRate" => if visits > 0.0 { row.num("bounced") / visits } else { 0.0 },
                    };
                    if !entry_exit {
                        let o = out.as_object_mut().expect("an object");
                        o.set("pageviews", row.num("pageviews"));
                        o.set(
                            "visitDuration",
                            if visits > 0.0 { js::round(row.num("duration") / visits) } else { 0.0 },
                        );
                    }
                    out
                })
                .collect());
        }

        // Rows from the visits that started in the range and that the filters pick, narrowed by any filter on
        // the same kind of row ("page is /pricing" on pages), as the rollups count them.
        let within_rows = |dimensions: &[&str]| {
            let rows = row_scope(&query.filters, dimensions, dialect);
            (
                format!(
                    " AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{}){}",
                    scope.sql, rows.sql
                ),
                concat(vec![params![&query.site, query.from, query.to], scope.params.clone(), rows.params]),
                query.to + EVENT_TAIL_MS,
            )
        };

        if dimension == "page" || dimension == "hostname" {
            let col = format!("e.{}", EVENT_DIMENSIONS.iter().find(|d| d.0 == dimension).map_or("", |d| d.1));
            let (wsql, wparams, wto) = within_rows(&["page", "hostname"]);
            let rows = self
                .all(
                    &format!(
                        "SELECT {col} AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, {LIVE_VIEWS} AS views
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'{wsql}
         GROUP BY {col} ORDER BY visitors DESC, pageviews DESC, {col}{} LIMIT ? OFFSET ?",
                        self.text_order()
                    ),
                    concat(vec![params![&query.site, query.from, wto], wparams.clone(), params![limit, offset]]),
                )
                .await?;
            let mut out: Vec<Value> =
                rows.iter().map(|r| obj! { "value" => r.text("value"), "visitors" => r.num("visitors"), "pageviews" => r.num("pageviews") }).collect();
            let live: HashMap<String, f64> = rows.iter().map(|r| (r.text("value"), r.num("views"))).collect();
            if dimension == "page" && !out.is_empty() {
                // Each pageview's engaged time added up and its deepest scroll, then the mean over pageviews.
                let size = VALUES_PER_QUERY.min(MAX_PARAMS.saturating_sub(3 + wparams.len())).max(1);
                let values: Vec<String> = rows.iter().map(|r| r.text("value")).collect();
                let times = in_pieces(&values, size, |piece| {
                    let wsql = wsql.clone();
                    let wparams = wparams.clone();
                    let site = query.site.clone();
                    async move {
                        let sql = format!(
                            "SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest
               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'{wsql}
               AND e.path IN ({}) GROUP BY e.path, e.pageview) t GROUP BY value",
                            piece.iter().map(|_| "?").collect::<Vec<_>>().join(", ")
                        );
                        let p = concat(vec![
                            params![&site, query.from, wto],
                            wparams,
                            piece.iter().map(Param::from).collect(),
                        ]);
                        self.all(&sql, p).await
                    }
                })
                .await?;
                let by_path: HashMap<String, &Row> = times.iter().map(|t| (t.text("value"), t)).collect();
                for row in &mut out {
                    let value = row.at("value").as_str().unwrap_or("").to_string();
                    let time = by_path.get(&value);
                    let views = live.get(&value).copied().unwrap_or(0.0);
                    let o = row.as_object_mut().expect("an object");
                    o.set(
                        "timeOnPage",
                        match time {
                            Some(t) if views != 0.0 => js::round(t.num("total") / views),
                            _ => 0.0,
                        },
                    );
                    o.set(
                        "scrollDepth",
                        match time {
                            Some(t) if !t.is_null("scroll") => js::round(t.num("scroll")),
                            _ => 0.0,
                        },
                    );
                }
            }
            return Ok(out);
        }

        if dimension == "event" {
            let (wsql, wparams, wto) = within_rows(&["event"]);
            let rows = self
                .all(
                    &format!(
                        "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'{wsql}
         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name{} LIMIT ? OFFSET ?",
                        self.text_order()
                    ),
                    concat(vec![params![&query.site, query.from, wto], wparams, params![limit, offset]]),
                )
                .await?;
            return Ok(rows.iter().map(|r| obj! { "value" => r.text("value"), "visitors" => r.num("visitors"), "events" => r.num("events") }).collect());
        }

        Ok(vec![])
    }

    /// Visits by quarter hour since the epoch, which the caller folds into local weekdays and hours,
    /// keeping time zones out of SQL. Each is (quarter, visits, visitors, pageviews, bounced).
    pub async fn hourly(&self, query: &Query) -> R<Vec<(i64, f64, f64, f64, f64)>> {
        let dialect = self.dialect();
        if let Some(plan) = self.rollup_plan(&query.site, !query.filters.is_empty(), query.from, query.to).await? {
            let mut sums: Vec<(i64, [f64; 4])> = Vec::new();
            let mut bump = |quarter: i64, row: &Row| {
                let at = match sums.iter().position(|(q, _)| *q == quarter) {
                    Some(at) => at,
                    None => {
                        sums.push((quarter, [0.0; 4]));
                        sums.len() - 1
                    }
                };
                let into = &mut sums[at].1;
                into[0] += row.num("visits");
                into[1] += row.num("visitors");
                into[2] += row.num("pageviews");
                into[3] += row.num("bounced");
            };
            let rolled = self
                .all(
                    &format!("SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN ({BUILT_DAYS})"),
                    params![&query.site, &query.site, query.from, query.to],
                )
                .await?;
            for row in &rolled {
                bump(js::to_i64(js::text_number(&row.text("value"))), row);
            }
            let w = within(&plan.rest);
            let raw = self
                .all(
                    &format!(
                        "SELECT {} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced
         FROM rl_sessions s WHERE s.site = ? AND {} AND {IS_VISIT} GROUP BY 1",
                        div(dialect, "s.started_at", 900_000),
                        w.sql
                    ),
                    concat(vec![params![&query.site], w.params]),
                )
                .await?;
            for row in &raw {
                bump(row.num("quarter").floor() as i64, row);
            }
            return Ok(sums.into_iter().map(|(q, s)| (q, s[0], s[1], s[2], s[3])).collect());
        }
        let matching = visit_scope(&query.filters, &query.site, query.from, query.to, dialect);
        // A page filter counts that page's views as pageviews here too, as the cards do.
        let pv = pageviews_of(&query.filters, &query.site, query.from, query.to, dialect);
        let rows = self
            .all(
                &format!(
                    "SELECT {} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
         SUM({}) AS pageviews, SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced
       FROM rl_sessions s {}
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{}
       GROUP BY 1",
                    div(dialect, "s.started_at", 900_000),
                    if pv.is_some() { "COALESCE(pv.n, 0)" } else { "s.pageviews" },
                    pv.as_ref().map_or(String::new(), |pv| format!("LEFT JOIN {} pv ON pv.session = s.id", pv.sql)),
                    matching.sql
                ),
                concat(vec![
                    pv.map(|p| p.params).unwrap_or_default(),
                    params![&query.site, query.from, query.to],
                    matching.params,
                ]),
            )
            .await?;
        Ok(rows
            .iter()
            .map(|r| {
                (
                    r.num("quarter").floor() as i64,
                    r.num("visits"),
                    r.num("visitors"),
                    r.num("pageviews"),
                    r.num("bounced"),
                )
            })
            .collect())
    }

    /// Who is on the site now: the last five minutes, and the last thirty by the minute.
    pub async fn realtime(&self, site: &str, now: i64) -> R<Value> {
        let since = now - 5 * 60_000;
        let order = self.text_order();
        let active = self
            .first("SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')", params![site, since])
            .await?
            .unwrap_or_default();
        let pages = self
            .all(
                &format!(
                    "SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path{order} LIMIT 10"
                ),
                params![site, since],
            )
            .await?;
        let sources = self
            .all(
                &format!(
                    "SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
       GROUP BY s.source ORDER BY visitors DESC, s.source{order} LIMIT 10"
                ),
                params![site, since],
            )
            .await?;
        let start = now.div_euclid(60_000) * 60_000 - 29 * 60_000;
        let per_minute = self
            .all(
                &format!(
                    "SELECT {} AS m, COUNT(*) AS n FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1",
                    div(self.dialect(), "(ts - ?)", 60_000)
                ),
                params![start, site, start],
            )
            .await?;
        let mut minutes = [0.0f64; 30];
        for row in &per_minute {
            let index = row.num("m").floor();
            if (0.0..30.0).contains(&index) {
                minutes[index as usize] += row.num("n");
            }
        }
        let countries = self
            .all(
                &format!(
                    "SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
       GROUP BY s.country ORDER BY visitors DESC, s.country{order} LIMIT 10"
                ),
                params![site, since],
            )
            .await?;
        let recent = self
            .all(
                "SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20",
                params![site, start],
            )
            .await?;
        let pairs = |rows: &[Row]| {
            Value::Array(
                rows.iter().map(|r| obj! { "value" => r.text("value"), "visitors" => r.num("visitors") }).collect(),
            )
        };
        Ok(obj! {
            "visitors" => active.num("n"),
            "pages" => pairs(&pages),
            "sources" => pairs(&sources),
            "countries" => pairs(&countries),
            "minutes" => Value::Array(minutes.iter().map(|m| Value::Number(*m)).collect()),
            "recent" => Value::Array(recent.iter().map(|r| obj! {
                "ts" => r.num("ts"),
                "kind" => r.text("kind"),
                "path" => r.text_or("path", ""),
                "name" => r.text_or("name", ""),
                "country" => r.text_or("country", ""),
                "city" => r.text_or("city", ""),
                "source" => r.text_or("source", ""),
                "device" => r.text_or("device", ""),
            }).collect()),
        })
    }
}

impl SiteRow {
    pub(crate) fn hostnames_value(hostnames: &[String]) -> Value {
        Value::Array(hostnames.iter().map(|h| Value::from(h.as_str())).collect())
    }
}

/// Creates the tables, or brings older ones up to date (migrate's work, under its lock).
async fn create(db: &dyn Db) -> R<()> {
    // On Postgres an index on a big table takes a while to build, so the build may run past the
    // statement timeout, and goes CONCURRENTLY, so another process still serving keeps writing meanwhile.
    let postgres = db.dialect() == Dialect::Postgres;
    if postgres {
        db.run("SET statement_timeout = 0", vec![]).await?;
    }
    let result = upgrade(db, postgres).await;
    if postgres {
        let _ = db.run("RESET statement_timeout", vec![]).await;
    }
    result
}

async fn upgrade(db: &dyn Db, postgres: bool) -> R<()> {
    let dialect = db.dialect();
    let statements = schema(dialect);
    db.run(&statements[0], vec![]).await?;
    let found = db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'", vec![]).await?.into_iter().next();
    let from = found.as_ref().map_or(SCHEMA_VERSION as f64, |r| js::text_number(&r.text("value")));
    if postgres {
        // A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
        let broken = db
            .all(
                "SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\\_%' AND c.relnamespace = current_schema()::regnamespace",
                vec![],
            )
            .await?;
        for row in broken {
            db.run(&format!("DROP INDEX IF EXISTS \"{}\"", row.text("name").replace('"', "")), vec![]).await?;
        }
    }
    let index_re = js_re!(r"^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (\w+)");
    for statement in &statements {
        let caps = index_re.captures(statement.as_bytes());
        if let Some(caps) = caps.filter(|_| dialect == Dialect::Mysql) {
            // MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
            let text = |i: usize| caps.get(i).map(|m| String::from_utf8_lossy(m.as_bytes()).into_owned());
            let unique = text(1).unwrap_or_default();
            let (name, table) = (text(2).unwrap_or_default(), text(3).unwrap_or_default());
            let there = db
                .all(
                    "SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1",
                    params![table, name],
                )
                .await?;
            if there.is_empty() {
                let replaced = crate::re::replace_first(
                    js_re!(r"^CREATE (UNIQUE )?INDEX IF NOT EXISTS"),
                    statement,
                    &format!("CREATE {unique}INDEX"),
                );
                db.run(&replaced, vec![]).await?;
            }
        } else if postgres && test(index_re, statement) {
            let unique = if statement.starts_with("CREATE UNIQUE") { "UNIQUE " } else { "" };
            let replaced = crate::re::replace_first(
                js_re!(r"^CREATE (UNIQUE )?INDEX IF NOT EXISTS"),
                statement,
                &format!("CREATE {unique}INDEX CONCURRENTLY IF NOT EXISTS"),
            );
            db.run(&replaced, vec![]).await?;
        } else {
            db.run(statement, vec![]).await?;
        }
    }
    // A column added by an upgrade that stopped before it recorded the new version is already there.
    let add_column = |sql: &'static str| async move {
        match db.run(sql, vec![]).await {
            Ok(_) => Ok(()),
            Err(e) if crate::re::test(js_re!(r"(?i)duplicate column|already exists"), &e.0) => Ok(()),
            Err(e) => Err(e),
        }
    };
    // Version 2: settings changed in the dashboard, kept apart from the ones in code.
    if from < 2.0 {
        add_column("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'").await?;
    }
    if from < 4.0 {
        db.run("DROP INDEX IF EXISTS rl_links_slug", vec![]).await?;
    }
    // Version 10: tokens that may change one site's settings, for a hub.
    if (8.0..10.0).contains(&from) {
        add_column("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'").await?;
    }
    // Written only when it changes, so a database opened read-only can still be read.
    if found.as_ref().is_none_or(|r| r.text("value") != SCHEMA_VERSION.to_string()) {
        db.run(
            &upsert(dialect, "rl_meta", &["\"key\"", "value"], &["\"key\""], &["value"]),
            params!["schema", SCHEMA_VERSION.to_string()],
        )
        .await?;
    }
    Ok(())
}
