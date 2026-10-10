//! Outgoing requests: the Rust stand-in for JavaScript's `fetch()`.

use std::net::IpAddr;
use std::sync::Arc;

use super::{Headers, Response};
use crate::BoxFuture;

/// What a request is sent with, the keys fetch's `init` takes where they
/// apply.
#[derive(Clone, Debug)]
pub struct FetchInit {
    /// The method, `GET` by default.
    pub method: String,
    /// The headers.
    pub headers: Headers,
    /// The body, if any.
    pub body: Option<Vec<u8>>,
    /// `redirect: "manual"`: a 3xx answer comes back as it is.
    pub manual_redirect: bool,
    /// The whole request's limit, in milliseconds.
    pub timeout_ms: u64,
    /// Stop reading past this many bytes: `FetchError::TooLong`, or with
    /// `truncate`, the first `max_bytes` (the start of a page).
    pub max_bytes: Option<usize>,
    /// With `max_bytes`, hand back the first bytes rather than fail.
    pub truncate: bool,
    /// Addresses a host name is pinned to, so an address checked is the one
    /// connected to: the host, its port, and its addresses.
    pub resolve: Vec<(String, u16, Vec<IpAddr>)>,
}

impl Default for FetchInit {
    fn default() -> Self {
        FetchInit {
            method: "GET".into(),
            headers: Headers::new(),
            body: None,
            manual_redirect: false,
            timeout_ms: 30_000,
            max_bytes: None,
            truncate: false,
            resolve: Vec::new(),
        }
    }
}

impl FetchInit {
    /// A request with this method.
    pub fn method(method: &str) -> FetchInit {
        FetchInit { method: method.to_ascii_uppercase(), ..FetchInit::default() }
    }

    /// The init with this header set.
    pub fn header(mut self, name: &str, value: impl AsRef<str>) -> FetchInit {
        self.headers.set(name, value.as_ref());
        self
    }

    /// The init with this body.
    pub fn body(mut self, body: impl Into<Vec<u8>>) -> FetchInit {
        self.body = Some(body.into());
        self
    }

    /// The init with this time limit.
    pub fn timeout(mut self, ms: u64) -> FetchInit {
        self.timeout_ms = ms;
        self
    }

    /// The init with a cap on the body read.
    pub fn max_bytes(mut self, max: usize) -> FetchInit {
        self.max_bytes = Some(max);
        self
    }
}

/// No answer came back: refused, timed out, bad TLS, or a body past its cap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FetchError {
    /// The request failed, with the reason.
    Failed(String),
    /// Time ran out.
    TimedOut,
    /// The body was longer than `max_bytes`.
    TooLong(usize),
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FetchError::Failed(m) => f.write_str(m),
            FetchError::TimedOut => f.write_str("The operation was aborted due to timeout"),
            FetchError::TooLong(n) => write!(f, "Body over {n} bytes"),
        }
    }
}

impl std::error::Error for FetchError {}

/// Everything that calls another server (mail services, importers,
/// connected installs, the assistant's providers, site icons) goes through
/// one, so tests and apps can pass their own.
pub trait Fetcher: Send + Sync {
    /// Sends the request and reads the answer.
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>>;
}

/// A shared Fetcher.
pub type SharedFetcher = Arc<dyn Fetcher>;

/// The default Fetcher: reqwest, on rustls with the platform's roots.
#[cfg(feature = "transport")]
#[derive(Clone)]
pub struct ReqwestFetcher {
    follow: reqwest::Client,
    manual: reqwest::Client,
}

#[cfg(feature = "transport")]
impl Default for ReqwestFetcher {
    fn default() -> Self {
        ReqwestFetcher::new()
    }
}

#[cfg(feature = "transport")]
impl ReqwestFetcher {
    /// A Fetcher with clients of its own.
    pub fn new() -> ReqwestFetcher {
        ReqwestFetcher { follow: client(false, &[]).unwrap_or_default(), manual: client(true, &[]).unwrap_or_default() }
    }
}

/// A client, pinned to the addresses given. A pinned client never goes through a proxy, as a proxy
/// would look the name up itself, and fails rather than fall back to one that is not pinned.
#[cfg(feature = "transport")]
fn client(manual: bool, resolve: &[(String, u16, Vec<IpAddr>)]) -> Result<reqwest::Client, FetchError> {
    let mut b = reqwest::Client::builder()
        .redirect(if manual { reqwest::redirect::Policy::none() } else { reqwest::redirect::Policy::limited(20) })
        .connect_timeout(std::time::Duration::from_secs(15));
    if !resolve.is_empty() {
        b = b.no_proxy();
    }
    for (host, port, addresses) in resolve {
        let addrs: Vec<std::net::SocketAddr> =
            addresses.iter().map(|ip| std::net::SocketAddr::new(*ip, *port)).collect();
        b = b.resolve_to_addrs(host, &addrs);
    }
    b.build().map_err(|e| FetchError::Failed(e.to_string()))
}

#[cfg(feature = "transport")]
impl Fetcher for ReqwestFetcher {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            let pinned;
            let http = if !init.resolve.is_empty() {
                pinned = client(init.manual_redirect, &init.resolve)?;
                &pinned
            } else if init.manual_redirect {
                &self.manual
            } else {
                &self.follow
            };
            let method =
                reqwest::Method::from_bytes(init.method.as_bytes()).map_err(|e| FetchError::Failed(e.to_string()))?;
            let mut req = http.request(method, url).timeout(std::time::Duration::from_millis(init.timeout_ms.max(1)));
            for (name, values) in init.headers.all() {
                for v in values {
                    req = req.header(name.as_str(), v.as_str());
                }
            }
            if let Some(body) = init.body {
                req = req.body(body);
            }
            let fail = |e: reqwest::Error| {
                if e.is_timeout() { FetchError::TimedOut } else { FetchError::Failed(e.to_string()) }
            };
            let mut answer = req.send().await.map_err(fail)?;
            let status = answer.status().as_u16();
            let mut headers = Headers::new();
            for (name, value) in answer.headers() {
                headers.append(name.as_str(), &String::from_utf8_lossy(value.as_bytes()));
            }
            let mut body = Vec::new();
            loop {
                match answer.chunk().await {
                    Ok(Some(chunk)) => {
                        if let Some(max) = init.max_bytes
                            && body.len() + chunk.len() > max
                        {
                            if init.truncate {
                                body.extend_from_slice(&chunk[..max - body.len()]);
                                break;
                            }
                            return Err(FetchError::TooLong(max));
                        }
                        body.extend_from_slice(&chunk);
                    }
                    Ok(None) => break,
                    Err(e) => return Err(fail(e)),
                }
            }
            Ok(Response { status, headers, body })
        })
    }
}

/// The Fetcher used when none is given: [`ReqwestFetcher`] with the
/// `transport` feature, else one that fails every request.
pub fn default_fetcher() -> SharedFetcher {
    #[cfg(feature = "transport")]
    {
        Arc::new(ReqwestFetcher::new())
    }
    #[cfg(not(feature = "transport"))]
    {
        Arc::new(NoFetcher)
    }
}

/// A Fetcher that fails every request, for a build without `transport`.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoFetcher;

impl Fetcher for NoFetcher {
    fn fetch<'a>(&'a self, _url: &'a str, _init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async { Err(FetchError::Failed("fetch failed: Runlight was built without a transport".into())) })
    }
}
