//! An incoming request, shaped like the Fetch API's `Request`.

use super::{Headers, SearchParams, Url};
use crate::js::{self, Value};

/// An incoming request, shaped like the Fetch API's `Request` so the routes
/// read as the TypeScript SDK's do: an absolute URL, a method, headers, the
/// body already read, and the address the connection came from (an
/// adapter's `RequestContext.ip`), before any proxy header is read.
#[derive(Clone, Debug, Default)]
pub struct Request {
    /// The absolute URL, as `request.url` gives it.
    pub url: String,
    /// The method, upper case.
    pub method: String,
    /// The headers.
    pub headers: Headers,
    /// The body, as sent.
    pub body: Vec<u8>,
    /// The address of the connection, or empty when the adapter has none.
    pub remote_address: String,
}

impl Request {
    /// A request for a URL with a method and no body.
    pub fn new(method: &str, url: impl Into<String>) -> Request {
        Request { url: url.into(), method: method.to_ascii_uppercase(), ..Request::default() }
    }

    /// `GET url`.
    pub fn get(url: impl Into<String>) -> Request {
        Request::new("GET", url)
    }

    /// The request with this header set.
    pub fn header(mut self, name: &str, value: impl AsRef<str>) -> Request {
        self.headers.set(name, value.as_ref());
        self
    }

    /// The request with this body.
    pub fn body(mut self, body: impl Into<Vec<u8>>) -> Request {
        self.body = body.into();
        self
    }

    /// The request with the connection's address.
    pub fn remote(mut self, address: impl Into<String>) -> Request {
        self.remote_address = address.into();
        self
    }

    /// The body as text, as `request.text()` decodes it: U+FFFD where the
    /// bytes are not UTF-8, and no byte order mark.
    pub fn text(&self) -> String {
        utf8(&self.body)
    }

    /// The body as JSON, as `request.json()` reads it.
    pub fn json(&self) -> Result<Value, js::JsonError> {
        js::parse(&self.text())
    }

    /// The body as form fields, as `request.formData()` reads an
    /// application/x-www-form-urlencoded body.
    pub fn form(&self) -> SearchParams {
        SearchParams::parse_bytes(&self.body)
    }

    /// The URL, parsed.
    pub fn parsed_url(&self) -> Url {
        Url::parse(&self.url).unwrap_or_else(|| Url::parse("http://localhost/").expect("a URL"))
    }
}

/// Text as `TextDecoder` gives it: U+FFFD where the bytes are not UTF-8, and
/// no byte order mark.
pub fn utf8(bytes: &[u8]) -> String {
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    String::from_utf8_lossy(bytes).into_owned()
}
