//! Journeys: the paths visits take through a site, page by page. Each
//! visit's pages are read in order, a page seen twice in a row (a refresh)
//! counts once, and the path is cut to a number of steps, from a start page
//! and to an end page when those are chosen. The answer lines the paths up
//! in columns, one per step, with the flows between them.

use std::cmp::Ordering;
use std::collections::HashMap;

use crate::js::{self, Value};
use crate::obj;
use crate::store::js_order;

/// What a journey is asked for with.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JourneyOptions {
    /// How many steps, 2 to 8 (5 for anything that is not a number).
    pub steps: f64,
    /// Start at this page.
    pub start: Option<String>,
    /// End at this page.
    pub end: Option<String>,
    /// Only paths that show this page at this step (0-based), to follow one page.
    pub through: Option<(f64, String)>,
}

/// How many pages of a visit to read: enough to find a start page and still have the steps after it.
pub const PAGES_PER_VISIT: i64 = 40;
const TOP: usize = 8;

fn lt(a: &str, b: &str) -> bool {
    js_order(a, b) == Ordering::Less
}

/// The journeys a set of visits' pages make, as the SDK's object.
pub fn journeys(rows: &[(String, String)], options: &JourneyOptions) -> Value {
    let floored = options.steps.floor();
    let steps = (if floored.is_nan() || floored == 0.0 { 5.0 } else { floored }).clamp(2.0, 8.0) as usize;
    // Group each visit's pages, dropping refreshes.
    let mut order: Vec<&str> = Vec::new();
    let mut visits: HashMap<&str, Vec<String>> = HashMap::new();
    for (session, path) in rows {
        let pages = visits.entry(session.as_str()).or_insert_with(|| {
            order.push(session.as_str());
            Vec::new()
        });
        if pages.last() != Some(path) {
            pages.push(path.clone());
        }
    }
    let mut sequences: Vec<Vec<String>> = Vec::new();
    // Visits that went on past the last step shown, so they never count as having gone no further.
    let mut cut: Vec<bool> = Vec::new();
    for session in order {
        let mut pages = visits[session].clone();
        if let Some(start) = options.start.as_deref().filter(|s| !s.is_empty()) {
            let Some(at) = pages.iter().position(|p| p == start) else { continue };
            pages = pages[at..].to_vec();
        }
        if let Some(end) = options.end.as_deref().filter(|s| !s.is_empty()) {
            let Some(at) = pages.iter().position(|p| p == end) else { continue };
            pages.truncate(at + 1);
        }
        let more = pages.len() > steps;
        pages.truncate(steps);
        if let Some((step, value)) = &options.through
            && !(js::is_integer(*step) && *step >= 0.0 && pages.get(*step as usize) == Some(value))
        {
            continue;
        }
        sequences.push(pages);
        cut.push(more);
    }

    let mut columns: Vec<Value> = Vec::new();
    let mut kept: Vec<Vec<String>> = Vec::new();
    for i in 0..steps {
        let mut counts: Vec<(String, i64)> = Vec::new();
        let mut reached = 0;
        let mut left = 0;
        for (s, was_cut) in sequences.iter().zip(&cut) {
            if s.len() <= i {
                continue;
            }
            reached += 1;
            if s.len() == i + 1 && !was_cut {
                left += 1;
            }
            match counts.iter_mut().find(|(v, _)| *v == s[i]) {
                Some(c) => c.1 += 1,
                None => counts.push((s[i].clone(), 1)),
            }
        }
        counts.sort_by(|a, b| {
            b.1.cmp(&a.1).then_with(|| if lt(&a.0, &b.0) { Ordering::Less } else { Ordering::Greater })
        });
        let top: Vec<(String, i64)> = counts.iter().take(TOP).cloned().collect();
        let rest: i64 = counts.iter().skip(TOP).map(|(_, v)| v).sum();
        kept.push(top.iter().map(|(v, _)| v.clone()).collect());
        if reached == 0 {
            break;
        }
        let mut items: Vec<Value> =
            top.iter().map(|(value, visits)| obj! { "value" => value.clone(), "visits" => *visits }).collect();
        if rest > 0 {
            items.push(obj! { "value" => "", "visits" => rest });
        }
        columns.push(obj! { "items" => Value::Array(items), "visits" => reached, "left" => left });
    }

    let mut links: Vec<(usize, String, String, i64)> = Vec::new();
    for s in &sequences {
        let mut i = 0;
        while i + 1 < s.len() && i + 1 < columns.len() {
            let from = if kept[i].contains(&s[i]) { s[i].clone() } else { String::new() };
            let to = if kept[i + 1].contains(&s[i + 1]) { s[i + 1].clone() } else { String::new() };
            match links.iter_mut().find(|l| l.0 == i && l.1 == from && l.2 == to) {
                Some(l) => l.3 += 1,
                None => links.push((i, from, to, 1)),
            }
            i += 1;
        }
    }
    // Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
    links.sort_by(|a, b| {
        a.0.cmp(&b.0).then(b.3.cmp(&a.3)).then_with(|| {
            if lt(&a.1, &b.1) {
                Ordering::Less
            } else if lt(&b.1, &a.1) {
                Ordering::Greater
            } else if lt(&a.2, &b.2) {
                Ordering::Less
            } else if lt(&b.2, &a.2) {
                Ordering::Greater
            } else {
                Ordering::Equal
            }
        })
    });

    let mut paths: Vec<(String, Vec<String>, i64)> = Vec::new();
    for s in &sequences {
        let key = s.join("\u{0}");
        match paths.iter_mut().find(|p| p.0 == key) {
            Some(p) => p.2 += 1,
            None => paths.push((key, s.clone(), 1)),
        }
    }
    paths.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| if lt(&a.0, &b.0) { Ordering::Less } else { Ordering::Greater }));

    obj! {
        "visits" => sequences.len(),
        "columns" => Value::Array(columns),
        "links" => Value::Array(links.into_iter().map(|(step, from, to, visits)| obj! { "step" => step, "from" => from, "to" => to, "visits" => visits }).collect()),
        "paths" => Value::Array(
            paths
                .into_iter()
                .take(20)
                .map(|(_, pages, visits)| obj! { "pages" => Value::Array(pages.into_iter().map(Value::from).collect()), "visits" => visits })
                .collect(),
        ),
    }
}

/// Journey options as a request's query gives them.
pub fn options_from(
    steps: Option<&str>,
    start: Option<&str>,
    end: Option<&str>,
    through: Option<(f64, String)>,
) -> JourneyOptions {
    JourneyOptions {
        steps: steps.map_or(f64::NAN, js::text_number),
        start: start.map(str::to_string),
        end: end.map(str::to_string),
        through,
    }
}
