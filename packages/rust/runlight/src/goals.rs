//! Goals: what is worth counting, checked as the dashboard sends them, and
//! the click rules the tracker applies.

use crate::hash::new_id;
use crate::js::{self, Object, Value};
use crate::re::{js_re, test};
use crate::sources::recorded_path;
use crate::store::{GoalRow, SiteRow};

/// Why something the dashboard sent was refused, as a code the dashboard says in its own words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodedError {
    /// The English message.
    pub message: String,
    /// The code.
    pub code: String,
    /// The words the message names, by placeholder.
    pub params: Vec<(String, String)>,
}

impl CodedError {
    /// An error with a message, a code, and its parameters.
    pub fn new(message: impl Into<String>, code: &str, params: &[(&str, &str)]) -> CodedError {
        CodedError {
            message: message.into(),
            code: code.into(),
            params: params.iter().map(|(k, v)| ((*k).to_string(), (*v).to_string())).collect(),
        }
    }

    /// The parameters as a JSON object.
    pub fn params_value(&self) -> Value {
        let mut o = Object::new();
        for (k, v) in &self.params {
            o.set(k.clone(), v.clone());
        }
        Value::Object(o)
    }
}

impl std::fmt::Display for CodedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CodedError {}

/// Why a goal was refused.
pub type GoalError = CodedError;

/// A page to match, written the way paths are recorded: the path of a pasted URL, with a leading
/// slash, percent-encoded as browsers send it, and with a hash route kept. `*` stays a wildcard.
/// `None` when it is not a path or a URL.
pub fn page_pattern(input: &str) -> Option<String> {
    let starred = input.replace('*', "__STAR__");
    // A pattern written to start with * keeps that start, rather than gaining a slash.
    let path = recorded_path(&if starred.starts_with("__STAR__") { format!("/{starred}") } else { starred })?;
    let pattern = path.replace("__STAR__", "*");
    Some(if input.starts_with('*') {
        pattern.strip_prefix('/').map(str::to_string).unwrap_or(pattern)
    } else {
        pattern
    })
}

const KINDS: [&str; 3] = ["event", "page", "click"];
const MODES: [&str; 3] = ["none", "fixed", "prop"];

/// `String(input[key] ?? "").trim().slice(0, max)`.
pub(crate) fn text(input: &Value, key: &str, max: usize) -> String {
    js::head16(js::trim(&js::str_or_empty(input.get(key))), max)
}

/// Checks and tidies a goal from the dashboard. `existing` is the site's other goals, so two goals
/// cannot share a name.
pub fn goal_from(
    input: &Value,
    site: &str,
    existing: &[GoalRow],
    now: i64,
    id: Option<&str>,
) -> Result<GoalRow, GoalError> {
    let name = text(input, "name", 80);
    if name.is_empty() {
        return Err(CodedError::new("Give the goal a name", "goal_name", &[]));
    }
    let lower = name.to_lowercase();
    if existing.iter().any(|g| Some(g.id.as_str()) != id && g.name.to_lowercase() == lower) {
        return Err(CodedError::new(
            format!("There is already a goal called \"{name}\""),
            "goal_exists",
            &[("name", &name)],
        ));
    }

    let kind = js::str_or_empty(input.get("kind"));
    if !KINDS.contains(&kind.as_str()) {
        return Err(CodedError::new("Pick what the goal counts: an event, a page visit, or a click", "goal_kind", &[]));
    }

    let mut match_ = text(input, "match", 500);
    let mut click_by = String::new();
    if kind == "event" && match_.is_empty() {
        return Err(CodedError::new("Enter the event's name", "goal_event", &[]));
    }
    if kind == "page" {
        if match_.is_empty() {
            return Err(CodedError::new("Enter a page path, like /thanks or /blog/*", "goal_page", &[]));
        }
        // A full URL is fine to paste; the path is what counts.
        match_ = page_pattern(&match_)
            .ok_or_else(|| CodedError::new("That page is not a path or a URL", "goal_page_bad", &[]))?;
    }
    if kind == "click" {
        click_by = if input.get("clickBy").and_then(Value::as_str) == Some("link") {
            "link".into()
        } else {
            "selector".into()
        };
        if match_.is_empty() {
            return Err(if click_by == "link" {
                CodedError::new("Enter the link's address, like https://buy.stripe.com/*", "goal_link", &[])
            } else {
                CodedError::new("Enter a CSS selector, like #signup or .buy-button", "goal_selector", &[])
            });
        }
    }

    // A click goal sends an event named after itself, so its name and an event goal's match must not meet.
    let others: Vec<&GoalRow> = existing.iter().filter(|g| Some(g.id.as_str()) != id).collect();
    if kind == "click" && others.iter().any(|g| g.kind == "event" && g.match_.to_lowercase() == lower) {
        return Err(CodedError::new(
            format!("An event goal already counts events called \"{name}\", so give this click goal another name"),
            "goal_event_taken",
            &[("name", &name)],
        ));
    }
    if kind == "event" && others.iter().any(|g| g.kind == "click" && g.name.to_lowercase() == match_.to_lowercase()) {
        return Err(CodedError::new(
            format!("The click goal \"{match_}\" already sends events with that name"),
            "goal_click_taken",
            &[("match", &match_)],
        ));
    }

    let mode_text = input.get("valueMode").map_or_else(|| "undefined".to_string(), js::js_string);
    let value_mode = if MODES.contains(&mode_text.as_str()) { mode_text } else { "none".to_string() };
    // Page visits and click rules carry no properties, so only an event can send its own amount.
    if value_mode == "prop" && kind != "event" {
        return Err(CodedError::new(
            "Only an event goal can take its amount from the event; use a fixed amount instead",
            "goal_prop_kind",
            &[],
        ));
    }
    let value = if value_mode == "fixed" { js::opt_number(input.get("value")) } else { 0.0 };
    if value_mode == "fixed" && !(0.0..1e9).contains(&value) {
        return Err(CodedError::new("Enter an amount, like 49 or 9.99", "goal_amount", &[]));
    }
    let value_prop = if value_mode == "prop" {
        let p = text(input, "valueProp", 40);
        if p.is_empty() { "revenue".to_string() } else { p }
    } else {
        String::new()
    };
    if value_mode == "prop" && !test(js_re!(r"^[A-Za-z0-9_.-]{1,40}$"), &value_prop) {
        return Err(CodedError::new(
            "A property name uses letters, numbers, dots, dashes, and underscores",
            "goal_prop_name",
            &[],
        ));
    }
    let currency = {
        let c = text(input, "currency", 20).to_uppercase();
        if c.is_empty() { "USD".to_string() } else { c }
    };
    if !test(js_re!(r"^[A-Z]{3}$"), &currency) {
        return Err(CodedError::new("Use a three-letter currency code, like USD or EUR", "goal_currency", &[]));
    }

    let before = existing.iter().find(|g| Some(g.id.as_str()) == id);
    Ok(GoalRow {
        id: id.map_or_else(new_id, str::to_string),
        site: site.to_string(),
        name,
        kind,
        match_,
        click_by,
        value_mode,
        value: js::round(value * 100.0) / 100.0,
        value_prop,
        currency,
        created_at: before.map_or(now, |b| b.created_at),
    })
}

/// Click rules for the tracker, keyed by site id and by each of the site's hostnames (or "*" for a
/// site with none), so the script finds its own. Each rule is [s for selector or h for a link, what
/// to match, the event to send].
pub fn click_rules(sites: &[SiteRow], goals: &[GoalRow]) -> Object {
    let mut out = Object::new();
    for site in sites {
        let rules: Vec<Value> = goals
            .iter()
            .filter(|g| g.site == site.id && g.kind == "click")
            .map(|g| {
                Value::Array(vec![
                    Value::from(if g.click_by == "link" { "h" } else { "s" }),
                    Value::from(g.match_.as_str()),
                    Value::from(g.name.as_str()),
                ])
            })
            .collect();
        if rules.is_empty() {
            continue;
        }
        let rules = Value::Array(rules);
        out.set(site.id.clone(), rules.clone());
        let hosts: Vec<String> = if site.hostnames.is_empty() { vec!["*".into()] } else { site.hostnames.clone() };
        for host in hosts {
            out.set(host.strip_prefix("www.").map(str::to_string).unwrap_or(host), rules.clone());
        }
    }
    out
}
