//! Email reports, rendered as the TypeScript SDK renders them for the cases in
//! packages/php/tests/fixtures/reports.json, on every database at hand.
//!
//! The TypeScript cases send tracker hits through `collect`, which this port
//! does not have yet, so the rows those hits leave behind come from
//! tests/fixtures/reports-rows.json (scripts/rust-fixtures-reports.mts writes
//! it from the SDK) and go in through the store's own insert_session and
//! insert_event, with each visit's totals set as collecting left them.

#![cfg(all(feature = "sqlite", feature = "postgres", feature = "mysql"))]

mod common;

use runlight::js::{self, Value};
use runlight::reports::{build_report, last_period};
use runlight::store::{EventRow, GoalRow, SessionRow, SiteRow, SqlStore};
use runlight::{params, store::Param};

fn text(v: &Value, key: &str) -> String {
    js::str_or_empty(v.get(key))
}

fn int(v: &Value, key: &str) -> i64 {
    v.at(key).as_f64().unwrap_or(0.0) as i64
}

fn opt_int(v: &Value, key: &str) -> Option<i64> {
    v.at(key).as_f64().map(|n| n as i64)
}

fn rows() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/reports-rows.json");
    js::parse(&std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))).expect("JSON")
}

fn goal_of(g: &Value) -> GoalRow {
    GoalRow {
        id: text(g, "id"),
        site: text(g, "site"),
        name: text(g, "name"),
        kind: text(g, "kind"),
        match_: text(g, "match"),
        click_by: text(g, "clickBy"),
        value_mode: text(g, "valueMode"),
        value: g.at("value").as_f64().unwrap_or(0.0),
        value_prop: text(g, "valueProp"),
        currency: text(g, "currency"),
        created_at: int(g, "createdAt"),
    }
}

/// Puts a case's goals, visits, and rows in the store.
async fn seed(store: &SqlStore, goals: &[Value], stored: &Value) {
    for g in goals {
        store.save_goal(&goal_of(g), None).await.unwrap();
    }
    for s in stored.at("sessions").as_array().unwrap() {
        let row = SessionRow {
            id: text(s, "id"),
            site: text(s, "site"),
            visitor: text(s, "visitor"),
            started_at: int(s, "started_at"),
            hostname: text(s, "hostname"),
            referrer_host: text(s, "referrer_host"),
            referrer_path: text(s, "referrer_path"),
            source: text(s, "source"),
            channel: text(s, "channel"),
            utm_source: text(s, "utm_source"),
            utm_medium: text(s, "utm_medium"),
            utm_campaign: text(s, "utm_campaign"),
            utm_term: text(s, "utm_term"),
            utm_content: text(s, "utm_content"),
            country: text(s, "country"),
            region: text(s, "region"),
            city: text(s, "city"),
            browser: text(s, "browser"),
            browser_version: text(s, "browser_version"),
            os: text(s, "os"),
            os_version: text(s, "os_version"),
            device: text(s, "device"),
            screen: text(s, "screen"),
            language: text(s, "language"),
        };
        store.insert_session(&row).await.unwrap();
        // The totals touch_session and add_engagement kept as the hits came in.
        store
            .db()
            .run(
                "UPDATE rl_sessions SET last_at = ?, entry_path = ?, exit_path = ?, pageviews = ?, events = ?, engaged_ms = ?, imported = ? WHERE id = ?",
                params![
                    int(s, "last_at"),
                    text(s, "entry_path"),
                    text(s, "exit_path"),
                    int(s, "pageviews"),
                    int(s, "events"),
                    Param::from(opt_int(s, "engaged_ms")),
                    int(s, "imported"),
                    text(s, "id"),
                ],
            )
            .await
            .unwrap();
    }
    for e in stored.at("events").as_array().unwrap() {
        let props = e.at("props").as_str().and_then(|p| js::parse(p).ok()).and_then(|p| p.as_object().cloned());
        let row = EventRow {
            site: text(e, "site"),
            ts: int(e, "ts"),
            kind: text(e, "kind"),
            visitor: text(e, "visitor"),
            session: text(e, "session"),
            pageview: text(e, "pageview"),
            path: text(e, "path"),
            hostname: text(e, "hostname"),
            title: text(e, "title"),
            name: text(e, "name"),
            props,
            engaged_ms: int(e, "engaged_ms"),
            scroll: opt_int(e, "scroll"),
            link: text(e, "link"),
        };
        store.insert_event(&row).await.unwrap();
    }
}

#[tokio::test]
async fn reports_render_as_the_typescript_sdk_renders_them_in_every_language() {
    let fixture = common::fixture("reports");
    let stored = rows();
    let cases = fixture.at("cases").as_array().unwrap();
    let mut checked = 0;
    for (kind, url) in common::kinds() {
        for case in cases {
            let name = text(case, "name");
            let rows = stored
                .at("cases")
                .as_array()
                .unwrap()
                .iter()
                .find(|c| text(c, "name") == name)
                .expect("rows for the case");
            let fresh = common::fresh(kind, &url).await;
            let store = fresh.store.clone();
            store.migrate().await.unwrap();
            seed(&store, case.at("goals").as_array().unwrap(), rows).await;
            let site = rows.at("site");
            let site = SiteRow {
                id: text(site, "id"),
                name: text(site, "name"),
                hostnames: site.at("hostnames").as_array().unwrap().iter().map(|h| js::str_or_empty(Some(h))).collect(),
                timezone: text(site, "timezone"),
            };
            let at = int(case, "at");
            for expected in case.at("reports").as_array().unwrap() {
                let (lang, frequency) = (text(expected, "lang"), text(expected, "frequency"));
                let label = format!("{kind}: {name}, {lang} {frequency}");
                let period = last_period(&frequency, at, &site.timezone);
                assert_eq!(period.to_value().to_json(), expected.at("period").to_json(), "{label}");
                let links = expected.at("links");
                let report = build_report(
                    &store,
                    &site,
                    &frequency,
                    &period,
                    &lang,
                    &text(links, "dashboard"),
                    &text(links, "unsubscribe"),
                )
                .await
                .unwrap();
                assert_eq!(report.subject, text(expected, "subject"), "{label}");
                assert_eq!(report.text, text(expected, "text"), "{label}");
                assert_eq!(report.html, text(expected, "html"), "{label}");
                checked += 1;
            }
            fresh.done().await;
        }
    }
    assert!(checked >= 36);
}
