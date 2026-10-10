//! A site's icon, for the dashboard header: the best icon its home page
//! links to, or /favicon.ico. Fetched from the site's own configured origin
//! (never from request input), cached in memory for a day.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use tokio::sync::OnceCell;

use crate::http::{Fetcher, Headers, Response, Url};
use crate::js;
use crate::safefetch::{Lookup, PublicFetchInit, public_fetch};

const TIMEOUT_MS: u64 = 4000;
const MAX_BYTES: usize = 256 * 1024;
const DAY: i64 = 86_400_000;
/// A few hundred sites at most; past that the oldest go, so the cache cannot grow without end.
const CACHE_SIZE: usize = 500;

/// An icon: its bytes and its media type (TypeScript's `{ body, type }`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Icon {
    /// The image.
    pub body: Vec<u8>,
    /// Its media type, lower case, without parameters.
    pub content_type: String,
}

/// The icons looked up, oldest first, with when.
struct Cache {
    order: Vec<String>,
    entries: HashMap<String, (i64, Option<Icon>)>,
}

static CACHE: LazyLock<Mutex<Cache>> =
    LazyLock::new(|| Mutex::new(Cache { order: Vec::new(), entries: HashMap::new() }));

/// One lookup under way, which every caller for the origin waits on.
type Pending = Arc<OnceCell<Option<Icon>>>;

/// Lookups under way, so many dashboards opening at once share one.
static PENDING: LazyLock<Mutex<HashMap<String, Pending>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// The value after a name at byte `at`, as
/// `(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?` reads it, and where it ends.
fn value_at(tag: &str, mut at: usize) -> Option<(&str, usize)> {
    let skip = |at: usize| at + tag[at..].chars().take_while(|c| js::is_space(*c)).map(char::len_utf8).sum::<usize>();
    at = skip(at);
    if !tag[at..].starts_with('=') {
        return None;
    }
    at = skip(at + 1);
    let rest = &tag[at..];
    for quote in ['"', '\''] {
        if let Some(inner) = rest.strip_prefix(quote)
            && let Some(end) = inner.find(quote)
        {
            return Some((&inner[..end], at + end + 2));
        }
    }
    let len: usize = rest.chars().take_while(|c| !js::is_space(*c) && *c != '>').map(char::len_utf8).sum();
    if len == 0 { None } else { Some((&rest[..len], at + len)) }
}

fn word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// A character that cannot be in an attribute's name: `[\s"'>/=]`.
fn not_name(c: char) -> bool {
    js::is_space(c) || matches!(c, '"' | '\'' | '>' | '/' | '=')
}

/// A tag's attributes, read one after another so a name inside another
/// (data-rel) or inside a value (title="rel=icon") is never taken for one.
/// The first of a repeated name counts, as in a browser. Each match of
/// `/([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g` after `<link`.
fn attrs(tag: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut at = "<link".len();
    while at < tag.len() {
        let c = tag[at..].chars().next().unwrap_or(' ');
        if not_name(c) {
            at += c.len_utf8();
            continue;
        }
        let len: usize = tag[at..].chars().take_while(|c| !not_name(*c)).map(char::len_utf8).sum();
        let name = tag[at..at + len].to_lowercase();
        at += len;
        let value = match value_at(tag, at) {
            Some((value, end)) => {
                at = end;
                js::trim(value).to_string()
            }
            None => String::new(),
        };
        out.entry(name).or_insert(value);
    }
    out
}

/// Every match of `/<link\b[^>]*>/gi`.
fn link_tags(html: &str) -> Vec<&str> {
    let b = html.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i + 5 <= b.len() {
        if b[i..i + 5].eq_ignore_ascii_case(b"<link") && !b.get(i + 5).is_some_and(|c| word(*c)) {
            if let Some(end) = html[i..].find('>') {
                out.push(&html[i..i + end + 1]);
                i += end + 1;
                continue;
            }
            // No '>' after this one, so none after any later one either.
            break;
        }
        i += 1;
    }
    out
}

/// Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG
/// icons, then any icon.
pub fn icon_links(html: &str, base: &str) -> Vec<String> {
    let mut found: Vec<(String, u8)> = Vec::new();
    for tag in link_tags(html) {
        let attributes = attrs(tag);
        let get = |name: &str| attributes.get(name).map_or("", String::as_str);
        let rel_text = get("rel").to_lowercase();
        let rel: Vec<&str> = rel_text.split(js::is_space).collect();
        let href = get("href");
        if href.is_empty() || !(rel.contains(&"icon") || rel.contains(&"apple-touch-icon")) {
            continue;
        }
        let Some(url) = Url::parse_with_base(href, base) else {
            continue;
        };
        let url = url.href();
        // Only https, which is all the fetch below takes.
        if !url.starts_with("https://") {
            continue;
        }
        let kind = get("type").to_lowercase();
        let score = if rel.contains(&"apple-touch-icon") {
            3
        } else if kind.contains("svg") || url.ends_with(".svg") {
            2
        } else if kind.contains("png") || url.ends_with(".png") {
            1
        } else {
            0
        };
        found.push((url, score));
    }
    // A stable sort, as Array.prototype.sort is.
    found.sort_by_key(|f| std::cmp::Reverse(f.1));
    found.into_iter().map(|(url, _)| url).collect()
}

/// A GET of a public https address, with redirects followed only to public addresses too.
async fn get(
    fetcher: &dyn Fetcher,
    url: &str,
    lookup: Option<&Lookup>,
    max_bytes: usize,
    truncate: bool,
) -> Option<Response> {
    let init = PublicFetchInit {
        timeout_ms: TIMEOUT_MS,
        headers: Headers::new().with("user-agent", "Runlight (+https://runlight.sh)"),
        redirects: 3,
        max_bytes: Some(max_bytes),
        truncate,
        lookup: lookup.cloned(),
        ..PublicFetchInit::new(TIMEOUT_MS)
    };
    public_fetch(fetcher, url, &init).await.ok()
}

async fn image(fetcher: &dyn Fetcher, url: &str, lookup: Option<&Lookup>) -> Option<Icon> {
    // An image must arrive whole, so one longer than the cap is no use.
    let response = get(fetcher, url, lookup, MAX_BYTES, false).await?;
    if !response.ok() {
        return None;
    }
    let header = response.headers.get("content-type").unwrap_or_default();
    let content_type = js::trim(header.split(';').next().unwrap_or("")).to_lowercase();
    if !content_type.starts_with("image/") {
        return None;
    }
    let declared = js::text_number(&response.headers.get("content-length").unwrap_or_default());
    if declared > MAX_BYTES as f64 || response.body.is_empty() || response.body.len() > MAX_BYTES {
        return None;
    }
    Some(Icon { body: response.body, content_type })
}

/// The site's icon, or None when it has none that can be fetched. `now` is
/// the clock, in milliseconds.
pub async fn fetch_icon(fetcher: &dyn Fetcher, origin: &str, now: i64) -> Option<Icon> {
    fetch_icon_with(fetcher, origin, now, None).await
}

/// [`fetch_icon`] with `lookup` standing in for DNS, in tests.
pub async fn fetch_icon_with(fetcher: &dyn Fetcher, origin: &str, now: i64, lookup: Option<&Lookup>) -> Option<Icon> {
    if let Ok(cache) = CACHE.lock()
        && let Some((at, icon)) = cache.entries.get(origin)
        && now - at < if icon.is_some() { DAY } else { DAY / 24 }
    {
        return icon.clone();
    }
    let cell = match PENDING.lock() {
        Ok(mut pending) => pending.entry(origin.to_string()).or_insert_with(|| Arc::new(OnceCell::new())).clone(),
        Err(_) => Arc::new(OnceCell::new()),
    };
    let icon = cell.get_or_init(|| look_up(fetcher, origin, now, lookup)).await.clone();
    if let Ok(mut pending) = PENDING.lock()
        && pending.get(origin).is_some_and(|c| Arc::ptr_eq(c, &cell))
    {
        pending.remove(origin);
    }
    icon
}

async fn look_up(fetcher: &dyn Fetcher, origin: &str, now: i64, lookup: Option<&Lookup>) -> Option<Icon> {
    let mut icon = None;
    // The head is all that is needed, so a huge page is not read to the end.
    let page = get(fetcher, &format!("{origin}/"), lookup, 200_000, true).await;
    if let Some(page) = page
        && page.ok()
        && page.headers.get("content-type").unwrap_or_default().contains("html")
    {
        // TextDecoder: invalid bytes become U+FFFD, and a leading byte order mark goes.
        let text = String::from_utf8_lossy(&page.body);
        let html = text.strip_prefix('\u{feff}').unwrap_or(&text);
        // A Response from the Fetcher has no url of its own, as the one Node's https module gives, so links resolve against the origin.
        for url in icon_links(html, origin).into_iter().take(4) {
            icon = image(fetcher, &url, lookup).await;
            if icon.is_some() {
                break;
            }
        }
    }
    if icon.is_none() {
        icon = image(fetcher, &format!("{origin}/favicon.ico"), lookup).await;
    }
    if let Ok(mut cache) = CACHE.lock() {
        // As a Map's set, an origin seen before keeps its place.
        if cache.entries.insert(origin.to_string(), (now, icon.clone())).is_none() {
            cache.order.push(origin.to_string());
        }
        if cache.order.len() > CACHE_SIZE {
            let oldest = cache.order.remove(0);
            cache.entries.remove(&oldest);
        }
    }
    icon
}
