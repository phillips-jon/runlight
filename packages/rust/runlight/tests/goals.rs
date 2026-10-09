//! Goals, funnels, and journeys against the fixtures written from the TypeScript SDK.

mod common;

use common::{fixture, list, s};
use runlight::js::{self, Value};
use runlight::obj;
use runlight::store::{FunnelRow, GoalRow, SiteRow};

fn goal_rows(v: &Value) -> Vec<GoalRow> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|g| GoalRow {
            id: s(g, "id").into(),
            site: s(g, "site").into(),
            name: s(g, "name").into(),
            kind: s(g, "kind").into(),
            match_: s(g, "match").into(),
            click_by: s(g, "clickBy").into(),
            value_mode: s(g, "valueMode").into(),
            value: g.at("value").as_f64().unwrap_or(0.0),
            value_prop: s(g, "valueProp").into(),
            currency: s(g, "currency").into(),
            created_at: g.at("createdAt").as_f64().unwrap_or(0.0) as i64,
        })
        .collect()
}

/// The answer as the fixture writes it: the row with a new id as "<random>", or the error.
fn outcome(result: Result<Value, runlight::goals::CodedError>, fresh: bool) -> String {
    match result {
        Ok(mut v) => {
            if fresh {
                let id = v.at("id").as_str().unwrap_or("").to_string();
                if id.len() == 24 && id.bytes().all(|b| b.is_ascii_hexdigit()) {
                    v.as_object_mut().unwrap().set("id", "<random>");
                }
            }
            obj! { "value" => v }.to_json()
        }
        Err(e) => obj! { "error" => obj! { "message" => e.message.clone(), "code" => e.code.clone(), "params" => e.params_value() } }.to_json(),
    }
}

#[test]
fn goals_and_funnels_are_checked_as_the_sdk_checks_them() {
    let f = fixture("goals");
    let existing = goal_rows(f.at("existing"));
    assert!(list(&f, "goals").len() > 50);
    for case in list(&f, "goals") {
        let id = case.at("id").as_str();
        let got = outcome(
            runlight::goals::goal_from(case.at("input"), "s", &existing, 1000, id).map(|g| g.to_value()),
            id.is_none(),
        );
        assert_eq!(got, case.at("result").to_json(), "{}", case.at("input").to_json());
    }
    let existing: Vec<FunnelRow> = list(&f, "existingFunnels")
        .iter()
        .map(|x| FunnelRow {
            id: s(x, "id").into(),
            site: s(x, "site").into(),
            name: s(x, "name").into(),
            steps: vec![],
            created_at: x.at("createdAt").as_f64().unwrap() as i64,
        })
        .collect();
    for case in list(&f, "funnels") {
        let id = case.at("id").as_str();
        let got = outcome(
            runlight::funnels::funnel_from(case.at("input"), "s", &existing, 1000, id).map(|g| g.to_value()),
            id.is_none(),
        );
        assert_eq!(got, case.at("result").to_json(), "{}", case.at("input").to_json());
    }
    for case in list(&f, "patterns") {
        let got: Value = runlight::goals::page_pattern(s(case, "input")).into();
        assert_eq!(got, *case.at("result"), "{}", s(case, "input"));
    }
}

#[test]
fn click_rules_are_keyed_by_site_and_host() {
    let f = fixture("goals");
    let goal = |id: &str, site: &str, name: &str, kind: &str, m: &str, by: &str| GoalRow {
        id: id.into(),
        site: site.into(),
        name: name.into(),
        kind: kind.into(),
        match_: m.into(),
        click_by: by.into(),
        value_mode: "none".into(),
        value: 0.0,
        value_prop: String::new(),
        currency: "USD".into(),
        created_at: 5,
    };
    let site = |id: &str, hosts: &[&str]| SiteRow {
        id: id.into(),
        name: id.to_uppercase(),
        hostnames: hosts.iter().map(|h| h.to_string()).collect(),
        timezone: "UTC".into(),
    };
    let rules = runlight::goals::click_rules(
        &[site("s", &["www.example.com", "shop.example.com"]), site("t", &[]), site("u", &["u.example"])],
        &[
            goal(&"c".repeat(24), "s", "Buy", "click", ".buy", "selector"),
            goal(&"d".repeat(24), "t", "Out", "click", "https://x.example/*", "link"),
            goal(&"e".repeat(24), "u", "E", "event", "E", ""),
        ],
    );
    assert_eq!(rules.to_json(), f.at("rules").to_json());
}

#[test]
fn journeys_match_the_sdk() {
    let f = fixture("journeys");
    let datasets: Vec<Vec<(String, String)>> = list(&f, "datasets")
        .iter()
        .map(|d| {
            d.as_array().unwrap().iter().map(|r| (s(r, "session").to_string(), s(r, "path").to_string())).collect()
        })
        .collect();
    for run in list(&f, "runs") {
        let o = run.at("options");
        let steps = match o.at("steps") {
            Value::String(t) => js::text_number(t),
            v => v.as_f64().unwrap_or(f64::NAN),
        };
        let options = runlight::journeys::JourneyOptions {
            steps,
            start: o.get("start").and_then(Value::as_str).map(str::to_string),
            end: o.get("end").and_then(Value::as_str).map(str::to_string),
            through: o.get("through").map(|t| (t.at("step").as_f64().unwrap(), s(t, "value").to_string())),
        };
        let got = runlight::journeys::journeys(&datasets[run.at("dataset").as_f64().unwrap() as usize], &options);
        assert_eq!(
            got.to_json(),
            run.at("result").to_json(),
            "dataset {} with {}",
            run.at("dataset").to_json(),
            o.to_json()
        );
    }
}
