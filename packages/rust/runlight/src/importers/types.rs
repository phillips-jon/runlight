//! What every importer shares: the shapes it hands back, and why an import stopped (importers/types.ts).
//!
//! A step's links leave the importer as JSON values in the TypeScript shapes, so a field the other
//! service sent as null stays null and one it left out stays out, as they do in the SDK:
//!
//! - ForeignLink: `sourceId` (the other service's id, so a re-run recognises the link), `slug`,
//!   `domain` (the short link's domain there; shortener-owned domains such as bit.ly and dub.sh are
//!   not kept), `name`, `url`, and `createdAt` (milliseconds).
//! - ForeignClick: `ts` (milliseconds), and whichever of `visit` (groups clicks into one visit),
//!   `referrer`, `path` and `query` (of the short URL as clicked, for campaign tags), `country`,
//!   `region`, `city`, `browser`, `os`, `device`, `screen`, and `language` the service knows.
//! - DailyClicks: `day` (YYYY-MM-DD, UTC) and `clicks`, for services that only keep counts.

use std::collections::HashMap;

use crate::BoxFuture;
use crate::error::Error;
use crate::goals::CodedError;
use crate::js::{self, Object, Value};
use crate::store::DbError;

/// The credentials a step comes with, never stored.
pub type Credentials = HashMap<String, String>;

/// `credentials[name]?.trim()`: `None` when there is no such field.
pub(crate) fn credential<'a>(credentials: &'a Credentials, name: &str) -> Option<&'a str> {
    credentials.get(name).map(|v| js::trim(v))
}

/// `credentials[name]?.trim()` when it is not empty (`credentials.x?.trim() || ...`).
pub(crate) fn filled<'a>(credentials: &'a Credentials, name: &str) -> Option<&'a str> {
    credential(credentials, name).filter(|v| !v.is_empty())
}

/// Why an import stopped: a code the dashboard says in its own words (an ImportError, or an HttpError
/// when a service answered with a status), or anything else, which the routes answer as a failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportError {
    /// An ImportError, with the status of an HttpError.
    Coded {
        /// The message, code, and params.
        error: CodedError,
        /// The status a service answered with, for an HttpError.
        status: Option<u16>,
    },
    /// Anything else: the database, or a service's answer in a shape the import cannot read (what
    /// JavaScript throws as a TypeError, SyntaxError, or RangeError).
    Other(Error),
}

impl ImportError {
    /// An ImportError.
    pub fn new(message: impl Into<String>, code: &str, params: &[(&str, &str)]) -> ImportError {
        ImportError::Coded { error: CodedError::new(message, code, params), status: None }
    }

    /// An HttpError: a service answered with a status that is not success.
    pub fn http(message: impl Into<String>, status: u16, code: &str, params: &[(&str, &str)]) -> ImportError {
        ImportError::Coded { error: CodedError::new(message, code, params), status: Some(status) }
    }

    /// What JavaScript throws as a TypeError or SyntaxError: not an ImportError.
    pub fn other(message: impl Into<String>) -> ImportError {
        ImportError::Other(Error::Other(message.into()))
    }

    /// The coded error, for an ImportError.
    pub fn coded(&self) -> Option<&CodedError> {
        match self {
            ImportError::Coded { error, .. } => Some(error),
            ImportError::Other(_) => None,
        }
    }

    /// The status, for an HttpError.
    pub fn status(&self) -> Option<u16> {
        match self {
            ImportError::Coded { status, .. } => *status,
            ImportError::Other(_) => None,
        }
    }

    /// Whether this is an HttpError (`error instanceof HttpError`).
    pub fn is_http(&self) -> bool {
        self.status().is_some()
    }

    /// The English message.
    pub fn message(&self) -> &str {
        match self {
            ImportError::Coded { error, .. } => &error.message,
            ImportError::Other(e) => e.message(),
        }
    }
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for ImportError {}

impl From<Error> for ImportError {
    fn from(e: Error) -> ImportError {
        ImportError::Other(e)
    }
}

impl From<DbError> for ImportError {
    fn from(e: DbError) -> ImportError {
        ImportError::Other(Error::Db(e))
    }
}

/// What one step of an import did. The page keeps calling until `cursor` is `None`.
#[derive(Clone, Debug, PartialEq)]
pub struct ImportStep {
    /// Where to pick up.
    pub cursor: Option<String>,
    /// Links handled so far, for the progress bar.
    pub done: f64,
    /// Links in all, or `None` when the service does not say.
    pub total: Option<f64>,
    /// Links written.
    pub links: f64,
    /// Clicks written.
    pub clicks: f64,
    /// Links already here.
    pub skipped: f64,
    /// Links that could not be written: `slug`, `reason`, and `code` and `params` when there are.
    pub failed: Vec<Value>,
}

impl ImportStep {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new();
        o.set("cursor", self.cursor.clone());
        o.set("done", self.done);
        o.set("total", self.total);
        o.set("links", self.links);
        o.set("clicks", self.clicks);
        o.set("skipped", self.skipped);
        o.set("failed", Value::Array(self.failed.clone()));
        Value::Object(o)
    }
}

/// Whether a link from this source is already in Runlight, so its history need not be fetched again:
/// imported from this source before, or the same slug to the same destination brought in some other
/// way. Called with the source's id, and the slug and destination when there are.
pub type Known =
    dyn Fn(String, Option<String>, Option<String>) -> BoxFuture<'static, Result<bool, ImportError>> + Send + Sync;

/// What a step is given.
pub struct StepInput<'a> {
    /// The credentials, which come with every step.
    pub credentials: &'a Credentials,
    /// Where the last step stopped.
    pub cursor: Option<&'a str>,
    /// Whether a link is already here.
    pub known: &'a Known,
    /// Runlight's clock, in milliseconds: the date of a link the source gives none for, and where
    /// Umami's history ends.
    pub now: i64,
}

/// One shortener. `step` does a bounded slice of work (a few links) and hands back a cursor, so imports
/// run in small requests that fit any host's time limit and can show progress. Credentials come with
/// every step and are never stored. The answer is `{ cursor, total, links }`, each link
/// `{ link, clicks?, daily?, known? }`, as the SDK's.
pub trait Importer: Send + Sync {
    /// One step, its requests sent through `http`.
    fn step<'a>(
        &'a self,
        http: &'a super::http::Http,
        input: StepInput<'a>,
    ) -> BoxFuture<'a, Result<Value, ImportError>>;
}

/// `{ cursor, total, links }`; a total of `None` is undefined, which JSON leaves out.
pub(crate) fn step_answer(cursor: Option<String>, total: Option<Value>, links: Vec<Value>) -> Value {
    let mut o = Object::new();
    o.set("cursor", cursor);
    set_opt(&mut o, "total", total);
    o.set("links", Value::Array(links));
    Value::Object(o)
}

/// `{ link: { sourceId, slug, domain, name, url, createdAt } }`, for the history to be added to. A
/// field of `None` is undefined, which JSON leaves out.
pub(crate) fn foreign_link(
    source_id: Option<Value>,
    slug: Option<Value>,
    domain: Option<Value>,
    name: Option<Value>,
    url: Option<Value>,
    created_at: f64,
) -> Object {
    let mut o = Object::new();
    set_opt(&mut o, "sourceId", source_id);
    set_opt(&mut o, "slug", slug);
    set_opt(&mut o, "domain", domain);
    set_opt(&mut o, "name", name);
    set_opt(&mut o, "url", url);
    o.set("createdAt", created_at);
    Object::new().with("link", o)
}

/// A link already here, marked known so its history is not fetched.
pub(crate) fn known_link(
    source_id: Option<Value>,
    slug: Option<Value>,
    name: Option<Value>,
    url: Option<Value>,
) -> Value {
    Value::Object(foreign_link(source_id, slug, Some(Value::from("")), name, url, 0.0).with("known", true))
}

/// A value as `known` is given it: undefined and null as nothing.
pub(crate) fn arg(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => None,
        Some(v) => Some(js::js_string(v)),
    }
}

/// Text as a value.
pub(crate) fn text(value: &str) -> Option<Value> {
    Some(Value::from(value))
}

/// Sets a field that may be undefined (`None`), which JSON leaves out.
pub(crate) fn set_opt(o: &mut Object, key: &str, value: Option<Value>) {
    if let Some(v) = value {
        o.set(key, v);
    }
}

/// `value?.[key]`: `None` for undefined, as for a value that is not an object.
pub(crate) fn field<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    match value {
        Some(Value::Object(o)) => o.get(key),
        Some(Value::Array(a)) => key.parse::<usize>().ok().and_then(|i| a.get(i)),
        _ => None,
    }
}

/// `a || b` over values that may be undefined.
pub(crate) fn or<'a>(a: Option<&'a Value>, b: Option<&'a Value>) -> Option<&'a Value> {
    if js::opt_truthy(a) { a } else { b }
}

/// `a ?? b` over values that may be undefined.
pub(crate) fn nullish<'a>(a: Option<&'a Value>, b: Option<&'a Value>) -> Option<&'a Value> {
    match a {
        None | Some(Value::Null) => b,
        _ => a,
    }
}

/// A value the SDK iterates with `for...of` (an array; anything else is a TypeError there).
pub(crate) fn items<'a>(value: Option<&'a Value>, what: &str) -> Result<&'a [Value], ImportError> {
    match value {
        Some(Value::Array(a)) => Ok(a),
        _ => Err(ImportError::other(format!("{what} is not iterable"))),
    }
}
