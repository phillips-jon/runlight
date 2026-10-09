//! Visit history from Umami: pageviews and custom events with where each visit came from, its place,
//! and its device, written as imported visits so the dashboard's history does not start the day
//! Runlight was installed (importers/visits.ts).
//!
//! The dashboard drives it a few days at a time, oldest first, so it fits any host's time limit and
//! shows progress. It stops where Runlight's own visits begin, so nothing is counted twice, and it
//! remembers how far it got, so running it again carries on from there.

use std::collections::HashMap;
use std::sync::Mutex;

use super::csvvisits::{CSV_BATCH, csv_format, csv_hit};
use super::http::{Http, parse_value};
use super::types::{Credentials, ImportError, field, filled, items, or};
use super::umami::{bearer, umami_sign_in};
use super::write::{browser_name, device_kind, hex_id, page_of, system_name, title};
use crate::js::{self, Object, Value};
use crate::params;
use crate::re::{js_re, test};
use crate::runlight::{Runlight, SESSION_IDLE_MS};
use crate::sources::attribute;
use crate::store::{DbError, EVENT_TAIL_MS, EventRow, SessionRow, SiteRow, SqlStore};
use crate::time::{add_days, local_date};

const DAY: f64 = 86_400_000.0;
/// Each step reads at most this many days, or stops after this many events.
const STEP_DAYS: f64 = 14.0;
const STEP_EVENTS: usize = 5_000;
/// A single day with more than this is refused rather than read without end.
const MAX_DAY_EVENTS: usize = 200_000;

/// Whether a hit is a pageview or a custom event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HitKind {
    /// A pageview.
    Pageview,
    /// A custom event.
    Event,
}

impl HitKind {
    /// `pageview` or `event`.
    pub fn as_str(self) -> &'static str {
        match self {
            HitKind::Pageview => "pageview",
            HitKind::Event => "event",
        }
    }
}

/// One pageview or event from another tool, in the shape every visit import writes. `key` groups rows
/// into visitors, as Umami's session id does.
#[derive(Clone, Debug, PartialEq)]
pub struct ImportedHit {
    /// When, in milliseconds.
    pub ts: f64,
    /// Groups rows into visitors.
    pub key: String,
    /// A pageview or an event.
    pub kind: HitKind,
    /// The page's host.
    pub hostname: String,
    /// The page's path.
    pub path: String,
    /// The page's query, without the `?`.
    pub query: String,
    /// Where the visit came from, as a full address.
    pub referrer: String,
    /// The page's title.
    pub title: String,
    /// The event's name.
    pub name: String,
    /// The country.
    pub country: String,
    /// The region, with or without its country.
    pub region: String,
    /// The city.
    pub city: String,
    /// The browser.
    pub browser: String,
    /// The system.
    pub os: String,
    /// The device.
    pub device: String,
    /// The screen.
    pub screen: String,
    /// The language.
    pub language: String,
}

/// What one step of a visit import did.
#[derive(Clone, Debug, PartialEq)]
pub struct VisitImportStep {
    /// Where to pick up, or `None` when done.
    pub cursor: Option<String>,
    /// Days read so far, for the progress bar.
    pub done: f64,
    /// Days in all.
    pub total: f64,
    /// Pageviews written.
    pub pageviews: f64,
    /// Events written.
    pub events: f64,
    /// Visits started.
    pub visits: f64,
}

impl VisitImportStep {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new();
        o.set("cursor", self.cursor.clone());
        o.set("done", self.done);
        o.set("total", self.total);
        o.set("pageviews", self.pageviews);
        o.set("events", self.events);
        o.set("visits", self.visits);
        Value::Object(o)
    }
}

/// What one batch of a CSV file did.
#[derive(Clone, Debug, PartialEq)]
pub struct CsvImportStep {
    /// Pageviews written.
    pub pageviews: f64,
    /// Events written.
    pub events: f64,
    /// Visits started.
    pub visits: f64,
    /// Rows left out.
    pub skipped: f64,
}

impl CsvImportStep {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new();
        o.set("pageviews", self.pageviews);
        o.set("events", self.events);
        o.set("visits", self.visits);
        o.set("skipped", self.skipped);
        Value::Object(o)
    }
}

fn progress_key(site: &str, website: &str) -> String {
    format!("import:umami-visits:{site}:{website}")
}

/// `{ id, name, domain }` of each website an Umami account can see, to pick which one becomes this
/// site's history.
pub async fn umami_websites(http: &Http, credentials: &Credentials) -> Result<Vec<Value>, ImportError> {
    let (base, token) = umami_sign_in(http, credentials, None).await?;
    let auth = bearer(token.as_ref());
    let headers = [("authorization", auth.as_str())];
    let mut out: Vec<Value> = Vec::new();
    for page in 1..100 {
        let body = http.get(&format!("{base}/api/websites?page={page}&pageSize=100"), &headers).await?;
        let data = items(field(Some(&body), "data"), "data")?;
        for w in data {
            let w = object_of(Some(w))?;
            let mut o = Object::new();
            for k in ["id", "name", "domain"] {
                if let Some(v) = field(w, k) {
                    o.set(k, v.clone());
                }
            }
            out.push(Value::Object(o));
        }
        if at_least(out.len(), field(Some(&body), "count")) || data.is_empty() {
            break;
        }
    }
    Ok(out)
}

/// `n >= count`, as JavaScript compares a number with whatever `count` is.
pub(crate) fn at_least(n: usize, count: Option<&Value>) -> bool {
    let c = count.map_or(f64::NAN, js::js_number);
    n as f64 >= c
}

/// A value whose fields are read: null and undefined are a TypeError, as `null.x` is.
pub(crate) fn object_of(value: Option<&Value>) -> Result<Option<&Value>, ImportError> {
    match value {
        None | Some(Value::Null) => Err(ImportError::other("TypeError: Cannot read properties of null")),
        v => Ok(v),
    }
}

/// Every page of an Umami list for a time window.
async fn all(
    http: &Http,
    base: &str,
    path: &str,
    headers: &[(&str, &str)],
    limit: usize,
) -> Result<Vec<Value>, ImportError> {
    let mut out: Vec<Value> = Vec::new();
    let mut page = 1;
    loop {
        let body = http.get(&format!("{base}/api{path}&page={page}&pageSize=1000"), headers).await?;
        let data = items(field(Some(&body), "data"), "data")?;
        out.extend(data.iter().cloned());
        if at_least(out.len(), field(Some(&body), "count")) || data.is_empty() {
            return Ok(out);
        }
        if out.len() > limit {
            let words = crate::intl::number("en", limit as f64, 0, 3);
            return Err(ImportError::new(
                format!("One day has more than {words} events, more than an import step can read"),
                "import_day_full",
                &[("limit", &limit.to_string())],
            ));
        }
        page += 1;
    }
}

/// A map key that tells apart values JavaScript's Map does (SameValueZero), such as "1" and 1.
fn map_key(value: Option<&Value>) -> String {
    match value {
        None => "undefined".into(),
        Some(v) => js::stringify(v),
    }
}

/// One step: read the next few days from Umami and write them as imported visits.
pub async fn import_umami_visits(
    rl: &Runlight,
    http: &Http,
    site_id: &str,
    credentials: &Credentials,
    website: &str,
    cursor: Option<&str>,
) -> Result<VisitImportStep, ImportError> {
    rl.init().await?;
    if rl.site(Some(site_id)).is_none() {
        return Err(ImportError::new("Unknown site", "unknown_site", &[]));
    }
    if !test(js_re!(r"^[A-Za-z0-9-]{1,64}$"), website) {
        return Err(ImportError::new("Pick the Umami website to import", "import_website", &[]));
    }

    let saved = match cursor.filter(|c| !c.is_empty()) {
        Some(c) => Some(js::parse(c).map_err(|e| ImportError::other(format!("SyntaxError: {e}")))?),
        None => None,
    };
    let saved_token = match &saved {
        Some(Value::Null) | None => None,
        Some(v) => field(Some(v), "token").cloned(),
    };
    let (base, token) = umami_sign_in(http, credentials, saved_token).await?;
    let auth = bearer(token.as_ref());
    let headers = [("authorization", auth.as_str())];
    let resumes = saved.as_ref().is_some_and(js::truthy)
        && field(saved.as_ref(), "website").and_then(Value::as_str) == Some(website);
    let mut state: Object = if resumes {
        saved.as_ref().and_then(Value::as_object).cloned().unwrap_or_default()
    } else {
        let info = http.get(&format!("{base}/api/websites/{website}"), &headers).await?;
        let created = super::http::or_now(parse_value(field(Some(&info), "createdAt")), rl.now());
        // Carry on where an earlier run stopped, and end where Runlight's own visits begin.
        let resumed = rl.store().setting(&progress_key(site_id, website)).await?.map_or(0.0, |s| js::text_number(&s));
        // Never older than the site keeps, or the next scheduled check would delete it again.
        let cutoff = rl.retention_cutoff(site_id).await?.unwrap_or(0) as f64;
        let start = js_max(&[(created / DAY).floor() * DAY, resumed, (cutoff / DAY).ceil() * DAY]);
        let own = rl.store().first_own_visit(site_id).await?;
        let end = own.unwrap_or_else(|| rl.now()) as f64;
        let mut o = Object::new();
        o.set("website", website);
        o.set("day", start);
        o.set("start", start);
        o.set("end", end);
        o
    };
    let num = |o: &Object, k: &str| o.get(k).map_or(f64::NAN, js::js_number);
    let (day, start, end) = (num(&state, "day"), num(&state, "start"), num(&state, "end"));
    let uses_key = filled(credentials, "apiKey").is_some();

    // Read whole days until the step has enough.
    let mut events: Vec<Value> = Vec::new();
    let from = day;
    let mut to = day;
    while to < end && to - from < STEP_DAYS * DAY && events.len() < STEP_EVENTS {
        let next = (to + DAY).min(end);
        let path = format!(
            "/websites/{website}/events?startAt={}&endAt={}",
            js::format_number(to),
            js::format_number(next - 1.0)
        );
        events.extend(all(http, &base, &path, &headers, MAX_DAY_EVENTS).await?);
        to = next;
    }
    let sessions = if events.is_empty() {
        vec![]
    } else {
        let path = format!(
            "/websites/{website}/sessions?startAt={}&endAt={}",
            js::format_number(from),
            js::format_number(to - 1.0)
        );
        all(http, &base, &path, &headers, MAX_DAY_EVENTS * STEP_DAYS as usize).await?
    };
    let mut info: HashMap<String, &Value> = HashMap::new();
    for s in &sessions {
        info.insert(map_key(field(object_of(Some(s))?, "id")), s);
    }

    let ns = format!("umami-visits:{website}");
    let mut visits: Vec<(f64, &Value)> = Vec::new();
    for e in &events {
        let e = object_of(Some(e))?;
        let kind = field(e, "eventType");
        let wanted = matches!(kind, Some(Value::Number(n)) if *n == 1.0)
            || (matches!(kind, Some(Value::Number(n)) if *n == 2.0) && js::opt_truthy(field(e, "eventName")));
        if !wanted {
            continue;
        }
        let ts = parse_value(field(e, "createdAt"));
        if ts.is_finite() && ts < end {
            visits.push((ts, e.unwrap_or(&Value::Null)));
        }
    }
    visits.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let hits: Vec<(String, ImportedHit)> = visits
        .iter()
        .map(|(ts, e)| {
            let session = info.get(&map_key(field(Some(e), "sessionId"))).copied();
            (ns.clone(), from_umami(e, *ts, session))
        })
        .collect();
    let key = progress_key(site_id, website);
    let to_text = js::format_number(to);
    let counts = write_step(rl, site_id, from, to, &hits, Some((&key, &to_text))).await?;

    let total_days = 1f64.max(((end - start) / DAY).ceil());
    let done_days = total_days.min(((to - start) / DAY).ceil());
    let more = to < end;
    let cursor = if more {
        state.set("day", to);
        if !uses_key {
            match token {
                Some(t) => state.set("token", t),
                None => {
                    state.remove("token");
                }
            }
        }
        Some(js::stringify(&Value::Object(state)))
    } else {
        None
    };
    Ok(VisitImportStep {
        cursor,
        done: done_days,
        total: total_days,
        pageviews: counts.0,
        events: counts.1,
        visits: counts.2,
    })
}

/// `Math.max` over numbers: NaN when any is.
fn js_max(values: &[f64]) -> f64 {
    let mut m = f64::NEG_INFINITY;
    for v in values {
        if v.is_nan() {
            return f64::NAN;
        }
        m = m.max(*v);
    }
    m
}

/// Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier
/// import left in those times is cleared first, so a step can always run again, and a visit carried in
/// from the step before is counted again from its rows. `done` is a setting written in the same
/// transaction, to remember how far it got. Answers pageviews, events, and visits written.
async fn write_step(
    rl: &Runlight,
    site_id: &str,
    from: f64,
    to: f64,
    hits: &[(String, ImportedHit)],
    done: Option<(&str, &str)>,
) -> Result<(f64, f64, f64), ImportError> {
    let Some(site) = rl.site(Some(site_id)) else { return Err(ImportError::new("Unknown site", "unknown_site", &[])) };
    let failure: Mutex<Option<ImportError>> = Mutex::new(None);
    let fail = |e: ImportError| {
        let message = e.message().to_string();
        *failure.lock().unwrap_or_else(|p| p.into_inner()) = Some(e);
        DbError(message)
    };
    let written = rl
        .store()
        .transaction(|store| {
            let (site, fail) = (&site, &fail);
            async move {
                let db = store.db();
                let mut counts = (0.0, 0.0, 0.0);
                // Days this step writes into are added up again later, with the imported visits in them.
                store.clear_rollups(site_id, None, Some((js::to_i64(from), js::to_i64(to)))).await?;
                // A failed earlier try at these days (on D1, which has no transactions) can
                // have left part of them behind. Clear it, so every step can safely run again.
                db.run(
                    "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND imported = 1)",
                    params![site_id, from, to, site_id],
                )
                .await?;
                // Visits of these days that kept no rows go too. Their rows would come within EVENT_TAIL_MS of the step,
                // so the time bounds let the (site, ts) index find them, with no scan of every event.
                db.run(
                    "DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
                    params![site_id, from, to, site_id, from, to + EVENT_TAIL_MS as f64],
                )
                .await?;
                for (ns, hit) in hits {
                    let made = write_event(&store, site, ns, hit).await.map_err(|e| match e {
                        ImportError::Other(crate::Error::Db(d)) => d,
                        e => fail(e),
                    })?;
                    if made {
                        counts.2 += 1.0;
                    }
                    if hit.kind == HitKind::Pageview {
                        counts.0 += 1.0;
                    } else {
                        counts.1 += 1.0;
                    }
                }
                // A visit that began in an earlier step and went on into this one is counted
                // again from its rows, so a repeated step cannot leave it with doubled totals.
                // The day it began may already be built, so that day is built again too.
                let carried = db
                    .all(
                        "SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
                        params![site_id, from, from - EVENT_TAIL_MS as f64, site_id, from, to],
                    )
                    .await?;
                if !carried.is_empty() {
                    let earliest = carried.iter().map(|c| c.num("started_at")).fold(f64::INFINITY, f64::min);
                    store.clear_rollups(site_id, None, Some((js::to_i64(earliest), js::to_i64(from)))).await?;
                    // Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
                    // Ninety ids a statement, within Cloudflare D1's 100 values.
                    let mut rows = Vec::new();
                    for chunk in carried.chunks(90) {
                        let ids: Vec<String> = chunk.iter().map(|c| c.text("id")).collect();
                        let mut p = params![site_id, earliest, to];
                        p.extend(ids.iter().map(|i| crate::store::Param::from(i.as_str())));
                        rows.extend(
                            db.all(
                                &format!(
                                    "SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN ({})
             ORDER BY e.ts, e.id",
                                    ids.iter().map(|_| "?").collect::<Vec<_>>().join(", ")
                                ),
                                p,
                            )
                            .await?,
                        );
                    }
                    // Pageviews, events, the last row's time, and the exit page, by visit in the order first seen.
                    let mut totals: Vec<(String, f64, f64, f64, Option<String>)> = Vec::new();
                    for r in &rows {
                        let session = r.text("session");
                        let at = match totals.iter().position(|t| t.0 == session) {
                            Some(i) => i,
                            None => {
                                totals.push((session, 0.0, 0.0, 0.0, None));
                                totals.len() - 1
                            }
                        };
                        let t = &mut totals[at];
                        if r.text("kind") == "pageview" {
                            t.1 += 1.0;
                            t.4 = Some(r.text("path"));
                        } else {
                            t.2 += 1.0;
                        }
                        t.3 = t.3.max(r.num("ts"));
                    }
                    for (id, pageviews, events, last, exit) in totals {
                        db.run(
                            "UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?",
                            params![pageviews, events, last, exit, &id],
                        )
                        .await?;
                    }
                }
                if let Some((key, value)) = done {
                    store.set_setting(key, Some(value)).await?;
                }
                Ok(counts)
            }
        })
        .await;
    match written {
        Ok(c) => Ok(c),
        Err(e) => Err(failure.into_inner().unwrap_or_else(|p| p.into_inner()).unwrap_or(ImportError::from(e))),
    }
}

/// The referrer as a full address, from Umami's domain, path, and query.
fn referrer_of(domain: Option<&Value>, path: Option<&Value>, query: Option<&Value>) -> String {
    if !js::opt_truthy(domain) {
        return String::new();
    }
    let path = if js::opt_truthy(path) { js::str_or_empty(path) } else { "/".into() };
    let query = if js::opt_truthy(query) {
        let q = js::str_or_empty(query);
        format!("?{}", q.strip_prefix('?').unwrap_or(&q))
    } else {
        String::new()
    };
    format!("https://{}{path}{query}", js::str_or_empty(domain))
}

/// One of Umami's events as a hit, with its visit's screen, language, and region.
fn from_umami(e: &Value, ts: f64, session: Option<&Value>) -> ImportedHit {
    let e = Some(e);
    let s = |k: &str| field(session, k);
    let text = |k: &str| js::str_or_empty(field(e, k));
    let pageview = matches!(field(e, "eventType"), Some(Value::Number(n)) if *n == 1.0);
    ImportedHit {
        ts,
        key: super::write::tpl(field(e, "sessionId")),
        kind: if pageview { HitKind::Pageview } else { HitKind::Event },
        hostname: text("hostname"),
        path: text("urlPath"),
        query: text("urlQuery"),
        referrer: referrer_of(field(e, "referrerDomain"), field(e, "referrerPath"), field(e, "referrerQuery")),
        title: text("pageTitle"),
        name: text("eventName"),
        country: text("country"),
        region: super::write::text_or_empty(or(s("subdivision1"), s("region"))),
        city: text("city"),
        browser: text("browser"),
        os: text("os"),
        device: text("device"),
        screen: js::str_or_empty(s("screen")),
        language: js::str_or_empty(s("language")),
    }
}

/// Writes one imported pageview or event as part of a Runlight visit. Visitors are hashed per day from
/// the hit's key, as live visitors are hashed per day, and a hit within thirty minutes of the visitor's
/// last one joins that visit. Ids come from `ns` and the key, so importing the same rows again makes the
/// same ids. Answers whether it started a new visit.
async fn write_event(store: &SqlStore, site: &SiteRow, ns: &str, e: &ImportedHit) -> Result<bool, ImportError> {
    let ts = js::to_i64(e.ts);
    // The site's own day, as live visitors are counted, so days add up the same way in rollups.
    let day = local_date(ts, &site.timezone);
    let visitor = hex_id(&format!("{ns}:{}:{day}", e.key), 16);
    // A visit that runs past midnight keeps the id it started with, as a live one does.
    let yesterday = hex_id(&format!("{ns}:{}:{}", e.key, add_days(&day, -1)), 16);
    let host = (if !e.hostname.is_empty() {
        e.hostname.clone()
    } else {
        site.hostnames.first().filter(|h| !h.is_empty()).cloned().unwrap_or_else(|| "imported.invalid".into())
    })
    .to_lowercase();
    let path = if e.path.is_empty() { "/" } else { e.path.as_str() };
    let query =
        if e.query.is_empty() { String::new() } else { format!("?{}", e.query.strip_prefix('?').unwrap_or(&e.query)) };
    let page = match page_of(&format!("https://{host}{path}{query}")) {
        Some(p) => p,
        None => page_of(&format!("https://{host}/")).ok_or_else(|| ImportError::other("TypeError: Invalid URL"))?,
    };
    let open = store.open_session(&site.id, &[visitor.clone(), yesterday], ts - SESSION_IDLE_MS).await?;
    let id = match &open {
        Some((id, _)) => id.clone(),
        None => {
            let id = hex_id(&format!("{ns}:{}:{}", e.key, js::format_number(e.ts)), 24);
            store.db().run("DELETE FROM rl_sessions WHERE id = ?", params![&id]).await?;
            let country = js::head16(&e.country.to_uppercase(), 2);
            let region = if e.region.is_empty() {
                String::new()
            } else {
                let r = if e.region.contains('-') { e.region.clone() } else { format!("{country}-{}", e.region) };
                js::head16(&r.to_uppercase(), 10)
            };
            let a = attribute(&page, &e.referrer, &site.hostnames);
            let two_letters = test(js_re!(r"^[A-Z]{2}$"), &country);
            store
                .insert_session(&SessionRow {
                    id: id.clone(),
                    site: site.id.clone(),
                    visitor: visitor.clone(),
                    started_at: ts,
                    hostname: page.hostname.clone(),
                    referrer_host: a.referrer_host,
                    referrer_path: a.referrer_path,
                    source: a.source,
                    channel: a.channel.to_string(),
                    utm_source: page.utm.source.clone(),
                    utm_medium: page.utm.medium.clone(),
                    utm_campaign: page.utm.campaign.clone(),
                    utm_term: page.utm.term.clone(),
                    utm_content: page.utm.content.clone(),
                    country: if two_letters { country.clone() } else { String::new() },
                    region: if two_letters { region } else { String::new() },
                    city: js::head16(&e.city, 100),
                    browser: browser_name(&e.browser.to_lowercase()).map_or_else(|| title(&e.browser), str::to_string),
                    browser_version: String::new(),
                    os: system_name(&e.os.to_lowercase()).map_or_else(|| e.os.clone(), str::to_string),
                    os_version: String::new(),
                    device: device_kind(&e.device.to_lowercase()).unwrap_or("").to_string(),
                    screen: js::head16(&e.screen, 20),
                    language: js::head16(&e.language, 35),
                })
                .await?;
            // No engaged time is known, so duration falls back to first-to-last pageview.
            store.db().run("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", params![&id]).await?;
            id
        }
    };
    let kind = e.kind.as_str();
    store.touch_session(&id, ts, kind, &page.path, true).await?;
    store
        .insert_event(&EventRow {
            site: site.id.clone(),
            ts,
            kind: kind.into(),
            // The visit's own visitor, which for one running past midnight is the id of the day it started.
            visitor: open.as_ref().map_or(visitor, |(_, v)| v.clone()),
            session: id,
            pageview: String::new(),
            path: page.path.clone(),
            hostname: page.hostname.clone(),
            title: if e.kind == HitKind::Pageview { js::head16(&e.title, 300) } else { String::new() },
            name: if e.kind == HitKind::Event { js::head16(&e.name, 120) } else { String::new() },
            props: None,
            engaged_ms: 0,
            scroll: None,
            link: String::new(),
        })
        .await?;
    Ok(open.is_none())
}

/// One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from before
/// Runlight's own first visit, and within what the site keeps, are written. A batch can run again: its
/// time span is cleared first, so batches must not share a moment, which the dashboard sees to. `rows`
/// is what the request sent (`undefined` as `None`).
pub async fn import_csv_visits(
    rl: &Runlight,
    site_id: &str,
    rows: Option<&Value>,
) -> Result<CsvImportStep, ImportError> {
    rl.init().await?;
    if rl.site(Some(site_id)).is_none() {
        return Err(ImportError::new("Unknown site", "unknown_site", &[]));
    }
    let rows = match rows {
        Some(Value::Array(a)) if a.len() <= CSV_BATCH => a,
        _ => {
            return Err(ImportError::new(
                format!("Send at most {CSV_BATCH} rows at a time"),
                "import_csv_batch",
                &[("max", &CSV_BATCH.to_string())],
            ));
        }
    };
    let clean: Vec<Object> = rows
        .iter()
        .map(|r| {
            let mut o = Object::new();
            let mut put = |k: &str, v: &Value| {
                o.set(js::trim(k).to_lowercase(), if v.is_null() { String::new() } else { js::js_string(v) });
            };
            match r {
                Value::Object(m) => m.iter().for_each(|(k, v)| put(k, v)),
                Value::Array(a) => a.iter().enumerate().for_each(|(i, v)| put(&i.to_string(), v)),
                _ => {}
            }
            o
        })
        .collect();
    let columns: Vec<&str> = clean.first().map(|o| o.keys().collect()).unwrap_or_default();
    let Some(format) = csv_format(&columns) else {
        return Err(ImportError::new(
            "This CSV is not an Umami export or Runlight's visit format",
            "import_csv_format",
            &[],
        ));
    };
    let cutoff = rl.retention_cutoff(site_id).await?.unwrap_or(0) as f64;
    let own = rl.store().first_own_visit(site_id).await?.map_or(f64::INFINITY, |t| t as f64);
    let end = own.min(rl.now() as f64);
    let mut hits: Vec<(String, ImportedHit)> =
        clean.iter().filter_map(|row| csv_hit(row, format)).filter(|(_, h)| h.ts >= cutoff && h.ts < end).collect();
    hits.sort_by(|a, b| a.1.ts.partial_cmp(&b.1.ts).unwrap_or(std::cmp::Ordering::Equal));
    let skipped = (clean.len() - hits.len()) as f64;
    let (Some(first), Some(last)) = (hits.first(), hits.last()) else {
        return Ok(CsvImportStep { pageviews: 0.0, events: 0.0, visits: 0.0, skipped });
    };
    let (from, to) = (first.1.ts, last.1.ts + 1.0);
    let counts = write_step(rl, site_id, from, to, &hits, None).await?;
    Ok(CsvImportStep { pageviews: counts.0, events: counts.1, visits: counts.2, skipped })
}
