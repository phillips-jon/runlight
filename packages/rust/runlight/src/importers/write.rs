//! Writes an imported link with its history (importers/write.ts).

use std::collections::HashSet;
use std::sync::Mutex;

use super::http::{date_parse, iso_string};
use super::types::{ImportError, field, or};
use crate::hash::sha256;
use crate::http::Url;
use crate::js::{self, Object, Value};
use crate::params;
use crate::re::{js_re, test};
use crate::runlight::Runlight;
use crate::sources::{Page, attribute, parse_page, strip_www};
use crate::store::{DbError, EventRow, LinkRow, SessionRow};

/// Domains run by the shorteners themselves. Links there stay on Runlight's own path.
const SHORTENER_DOMAINS: [&str; 10] =
    ["bit.ly", "bitly.com", "j.mp", "dub.sh", "dub.co", "dub.link", "short.gy", "rebrand.ly", "rebrandly.com", "rb.gy"];

/// The first `length` hex digits of a value's SHA-256.
pub fn hex_id(value: &str, length: usize) -> String {
    sha256(value)[..length].to_string()
}

/// The Runlight id an imported link gets, from its source and its id there.
pub fn imported_link_id(source: &str, source_id: &str) -> String {
    hex_id(&format!("{source}:{source_id}"), 24)
}

/// Two destinations are the same link when they differ only by a trailing slash.
pub fn same_url(a: &str, b: &str) -> bool {
    a.strip_suffix('/').unwrap_or(a) == b.strip_suffix('/').unwrap_or(b)
}

/// Browser names as other tools write them, in Runlight's spelling.
pub fn browser_name(lower: &str) -> Option<&'static str> {
    Some(match lower {
        "chrome" | "crios" => "Chrome",
        "chromium-webview" | "chrome webview" => "Android WebView",
        "safari" | "ios" | "ios-webview" | "mobile safari" => "Safari",
        "firefox" | "fxios" => "Firefox",
        "edge" | "edge-chromium" | "edge-ios" | "microsoft edge" => "Edge",
        "opera" | "opera-mini" => "Opera",
        "samsung" | "samsung internet" => "Samsung Internet",
        "yandexbrowser" => "Yandex Browser",
        "facebook" => "Facebook",
        "instagram" => "Instagram",
        "brave" => "Brave",
        "duckduckgo" => "DuckDuckGo",
        _ => return None,
    })
}

/// System names as other tools write them, in Runlight's spelling.
pub fn system_name(lower: &str) -> Option<&'static str> {
    Some(match lower {
        "mac os" | "mac os x" | "macos" => "macOS",
        "ios" => "iOS",
        "android os" | "android" => "Android",
        "windows 10" | "windows 11" | "windows 7" | "windows" => "Windows",
        "linux" => "Linux",
        "chrome os" | "chromium os" => "Chrome OS",
        _ => return None,
    })
}

/// Device kinds as other tools write them, in Runlight's words.
pub fn device_kind(lower: &str) -> Option<&'static str> {
    Some(match lower {
        "desktop" | "laptop" => "desktop",
        "mobile" | "smartphone" | "phone" => "mobile",
        "tablet" => "tablet",
        _ => return None,
    })
}

/// The first letter upper case (`v[0].toUpperCase() + v.slice(1)`).
pub fn title(v: &str) -> String {
    let mut chars = v.chars();
    match chars.next() {
        None => String::new(),
        // A letter outside the Basic Multilingual Plane is two UTF-16 units, and JavaScript upper-cases only the first.
        Some(c) if (c as u32) > 0xFFFF => v.to_string(),
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
    }
}

/// A value as a template literal writes it: `undefined` for a missing one.
pub(crate) fn tpl(value: Option<&Value>) -> String {
    value.map_or_else(|| "undefined".to_string(), js::js_string)
}

/// `(value || "")` as text.
pub(crate) fn text_or_empty(value: Option<&Value>) -> String {
    if js::opt_truthy(value) { tpl(value) } else { String::new() }
}

/// `value ?? ""` as text.
pub(crate) fn text_or_blank(value: Option<&Value>) -> String {
    js::str_or_empty(value)
}

/// `parsePage(new URL(url))`, or `None` where the URL constructor throws.
pub(crate) fn page_of(url: &str) -> Option<Page> {
    Url::parse(url).map(|u| parse_page(&u))
}

/// What became of one link.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WriteStatus {
    /// Written, with its history.
    Created,
    /// Already here.
    Skipped,
    /// Refused, with why.
    Failed,
}

/// What writing one link did.
#[derive(Clone, Debug, PartialEq)]
pub struct WriteResult {
    /// Written, already here, or refused.
    pub status: WriteStatus,
    /// Clicks written.
    pub clicks: f64,
    /// Why it was refused.
    pub reason: Option<String>,
    /// The reason as a code, for the dashboard to say in its own words.
    pub code: Option<String>,
    /// The code's params.
    pub params: Vec<(String, String)>,
}

impl WriteResult {
    fn skipped() -> WriteResult {
        WriteResult { status: WriteStatus::Skipped, clicks: 0.0, reason: None, code: None, params: vec![] }
    }
}

/// Writes one link and its history in a single transaction: the link (and its branded domain), then each
/// click as a visit like a live one, or daily counts as clicks without visitors. Ids come from the
/// source's own ids, so importing again skips what is already there. `foreign` is the ForeignLink and
/// `history` holds its `clicks` and `daily`, as the importers hand them back.
pub async fn write_link(
    rl: &Runlight,
    site: &str,
    source: &str,
    foreign: &Value,
    history: &Value,
) -> Result<WriteResult, ImportError> {
    let f = Some(foreign);
    let source_id = tpl(field(f, "sourceId"));
    let slug = tpl(field(f, "slug"));
    let url = tpl(field(f, "url"));
    let id = imported_link_id(source, &source_id);
    let store = rl.store();
    if store.link_by_id(&id).await?.is_some() {
        return Ok(WriteResult::skipped());
    }
    let taken = store.link_by_slug(&slug).await?;
    // The same slug to the same place is this link, brought in earlier some other way.
    if let Some(taken) = taken {
        if same_url(&taken.url, &url) {
            return Ok(WriteResult::skipped());
        }
        return Ok(WriteResult {
            status: WriteStatus::Failed,
            clicks: 0.0,
            reason: Some(format!("/{slug} is already used by \"{}\"", taken.name)),
            code: Some("import_slug_taken".into()),
            params: vec![("slug".into(), slug.clone()), ("name".into(), taken.name.clone())],
        });
    }
    if !test(js_re!(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$"), &slug) {
        return Ok(WriteResult {
            status: WriteStatus::Failed,
            clicks: 0.0,
            reason: Some(format!("/{slug} has characters Runlight slugs cannot use")),
            code: Some("import_slug_bad".into()),
            params: vec![("slug".into(), slug.clone())],
        });
    }

    let mut domain = strip_www(&text_or_empty(field(f, "domain")));
    if SHORTENER_DOMAINS.contains(&domain.as_str()) {
        domain = String::new();
    }
    let now = rl.now();
    let name = js::head16(&tpl(or(field(f, "name"), field(f, "slug"))), 100);
    let created = field(f, "createdAt").map_or(f64::NAN, js::js_number);
    let created_at = if js::opt_truthy(field(f, "createdAt")) { js::to_i64(created) } else { now };
    let clicks_in = field(Some(history), "clicks").and_then(Value::as_array).cloned().unwrap_or_default();
    let daily_in = field(Some(history), "daily").and_then(Value::as_array).cloned().unwrap_or_default();
    let failure: Mutex<Option<ImportError>> = Mutex::new(None);
    let fail = |e: ImportError| {
        let message = e.message().to_string();
        *failure.lock().unwrap_or_else(|p| p.into_inner()) = Some(e);
        DbError(message)
    };
    // Nothing in the transaction is one link's own problem (those are checked above),
    // so a failure in it is the database's, and it stops the import rather than marking the link.
    let written = store
        .transaction(|store| {
            let (id, slug, domain, url, name, site, source, source_id) = (&id, &slug, &domain, &url, &name, site, source, &source_id);
            let (clicks_in, daily_in, fail) = (&clicks_in, &daily_in, &fail);
            async move {
                let db = store.db();
                // On a database without transactions (D1), a failed earlier try can have left
                // some of this link's clicks behind. Clear them, then write the link row last,
                // so a link only counts as imported once all of its history is in.
                db.run(
                    "DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')",
                    params![id],
                )
                .await?;
                db.run("DELETE FROM rl_events WHERE link = ?", params![id]).await?;

                let mut clicks: i64 = 0;
                let mut made: HashSet<String> = HashSet::new();
                for c in clicks_in {
                    let c = Some(c);
                    let ts = match field(c, "ts") {
                        Some(Value::Number(n)) if n.is_finite() => *n,
                        _ => continue,
                    };
                    let visit_key = match field(c, "visit") {
                        None | Some(Value::Null) => format!("{}:{clicks}", js::format_number(ts)),
                        Some(v) => js::js_string(v),
                    };
                    let session = hex_id(&format!("{source}:{source_id}:{visit_key}"), 24);
                    // A visitor id lasts one day at most, as every other visitor id does.
                    let day = js::head16(&iso_string(ts).map_err(fail)?, 10);
                    let visitor = hex_id(&format!("{source}:{visit_key}:{day}"), 16);
                    let path_value = field(c, "path");
                    let path = if js::opt_truthy(path_value) { tpl(path_value) } else { format!("/{slug}") };
                    if made.insert(session.clone()) {
                        db.run("DELETE FROM rl_sessions WHERE id = ?", params![&session]).await?;
                        let host = if domain.is_empty() { "link.invalid" } else { domain.as_str() };
                        let query = field(c, "query");
                        let query = if js::opt_truthy(query) {
                            format!("?{}", tpl(query).strip_prefix('?').map_or_else(|| tpl(query), str::to_string))
                        } else {
                            String::new()
                        };
                        let page = match page_of(&format!("https://{host}{path}{query}")) {
                            Some(p) => p,
                            None => page_of(&format!("https://{host}/{slug}")).ok_or_else(|| fail(ImportError::other("TypeError: Invalid URL")))?,
                        };
                        let country = js::head16(&text_or_empty(field(c, "country")).to_uppercase(), 2);
                        let region_value = field(c, "region");
                        let region = if js::opt_truthy(region_value) {
                            let r = tpl(region_value);
                            js::head16(&(if r.contains('-') { r } else { format!("{country}-{r}") }).to_uppercase(), 10)
                        } else {
                            String::new()
                        };
                        let referrer = text_or_blank(field(c, "referrer"));
                        let a = attribute(&page, &referrer, &[]);
                        let browser = text_or_empty(field(c, "browser"));
                        let os = field(c, "os");
                        store
                            .insert_session(&SessionRow {
                                id: session.clone(),
                                site: site.to_string(),
                                visitor: visitor.clone(),
                                started_at: js::to_i64(ts),
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
                                country: if test(js_re!(r"^[A-Z]{2}$"), &country) { country.clone() } else { String::new() },
                                region: if country.is_empty() { String::new() } else { region },
                                city: js::head16(&text_or_empty(field(c, "city")), 100),
                                browser: browser_name(&browser.to_lowercase()).map_or_else(|| title(&browser), str::to_string),
                                browser_version: String::new(),
                                os: system_name(&text_or_empty(os).to_lowercase()).map_or_else(|| text_or_blank(os), str::to_string),
                                os_version: String::new(),
                                device: device_kind(&text_or_empty(field(c, "device")).to_lowercase()).unwrap_or("").to_string(),
                                screen: text_or_blank(field(c, "screen")),
                                language: text_or_blank(field(c, "language")),
                            })
                            .await?;
                        db.run("UPDATE rl_sessions SET imported = 1 WHERE id = ?", params![&session]).await?;
                    }
                    store.touch_session(&session, js::to_i64(ts), "click", &path, true).await?;
                    store
                        .insert_event(&EventRow {
                            site: site.to_string(),
                            ts: js::to_i64(ts),
                            kind: "click".into(),
                            visitor,
                            session,
                            pageview: String::new(),
                            path: js::head16(&path, 1000),
                            hostname: domain.clone(),
                            title: String::new(),
                            name: slug.clone(),
                            props: None,
                            engaged_ms: 0,
                            scroll: None,
                            link: id.clone(),
                        })
                        .await?;
                    clicks += 1;
                }

                // Counts without detail: clicks spread through each day, with no visitor or visit.
                for d in daily_in {
                    let d = Some(d);
                    let start = date_parse(&format!("{}T00:00:00Z", tpl(field(d, "day"))));
                    let count = field(d, "clicks").map_or(f64::NAN, js::js_number);
                    if !start.is_finite() || count.is_nan() || count <= 0.0 {
                        continue;
                    }
                    let n = count.min(1_000_000.0);
                    let mut i = 0.0;
                    while i < n {
                        store
                            .insert_event(&EventRow {
                                site: site.to_string(),
                                ts: js::to_i64(start + (((i + 0.5) / n) * 86_400_000.0).floor()),
                                kind: "click".into(),
                                visitor: String::new(),
                                session: String::new(),
                                pageview: String::new(),
                                path: format!("/{slug}"),
                                hostname: domain.clone(),
                                title: String::new(),
                                name: slug.clone(),
                                props: Some(Object::new().with("imported", "daily")),
                                engaged_ms: 0,
                                scroll: None,
                                link: id.clone(),
                            })
                            .await?;
                        clicks += 1;
                        i += 1.0;
                    }
                }
                if !domain.is_empty() {
                    store.add_link_domain(domain, site, now).await?;
                }
                store
                    .insert_link(&LinkRow {
                        id: id.clone(),
                        site: site.to_string(),
                        domain: domain.clone(),
                        slug: slug.clone(),
                        name: name.clone(),
                        url: url.clone(),
                        created_at,
                        updated_at: created_at,
                    })
                    .await?;
                Ok(clicks)
            }
        })
        .await;
    let clicks = match written {
        Ok(n) => n,
        Err(e) => return Err(failure.into_inner().unwrap_or_else(|p| p.into_inner()).unwrap_or(ImportError::from(e))),
    };
    if !domain.is_empty() {
        rl.forget_link_domains();
    }
    Ok(WriteResult { status: WriteStatus::Created, clicks: clicks as f64, reason: None, code: None, params: vec![] })
}
