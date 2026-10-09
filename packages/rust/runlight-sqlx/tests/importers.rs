//! The importers, as the TypeScript SDK's tests have them: importers.test.ts, visits-import.test.ts,
//! visits-import-days.test.ts, and visits-csv.test.ts, on SQLite in memory, plus the importer scenarios
//! of packages/php/tests/fixtures/outbound.json (each importer, run step by step against the same
//! answers, must send the SDK's exact requests, wait as long between tries, ask about the same known
//! links, and hand back the same steps, cursors included).

#![cfg(all(feature = "sqlite", feature = "postgres", feature = "mysql"))]

mod common;

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use runlight::http::{FetchError, FetchInit, Fetcher, Headers, Request, Response, Url};
use runlight::importers::csvvisits::{CsvFormat, csv_format, row_time};
use runlight::importers::http::{Sleep, date_parse};
use runlight::importers::visits::{import_csv_visits, import_umami_visits, umami_websites};
use runlight::importers::{Credentials, Http, ImportError, Known, StepInput, import_step_with, importer};
use runlight::js::{self, Object, Value};
use runlight::store::{Db, DbError, Dialect, Hold, Param, Row, SqlStore};
use runlight::{
    BoxFuture, Routes, RoutesOptions, Runlight, RunlightOptions, SiteOptions, TokenOption, arr, obj, params,
};

type Answer =
    Box<dyn Fn(&Url, &FetchInit) -> Option<Result<(u16, Value, Vec<(String, String)>), FetchError>> + Send + Sync>;

/// Answers requests from a list of handlers (the first that answers wins), recording what was asked.
struct Fake {
    answer: Answer,
    calls: Mutex<Vec<String>>,
    requests: Mutex<Vec<Value>>,
}

impl Fake {
    fn new(answer: Answer) -> Arc<Fake> {
        Arc::new(Fake { answer, calls: Mutex::new(vec![]), requests: Mutex::new(vec![]) })
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl Fetcher for Fake {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            let u = Url::parse(url).expect("a URL");
            self.calls.lock().unwrap().push(format!("{} {}{}", init.method, u.host(), u.pathname()));
            let mut headers = Object::new();
            let mut entries = init.headers.entries();
            entries.sort();
            for (k, v) in entries {
                headers.set(k, v);
            }
            let body = init.body.as_deref().map(|b| String::from_utf8_lossy(b).into_owned()).unwrap_or_default();
            self.requests
                .lock()
                .unwrap()
                .push(obj! { "method" => init.method.clone(), "url" => url, "headers" => headers, "body" => body });
            match (self.answer)(&u, &init) {
                None => Ok(Response::new("{}", 404, Headers::new())),
                Some(Err(e)) => Err(e),
                Some(Ok((status, body, extra))) => {
                    let mut h = Headers::new().with("content-type", "application/json");
                    for (k, v) in extra {
                        h.set(&k, &v);
                    }
                    Ok(Response::new(js::stringify(&body), status, h))
                }
            }
        })
    }
}

/// A JavaScript pattern as the regex crate reads it.
fn pattern(p: &str) -> fancy_regex::Regex {
    fancy_regex::Regex::new(&p.replace("\\/", "/")).expect("pattern")
}

/// Answers from a table of URL patterns, as importers.test.ts's `serve` does.
fn serve(routes: Vec<(&str, Value)>) -> Arc<Fake> {
    let table: Vec<(fancy_regex::Regex, Value)> = routes.into_iter().map(|(p, v)| (pattern(p), v)).collect();
    Fake::new(Box::new(move |url, _| {
        let href = url.href();
        table.iter().find(|(re, _)| re.is_match(&href).unwrap_or(false)).map(|(_, v)| {
            let status = v.get("status").and_then(Value::as_f64).unwrap_or(200.0) as u16;
            Ok((status, v.get("body").cloned().unwrap_or(Value::Null), vec![]))
        })
    }))
}

/// No waiting between tries; the waits are recorded.
fn no_wait() -> (Sleep, Arc<Mutex<Vec<f64>>>) {
    let waits = Arc::new(Mutex::new(vec![]));
    let kept = waits.clone();
    let sleep: Sleep = Arc::new(move |ms: f64| {
        kept.lock().unwrap().push(ms);
        Box::pin(async {})
    });
    (sleep, waits)
}

fn creds(pairs: &[(&str, &str)]) -> Credentials {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn parse_ms(iso: &str) -> i64 {
    date_parse(iso) as i64
}

async fn store() -> SqlStore {
    runlight_sqlx::connect(":memory:").await.expect("SQLite")
}

/// A Runlight on SQLite in memory with the blog site, a clock, and a fetcher.
async fn make(now: i64, timezone: &str, fetcher: Option<Arc<Fake>>) -> (Runlight, Routes, Arc<AtomicI64>) {
    make_on(store().await, now, timezone, fetcher)
}

fn make_on(
    store: SqlStore,
    now: i64,
    timezone: &str,
    fetcher: Option<Arc<Fake>>,
) -> (Runlight, Routes, Arc<AtomicI64>) {
    let clock = Arc::new(AtomicI64::new(now));
    let mut options = RunlightOptions::new(store);
    options.site = Some(SiteOptions {
        hostnames: Some(vec!["blog.example.com".into()]),
        timezone: Some(timezone.into()),
        ..SiteOptions::default()
    });
    let c = clock.clone();
    options.now = Some(Arc::new(move || c.load(Ordering::SeqCst)));
    if let Some(f) = fetcher {
        options.fetcher = Some(f);
    }
    let rl = Runlight::new(options).expect("Runlight");
    let routes = rl.routes(RoutesOptions { token: TokenOption::Open, ..RoutesOptions::default() }).expect("routes");
    (rl, routes, clock)
}

async fn get(routes: &Routes, path: &str) -> Value {
    let request = Request {
        url: format!("https://x.com/runlight{path}"),
        method: "GET".into(),
        headers: Headers::new(),
        body: vec![],
        remote_address: String::new(),
    };
    js::parse(&routes.handle(request).await.text()).expect("JSON")
}

async fn post(routes: &Routes, path: &str, headers: &[(&str, &str)], body: &str) -> Response {
    let mut h = Headers::new();
    for (k, v) in headers {
        h.set(k, v);
    }
    let request = Request {
        url: format!("https://x.com/runlight{path}"),
        method: "POST".into(),
        headers: h,
        body: body.as_bytes().to_vec(),
        remote_address: String::new(),
    };
    routes.handle(request).await
}

/// The values of a breakdown's rows.
async fn values(routes: &Routes, path: &str) -> Vec<String> {
    get(routes, path).await.at("rows").as_array().unwrap().iter().map(|r| js::js_string(r.at("value"))).collect()
}

fn stat(v: &Value, key: &str) -> f64 {
    v.at("stats").at(key).as_f64().unwrap()
}

// The importer scenarios in outbound.json.

#[tokio::test]
async fn importer_scenarios_match_typescript() {
    let fixture = common::fixture("outbound");
    let now = fixture.at("now").as_f64().unwrap() as i64;
    for scenario in fixture.at("importers").as_array().unwrap() {
        let name = js::js_string(scenario.at("name"));
        let routes: Vec<Value> = scenario.at("routes").as_array().unwrap().clone();
        let left: Arc<Mutex<Vec<f64>>> = Arc::new(Mutex::new(
            routes.iter().map(|r| r.get("times").and_then(Value::as_f64).unwrap_or(f64::INFINITY)).collect(),
        ));
        let patterns: Vec<fancy_regex::Regex> =
            routes.iter().map(|r| pattern(&js::js_string(r.at("pattern")))).collect();
        let fake = Fake::new(Box::new(move |url, _| {
            let href = url.href();
            let mut left = left.lock().unwrap();
            for (i, route) in routes.iter().enumerate() {
                if left[i] <= 0.0 || !patterns[i].is_match(&href).unwrap_or(false) {
                    continue;
                }
                left[i] -= 1.0;
                if js::opt_truthy(route.get("unreachable")) {
                    return Some(Err(FetchError::Failed("fetch failed".into())));
                }
                let status = route.get("status").and_then(Value::as_f64).unwrap_or(200.0) as u16;
                let headers = route
                    .get("headers")
                    .and_then(Value::as_object)
                    .map(|h| h.iter().map(|(k, v)| (k.to_string(), js::js_string(v))).collect())
                    .unwrap_or_default();
                return Some(Ok((status, route.get("body").cloned().unwrap_or(Value::Null), headers)));
            }
            None
        }));
        let (sleep, waits) = no_wait();
        let http = Http::with_sleep(fake.clone(), sleep);
        let credentials: Credentials = scenario
            .at("credentials")
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.to_string(), js::js_string(v)))
            .collect();
        let known_list: Vec<String> = scenario.at("known").as_array().unwrap().iter().map(js::js_string).collect();
        let known_calls: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(vec![]));
        let calls = known_calls.clone();
        let known: &Known = &move |id: String, slug: Option<String>, url: Option<String>| {
            calls.lock().unwrap().push(Value::Array(vec![
                Value::from(id.clone()),
                Value::from(slug.clone()),
                Value::from(url.clone()),
            ]));
            let both =
                format!("{} {}", slug.unwrap_or_else(|| "undefined".into()), url.unwrap_or_else(|| "undefined".into()));
            let found = known_list.contains(&id) || known_list.contains(&both);
            Box::pin(async move { Ok(found) })
        };
        let source = js::js_string(scenario.at("source"));
        let imp = importer(&source).expect("an importer");
        let steps = scenario.at("steps").as_array().unwrap();
        let mut cursor: Option<String> = steps[0].get("cursor").and_then(Value::as_str).map(str::to_string);
        for (i, want) in steps.iter().enumerate() {
            assert_eq!(
                want.get("cursor").and_then(Value::as_str),
                cursor.as_deref(),
                "{name}: step {i} starts from the same cursor"
            );
            let input = StepInput { credentials: &credentials, cursor: cursor.as_deref(), known, now };
            match imp.step(&http, input).await {
                Ok(result) => {
                    assert!(want.get("error").is_none(), "{name}: step {i} should fail");
                    assert_eq!(js::stringify(&result), js::stringify(want.at("result")), "{name}: step {i}");
                    cursor = result.get("cursor").and_then(Value::as_str).map(str::to_string);
                }
                Err(error) => {
                    let Some(w) = want.get("error") else { panic!("{name}: step {i} should not fail: {error}") };
                    let coded =
                        error.coded().unwrap_or_else(|| panic!("{name}: step {i} failed without a code: {error}"));
                    let mut got = Object::new();
                    got.set("message", coded.message.clone());
                    got.set("code", coded.code.clone());
                    got.set("params", coded.params_value());
                    if let Some(s) = error.status() {
                        got.set("status", i64::from(s));
                    }
                    got.set("name", if error.is_http() { "HttpError" } else { "ImportError" });
                    assert_eq!(js::stringify(&Value::Object(got)), js::stringify(w), "{name}: step {i}");
                }
            }
        }
        let normalize = |list: &[Value]| -> Vec<String> {
            list.iter()
                .map(|r| {
                    let mut o = r.as_object().unwrap().clone();
                    let mut h: Vec<(String, Value)> = o
                        .get("headers")
                        .unwrap()
                        .as_object()
                        .unwrap()
                        .iter()
                        .map(|(k, v)| (k.to_string(), v.clone()))
                        .collect();
                    h.sort_by(|a, b| a.0.cmp(&b.0));
                    let mut ho = Object::new();
                    for (k, v) in h {
                        ho.set(k, v);
                    }
                    o.set("headers", ho);
                    js::stringify(&Value::Object(o))
                })
                .collect()
        };
        let mut sent = normalize(&fake.requests.lock().unwrap());
        let mut wanted = normalize(scenario.at("requests").as_array().unwrap());
        if !js::opt_truthy(scenario.get("ordered")) {
            sent.sort();
            wanted.sort();
        }
        assert_eq!(sent, wanted, "{name}: requests");
        assert_eq!(
            js::stringify(&Value::Array(waits.lock().unwrap().iter().map(|w| Value::from(*w)).collect())),
            js::stringify(scenario.at("waits")),
            "{name}: waits"
        );
        assert_eq!(
            js::stringify(&Value::Array(known_calls.lock().unwrap().clone())),
            js::stringify(scenario.at("knownCalls")),
            "{name}: known calls"
        );
    }
}

// importers.test.ts

/// Runs an import to its end, adding up what each step did.
async fn run_all(
    rl: &Runlight,
    http: &Http,
    source: &str,
    credentials: &Credentials,
) -> (f64, f64, f64, Vec<Value>, f64) {
    let (mut links, mut clicks, mut skipped, mut failed) = (0.0, 0.0, 0.0, vec![]);
    let mut cursor: Option<String> = None;
    let mut done = 0.0;
    loop {
        let step =
            import_step_with(rl, http, "default", source, credentials, cursor.as_deref(), done).await.expect("a step");
        cursor = step.cursor;
        done = step.done;
        links += step.links;
        clicks += step.clicks;
        skipped += step.skipped;
        failed.extend(step.failed);
        if cursor.is_none() {
            break;
        }
    }
    (links, clicks, skipped, failed, done)
}

fn importing(fake: Arc<Fake>) -> Http {
    Http::with_sleep(fake, no_wait().0)
}

const NOW: i64 = 1_791_471_845_678;

async fn all_links(rl: &Runlight) -> Vec<(runlight::store::LinkRow, f64, f64)> {
    rl.store().links("default", 0, NOW + 1).await.unwrap()
}

#[tokio::test]
async fn dub_every_click_where_the_plan_allows() {
    let fake = serve(vec![
        (r"api\.dub\.co\/links\?.*startingAfter=l2", obj! { "body" => arr![] }),
        (
            r"api\.dub\.co\/links\?",
            obj! { "body" => js::parse(r#"[
                { "id": "l1", "domain": "dub.sh", "key": "launch", "url": "https://a.com/launch", "title": "Launch", "createdAt": "2026-01-02T00:00:00Z" },
                { "id": "l2", "domain": "go.brand.com", "key": "sale", "url": "https://a.com/sale", "title": null, "createdAt": "2026-02-03T00:00:00Z" }
            ]"#).unwrap() },
        ),
        (
            r"\/events\?.*linkId=l1",
            obj! { "body" => js::parse(r#"[
                { "timestamp": "2026-03-01T10:00:00Z", "click": { "id": "c1", "country": "CA", "city": "Toronto", "device": "Mobile", "browser": "Chrome", "os": "iOS", "referer": "instagram.com", "refererUrl": "https://instagram.com/" } },
                { "timestamp": "2026-03-02T10:00:00Z", "click": { "id": "c2", "country": "US", "device": "Desktop", "browser": "Safari", "os": "Mac OS", "referer": "(direct)" } }
            ]"#).unwrap() },
        ),
        (r"\/events\?.*linkId=l2", obj! { "body" => arr![] }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let (links, clicks, ..) = run_all(&rl, &importing(fake), "dub", &creds(&[("apiKey", "dub_test")])).await;
    assert_eq!((links, clicks), (2.0, 2.0));
    let all = all_links(&rl).await;
    assert_eq!(
        all.iter().find(|l| l.0.slug == "launch").unwrap().0.domain,
        "",
        "dub.sh stays behind; the link moves to /go"
    );
    assert_eq!(
        all.iter().find(|l| l.0.slug == "sale").unwrap().0.domain,
        "go.brand.com",
        "branded domains come across"
    );
    let rows = rl
        .store()
        .db()
        .all("SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1", vec![])
        .await
        .unwrap();
    assert_eq!(
        (rows[0].text("country"), rows[0].text("source"), rows[0].text("device")),
        ("CA".into(), "Instagram".into(), "mobile".into())
    );
}

#[tokio::test]
async fn dub_daily_counts_when_the_plan_has_no_events_api() {
    let fake = serve(vec![
        (
            r"api\.dub\.co\/links\?",
            obj! { "body" => js::parse(r#"[{ "id": "l1", "domain": "dub.sh", "key": "x", "url": "https://a.com", "title": "X", "createdAt": "2026-01-02T00:00:00Z" }]"#).unwrap() },
        ),
        (
            r"\/events\?",
            obj! { "status" => 403, "body" => obj! { "error" => obj! { "message" => "Business plan required" } } },
        ),
        (
            r"\/analytics\?",
            obj! { "body" => js::parse(r#"[{ "start": "2026-03-01T00:00:00.000Z", "clicks": 3 }, { "start": "2026-03-02T00:00:00.000Z", "clicks": 0 }]"#).unwrap() },
        ),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let (_, clicks, ..) = run_all(&rl, &importing(fake), "dub", &creds(&[("apiKey", "dub_test")])).await;
    assert_eq!(clicks, 3.0);
    let all = all_links(&rl).await;
    assert_eq!(all[0].1, 3.0);
    assert_eq!(all[0].2, 0.0, "daily counts add clicks, not made-up visitors");
}

#[tokio::test]
async fn bitly_every_group_custom_back_halves_daily_counts() {
    let fake = serve(vec![
        (
            r"\/v4\/groups$",
            obj! { "body" => js::parse(r#"{ "groups": [{ "guid": "G1" }, { "guid": "G2" }] }"#).unwrap() },
        ),
        (
            r"\/groups\/G1\/bitlinks",
            obj! { "body" => js::parse(r#"{ "links": [
                { "id": "bit.ly/3abc", "link": "https://bit.ly/3abc", "long_url": "https://a.com/1", "title": "One", "created_at": "2026-01-01T00:00:00+0000", "custom_bitlinks": ["https://t.brand.com/one"] },
                { "id": "bit.ly/gone", "link": "https://bit.ly/gone", "long_url": "https://a.com/x", "title": "Gone", "created_at": "2026-01-01T00:00:00+0000", "is_deleted": true }
            ], "pagination": { "search_after": "" } }"#).unwrap() },
        ),
        (
            r"\/groups\/G2\/bitlinks",
            obj! { "body" => js::parse(r#"{ "links": [{ "id": "bit.ly/4def", "link": "https://bit.ly/4def", "long_url": "https://a.com/2", "title": null, "created_at": "2026-02-01T00:00:00+0000" }], "pagination": {} }"#).unwrap() },
        ),
        (
            r"\/bitlinks\/bit\.ly%2F3abc\/clicks",
            obj! { "body" => js::parse(r#"{ "link_clicks": [{ "clicks": 5, "date": "2026-03-01T00:00:00+0000" }, { "clicks": 2, "date": "2026-03-02T00:00:00+0000" }] }"#).unwrap() },
        ),
        (
            r"\/bitlinks\/bit\.ly%2F4def\/clicks",
            obj! { "status" => 402, "body" => obj! { "message" => "UPGRADE_REQUIRED" } },
        ),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let (links, clicks, ..) = run_all(&rl, &importing(fake), "bitly", &creds(&[("token", "bitly_test")])).await;
    assert_eq!(links, 2.0, "the deleted link is skipped");
    assert_eq!(clicks, 7.0);
    let mut pairs: Vec<(String, String)> = all_links(&rl).await.into_iter().map(|l| (l.0.domain, l.0.slug)).collect();
    pairs.sort();
    assert_eq!(pairs, vec![("".to_string(), "4def".to_string()), ("t.brand.com".to_string(), "one".to_string())]);
}

#[tokio::test]
async fn shortio_every_domain_paged_with_daily_counts_in_either_shape() {
    let fake = serve(vec![
        (
            r"api\.short\.io\/api\/domains",
            obj! { "body" => js::parse(r#"[{ "id": 7, "hostname": "s.brand.com" }]"#).unwrap() },
        ),
        (
            r"api\/links\?.*pageToken=P2",
            obj! { "body" => js::parse(r#"{ "links": [{ "idString": "lnk2", "id": 2, "path": "two", "originalURL": "https://a.com/2", "createdAt": "2026-02-01T00:00:00Z" }], "nextPageToken": null }"#).unwrap() },
        ),
        (
            r"api\/links\?domain_id=7",
            obj! { "body" => js::parse(r#"{ "links": [{ "idString": "lnk1", "id": 1, "path": "one", "originalURL": "https://a.com/1", "title": "One", "createdAt": "2026-01-01T00:00:00Z" }], "nextPageToken": "P2" }"#).unwrap() },
        ),
        (
            r"statistics\/link\/lnk1\/by_interval",
            obj! { "body" => js::parse(r#"{ "clickStatistics": [{ "x": "2026-03-01T00:00:00Z", "y": 4 }] }"#).unwrap() },
        ),
        (
            r"statistics\/link\/lnk2\/by_interval",
            obj! { "body" => obj! { "clickStatistics" => obj! { "datasets" => arr![obj! { "data" => arr![obj! { "x" => 1_772_409_600_000_i64, "y" => 1 }] }] } } },
        ),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let (links, clicks, ..) = run_all(&rl, &importing(fake), "shortio", &creds(&[("apiKey", "sk_test")])).await;
    assert_eq!((links, clicks), (2.0, 5.0));
}

#[tokio::test]
async fn rebrandly_links_only_paged_by_the_last_id() {
    let page = |from: usize, n: usize| -> Value {
        Value::Array(
            (0..n)
                .map(|i| {
                    let k = from + i;
                    obj! {
                        "id" => format!("r{k}"),
                        "slashtag" => format!("s{k}"),
                        "destination" => format!("https://a.com/{k}"),
                        "domain" => obj! { "fullName" => "rebrand.ly" },
                        "createdAt" => "2026-01-01T00:00:00Z",
                    }
                })
                .collect(),
        )
    };
    let fake = serve(vec![
        (r"\/links\?.*last=r24", obj! { "body" => page(25, 3) }),
        (r"rebrandly\.com\/v1\/links\?", obj! { "body" => page(0, 25) }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let (links, clicks, ..) = run_all(&rl, &importing(fake), "rebrandly", &creds(&[("apiKey", "rb_test")])).await;
    assert_eq!((links, clicks), (28.0, 0.0));
    assert_eq!(all_links(&rl).await[0].0.domain, "", "rebrand.ly stays behind");
}

#[tokio::test]
async fn umami_signs_in_with_a_username_and_password_and_re_runs_skip_what_is_there() {
    let fake = Fake::new(Box::new(|url, init| {
        let href = url.href();
        let ok = |v: Value| Some(Ok((200, v, vec![])));
        if href.contains("/api/auth/login") {
            let body = js::parse(&String::from_utf8_lossy(init.body.as_deref().unwrap_or_default())).unwrap();
            return ok(if body.at("password").as_str() == Some("pw") {
                obj! { "token" => "tok" }
            } else {
                obj! {}
            });
        }
        if href.contains("/api/links?") {
            return ok(js::parse(r#"{ "data": [{ "id": "u-1", "name": "Golden", "url": "https://a.com", "slug": "golden", "createdAt": "2026-01-01T00:00:00Z", "deletedAt": null, "customDomain": { "domain": "t.brand.com" } }], "count": 1 }"#).unwrap());
        }
        if href.contains("/websites/u-1/events") {
            return ok(js::parse(r#"{ "data": [{ "sessionId": "s1", "createdAt": "2026-03-01T00:00:00Z", "urlPath": "/golden", "urlQuery": "utm_source=newsletter", "referrerDomain": "", "referrerPath": "", "country": "GB", "city": "London", "device": "mobile", "os": "iOS", "browser": "ios" }], "count": 1 }"#).unwrap());
        }
        if href.contains("/websites/u-1/sessions") {
            return ok(js::parse(r#"{ "data": [{ "id": "s1", "screen": "390x844", "language": "en-GB", "region": "ENG" }], "count": 1 }"#).unwrap());
        }
        None
    }));
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let http = importing(fake.clone());
    let c = creds(&[("url", "https://stats.example.com/"), ("username", "jon"), ("password", "pw")]);
    let first = import_step_with(&rl, &http, "default", "umami", &c, None, 0.0).await.unwrap();
    assert_eq!((first.links, first.clicks), (1.0, 1.0));
    assert!(fake.calls()[0].starts_with("POST stats.example.com/api/auth/login"));
    let rows = rl.store().db().all("SELECT region, source, browser FROM rl_sessions", vec![]).await.unwrap();
    assert_eq!(
        (rows[0].text("region"), rows[0].text("source"), rows[0].text("browser")),
        ("GB-ENG".into(), "Newsletter".into(), "Safari".into())
    );
    let again = import_step_with(&rl, &http, "default", "umami", &c, None, 0.0).await.unwrap();
    assert_eq!(again.skipped, 1.0);
    let bad =
        import_step_with(&rl, &http, "default", "umami", &creds(&[("url", "nope")]), None, 0.0).await.unwrap_err();
    assert!(bad.message().contains("Umami address"));
    let nowhere = import_step_with(&rl, &http, "default", "nowhere", &creds(&[]), None, 0.0).await.unwrap_err();
    assert!(nowhere.message().contains("cannot import"));
    assert_eq!(nowhere.coded().unwrap().code, "import_source");
}

#[tokio::test]
async fn umami_a_link_already_here_with_the_same_slug_and_destination_is_skipped_before_its_history_is_fetched() {
    let fake = serve(vec![
        (
            r"\/api\/links\?",
            obj! { "body" => js::parse(r#"{ "data": [{ "id": "u-9", "name": "Golden", "url": "https://a.com/", "slug": "golden", "createdAt": "2026-01-01T00:00:00Z", "deletedAt": null }], "count": 1 }"#).unwrap() },
        ),
        (r"\/websites\/u-9\/", obj! { "body" => obj! { "data" => arr![], "count" => 0 } }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    rl.init().await.unwrap();
    // Brought in earlier some other way, such as a CSV, so it has no Umami id.
    rl.links()
        .create(
            "default",
            &runlight::links::LinkInput {
                url: "https://a.com".into(),
                slug: Some("golden".into()),
                name: Some("Golden".into()),
                domain: None,
            },
        )
        .await
        .unwrap();
    let step = import_step_with(
        &rl,
        &importing(fake.clone()),
        "default",
        "umami",
        &creds(&[("url", "https://stats.example.com/"), ("apiKey", "k")]),
        None,
        0.0,
    )
    .await
    .unwrap();
    assert_eq!((step.skipped, step.links), (1.0, 0.0));
    assert!(!fake.calls().iter().any(|c| c.contains("/websites/u-9/")), "no history was fetched for it");
}

#[tokio::test]
async fn a_link_whose_slug_is_taken_or_unusable_is_reported_with_a_code() {
    let fake = serve(vec![
        (
            r"api\.dub\.co\/links\?",
            obj! { "body" => js::parse(r#"[
                { "id": "d1", "domain": "dub.sh", "key": "golden", "url": "https://b.com", "title": "Taken", "createdAt": "2026-01-02T00:00:00Z" },
                { "id": "d2", "domain": "dub.sh", "key": "bad key", "url": "https://b.com/2", "title": "Bad", "createdAt": "2026-01-02T00:00:00Z" }
            ]"#).unwrap() },
        ),
        (r"\/events\?", obj! { "body" => arr![] }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    rl.init().await.unwrap();
    rl.links()
        .create(
            "default",
            &runlight::links::LinkInput {
                url: "https://a.com".into(),
                slug: Some("golden".into()),
                name: Some("Golden".into()),
                domain: None,
            },
        )
        .await
        .unwrap();
    let step =
        import_step_with(&rl, &importing(fake), "default", "dub", &creds(&[("apiKey", "k")]), None, 0.0).await.unwrap();
    assert_eq!(
        js::stringify(&Value::Array(step.failed)),
        r#"[{"slug":"golden","reason":"/golden is already used by \"Golden\"","code":"import_slug_taken","params":{"slug":"golden","name":"Golden"}},{"slug":"bad key","reason":"/bad key has characters Runlight slugs cannot use","code":"import_slug_bad","params":{"slug":"bad key"}}]"#
    );
}

// visits-import.test.ts

/// A small Umami: one website, two days of events, answering by time window like the real API.
fn fake_umami() -> Arc<Fake> {
    let events = js::parse(
        r#"[
        { "sessionId": "s1", "createdAt": "2026-03-01T10:00:00.000Z", "hostname": "blog.example.com", "urlPath": "/", "urlQuery": "utm_campaign=spring", "referrerDomain": "www.google.com", "referrerPath": "/", "pageTitle": "Home", "eventType": 1, "country": "CA", "city": "Toronto", "device": "mobile", "os": "iOS", "browser": "ios" },
        { "sessionId": "s1", "createdAt": "2026-03-01T10:02:00.000Z", "hostname": "blog.example.com", "urlPath": "/pricing", "pageTitle": "Pricing", "eventType": 1, "country": "CA", "city": "Toronto", "device": "mobile", "os": "iOS", "browser": "ios" },
        { "sessionId": "s1", "createdAt": "2026-03-01T10:03:00.000Z", "hostname": "blog.example.com", "urlPath": "/pricing", "eventType": 2, "eventName": "Signup", "country": "CA", "city": "Toronto", "device": "mobile", "os": "iOS", "browser": "ios" },
        { "sessionId": "s1", "createdAt": "2026-03-01T12:30:00.000Z", "hostname": "blog.example.com", "urlPath": "/blog", "eventType": 1, "country": "CA", "city": "Toronto", "device": "mobile", "os": "iOS", "browser": "ios" },
        { "sessionId": "s2", "createdAt": "2026-03-02T09:00:00.000Z", "hostname": "blog.example.com", "urlPath": "/", "eventType": 1, "country": "GB", "city": "London", "device": "desktop", "os": "Mac OS", "browser": "chrome" },
        { "sessionId": "s2", "createdAt": "2026-03-02T09:00:01.000Z", "hostname": "blog.example.com", "urlPath": "/", "eventType": 5, "country": "GB", "city": "London", "device": "desktop", "os": "Mac OS", "browser": "chrome" }
    ]"#,
    )
    .unwrap();
    let sessions = js::parse(
        r#"[{ "id": "s1", "screen": "390x844", "language": "en-CA", "region": "CA-ON" }, { "id": "s2", "screen": "1440x900", "language": "en-GB", "region": "GB-ENG" }]"#,
    )
    .unwrap();
    umami_answering(events, sessions, "2026-03-01T08:00:00Z", true, Some("Bearer key"))
}

/// An Umami answering with these events (newest first when `reverse`) and sessions.
fn umami_answering(
    events: Value,
    sessions: Value,
    created: &str,
    reverse: bool,
    auth: Option<&'static str>,
) -> Arc<Fake> {
    let created = created.to_string();
    Fake::new(Box::new(move |url, init| {
        if let Some(a) = auth {
            assert_eq!(init.headers.get("authorization").as_deref(), Some(a), "every request carries the key");
        }
        let reply = |v: Value| Some(Ok((200, v, vec![])));
        let path = url.pathname();
        if path == "/api/websites" {
            return reply(
                js::parse(r#"{ "data": [{ "id": "w1", "name": "Blog", "domain": "blog.example.com" }], "count": 1 }"#)
                    .unwrap(),
            );
        }
        if path == "/api/websites/w1" {
            return reply(obj! { "id" => "w1", "createdAt" => created.clone() });
        }
        let q = url.search_params();
        let from = js::text_number(q.get("startAt").unwrap_or_default());
        let to = js::text_number(q.get("endAt").unwrap_or_default());
        if path == "/api/websites/w1/events" {
            let mut rows: Vec<Value> = events
                .as_array()
                .unwrap()
                .iter()
                .filter(|e| {
                    let t = date_parse(e.at("createdAt").as_str().unwrap());
                    t >= from && t <= to
                })
                .cloned()
                .collect();
            if reverse {
                rows.reverse();
            }
            let n = rows.len();
            return reply(obj! { "data" => Value::Array(rows), "count" => n });
        }
        if path == "/api/websites/w1/sessions" {
            let n = sessions.as_array().unwrap().len();
            return reply(obj! { "data" => sessions.clone(), "count" => n });
        }
        None
    }))
}

/// Imports a website's history to its end, adding up what each step did.
async fn import_all(rl: &Runlight, http: &Http, credentials: &Credentials) -> (f64, f64, f64, usize) {
    let (mut pageviews, mut events, mut visits, mut steps) = (0.0, 0.0, 0.0, 0);
    let mut cursor: Option<String> = None;
    loop {
        let step =
            import_umami_visits(rl, http, "default", credentials, "w1", cursor.as_deref()).await.expect("a step");
        assert!(step.done <= step.total);
        cursor = step.cursor;
        pageviews += step.pageviews;
        events += step.events;
        visits += step.visits;
        steps += 1;
        if cursor.is_none() {
            break;
        }
    }
    (pageviews, events, visits, steps)
}

fn key_creds() -> Credentials {
    creds(&[("url", "https://umami.example.com"), ("apiKey", "key")])
}

const RANGE: &str = "from=2026-03-01&to=2026-03-03&compare=off";

#[tokio::test]
async fn umami_visit_history_pageviews_and_events_become_visits_with_sources_places_and_devices() {
    let fake = fake_umami();
    let http = importing(fake.clone());
    let websites = umami_websites(&http, &key_creds()).await.unwrap();
    assert_eq!(js::stringify(&Value::Array(websites)), r#"[{"id":"w1","name":"Blog","domain":"blog.example.com"}]"#);

    let (rl, routes, clock) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", Some(fake)).await;
    let (pageviews, events, visits, _) = import_all(&rl, &http, &key_creds()).await;
    assert_eq!((pageviews, events, visits), (4.0, 1.0, 3.0));

    let stats = get(&routes, &format!("/api/stats?{RANGE}")).await;
    assert_eq!(stat(&stats, "pageviews"), 4.0);
    assert_eq!(stat(&stats, "visits"), 3.0);
    assert_eq!(stat(&stats, "visitors"), 2.0, "one Umami session on one day is one visitor");
    assert!(stat(&stats, "visitDuration") > 0.0, "imported visits take their length from first to last pageview");
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=source")).await, vec!["Google"]);
    let mut regions = values(&routes, &format!("/api/breakdown?{RANGE}&dimension=region")).await;
    regions.sort();
    assert_eq!(regions, vec!["CA-ON", "GB-ENG"]);
    let mut browsers = values(&routes, &format!("/api/breakdown?{RANGE}&dimension=browser")).await;
    browsers.sort();
    assert_eq!(browsers, vec!["Chrome", "Safari"]);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=event")).await, vec!["Signup"]);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=utm_campaign")).await, vec!["spring"]);

    // Running it again carries on from where it stopped, so nothing doubles.
    clock.fetch_add(86_400_000, Ordering::SeqCst);
    let again = import_umami_visits(&rl, &http, "default", &key_creds(), "w1", None).await.unwrap();
    assert_eq!(again.pageviews, 0.0);
    assert_eq!(stat(&get(&routes, &format!("/api/stats?{RANGE}")).await, "pageviews"), 4.0);

    // No imported visitor id lasts past a day.
    let ids = rl
        .store()
        .db()
        .all("SELECT DISTINCT visitor, date(ts / 1000, 'unixepoch') AS day FROM rl_events", vec![])
        .await
        .unwrap();
    let mut days: std::collections::HashMap<String, std::collections::HashSet<String>> = Default::default();
    for r in ids {
        days.entry(r.text("visitor")).or_default().insert(r.text("day"));
    }
    assert!(days.values().all(|d| d.len() == 1));
}

/// Runlight's own first visit, sent through the tracker.
async fn live_visit(routes: &Routes) {
    let answer = post(
        routes,
        "/e",
        &[("user-agent", "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36"), ("x-forwarded-for", "203.0.113.9")],
        r#"{"k":"pageview","u":"https://blog.example.com/"}"#,
    )
    .await;
    assert_eq!(answer.status, 202);
}

#[tokio::test]
async fn umami_visit_history_stops_where_runlights_own_visits_begin() {
    let fake = fake_umami();
    let (rl, routes, _) = make(parse_ms("2026-03-01T23:00:00Z"), "UTC", Some(fake.clone())).await;
    // Runlight started counting on the evening of March 1st.
    live_visit(&routes).await;
    let (pageviews, ..) = import_all(&rl, &importing(fake), &key_creds()).await;
    assert_eq!(pageviews, 3.0, "March 2nd is left to Runlight");
}

/// A database with no transactions that fails after writing part of a step, as D1 can.
struct Flaky {
    inner: Arc<dyn Db>,
    failing: AtomicBool,
    writes: AtomicUsize,
}

impl Db for Flaky {
    fn dialect(&self) -> Dialect {
        self.inner.dialect()
    }

    fn all<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, DbError>> {
        self.inner.all(sql, params)
    }

    fn run<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<u64, DbError>> {
        Box::pin(async move {
            if self.failing.load(Ordering::SeqCst)
                && sql.starts_with("INSERT INTO rl_events")
                && self.writes.fetch_add(1, Ordering::SeqCst) >= 2
            {
                self.failing.store(false, Ordering::SeqCst);
                return Err(DbError("connection lost".into()));
            }
            self.inner.run(sql, params).await
        })
    }

    fn hold(&self, kind: Hold) -> BoxFuture<'_, Result<Arc<dyn Db>, DbError>> {
        Box::pin(async move {
            if self.failing.load(Ordering::SeqCst) && kind == Hold::Transaction {
                // No transaction: what is written stays written.
                return Ok(Arc::new(Flaky {
                    inner: self.inner.clone(),
                    failing: AtomicBool::new(true),
                    writes: AtomicUsize::new(0),
                }) as Arc<dyn Db>);
            }
            self.inner.hold(kind).await
        })
    }
}

#[tokio::test]
async fn a_step_that_failed_part_way_can_run_again_without_counting_anything_twice() {
    let fake = fake_umami();
    let inner = store().await;
    let flaky =
        Arc::new(Flaky { inner: inner.db().clone(), failing: AtomicBool::new(false), writes: AtomicUsize::new(0) });
    let (rl, routes, _) =
        make_on(SqlStore::new(flaky.clone()), parse_ms("2026-03-04T00:00:00Z"), "UTC", Some(fake.clone()));
    rl.init().await.unwrap();
    let http = importing(fake);
    flaky.failing.store(true, Ordering::SeqCst);
    let failed = import_umami_visits(&rl, &http, "default", &key_creds(), "w1", None).await.unwrap_err();
    assert!(failed.message().contains("connection lost"));
    flaky.failing.store(false, Ordering::SeqCst);
    let written = rl.store().db().all("SELECT COUNT(*) AS n FROM rl_events", vec![]).await.unwrap();
    assert_eq!(written[0].int("n"), 2, "half of the first step was left behind");

    import_all(&rl, &http, &key_creds()).await;
    let stats = get(&routes, &format!("/api/stats?{RANGE}")).await;
    assert_eq!(stat(&stats, "pageviews"), 4.0);
    assert_eq!(stat(&stats, "visits"), 3.0);
    let totals = rl
        .store()
        .db()
        .all("SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions", vec![])
        .await
        .unwrap();
    assert_eq!((totals[0].int("pageviews"), totals[0].int("events")), (4, 1));
}

#[tokio::test]
async fn umami_visit_history_skips_days_older_than_the_site_keeps() {
    let fake = fake_umami();
    let (rl, _, _) = make(parse_ms("2026-09-01T12:00:00Z"), "UTC", Some(fake.clone())).await;
    rl.init().await.unwrap();
    // Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
    rl.set_retention("default", Some(6)).await.unwrap();
    let (pageviews, ..) = import_all(&rl, &importing(fake), &key_creds()).await;
    assert_eq!(pageviews, 1.0, "only March 2nd comes in");
}

#[tokio::test]
async fn an_imported_visit_across_utc_midnight_is_one_visit_on_the_sites_own_day() {
    let events = js::parse(
        r#"[
        { "sessionId": "n1", "createdAt": "2026-03-02T23:55:00.000Z", "hostname": "blog.example.com", "urlPath": "/", "eventType": 1, "country": "CA", "device": "desktop", "os": "Mac OS", "browser": "chrome" },
        { "sessionId": "n1", "createdAt": "2026-03-03T00:05:00.000Z", "hostname": "blog.example.com", "urlPath": "/about", "eventType": 1, "country": "CA", "device": "desktop", "os": "Mac OS", "browser": "chrome" }
    ]"#,
    )
    .unwrap();
    let fake = umami_answering(events, js::parse(r#"[{ "id": "n1" }]"#).unwrap(), "2026-03-02T00:00:00Z", false, None);
    let (rl, routes, _) = make(parse_ms("2026-03-10T00:00:00Z"), "America/Toronto", Some(fake.clone())).await;
    import_all(&rl, &importing(fake), &key_creds()).await;
    let stats = get(&routes, "/api/stats?from=2026-03-02&to=2026-03-02&compare=off").await;
    assert_eq!((stat(&stats, "visits"), stat(&stats, "visitors"), stat(&stats, "pageviews")), (1.0, 1.0, 2.0));
}

#[tokio::test]
async fn a_step_cursor_carries_a_sign_in_token_but_never_an_api_key() {
    let events = js::parse(r#"[{ "sessionId": "s1", "createdAt": "2026-03-01T10:00:00.000Z", "hostname": "blog.example.com", "urlPath": "/", "eventType": 1 }]"#).unwrap();
    let fake = umami_answering(events, js::parse("[]").unwrap(), "2026-01-01T00:00:00Z", false, None);
    let login = Fake::new(Box::new(move |url, init| {
        if url.pathname() == "/api/auth/login" {
            return Some(Ok((200, obj! { "token" => "session-token" }, vec![])));
        }
        (fake.answer)(url, init)
    }));
    let (rl, _, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", Some(login.clone())).await;
    let http = importing(login);
    let with_key = import_umami_visits(&rl, &http, "default", &key_creds(), "w1", None).await.unwrap();
    assert!(!with_key.cursor.as_deref().unwrap().contains("key"));
    assert!(!with_key.cursor.as_deref().unwrap().contains("token"));
    let password = creds(&[("url", "https://umami.example.com"), ("username", "jon"), ("password", "pw")]);
    let (rl, _, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", None).await;
    let step = import_umami_visits(&rl, &http, "default", &password, "w1", None).await.unwrap();
    let cursor = js::parse(step.cursor.as_deref().unwrap()).unwrap();
    assert_eq!(cursor.at("token").as_str(), Some("session-token"));
    assert!(!step.cursor.unwrap().contains("pw"));
}

// visits-import-days.test.ts

fn ev(session: &str, iso: &str, path: &str, event: Option<&str>) -> Value {
    let mut o = Object::new();
    o.set("sessionId", session);
    o.set("createdAt", js::iso_string(parse_ms(iso)));
    o.set("hostname", "blog.example.com");
    o.set("urlPath", path);
    o.set("eventType", if event.is_some() { 2 } else { 1 });
    if let Some(e) = event {
        o.set("eventName", e);
    }
    Value::Object(o)
}

async fn breakdown_pairs(routes: &Routes, path: &str, count: &str) -> Vec<(String, f64)> {
    get(routes, path)
        .await
        .at("rows")
        .as_array()
        .unwrap()
        .iter()
        .map(|r| (js::js_string(r.at("value")), r.at(count).as_f64().unwrap()))
        .collect()
}

#[tokio::test]
async fn an_imported_visit_that_runs_past_midnight_keeps_one_visitor_on_all_its_rows() {
    let events = Value::Array(vec![
        ev("s1", "2026-03-01T23:50:00Z", "/a", None),
        ev("s1", "2026-03-02T00:05:00Z", "/b", None),
        ev("s1", "2026-03-02T00:06:00Z", "/b", Some("Signup")),
        ev("s1", "2026-03-02T10:00:00Z", "/b", None),
        ev("s1", "2026-03-02T10:01:00Z", "/b", Some("Signup")),
    ]);
    let fake = umami_answering(events, js::parse("[]").unwrap(), "2026-03-01T00:00:00.000Z", true, None);
    let (rl, routes, _) = make(parse_ms("2026-03-05T12:00:00Z"), "UTC", Some(fake.clone())).await;
    import_all(&rl, &importing(fake), &key_creds()).await;
    let differing = rl
        .store()
        .db()
        .all("SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor", vec![])
        .await
        .unwrap();
    assert!(differing.is_empty());
    let read = || async {
        (
            breakdown_pairs(&routes, "/api/breakdown?from=2026-03-01&to=2026-03-02&dimension=page", "visitors").await,
            breakdown_pairs(&routes, "/api/breakdown?from=2026-03-01&to=2026-03-02&dimension=event", "visitors").await,
        )
    };
    let raw = read().await;
    while rl.build_rollups().await.unwrap() > 0 {}
    assert_eq!(read().await, raw, "the same before and after the days are built");
    assert_eq!(raw.1, vec![("Signup".to_string(), 2.0)]);
}

#[tokio::test]
async fn a_visit_that_crosses_into_the_next_import_step_has_its_first_day_built_again() {
    let events = Value::Array(vec![
        ev("s0", "2026-03-02T10:00:00Z", "/", None),
        ev("s1", "2026-03-14T23:50:00Z", "/a", None),
        ev("s1", "2026-03-15T00:10:00Z", "/b", None),
        ev("s2", "2026-03-20T10:00:00Z", "/", None),
    ]);
    let fake = umami_answering(events, js::parse("[]").unwrap(), "2026-03-01T00:00:00.000Z", true, None);
    let (rl, routes, _) = make(parse_ms("2026-03-25T12:00:00Z"), "UTC", Some(fake.clone())).await;
    let http = importing(fake);
    let mut cursor = import_umami_visits(&rl, &http, "default", &key_creds(), "w1", None).await.unwrap().cursor;
    // The scheduled check builds days between two steps.
    while rl.build_rollups().await.unwrap() > 0 {}
    while let Some(c) = cursor {
        cursor = import_umami_visits(&rl, &http, "default", &key_creds(), "w1", Some(&c)).await.unwrap().cursor;
    }
    while rl.build_rollups().await.unwrap() > 0 {}
    let read = || async {
        (
            js::stringify(get(&routes, "/api/stats?from=2026-03-14&to=2026-03-14&compare=off").await.at("stats")),
            breakdown_pairs(&routes, "/api/breakdown?from=2026-03-14&to=2026-03-14&dimension=page", "pageviews").await,
        )
    };
    let rolled = read().await;
    rl.store().clear_rollups("default", None, None).await.unwrap();
    assert_eq!(rolled, read().await);
    assert_eq!(js::parse(&rolled.0).unwrap().at("pageviews").as_f64(), Some(2.0));
}

// visits-csv.test.ts

/// Runlight's own columns: two pageviews and a signup in one visit, then a direct visit the next day.
fn runlight_rows() -> Vec<Value> {
    js::parse(
        r#"[
        { "time": "2026-03-01T10:00:00Z", "url": "https://blog.example.com/?utm_campaign=spring", "referrer": "www.google.com", "visitor": "a", "country": "CA", "region": "CA-ON", "city": "Toronto", "browser": "Safari", "os": "iOS", "device": "mobile", "title": "Home" },
        { "time": "2026-03-01T10:02:00Z", "url": "https://blog.example.com/pricing", "visitor": "a", "country": "CA", "browser": "Safari", "os": "iOS", "device": "mobile" },
        { "time": "2026-03-01T10:03:00Z", "url": "https://blog.example.com/pricing", "event": "Signup", "visitor": "a" },
        { "time": "1772442000", "path": "/", "hostname": "blog.example.com", "visitor": "b", "country": "GB", "browser": "Chrome", "os": "macOS", "device": "desktop" },
        { "time": "yesterday", "path": "/x", "visitor": "c" }
    ]"#,
    )
    .unwrap()
    .as_array()
    .unwrap()
    .clone()
}

fn csv_json(step: &runlight::importers::visits::CsvImportStep) -> String {
    js::stringify(&step.to_value())
}

#[tokio::test]
async fn csv_in_runlights_format_rows_become_visits_with_sources_places_devices_and_events() {
    let (rl, routes, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", None).await;
    let rows = Value::Array(runlight_rows());
    let step = import_csv_visits(&rl, "default", Some(&rows)).await.unwrap();
    assert_eq!(csv_json(&step), r#"{"pageviews":3,"events":1,"visits":2,"skipped":1}"#);
    let stats = get(&routes, &format!("/api/stats?{RANGE}")).await;
    assert_eq!((stat(&stats, "pageviews"), stat(&stats, "visits"), stat(&stats, "visitors")), (3.0, 2.0, 2.0));
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=source")).await, vec!["Google"]);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=utm_campaign")).await, vec!["spring"]);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=event")).await, vec!["Signup"]);
    let mut devices = values(&routes, &format!("/api/breakdown?{RANGE}&dimension=device")).await;
    devices.sort();
    assert_eq!(devices, vec!["desktop", "mobile"]);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=region")).await, vec!["CA-ON"]);

    // The same file again replaces what it brought in, so nothing doubles.
    import_csv_visits(&rl, "default", Some(&rows)).await.unwrap();
    let stats = get(&routes, &format!("/api/stats?{RANGE}")).await;
    assert_eq!((stat(&stats, "pageviews"), stat(&stats, "visits")), (3.0, 2.0));
}

#[tokio::test]
async fn csv_in_runlights_format_without_a_visitor_column_every_row_is_its_own_visit() {
    let (rl, routes, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", None).await;
    let rows = js::parse(
        r#"[{ "time": "2026-03-01 10:00:00", "path": "/a" }, { "time": "2026-03-01 10:01:00", "path": "/b?ref=x" }]"#,
    )
    .unwrap();
    assert_eq!(import_csv_visits(&rl, "default", Some(&rows)).await.unwrap().visits, 2.0);
    import_csv_visits(&rl, "default", Some(&rows)).await.unwrap();
    assert_eq!(
        stat(&get(&routes, &format!("/api/stats?{RANGE}")).await, "visits"),
        2.0,
        "the same rows get the same ids the second time"
    );
    let mut pages = values(&routes, &format!("/api/breakdown?{RANGE}&dimension=page")).await;
    pages.sort();
    assert_eq!(pages, vec!["/a", "/b"]);
}

#[tokio::test]
async fn csv_from_umamis_export_pageviews_and_named_events_come_across_other_event_types_do_not() {
    let (rl, routes, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", None).await;
    let rows = js::parse(
        r#"[
        { "website_id": "w1", "session_id": "s1", "created_at": "2026-03-01 10:00:00", "hostname": "blog.example.com", "url_path": "/", "url_query": "", "referrer_domain": "news.ycombinator.com", "page_title": "Home", "event_type": "1", "country": "CA", "subdivision1": "ON", "city": "Toronto", "browser": "ios", "os": "iOS", "device": "mobile", "screen": "390x844", "language": "en-CA" },
        { "website_id": "w1", "session_id": "s1", "created_at": "2026-03-01 10:03:00", "hostname": "blog.example.com", "url_path": "/pricing", "event_type": "2", "event_name": "Signup" },
        { "website_id": "w1", "session_id": "s1", "created_at": "2026-03-01 10:03:01", "hostname": "blog.example.com", "url_path": "/pricing", "event_type": "5" },
        { "website_id": "w1", "session_id": "s2", "created_at": "2026-03-02T09:00:00.000Z", "hostname": "blog.example.com", "url_path": "/blog", "event_type": "1", "country": "GB", "browser": "chrome", "os": "Mac OS", "device": "desktop" }
    ]"#,
    )
    .unwrap();
    let step = import_csv_visits(&rl, "default", Some(&rows)).await.unwrap();
    assert_eq!(csv_json(&step), r#"{"pageviews":2,"events":1,"visits":2,"skipped":1}"#);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=source")).await, vec!["Hacker News"]);
    assert_eq!(values(&routes, &format!("/api/breakdown?{RANGE}&dimension=region")).await, vec!["CA-ON"]);
    let mut browsers = values(&routes, &format!("/api/breakdown?{RANGE}&dimension=browser")).await;
    browsers.sort();
    assert_eq!(browsers, vec!["Chrome", "Safari"]);
}

#[tokio::test]
async fn csv_rows_from_after_runlights_own_first_visit_are_left_to_runlight() {
    let (rl, routes, _) = make(parse_ms("2026-03-01T23:00:00Z"), "UTC", None).await;
    live_visit(&routes).await;
    let rows = Value::Array(runlight_rows()[..4].to_vec());
    let step = import_csv_visits(&rl, "default", Some(&rows)).await.unwrap();
    assert_eq!(step.pageviews, 2.0, "March 2nd is left to Runlight");
    assert_eq!(step.skipped, 1.0);
}

#[tokio::test]
async fn the_csv_route_refuses_a_file_it_cannot_read_and_a_batch_that_is_too_big() {
    let (_, routes, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", None).await;
    let send = |rows: Value| {
        let routes = &routes;
        async move {
            let body = js::stringify(&obj! { "rows" => rows });
            let answer = post(routes, "/api/import/csv/visits", &[("content-type", "application/json")], &body).await;
            (answer.status, js::parse(&answer.text()).unwrap())
        }
    };
    let (status, unknown) = send(js::parse(r#"[{ "date": "2026-03-01", "visitors": "12" }]"#).unwrap()).await;
    assert_eq!(status, 400);
    assert_eq!(unknown.at("code").as_str(), Some("import_csv_format"));
    let (_, big) = send(Value::Array(vec![runlight_rows()[0].clone(); 2001])).await;
    assert_eq!(big.at("code").as_str(), Some("import_csv_batch"));
    let (status, ok) = send(Value::Array(runlight_rows())).await;
    assert_eq!(status, 200);
    assert_eq!(ok.at("visits").as_f64(), Some(2.0));
}

#[test]
fn csv_times_and_formats() {
    assert_eq!(csv_format(&["created_at", "url_path", "session_id"]), Some(CsvFormat::Umami));
    assert_eq!(csv_format(&["time", "url"]), Some(CsvFormat::Runlight));
    assert_eq!(csv_format(&["date", "visitors"]), None);
    let iso = date_parse("2026-03-01T10:00:00Z");
    let row = |k: &str, v: &str| Object::new().with(k, v);
    assert_eq!(row_time(&row("time", "2026-03-01 10:00:00"), CsvFormat::Runlight), iso, "no zone reads as UTC");
    assert_eq!(row_time(&row("time", "2026-03-01T12:00:00+02:00"), CsvFormat::Runlight), iso);
    assert_eq!(row_time(&row("time", &js::format_number(iso / 1000.0)), CsvFormat::Runlight), iso, "Unix seconds");
    assert_eq!(row_time(&row("time", &js::format_number(iso)), CsvFormat::Runlight), iso, "Unix milliseconds");
    assert_eq!(row_time(&row("created_at", "2026-03-01 10:00:00"), CsvFormat::Umami), iso);
    assert!(row_time(&row("time", ""), CsvFormat::Runlight).is_nan());
}

#[test]
fn dates_parse_as_javascript_parses_them() {
    assert_eq!(date_parse("2026-01-01T00:00:00Z"), 1_767_225_600_000.0);
    assert_eq!(date_parse("2026-01-01T00:00:00+0000"), 1_767_225_600_000.0);
    assert_eq!(date_parse("2026-01-01"), 1_767_225_600_000.0);
    assert_eq!(date_parse("2026-01-01T02:00:00.5+02:00"), 1_767_225_600_500.0);
    assert_eq!(date_parse("1970-01-01T00:00:00.000Z"), 0.0);
    assert!(date_parse("nope").is_nan());
    assert!(date_parse("2026-02-30").is_nan());
    assert!(date_parse("").is_nan());
    assert_eq!(runlight::importers::http::iso_string(1_772_409_600_000.0).unwrap(), "2026-03-02T00:00:00.000Z");
    assert_eq!(runlight::importers::http::iso_string(-1.0).unwrap(), "1969-12-31T23:59:59.999Z");
    assert!(runlight::importers::http::iso_string(f64::NAN).is_err());
}

#[test]
fn import_errors_carry_their_code() {
    let e = ImportError::http("a.com answered 500", 500, "import_status", &[("host", "a.com"), ("status", "500")]);
    assert!(e.is_http());
    assert_eq!(e.coded().unwrap().code, "import_status");
    assert!(!ImportError::new("x", "y", &[]).is_http());
    let _ = params![1];
}

// The cases added with unreadable dates, missing totals, tokenless sign-ins, and transient Dub failures.

#[tokio::test]
async fn shortio_a_point_whose_date_cannot_be_read_is_skipped_not_the_whole_step() {
    let fake = serve(vec![
        (
            r"api\.short\.io\/api\/domains",
            obj! { "body" => js::parse(r#"[{ "id": 7, "hostname": "s.brand.com" }]"#).unwrap() },
        ),
        (
            r"api\/links\?domain_id=7",
            obj! { "body" => js::parse(r#"{ "links": [{ "idString": "lnk1", "id": 1, "path": "one", "originalURL": "https://a.com/1", "createdAt": "2026-01-01T00:00:00Z" }], "nextPageToken": null }"#).unwrap() },
        ),
        (
            r"statistics\/link\/lnk1\/by_interval",
            obj! { "body" => js::parse(r#"{ "clickStatistics": [{ "x": "1772409600000", "y": 1 }, { "x": "2026-03-01T00:00:00Z", "y": 4 }, { "x": 9e15, "y": 2 }] }"#).unwrap() },
        ),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let (links, clicks, ..) = run_all(&rl, &importing(fake), "shortio", &creds(&[("apiKey", "sk_test")])).await;
    assert_eq!((links, clicks), (1.0, 4.0));
}

#[tokio::test]
async fn umami_a_link_list_without_a_count_gives_no_total_and_pages_on_while_pages_are_full() {
    let link = |i: usize| {
        obj! { "id" => format!("u{i}"), "name" => format!("N{i}"), "url" => format!("https://a.com/{i}"), "slug" => format!("s{i}"), "createdAt" => "2026-01-01T00:00:00Z", "deletedAt" => Value::Null }
    };
    let fake = serve(vec![
        (r"\/api\/links\?page=1&", obj! { "body" => obj! { "data" => Value::Array((0..5).map(link).collect()) } }),
        (r"\/api\/links\?page=2&", obj! { "body" => obj! { "data" => arr![link(5)], "count" => "six" } }),
        (r"\/websites\/", obj! { "body" => obj! { "data" => arr![], "count" => 0 } }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let http = importing(fake);
    let c = creds(&[("url", "https://stats.example.com"), ("apiKey", "k")]);
    let first = import_step_with(&rl, &http, "default", "umami", &c, None, 0.0).await.unwrap();
    assert_eq!(first.total, None);
    assert!(first.cursor.is_some(), "a full page may have more after it");
    let second =
        import_step_with(&rl, &http, "default", "umami", &c, first.cursor.as_deref(), first.done).await.unwrap();
    assert_eq!((second.cursor, second.done, second.total), (None, 6.0, None));
    let empty_fake = serve(vec![(r"\/api\/links\?", obj! { "body" => obj! { "data" => arr![] } })]);
    let empty = import_step_with(&rl, &importing(empty_fake), "default", "umami", &c, None, 0.0).await.unwrap();
    assert_eq!((empty.cursor, empty.done, empty.total), (None, 0.0, None));
}

#[tokio::test]
async fn umami_a_sign_in_that_answers_without_a_token_is_refused_there() {
    let fake = serve(vec![
        (r"\/api\/auth\/login", obj! { "body" => obj! {} }),
        (r"\/api\/links\?", obj! { "body" => obj! { "data" => arr![], "count" => 0 } }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let c = creds(&[("url", "https://stats.example.com"), ("username", "jon"), ("password", "bad")]);
    let error = import_step_with(&rl, &importing(fake.clone()), "default", "umami", &c, None, 0.0).await.unwrap_err();
    assert_eq!(error.coded().unwrap().code, "import_refused");
    assert!(!error.is_http());
    assert_eq!(fake.calls(), vec!["POST stats.example.com/api/auth/login"], "nothing is asked with a missing token");
}

#[tokio::test]
async fn dub_a_failed_events_request_fails_the_step_and_keeps_per_click_history_for_the_rest() {
    let failing = Arc::new(AtomicBool::new(true));
    let f = failing.clone();
    let links = js::parse(
        r#"[
        { "id": "l1", "domain": "dub.sh", "key": "a", "url": "https://a.com/a", "title": "A", "createdAt": "2026-01-02T00:00:00Z" },
        { "id": "l2", "domain": "dub.sh", "key": "b", "url": "https://a.com/b", "title": "B", "createdAt": "2026-01-02T00:00:00Z" }
    ]"#,
    )
    .unwrap();
    let fake = Fake::new(Box::new(move |url, _| {
        let href = url.href();
        let ok = |v: Value| Some(Ok((200, v, vec![])));
        if href.contains("api.dub.co/links?") {
            return ok(if href.contains("startingAfter=l2") { arr![] } else { links.clone() });
        }
        if href.contains("/events?") && href.contains("linkId=l1") {
            if f.load(Ordering::SeqCst) {
                return Some(Ok((500, obj! {}, vec![])));
            }
            return ok(js::parse(r#"[{ "timestamp": "2026-03-01T10:00:00Z", "click": { "id": "c1" } }]"#).unwrap());
        }
        if href.contains("/events?") && href.contains("linkId=l2") {
            return ok(js::parse(r#"[{ "timestamp": "2026-03-02T10:00:00Z", "click": { "id": "c2" } }]"#).unwrap());
        }
        if href.contains("/analytics?") {
            return ok(js::parse(r#"[{ "start": "2026-03-01T00:00:00.000Z", "clicks": 9 }]"#).unwrap());
        }
        None
    }));
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    rl.init().await.unwrap();
    let http = importing(fake.clone());
    let c = creds(&[("apiKey", "k")]);
    let error = import_step_with(&rl, &http, "default", "dub", &c, None, 0.0).await.unwrap_err();
    assert_eq!(error.coded().unwrap().code, "import_status");
    assert!(!fake.calls().iter().any(|c| c.contains("/analytics")), "a server error does not switch to daily counts");
    failing.store(false, Ordering::SeqCst);
    let step = import_step_with(&rl, &http, "default", "dub", &c, None, 0.0).await.unwrap();
    assert_eq!(step.links, 2.0);
    assert_eq!(step.clicks, 2.0, "both links keep every click");
    assert!(!fake.calls().iter().any(|c| c.contains("/analytics")));
}

#[tokio::test]
async fn rebrandly_a_numeric_id_still_gives_a_text_cursor() {
    let list = Value::Array(
        (0..25)
            .map(|i| obj! { "id" => i, "slashtag" => format!("s{i}"), "destination" => format!("https://a.com/{i}"), "createdAt" => "2026-01-01T00:00:00Z" })
            .collect(),
    );
    let fake = serve(vec![
        (r"\/links\?.*last=24", obj! { "body" => arr![] }),
        (r"rebrandly\.com\/v1\/links\?", obj! { "body" => list }),
    ]);
    let (rl, _, _) = make(NOW, "UTC", Some(fake.clone())).await;
    let step = import_step_with(&rl, &importing(fake), "default", "rebrandly", &creds(&[("apiKey", "rb")]), None, 0.0)
        .await
        .unwrap();
    assert_eq!(step.cursor.as_deref(), Some("24"));
}

#[tokio::test]
async fn http_a_negative_retry_after_waits_the_default_backoff() {
    let calls = Arc::new(AtomicUsize::new(0));
    let n = calls.clone();
    let fake = Fake::new(Box::new(move |_, _| {
        if n.fetch_add(1, Ordering::SeqCst) == 0 {
            Some(Ok((429, obj! {}, vec![("retry-after".to_string(), "-5".to_string())])))
        } else {
            Some(Ok((200, arr![], vec![])))
        }
    }));
    let (sleep, waits) = no_wait();
    let http = Http::with_sleep(fake, sleep);
    assert_eq!(js::stringify(&http.get("https://api.example.com/x", &[]).await.unwrap()), "[]");
    assert_eq!(*waits.lock().unwrap(), vec![800.0]);
}

#[tokio::test]
async fn umami_visit_history_an_unreadable_saved_progress_setting_starts_as_if_there_were_none() {
    let fake = fake_umami();
    let (rl, _, _) = make(parse_ms("2026-03-04T00:00:00Z"), "UTC", Some(fake.clone())).await;
    rl.init().await.unwrap();
    rl.store().set_setting("import:umami-visits:default:w1", Some("not a number")).await.unwrap();
    let http = importing(fake);
    let mut cursor: Option<String> = None;
    let mut pageviews = 0.0;
    loop {
        let step = import_umami_visits(&rl, &http, "default", &key_creds(), "w1", cursor.as_deref()).await.unwrap();
        assert!(step.done.is_finite() && step.total.is_finite(), "progress is a number");
        cursor = step.cursor;
        pageviews += step.pageviews;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(pageviews, 4.0, "every day is read from the website's start");
}
