//! Visit history from a CSV file, in one of two shapes: Umami's data export (one row per pageview or
//! event, as in its website_event table) or Runlight's own, documented on the dashboard docs page
//! (importers/csvvisits.ts). The dashboard reads the file, sorts it with `row_time`, and sends it in
//! batches; the server turns each row into a hit with `csv_hit`. Nothing here touches a database.

use super::http::date_parse;
use super::visits::{HitKind, ImportedHit};
use crate::http::Url;
use crate::js::{self, Object, Value};
use crate::re::{js_re, test};

/// The two shapes a file can be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CsvFormat {
    /// Umami's data export.
    Umami,
    /// Runlight's own columns.
    Runlight,
}

/// At most this many rows in one request.
pub const CSV_BATCH: usize = 2000;

/// Which shape a file is, from its header row (lower case, as the dashboard reads it).
pub fn csv_format(columns: &[&str]) -> Option<CsvFormat> {
    let has = |c: &str| columns.contains(&c);
    if has("created_at") && has("url_path") {
        return Some(CsvFormat::Umami);
    }
    if has("time") && (has("path") || has("url")) {
        return Some(CsvFormat::Runlight);
    }
    None
}

/// A row's column as text: `None` when it has none.
fn get<'a>(row: &'a Object, name: &str) -> Option<&'a str> {
    row.get(name).and_then(Value::as_str)
}

/// A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56" (both
/// read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or milliseconds.
pub fn row_time(row: &Object, format: CsvFormat) -> f64 {
    let text = js::trim(get(row, if format == CsvFormat::Umami { "created_at" } else { "time" }).unwrap_or(""));
    if text.is_empty() {
        return f64::NAN;
    }
    if test(js_re!(r"^\d+(\.\d+)?$"), text) {
        let n = js::text_number(text);
        return if n < 1e12 { js::round(n * 1000.0) } else { js::round(n) };
    }
    let iso = text.replacen(' ', "T", 1);
    if test(js_re!(r"[zZ]|[+-]\d\d:?\d\d$"), &iso) || !test(js_re!(r"T\d"), &iso) {
        date_parse(&iso)
    } else {
        date_parse(&format!("{iso}Z"))
    }
}

/// The first of the columns with something in it, trimmed.
fn cell(row: &Object, names: &[&str]) -> String {
    for n in names {
        if let Some(v) = get(row, n) {
            let t = js::trim(v);
            if !t.is_empty() {
                return t.to_string();
            }
        }
    }
    String::new()
}

/// A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids.
fn own_key(row: &Object) -> String {
    let mut entries: Vec<(&str, &Value)> = row.iter().collect();
    entries.sort_by(|(a, _), (b, _)| a.encode_utf16().cmp(b.encode_utf16()));
    let list: Vec<Value> = entries.into_iter().map(|(k, v)| Value::Array(vec![Value::from(k), v.clone()])).collect();
    format!("row:{}", js::stringify(&Value::Array(list)))
}

/// Whether text starts with a scheme and `//`.
fn has_scheme(value: &str) -> bool {
    test(js_re!(r"(?i)^[a-z][a-z0-9+.-]*://"), value)
}

/// A referrer as a full address: a bare domain gains https://.
fn full_referrer(value: &str) -> String {
    if value.is_empty() {
        String::new()
    } else if has_scheme(value) {
        value.to_string()
    } else {
        format!("https://{value}")
    }
}

/// One row as a hit and the namespace its ids are made in, or `None` for a row that is not a pageview or
/// a named event, or has no time. Umami rows use the namespace the Umami API import does, so the same
/// visits brought in both ways get the same ids. `row` holds text, its column names trimmed and lower case.
pub fn csv_hit(row: &Object, format: CsvFormat) -> Option<(String, ImportedHit)> {
    let ts = row_time(row, format);
    if !ts.is_finite() {
        return None;
    }
    let c = |names: &[&str]| cell(row, names);
    if format == CsvFormat::Umami {
        let kind = Some(c(&["event_type"])).filter(|t| !t.is_empty()).unwrap_or_else(|| "1".into());
        let name = c(&["event_name"]);
        if kind != "1" && !(kind == "2" && !name.is_empty()) {
            return None;
        }
        let website = c(&["website_id"]);
        let referrer = {
            let domain = c(&["referrer_domain"]);
            if domain.is_empty() {
                String::new()
            } else {
                let query = c(&["referrer_query"]);
                let path = Some(c(&["referrer_path"])).filter(|p| !p.is_empty()).unwrap_or_else(|| "/".into());
                let query = if query.is_empty() {
                    String::new()
                } else {
                    format!("?{}", query.strip_prefix('?').unwrap_or(&query))
                };
                format!("https://{domain}{path}{query}")
            }
        };
        let key = Some(c(&["session_id", "visit_id"])).filter(|k| !k.is_empty()).unwrap_or_else(|| own_key(row));
        return Some((
            if website.is_empty() { "umami-csv".into() } else { format!("umami-visits:{website}") },
            ImportedHit {
                ts,
                key,
                kind: if kind == "1" { HitKind::Pageview } else { HitKind::Event },
                hostname: c(&["hostname"]),
                path: Some(c(&["url_path"])).filter(|p| !p.is_empty()).unwrap_or_else(|| "/".into()),
                query: c(&["url_query"]),
                referrer,
                title: c(&["page_title"]),
                name: if kind == "2" { name } else { String::new() },
                country: c(&["country"]),
                region: c(&["subdivision1", "region"]),
                city: c(&["city"]),
                browser: c(&["browser"]),
                os: c(&["os"]),
                device: c(&["device"]),
                screen: c(&["screen"]),
                language: c(&["language"]),
            },
        ));
    }
    // Runlight's own shape: a full url, or a path (with its query) and a hostname.
    let mut hostname = c(&["hostname"]);
    let mut path = c(&["path"]);
    let mut query = String::new();
    let url = c(&["url"]);
    if !url.is_empty() {
        let u = Url::parse(&if has_scheme(&url) { url.clone() } else { format!("https://{url}") })?;
        if hostname.is_empty() {
            hostname = u.hostname();
        }
        path = u.pathname();
        query = js::slice16(&u.search(), 1, i64::MAX);
    } else if let Some(at) = path.find('?') {
        query = path[at + 1..].to_string();
        path.truncate(at);
    }
    if !path.starts_with('/') {
        path = format!("/{path}");
    }
    let name = c(&["event"]);
    Some((
        "csv".into(),
        ImportedHit {
            ts,
            // Without a visitor column every row is its own visit.
            key: Some(c(&["visitor"])).filter(|k| !k.is_empty()).unwrap_or_else(|| own_key(row)),
            kind: if name.is_empty() { HitKind::Pageview } else { HitKind::Event },
            hostname,
            path,
            query,
            referrer: full_referrer(&c(&["referrer"])),
            title: c(&["title"]),
            name,
            country: c(&["country"]),
            region: c(&["region"]),
            city: c(&["city"]),
            browser: c(&["browser"]),
            os: c(&["os"]),
            device: c(&["device"]),
            screen: c(&["screen"]),
            language: c(&["language"]),
        },
    ))
}
