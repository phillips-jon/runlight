//! Funnels: steps a visit is expected to take in order, checked as the
//! dashboard sends them.

use crate::goals::{CodedError, page_pattern};
use crate::hash::new_id;
use crate::js::{self, Value};
use crate::store::{FunnelRow, FunnelStep};

/// Why a funnel was refused.
pub type FunnelError = CodedError;

/// Checks and tidies a funnel from the dashboard: a name, and two to eight steps, each a page (with *
/// as a wildcard) or an event name.
pub fn funnel_from(
    input: &Value,
    site: &str,
    existing: &[FunnelRow],
    now: i64,
    id: Option<&str>,
) -> Result<FunnelRow, FunnelError> {
    let name = js::head16(js::trim(&js::str_or_empty(input.get("name"))), 80);
    if name.is_empty() {
        return Err(CodedError::new("Give the funnel a name", "funnel_name", &[]));
    }
    let lower = name.to_lowercase();
    if existing.iter().any(|f| Some(f.id.as_str()) != id && f.name.to_lowercase() == lower) {
        return Err(CodedError::new(
            format!("There is already a funnel called \"{name}\""),
            "funnel_exists",
            &[("name", &name)],
        ));
    }
    let raw: &[Value] = input.get("steps").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    let mut steps = Vec::new();
    for item in raw {
        let step = if item.is_object() || item.is_array() { item.clone() } else { Value::Null };
        let kind = if step.get("kind").and_then(Value::as_str) == Some("event") { "event" } else { "page" };
        let mut match_ = js::head16(js::trim(&js::str_or_empty(step.get("match"))), 500);
        if match_.is_empty() {
            continue;
        }
        if kind == "page" {
            // A full URL is fine to paste; the path is what counts.
            match_ = page_pattern(&match_).ok_or_else(|| {
                CodedError::new(
                    format!("\"{match_}\" is not a path or a URL"),
                    "funnel_page_bad",
                    &[("match", &match_)],
                )
            })?;
        }
        steps.push(FunnelStep { kind: kind.into(), match_ });
    }
    if steps.len() < 2 {
        return Err(CodedError::new("A funnel needs at least two steps", "funnel_short", &[]));
    }
    if steps.len() > 8 {
        return Err(CodedError::new("A funnel has at most eight steps", "funnel_long", &[]));
    }
    Ok(FunnelRow {
        id: id.map_or_else(new_id, str::to_string),
        site: site.to_string(),
        name,
        steps,
        created_at: existing.iter().find(|f| Some(f.id.as_str()) == id).map_or(now, |f| f.created_at),
    })
}
