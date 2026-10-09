//! JSON over HTTPS with a timeout and a few retries on rate limits and server errors
//! (importers/http.ts), plus the few pieces of JavaScript the importers lean on: `Date.parse` and
//! `new Date(ms).toISOString()`.

use std::sync::Arc;

use super::types::ImportError;
use crate::BoxFuture;
use crate::http::{FetchInit, SharedFetcher, Url};
use crate::js::{self, Value};

/// Waits this many milliseconds.
pub type Sleep = Arc<dyn Fn(f64) -> BoxFuture<'static, ()> + Send + Sync>;

/// How an importer reaches another service: the fetcher every request goes through, and how it
/// waits between tries (tests pass one that only records the wait).
#[derive(Clone)]
pub struct Http {
    fetcher: SharedFetcher,
    sleep: Sleep,
}

impl Http {
    /// Requests through `fetcher`, waiting for real between tries.
    pub fn new(fetcher: SharedFetcher) -> Http {
        Http {
            fetcher,
            sleep: Arc::new(|ms: f64| {
                Box::pin(async move {
                    if ms > 0.0 {
                        tokio::time::sleep(std::time::Duration::from_millis(ms as u64)).await;
                    }
                })
            }),
        }
    }

    /// Requests through `fetcher`, waiting with `sleep`.
    pub fn with_sleep(fetcher: SharedFetcher, sleep: Sleep) -> Http {
        Http { fetcher, sleep }
    }

    /// Waits `ms` milliseconds (`pause`).
    pub async fn pause(&self, ms: f64) {
        (self.sleep)(ms).await;
    }

    /// GET (or the method given) a URL and read its JSON, with `accept: application/json` and the
    /// headers given. A request that cannot reach the host is tried three times; a rate limit or server
    /// error four, waiting as the service asks (at most ten seconds).
    pub async fn get_json(
        &self,
        url: &str,
        method: &str,
        headers: &[(&str, &str)],
        body: Option<&str>,
    ) -> Result<Value, ImportError> {
        let mut attempt: u32 = 1;
        loop {
            let mut init = FetchInit::method(method).header("accept", "application/json").timeout(20_000);
            for (k, v) in headers {
                init = init.header(k, v);
            }
            if let Some(b) = body {
                init = init.body(b.as_bytes().to_vec());
            }
            let response = match self.fetcher.fetch(url, init).await {
                Ok(r) => r,
                Err(_) => {
                    if attempt < 3 {
                        attempt += 1;
                        continue;
                    }
                    let host = host_of(url)?;
                    return Err(ImportError::new(format!("Could not reach {host}"), "unreachable", &[("host", &host)]));
                }
            };
            if response.ok() {
                return js::parse(&response.text()).map_err(|e| ImportError::other(format!("SyntaxError: {e}")));
            }
            let status = response.status;
            if status == 401 {
                return Err(ImportError::http("The key or sign-in was refused", 401, "import_refused", &[]));
            }
            if (status == 429 || status >= 500) && attempt < 4 {
                let asked = match response.headers.get("retry-after") {
                    None => 0.0,
                    Some(v) => js::text_number(&v),
                } * 1000.0;
                let wait = if asked == 0.0 || asked.is_nan() { 800.0 * f64::from(attempt) } else { asked };
                self.pause(wait.min(10_000.0)).await;
                attempt += 1;
                continue;
            }
            let host = host_of(url)?;
            return Err(ImportError::http(
                format!("{host} answered {status}"),
                status,
                "import_status",
                &[("host", &host), ("status", &status.to_string())],
            ));
        }
    }

    /// [`Http::get_json`] with a GET and these headers.
    pub async fn get(&self, url: &str, headers: &[(&str, &str)]) -> Result<Value, ImportError> {
        self.get_json(url, "GET", headers, None).await
    }
}

/// `new URL(url).host`; a URL that does not parse is a TypeError.
fn host_of(url: &str) -> Result<String, ImportError> {
    Url::parse(url).map(|u| u.host()).ok_or_else(|| ImportError::other(format!("Invalid URL: {url}")))
}

/// `Date.parse`: milliseconds, or NaN for text that is not a date. The ISO forms are read as
/// JavaScript reads them (a date alone is UTC, a date and time without an offset is local time);
/// other forms with a date and a time, as services send them, as V8's fallback parser reads them.
pub fn date_parse(text: &str) -> f64 {
    let t = js::trim(text);
    if let Some(caps) = crate::re::js_re!(
        r"^([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:\d{2})?)?$"
    )
    .captures(t.as_bytes())
    {
        let g = |n: usize| caps.get(n).map(|m| String::from_utf8_lossy(m.as_bytes()).into_owned());
        let num = |n: usize, d: i64| g(n).and_then(|s| s.parse::<i64>().ok()).unwrap_or(d);
        let year_text = g(1).unwrap_or_default();
        let year = num(1, 0);
        let month = num(2, 1);
        let day = num(3, 1);
        let timed = g(4).is_some();
        let hour = num(4, 0);
        let minute = num(5, 0);
        let second = num(6, 0);
        let ms = g(7).map_or(0, |f| format!("{f:0<3}")[..3].parse::<i64>().unwrap_or(0));
        let days_in = match month {
            2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
            2 => 28,
            4 | 6 | 9 | 11 => 30,
            _ => 31,
        };
        if year_text == "-000000"
            || !(1..=12).contains(&month)
            || day < 1
            || day > days_in
            || hour > 24
            || minute > 59
            || second > 59
            || (hour == 24 && (minute != 0 || second != 0 || ms != 0))
        {
            return f64::NAN;
        }
        let utc = js::date_utc(year, month - 1, day, hour, minute, second, ms);
        let zone = g(8).unwrap_or_default();
        let at = if zone == "Z" || (!timed && zone.is_empty()) {
            utc
        } else if !zone.is_empty() {
            let sign = if zone.starts_with('-') { -1 } else { 1 };
            let h: i64 = zone[1..3].parse().unwrap_or(0);
            let m: i64 = zone[4..6].parse().unwrap_or(0);
            utc - sign * (h * 60 + m) * 60_000
        } else {
            local(utc)
        };
        return if at.unsigned_abs() > 8_640_000_000_000_000 { f64::NAN } else { at as f64 };
    }
    if t.is_empty() || !t.bytes().any(|b| b.is_ascii_digit()) {
        return f64::NAN;
    }
    // V8 reads a date and time with an offset in other spellings too, such as +0000 or a space for the T.
    if let Ok(ts) = t.parse::<jiff::Timestamp>() {
        return ts.as_millisecond() as f64;
    }
    if let Ok(dt) = t.parse::<jiff::civil::DateTime>()
        && let Ok(z) = dt.to_zoned(jiff::tz::TimeZone::system())
    {
        return z.timestamp().as_millisecond() as f64;
    }
    f64::NAN
}

/// A UTC reading of a local wall time, moved to the instant it is in the process's zone.
fn local(utc: i64) -> i64 {
    let Ok(ts) = jiff::Timestamp::from_millisecond(utc) else { return utc };
    let offset = jiff::tz::TimeZone::system().to_offset(ts).seconds();
    utc - i64::from(offset) * 1000
}

/// `new Date(ms).toISOString()`, or a RangeError for a time that is not one.
pub fn iso_string(ms: f64) -> Result<String, ImportError> {
    if !ms.is_finite() || ms.abs() > 8.64e15 {
        return Err(ImportError::other("RangeError: Invalid time value"));
    }
    Ok(js::iso_string(ms.trunc() as i64))
}

/// `Date.parse(value)` for a value that may not be text: NaN unless it is.
pub fn parse_value(value: Option<&Value>) -> f64 {
    match value {
        Some(Value::String(s)) => date_parse(s),
        // Date.parse(x) reads String(x) first.
        Some(v @ (Value::Number(_) | Value::Bool(_) | Value::Array(_))) => date_parse(&js::js_string(v)),
        None => f64::NAN,
        Some(Value::Null) => date_parse("null"),
        Some(Value::Object(_)) => f64::NAN,
    }
}

/// `x || fallback` for a parsed date: NaN and 0 fall back.
pub fn or_now(ms: f64, now: i64) -> f64 {
    if ms == 0.0 || ms.is_nan() { now as f64 } else { ms }
}
