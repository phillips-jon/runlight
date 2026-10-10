//! Fetches from addresses that other people's input names, such as the icon
//! links on a site's home page or a link domain, and only from the public
//! internet. Only https is fetched, never a private, loopback, link-local,
//! or metadata address, and redirects are followed by hand under the same
//! rules. The name is resolved and every address it gives is checked before
//! each hop, and the request is pinned to the checked addresses (the
//! Fetcher's `resolve`), so a name that answers differently a moment later
//! gets nowhere.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::BoxFuture;
use crate::http::{FetchError, FetchInit, Fetcher, Headers, Response, Url};
use crate::re::{js_re, test};

/// Refused before anything was fetched, because the address is not on the
/// public internet. The text names what was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrivateAddressError(pub String);

impl std::fmt::Display for PrivateAddressError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} is not a public address", self.0)
    }
}

impl std::error::Error for PrivateAddressError {}

/// Why a public fetch gave nothing back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PublicFetchError {
    /// The address, or one a redirect named, is off the public internet.
    Private(PrivateAddressError),
    /// The URL, or a redirect's location, is not one (JavaScript's `TypeError: Invalid URL`).
    InvalidUrl(String),
    /// The request failed, or time ran out (`FetchError::TimedOut`).
    Fetch(FetchError),
}

impl std::fmt::Display for PublicFetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PublicFetchError::Private(e) => e.fmt(f),
            PublicFetchError::InvalidUrl(_) => f.write_str("Invalid URL"),
            PublicFetchError::Fetch(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for PublicFetchError {}

impl From<PrivateAddressError> for PublicFetchError {
    fn from(e: PrivateAddressError) -> Self {
        PublicFetchError::Private(e)
    }
}

impl From<FetchError> for PublicFetchError {
    fn from(e: FetchError) -> Self {
        PublicFetchError::Fetch(e)
    }
}

/// Looks a name up: every address it resolves to, v4 and v6, as text. Empty
/// when it does not resolve. Tests pass their own in place of DNS.
pub type Lookup = Arc<dyn Fn(&str) -> BoxFuture<'static, Vec<String>> + Send + Sync>;

fn v4(text: &str) -> Option<[u32; 4]> {
    let parts: Vec<&str> = text.split('.').collect();
    if parts.len() != 4 {
        return None;
    }
    let mut out = [0u32; 4];
    for (i, p) in parts.iter().enumerate() {
        if p.is_empty() || p.len() > 3 || !p.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let n: u32 = p.parse().ok()?;
        if n > 255 {
            return None;
        }
        out[i] = n;
    }
    Some(out)
}

fn public_v4([a, b, c, _]: [u32; 4]) -> bool {
    if a == 0 || a == 10 || a == 127 || a >= 224 {
        return false;
    }
    if a == 100 && (64..128).contains(&b) {
        return false;
    }
    if a == 169 && b == 254 {
        return false;
    }
    if a == 172 && (16..32).contains(&b) {
        return false;
    }
    if a == 192 && b == 168 {
        return false;
    }
    if a == 192 && b == 0 && (c == 0 || c == 2) {
        return false;
    }
    if a == 198 && (b == 18 || b == 19) {
        return false;
    }
    if a == 198 && b == 51 && c == 100 {
        return false;
    }
    if a == 203 && b == 0 && c == 113 {
        return false;
    }
    true
}

/// `text.replace(/^\[|\]$/g, "")`.
fn unbracket(text: &str) -> &str {
    let text = text.strip_prefix('[').unwrap_or(text);
    text.strip_suffix(']').unwrap_or(text)
}

/// An IPv6 address as eight 16-bit groups, or None when it is not one.
fn v6(text: &str) -> Option<[u32; 8]> {
    let mut address = unbracket(text).split('%').next().unwrap_or("").to_lowercase();
    // A trailing IPv4 address becomes the last two groups: /(\d{1,3}(?:\.\d{1,3}){3})$/.
    if let Some(tail) = trailing_v4(&address) {
        let four = v4(&tail)?;
        address = format!(
            "{}{:x}:{:x}",
            &address[..address.len() - tail.len()],
            (four[0] << 8) | four[1],
            (four[2] << 8) | four[3]
        );
    }
    let halves: Vec<&str> = address.split("::").collect();
    if halves.len() > 2 {
        return None;
    }
    let head: Vec<&str> = if halves[0].is_empty() { vec![] } else { halves[0].split(':').collect() };
    let rest: Vec<&str> =
        if halves.len() == 2 && !halves[1].is_empty() { halves[1].split(':').collect() } else { vec![] };
    let missing = 8 - head.len() as i64 - rest.len() as i64;
    if if halves.len() == 1 { missing != 0 } else { missing < 1 } {
        return None;
    }
    let fill = if halves.len() == 2 { missing as usize } else { 0 };
    let groups: Vec<&str> =
        head.iter().copied().chain(std::iter::repeat_n("0", fill)).chain(rest.iter().copied()).collect();
    let mut out = [0u32; 8];
    for (i, g) in groups.iter().enumerate() {
        if g.is_empty() || g.len() > 4 || !g.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        out[i] = u32::from_str_radix(g, 16).ok()?;
    }
    Some(out)
}

/// The longest match of `\d{1,3}(?:\.\d{1,3}){3}` that ends the text, found
/// as JavaScript's leftmost match is.
fn trailing_v4(text: &str) -> Option<String> {
    let b = text.as_bytes();
    // The leftmost start whose greedy match reaches the end.
    for start in 0..b.len() {
        if let Some(end) = v4_run(b, start)
            && end == b.len()
        {
            return Some(text[start..].to_string());
        }
    }
    None
}

/// Where `\d{1,3}(?:\.\d{1,3}){3}` matching at `start` can end at the text's
/// end, trying each count of digits as backtracking would.
fn v4_run(b: &[u8], start: usize) -> Option<usize> {
    fn digits_then(b: &[u8], at: usize, parts_left: usize) -> Option<usize> {
        for n in (1..=3).rev() {
            if at + n <= b.len() && b[at..at + n].iter().all(u8::is_ascii_digit) {
                let end = at + n;
                if parts_left == 0 {
                    if end == b.len() {
                        return Some(end);
                    }
                } else if b.get(end) == Some(&b'.')
                    && let Some(e) = digits_then(b, end + 1, parts_left - 1)
                {
                    return Some(e);
                }
            }
        }
        None
    }
    digits_then(b, start, 3)
}

/// Whether an IP address, v4 or v6, is on the public internet. Anything that
/// is not an address is not.
pub fn public_address(ip: &str) -> bool {
    if let Some(four) = v4(ip) {
        return public_v4(four);
    }
    let Some(g) = v6(ip) else {
        return false;
    };
    let embedded = |hi: u32, lo: u32| [hi >> 8, hi & 255, lo >> 8, lo & 255];
    // IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
    if g[..5].iter().all(|x| *x == 0) && (g[5] == 0xffff || g[5] == 0) {
        return if g[5] == 0 && g[6] == 0 && g[7] <= 1 { false } else { public_v4(embedded(g[6], g[7])) };
    }
    if g[0] == 0x64 && g[1] == 0xff9b && g[2..6].iter().all(|x| *x == 0) {
        return public_v4(embedded(g[6], g[7]));
    }
    // 6to4 carries an IPv4 address in its second and third groups.
    if g[0] == 0x2002 {
        return public_v4(embedded(g[1], g[2]));
    }
    if (g[0] & 0xfe00) == 0xfc00 || (g[0] & 0xffc0) == 0xfe80 || (g[0] & 0xff00) == 0xff00 {
        return false;
    }
    // Teredo, documentation, and discard prefixes.
    if g[0] == 0x2001 && (g[1] == 0 || g[1] == 0xdb8) {
        return false;
    }
    if g[0] == 0x100 && g[1..4].iter().all(|x| *x == 0) {
        return false;
    }
    true
}

fn is_literal(host: &str) -> bool {
    v4(host).is_some() || v6(host).is_some()
}

/// Every address a name resolves to, v4 and v6, as the system resolver
/// gives them (the hosts file included). Empty when it does not resolve. An
/// address is its own answer.
pub async fn lookup(name: &str) -> Vec<String> {
    let bare = unbracket(name);
    if is_literal(bare) {
        return vec![bare.to_string()];
    }
    let mut found: Vec<String> = Vec::new();
    if let Ok(addresses) = tokio::net::lookup_host((bare, 0)).await {
        for a in addresses {
            let ip = a.ip().to_string();
            if !found.contains(&ip) {
                found.push(ip);
            }
        }
    }
    found
}

async fn resolve(name: &str, with: Option<&Lookup>) -> Vec<String> {
    match with {
        Some(f) => f(name).await,
        None => lookup(name).await,
    }
}

/// The public addresses a name resolves to, for setting up DNS records. None
/// where it does not resolve. `with` stands in for DNS in tests.
pub async fn public_addresses(name: &str, with: Option<&Lookup>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in resolve(name, with).await {
        if public_address(&a) && !out.contains(&a) {
            out.push(a);
        }
    }
    out
}

/// Whether a name resolves to an address off the public internet. False when
/// it does not resolve. `with` stands in for DNS in tests.
pub async fn resolves_privately(name: &str, with: Option<&Lookup>) -> bool {
    resolve(name, with).await.iter().any(|a| !public_address(a))
}

/// What a public fetch is sent with.
#[derive(Clone)]
pub struct PublicFetchInit {
    /// The method, `GET` by default.
    pub method: String,
    /// The body, if any.
    pub body: Option<Vec<u8>>,
    /// The whole fetch's limit, every hop included, in milliseconds.
    pub timeout_ms: u64,
    /// The headers sent on every hop.
    pub headers: Headers,
    /// How many redirects to follow. Only a GET follows any.
    pub redirects: u32,
    /// A cap on the body, passed to the Fetcher.
    pub max_bytes: Option<usize>,
    /// With `max_bytes`, the first bytes rather than a failure.
    pub truncate: bool,
    /// Stands in for DNS, in tests.
    pub lookup: Option<Lookup>,
}

impl PublicFetchInit {
    /// A fetch with this time limit, no redirects, and no other options.
    pub fn new(timeout_ms: u64) -> PublicFetchInit {
        PublicFetchInit {
            method: "GET".into(),
            body: None,
            timeout_ms,
            headers: Headers::new(),
            redirects: 0,
            max_bytes: None,
            truncate: false,
            lookup: None,
        }
    }
}

/// Requests an https URL on the public internet, following up to `redirects`
/// redirects that stay on it, within `timeout_ms` in all. Fails with
/// `Private` for an address off it, and `Fetch(FetchError::TimedOut)` when
/// time runs out. A redirect past the last one comes back as it is, as
/// does any redirect for a request other than a GET.
pub async fn public_fetch(
    fetcher: &dyn Fetcher,
    target: &str,
    init: &PublicFetchInit,
) -> Result<Response, PublicFetchError> {
    let until = Instant::now() + Duration::from_millis(init.timeout_ms);
    let left = || until.saturating_duration_since(Instant::now());
    let mut url = Url::parse(target).ok_or_else(|| PublicFetchError::InvalidUrl(target.to_string()))?;
    let mut hop: u32 = 0;
    let method = init.method.to_ascii_uppercase();
    let redirects = if method == "GET" { init.redirects } else { 0 };
    loop {
        if url.protocol() != "https:" {
            return Err(PrivateAddressError(url.href()).into());
        }
        let host = unbracket(&url.hostname()).to_lowercase();
        let literal = is_literal(&host);
        if literal && !public_address(&host) {
            return Err(PrivateAddressError(host).into());
        }
        if host == "localhost" || host.ends_with(".localhost") {
            return Err(PrivateAddressError(host).into());
        }
        let mut options = FetchInit {
            method: method.clone(),
            headers: init.headers.clone(),
            body: init.body.clone(),
            manual_redirect: true,
            max_bytes: init.max_bytes,
            truncate: init.truncate,
            ..FetchInit::default()
        };
        let port = url.port().parse::<u16>().unwrap_or(443);
        if literal {
            // Pinned to itself, so the request goes straight there and never through a proxy.
            options.resolve = host.parse::<IpAddr>().map(|ip| vec![(host.clone(), port, vec![ip])]).unwrap_or_default();
        } else {
            // The address checked is the address used: every one the name gives must be public, and the
            // connection is pinned to them, so a second lookup cannot hand back another.
            let addresses = match tokio::time::timeout(left(), resolve(&host, init.lookup.as_ref())).await {
                Ok(found) => found,
                Err(_) => return Err(FetchError::TimedOut.into()),
            };
            if addresses.is_empty() {
                return Err(FetchError::Failed(format!("getaddrinfo ENOTFOUND {host}")).into());
            }
            if addresses.iter().any(|a| !public_address(a)) {
                return Err(PrivateAddressError(host).into());
            }
            let ips: Vec<IpAddr> = addresses.iter().filter_map(|a| unbracket(a).parse().ok()).collect();
            options.resolve = vec![(host.clone(), port, ips)];
        }
        let remaining = left();
        let ms = remaining.as_millis() as u64;
        if ms == 0 {
            return Err(FetchError::TimedOut.into());
        }
        options.timeout_ms = ms;
        let href = url.href();
        let answer = match tokio::time::timeout(remaining, fetcher.fetch(&href, options)).await {
            Err(_) => return Err(FetchError::TimedOut.into()),
            // Whichever way the request gave up, the caller hears that time ran out.
            Ok(Err(e)) if e == FetchError::TimedOut || Instant::now() >= until => {
                return Err(FetchError::TimedOut.into());
            }
            Ok(Err(e)) => return Err(e.into()),
            Ok(Ok(answer)) => answer,
        };
        let location = answer.headers.get("location").unwrap_or_default();
        if answer.status < 300 || answer.status >= 400 || location.is_empty() || hop >= redirects {
            return Ok(answer);
        }
        url = Url::parse_with_base(&location, &href).ok_or(PublicFetchError::InvalidUrl(location))?;
        hop += 1;
    }
}

/// An install on this machine: http://localhost or http://127.0.0.1, with any port.
fn local_install(url: &str) -> bool {
    test(js_re!(r"^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)"), url)
}

/// Whether an address can be another Runlight install's: https, or, with
/// `local`, an install on this machine, which only code can allow.
pub fn install_address(url: &str, local: bool) -> bool {
    test(js_re!(r"^https://[^/]+"), url) || (local && local_install(url))
}

/// Fetches from another Runlight install, which someone signed in named: a
/// public address as [`public_fetch`] fetches it, with no redirect followed,
/// so a token sent there goes nowhere else. With `local`, an install on this
/// machine is fetched as it is, still without following a redirect. A
/// refused address fails as a request that could not connect.
pub(crate) async fn install_fetch(
    fetcher: &dyn Fetcher,
    url: &str,
    mut init: FetchInit,
    local: bool,
    lookup: Option<&Lookup>,
) -> Result<Response, FetchError> {
    if local && local_install(url) {
        init.manual_redirect = true;
        return fetcher.fetch(url, init).await;
    }
    let options = PublicFetchInit {
        method: init.method,
        body: init.body,
        timeout_ms: init.timeout_ms,
        headers: init.headers,
        redirects: 0,
        max_bytes: init.max_bytes,
        truncate: init.truncate,
        lookup: lookup.cloned(),
    };
    public_fetch(fetcher, url, &options).await.map_err(|e| match e {
        PublicFetchError::Fetch(e) => e,
        e => FetchError::Failed(e.to_string()),
    })
}
