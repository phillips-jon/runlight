//! Report queries: which dimensions exist, where each lives, and how
//! filters are read from a URL. Shared by every store.

use crate::js::{self, Value};
use crate::obj;

/// Dimensions recorded per event, and their columns.
pub const EVENT_DIMENSIONS: [(&str, &str); 3] = [("page", "path"), ("hostname", "hostname"), ("event", "name")];

/// Dimensions recorded once per session, from its first request, and their
/// columns.
pub const SESSION_DIMENSIONS: [(&str, &str); 20] = [
    ("entry", "entry_path"),
    ("exit", "exit_path"),
    ("referrer", "referrer_host"),
    ("source", "source"),
    ("channel", "channel"),
    ("utm_source", "utm_source"),
    ("utm_medium", "utm_medium"),
    ("utm_campaign", "utm_campaign"),
    ("utm_term", "utm_term"),
    ("utm_content", "utm_content"),
    ("country", "country"),
    ("region", "region"),
    ("city", "city"),
    ("browser", "browser"),
    ("browser_version", "browser_version"),
    ("os", "os"),
    ("os_version", "os_version"),
    ("device", "device"),
    ("screen", "screen"),
    ("language", "language"),
];

/// Every dimension a report can break down by: event ones, session ones,
/// then the AI agent fetches, which are their own rows outside visits.
pub fn dimensions() -> Vec<&'static str> {
    let mut out: Vec<&str> = EVENT_DIMENSIONS.iter().map(|d| d.0).collect();
    out.extend(SESSION_DIMENSIONS.iter().map(|d| d.0));
    out.push("ai_agent");
    out.push("ai_page");
    out
}

/// A filter: a dimension, `is`, `not`, or `contains`, and a value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Filter {
    /// An event or session dimension.
    pub dimension: String,
    /// `is`, `not`, or `contains`.
    pub op: String,
    /// The value, at most 500 UTF-16 code units.
    pub value: String,
}

impl Filter {
    /// As the SDK's object writes it.
    pub fn to_value(&self) -> Value {
        obj! { "dimension" => self.dimension.clone(), "op" => self.op.clone(), "value" => self.value.clone() }
    }
}

/// What a report reads: a site, a span of time, and filters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Query {
    /// The site's id.
    pub site: String,
    /// Inclusive, epoch milliseconds.
    pub from: i64,
    /// Exclusive, epoch milliseconds.
    pub to: i64,
    /// The filters.
    pub filters: Vec<Filter>,
}

/// Whether a report can break down by this dimension.
pub fn is_dimension(value: &str) -> bool {
    dimensions().contains(&value)
}

/// Whether the dimension is recorded once per session.
pub fn is_session_dimension(value: &str) -> bool {
    SESSION_DIMENSIONS.iter().any(|d| d.0 == value)
}

/// Whether the dimension is recorded per event.
pub fn is_event_dimension(value: &str) -> bool {
    EVENT_DIMENSIONS.iter().any(|d| d.0 == value)
}

/// The column a dimension lives in.
pub fn column_of(dimension: &str) -> Option<&'static str> {
    SESSION_DIMENSIONS.iter().chain(EVENT_DIMENSIONS.iter()).find(|d| d.0 == dimension).map(|d| d.1)
}

/// `dimension:op:value`, where the value may itself contain colons.
pub fn parse_filter(text: &str) -> Option<Filter> {
    let first = text.find(':')?;
    let second = first + 1 + text[first + 1..].find(':')?;
    let dimension = &text[..first];
    let op = &text[first + 1..second];
    let value = &text[second + 1..];
    if !is_session_dimension(dimension) && !is_event_dimension(dimension) {
        return None;
    }
    if op != "is" && op != "not" && op != "contains" {
        return None;
    }
    Some(Filter { dimension: dimension.into(), op: op.into(), value: js::head16(value, 500) })
}

/// The most filters a query takes, which keeps every statement within
/// Cloudflare D1's 100 values.
pub const MAX_FILTERS: usize = 6;
