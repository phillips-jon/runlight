//! An answer, shaped like the Fetch API's `Response`.

use super::Headers;
use super::request::utf8;
use crate::js::{self, Value};

/// An answer: a status, headers, and the whole body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Response {
    /// The status code.
    pub status: u16,
    /// The headers.
    pub headers: Headers,
    /// The body.
    pub body: Vec<u8>,
}

impl Default for Response {
    fn default() -> Self {
        Response { status: 200, headers: Headers::new(), body: Vec::new() }
    }
}

impl Response {
    /// `new Response(body, { status, headers })`.
    pub fn new(body: impl Into<Vec<u8>>, status: u16, headers: Headers) -> Response {
        Response { status, headers, body: body.into() }
    }

    /// `Response.json(data, { status })`: the JSON with
    /// `content-type: application/json`.
    pub fn json(data: &Value, status: u16) -> Response {
        Response::new(js::stringify(data), status, Headers::new().with("content-type", "application/json"))
    }

    /// An empty answer with this status.
    pub fn status(status: u16) -> Response {
        Response { status, ..Response::default() }
    }

    /// The answer with this header set.
    pub fn header(mut self, name: &str, value: impl AsRef<str>) -> Response {
        self.headers.set(name, value.as_ref());
        self
    }

    /// Whether the status is from 200 to 299.
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    /// The body as text, as `response.text()` decodes it.
    pub fn text(&self) -> String {
        utf8(&self.body)
    }

    /// The body as JSON.
    pub fn json_body(&self) -> Result<Value, js::JsonError> {
        js::parse(&self.text())
    }
}
