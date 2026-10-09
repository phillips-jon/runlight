//! JavaScript's `URL`, on the `url` crate's WHATWG parser, with the parts
//! named and written as `URL`'s getters write them.

use super::SearchParams;

/// A parsed URL, as `new URL(input, base)` makes one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Url {
    inner: url::Url,
}

impl Url {
    /// `new URL(input)`, or `None` where it throws.
    pub fn parse(input: &str) -> Option<Url> {
        url::Url::parse(input).ok().map(|inner| Url { inner })
    }

    /// `new URL(input, base)`, or `None` where it throws.
    pub fn parse_with_base(input: &str, base: &str) -> Option<Url> {
        let base = url::Url::parse(base).ok()?;
        if let Ok(inner) = url::Url::options().base_url(Some(&base)).parse(input) {
            return Some(Url { inner });
        }
        // The url crate refuses a path of three or more slashes against a special base, where the
        // standard reads the slashes past the second as nothing, as it does in an absolute URL.
        let trimmed = input.trim_start_matches(|c: char| c <= ' ');
        let special = matches!(base.scheme(), "http" | "https" | "ws" | "wss" | "ftp" | "file");
        if special && trimmed.starts_with(['/', '\\']) {
            return Url::parse(&format!("{}:{trimmed}", base.scheme()));
        }
        None
    }

    /// `URL.canParse(input)`.
    pub fn can_parse(input: &str) -> bool {
        Url::parse(input).is_some()
    }

    /// `href`: the whole URL as written back.
    pub fn href(&self) -> String {
        self.inner.as_str().to_string()
    }

    /// `protocol`: the scheme and its colon, `https:`.
    pub fn protocol(&self) -> String {
        format!("{}:", self.inner.scheme())
    }

    /// `username`.
    pub fn username(&self) -> String {
        self.inner.username().to_string()
    }

    /// `password`.
    pub fn password(&self) -> String {
        self.inner.password().unwrap_or("").to_string()
    }

    /// `hostname`: the host without the port, an IPv6 address in brackets.
    pub fn hostname(&self) -> String {
        self.inner.host_str().unwrap_or("").to_string()
    }

    /// `port`: empty for the scheme's default.
    pub fn port(&self) -> String {
        self.inner.port().map(|p| p.to_string()).unwrap_or_default()
    }

    /// `host`: the hostname and, unless it is the default, the port.
    pub fn host(&self) -> String {
        match self.inner.port() {
            Some(p) => format!("{}:{p}", self.hostname()),
            None => self.hostname(),
        }
    }

    /// `origin`: scheme, host, and port, or `null` for a URL without one.
    pub fn origin(&self) -> String {
        self.inner.origin().ascii_serialization()
    }

    /// `pathname`.
    pub fn pathname(&self) -> String {
        self.inner.path().to_string()
    }

    /// `search`: `?` and the query, or empty when there is none or it is
    /// empty.
    pub fn search(&self) -> String {
        match self.inner.query() {
            Some(q) if !q.is_empty() => format!("?{q}"),
            _ => String::new(),
        }
    }

    /// `hash`: `#` and the fragment, or empty.
    pub fn hash(&self) -> String {
        match self.inner.fragment() {
            Some(f) if !f.is_empty() => format!("#{f}"),
            _ => String::new(),
        }
    }

    /// `searchParams`, a copy: change it and give it back with
    /// `set_search_params`.
    pub fn search_params(&self) -> SearchParams {
        SearchParams::parse(self.inner.query().unwrap_or(""))
    }

    /// `url.search = params.toString()`, as changing `searchParams` does: no
    /// `?` at all when the params are empty.
    pub fn set_search_params(&mut self, params: &SearchParams) {
        let text = params.to_string();
        self.inner.set_query(if text.is_empty() { None } else { Some(&text) });
    }

    /// `url.search = text`.
    pub fn set_search(&mut self, text: &str) {
        let text = text.strip_prefix('?').unwrap_or(text);
        self.inner.set_query(if text.is_empty() { None } else { Some(text) });
    }

    /// `url.pathname = path`.
    pub fn set_pathname(&mut self, path: &str) {
        self.inner.set_path(path);
    }

    /// `url.hash = text`.
    pub fn set_hash(&mut self, text: &str) {
        let text = text.strip_prefix('#').unwrap_or(text);
        self.inner.set_fragment(if text.is_empty() { None } else { Some(text) });
    }

    /// `url.hostname = host`; false where the URL refuses it.
    pub fn set_hostname(&mut self, host: &str) -> bool {
        self.inner.set_host(Some(host)).is_ok()
    }

    /// `url.protocol = scheme`; false where the URL refuses it.
    pub fn set_protocol(&mut self, scheme: &str) -> bool {
        self.inner.set_scheme(scheme.trim_end_matches(':')).is_ok()
    }
}

impl std::fmt::Display for Url {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.inner.as_str())
    }
}
