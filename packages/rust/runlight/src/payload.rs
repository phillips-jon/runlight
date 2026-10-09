//! What the tracker sends, after validation. Anything malformed is dropped.

use crate::http::Url;
use crate::js::{self, Object, Value};

/// A tracker hit.
#[derive(Clone, Debug, PartialEq)]
pub struct Payload {
    /// `pageview`, `event`, or `engagement`.
    pub kind: &'static str,
    /// The site id the script was given, or empty.
    pub site: String,
    /// The page's URL.
    pub url: Url,
    /// The referrer.
    pub referrer: String,
    /// The page's title.
    pub title: String,
    /// The screen's width.
    pub screen_width: Option<i64>,
    /// The screen's height.
    pub screen_height: Option<i64>,
    /// The browser's language.
    pub language: String,
    /// An event's name.
    pub name: String,
    /// An event's properties.
    pub props: Option<Object>,
    /// The pageview's id.
    pub pageview_id: String,
    /// Engaged time an engagement ping reports.
    pub engaged_ms: i64,
    /// The deepest scroll, percent.
    pub scroll: Option<i64>,
}

/// The longest body a tracker hit can be.
pub const MAX_BODY: usize = 8 * 1024;
/// One engagement ping covers at most the 30 minutes a session can idle.
const MAX_ENGAGED_MS: i64 = 30 * 60 * 1000;
const MAX_PROPS: usize = 30;

fn str_(value: Option<&Value>, max: usize) -> String {
    match value {
        Some(Value::String(s)) => js::head16(s, max),
        _ => String::new(),
    }
}

fn int(value: Option<&Value>, min: i64, max: i64) -> Option<i64> {
    let n = value?.finite()?;
    Some((js::round(n) as i64).clamp(min, max).min(max).max(min))
}

fn props(value: Option<&Value>) -> Option<Object> {
    let Some(Value::Object(o)) = value else { return None };
    let mut out = Object::new();
    let mut count = 0;
    for (key, raw) in o.iter() {
        if count >= MAX_PROPS {
            break;
        }
        let k = js::head16(js::trim(key), 60);
        if k.is_empty() {
            continue;
        }
        let text = match raw {
            Value::String(s) => js::head16(s, 500),
            Value::Number(n) if n.is_finite() => js::format_number(*n),
            Value::Bool(b) => b.to_string(),
            _ => continue,
        };
        // `out["__proto__"] = text` sets no property of its own in JavaScript, and still counts.
        if k != "__proto__" {
            out.set(k, text);
        }
        count += 1;
    }
    (count > 0).then_some(out)
}

/// The hit in a tracker's body, or `None` when anything about it is wrong.
pub fn parse_payload(text: &str) -> Option<Payload> {
    if js::len16(text) > MAX_BODY {
        return None;
    }
    let body = js::parse(text).ok()?;
    if !body.is_object() {
        return None;
    }
    let kind = match body.get("k") {
        Some(Value::String(k)) if k == "pageview" => "pageview",
        Some(Value::String(k)) if k == "event" => "event",
        Some(Value::String(k)) if k == "engagement" => "engagement",
        _ => return None,
    };
    let url = Url::parse(&str_(body.get("u"), 2048))?;
    let protocol = url.protocol();
    if protocol != "http:" && protocol != "https:" {
        return None;
    }
    let name = js::trim(&str_(body.get("n"), 120)).to_string();
    if kind == "event" && name.is_empty() {
        return None;
    }
    let pageview_id = str_(body.get("i"), 32);
    if !pageview_id.is_empty() && !pageview_id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return None;
    }
    if kind == "engagement" && pageview_id.is_empty() {
        return None;
    }
    Some(Payload {
        kind,
        site: str_(body.get("s"), 64),
        url,
        referrer: str_(body.get("r"), 2048),
        title: str_(body.get("t"), 500),
        screen_width: int(body.get("w"), 0, 20000),
        screen_height: int(body.get("h"), 0, 20000),
        language: str_(body.get("l"), 35),
        name,
        props: if kind == "event" { props(body.get("p")) } else { None },
        pageview_id,
        engaged_ms: if kind == "engagement" { int(body.get("e"), 0, MAX_ENGAGED_MS).unwrap_or(0) } else { 0 },
        scroll: int(body.get("d"), 0, 100),
    })
}
