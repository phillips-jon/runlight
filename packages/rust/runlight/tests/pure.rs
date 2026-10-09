//! The pure modules against the fixtures written from the TypeScript SDK:
//! user agents, sources, queries, payloads, time, place, URLs, CSV, and ZIP.

mod common;

use base64::Engine;
use common::{conformance, fixture, list, s};
use runlight::geo::{self, Found};
use runlight::http::{Headers, SearchParams, Url};
use runlight::js::{self, Value};
use runlight::{obj, payload, query, sources, time, ua, zip};

fn opt(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn hints(v: Option<&Value>) -> ua::ClientHints {
    let v = v.cloned().unwrap_or(Value::Null);
    ua::ClientHints { brands: opt(v.get("brands")), mobile: opt(v.get("mobile")), platform: opt(v.get("platform")) }
}

#[test]
fn user_agents_read_as_the_sdk_reads_them() {
    let mut failures = Vec::new();
    for case in list(&conformance("ua"), "cases") {
        let text = s(case, "ua");
        let agent = ua::ai_agent(text);
        if let Some(want) = case.get("agent") {
            if agent.map(|a| (a.name, a.kind)) != Some((s(want, "name"), s(want, "kind"))) {
                failures.push(format!("agent {text}"));
            }
            continue;
        }
        if agent.is_some() {
            failures.push(format!("not an agent: {text}"));
        }
        if ua::is_bot(text) != js::opt_truthy(case.get("bot")) {
            failures.push(format!("bot {text}"));
        }
        if let Some(client) = case.get("client") {
            let got =
                ua::parse_client(text, &hints(case.get("hints")), case.get("screenWidth").and_then(Value::as_f64));
            if got.to_value() != *client {
                failures.push(format!("{text}: {}", got.to_value().to_json()));
            }
        }
    }
    for case in list(&fixture("ua"), "cases") {
        let text = s(case, "ua");
        let agent = ua::ai_agent(text)
            .map(|a| obj! { "name" => a.name, "company" => a.company, "kind" => a.kind, "token" => a.token });
        let got = obj! {
            "agent" => agent,
            "bot" => ua::is_bot(text),
            "client" => ua::parse_client(text, &hints(case.get("hints")), case.get("screenWidth").and_then(Value::as_f64)).to_value(),
        };
        let want = obj! { "agent" => case.at("agent").clone(), "bot" => case.at("bot").clone(), "client" => case.at("client").clone() };
        if got != want {
            failures.push(format!("{text}: {} not {}", got.to_json(), want.to_json()));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

fn found(f: Option<sources::Found>) -> Value {
    f.map_or(Value::Null, |f| {
        let kind = match f.kind {
            runlight::data::sources::SourceKind::Search => "search",
            runlight::data::sources::SourceKind::Social => "social",
            runlight::data::sources::SourceKind::Ai => "ai",
            runlight::data::sources::SourceKind::Email => "email",
            runlight::data::sources::SourceKind::Other => "other",
        };
        obj! { "name" => f.name, "kind" => kind }
    })
}

fn name_and_kind(v: &Value) -> Value {
    if v.is_null() {
        Value::Null
    } else {
        obj! { "name" => v.at("name").clone(), "kind" => v.at("kind").clone() }
    }
}

fn page_value(p: &sources::Page) -> Value {
    obj! {
        "hostname" => p.hostname.clone(),
        "path" => p.path.clone(),
        "utm" => obj! {
            "source" => p.utm.source.clone(), "medium" => p.utm.medium.clone(), "campaign" => p.utm.campaign.clone(),
            "term" => p.utm.term.clone(), "content" => p.utm.content.clone(),
        },
        "ref" => p.ref_.clone(),
        "paid" => p.paid,
    }
}

#[test]
fn sources_and_channels_match_the_sdk() {
    let f = fixture("sources");
    let mut failures = Vec::new();
    for case in list(&f, "hosts") {
        if found(sources::source_for_host(s(case, "host"))) != name_and_kind(case.at("source")) {
            failures.push(format!("host {}", s(case, "host")));
        }
    }
    for case in list(&f, "aliases") {
        if found(sources::source_for_alias(s(case, "alias"))) != name_and_kind(case.at("source")) {
            failures.push(format!("alias {}", s(case, "alias")));
        }
    }
    for case in list(&f, "pages") {
        let page = sources::parse_page(&Url::parse(s(case, "url")).unwrap());
        if page_value(&page) != *case.at("page") {
            failures.push(format!("page {}: {}", s(case, "url"), page_value(&page).to_json()));
        }
    }
    for case in list(&f, "visits") {
        let page = sources::parse_page(&Url::parse(s(case, "url")).unwrap());
        let internal: Vec<String> = list(case, "internal").iter().map(js::js_string).collect();
        let a = sources::attribute(&page, s(case, "referrer"), &internal);
        let got = obj! { "referrerHost" => a.referrer_host, "referrerPath" => a.referrer_path, "source" => a.source, "channel" => a.channel };
        if got != *case.at("attribution") {
            failures.push(format!("visit {} from {}: {}", s(case, "url"), s(case, "referrer"), got.to_json()));
        }
    }
    for case in list(&f, "recordedPaths") {
        let got: Value = sources::recorded_path(s(case, "input")).into();
        if got != *case.at("path") {
            failures.push(format!("recorded {:?}: {}", s(case, "input"), got.to_json()));
        }
    }
    for case in list(&f, "readablePaths") {
        if sources::readable_path(s(case, "input")) != s(case, "path") {
            failures.push(format!("readable {:?}: {}", s(case, "input"), sources::readable_path(s(case, "input"))));
        }
    }
    for case in list(&f, "stripWww") {
        if sources::strip_www(s(case, "input")) != s(case, "host") {
            failures.push(format!("stripWww {}", s(case, "input")));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn queries_and_filters_match_the_sdk() {
    let f = fixture("query");
    let dims: Vec<Value> = query::dimensions().into_iter().map(Value::from).collect();
    assert_eq!(Value::Array(dims), *f.at("dimensions"));
    assert_eq!(f.at("maxFilters").as_f64(), Some(query::MAX_FILTERS as f64));
    for case in list(&f, "dimensionTests") {
        let v = s(case, "value");
        assert_eq!(Value::from(query::is_dimension(v)), *case.at("isDimension"), "{v}");
        assert_eq!(Value::from(query::is_session_dimension(v)), *case.at("isSessionDimension"), "{v}");
        assert_eq!(Value::from(query::is_event_dimension(v)), *case.at("isEventDimension"), "{v}");
    }
    for case in list(&f, "filters") {
        let got = query::parse_filter(s(case, "text")).map_or(Value::Null, |f| f.to_value());
        assert_eq!(got, *case.at("filter"), "{}", s(case, "text"));
    }
}

#[test]
fn payloads_match_the_sdk() {
    let f = fixture("payload");
    let mut failures = Vec::new();
    for case in list(&f, "cases") {
        let got = payload::parse_payload(s(case, "text")).map_or(Value::Null, |p| {
            obj! {
                "kind" => p.kind, "site" => p.site, "url" => p.url.href(), "referrer" => p.referrer, "title" => p.title,
                "screenWidth" => p.screen_width, "screenHeight" => p.screen_height, "language" => p.language, "name" => p.name,
                "props" => p.props.map(|o| o.to_json()), "pageviewId" => p.pageview_id, "engagedMs" => p.engaged_ms, "scroll" => p.scroll,
            }
        });
        if got != *case.at("payload") {
            failures.push(format!("{}: {} not {}", s(case, "text"), got.to_json(), case.at("payload").to_json()));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

const SYSTEM_V_SUMMER: [&str; 6] =
    ["systemv/ast4adt", "systemv/est5edt", "systemv/cst6cdt", "systemv/mst7mdt", "systemv/pst8pdt", "systemv/yst9ydt"];

#[test]
fn zones_and_local_times_match_the_sdk() {
    let f = fixture("time");
    let mut failures = Vec::new();
    let samples: Vec<i64> = list(&f, "sampleTimes").iter().map(|v| v.as_f64().unwrap() as i64).collect();
    for zone in list(&f, "zones") {
        let name = s(zone, "name");
        let valid = time::is_timezone(name);
        if Value::from(valid) != *zone.at("valid") {
            failures.push(format!("{name} {}", if valid { "taken" } else { "refused" }));
            continue;
        }
        if !valid || SYSTEM_V_SUMMER.contains(&name.to_ascii_lowercase().as_str()) {
            continue;
        }
        for (i, ts) in samples.iter().enumerate() {
            if *ts < 0 {
                continue;
            }
            let (w, h) = time::local_weekday_hour(*ts, name);
            let local = format!("{} {w} {h}", time::local_date(*ts, name));
            if Some(local.as_str()) != zone.at("local").as_array().and_then(|a| a[i].as_str()) {
                failures.push(format!("{name} at {ts}: {local}"));
            }
        }
    }
    for case in list(&f, "instants") {
        let a = case.as_array().unwrap();
        let (zone, ts) = (a[0].as_str().unwrap(), a[1].as_f64().unwrap() as i64);
        let (w, h) = time::local_weekday_hour(ts, zone);
        let got = format!("{} {w} {h}", time::local_date(ts, zone));
        let want = format!("{} {} {}", a[2].as_str().unwrap(), a[3].as_f64().unwrap(), a[4].as_f64().unwrap());
        if got != want {
            failures.push(format!("{zone} {ts}: {got} not {want}"));
        }
    }
    for case in list(&f, "starts") {
        let a = case.as_array().unwrap();
        let got = time::start_of(a[1].as_str().unwrap(), a[0].as_str().unwrap(), a[2].as_f64().unwrap() as i64);
        if got as f64 != a[3].as_f64().unwrap() {
            failures.push(format!("{} start {}: {got}", a[0].as_str().unwrap(), a[1].to_json()));
        }
    }
    for case in list(&f, "dayStarts") {
        let a = case.as_array().unwrap();
        let (zone, year) = (a[0].as_str().unwrap(), a[1].as_f64().unwrap() as i64);
        let mut days = Vec::new();
        let mut d = format!("{year}-01-01");
        while d < format!("{}-01-01", year + 1) {
            days.push(Value::from(time::start_of(&d, zone, 0)));
            d = time::add_days(&d, 1);
        }
        if runlight::hash::sha256(&js::stringify(&Value::Array(days))) != a[2].as_str().unwrap() {
            failures.push(format!("{zone} {year}: every day's start"));
        }
    }
    // The fixture came from Node's ICU with time zone data 2025c. The system's database disagrees
    // wherever a zone's rules changed since (Morocco and British Columbia), so those zones are
    // compared only on 2025c.
    if tzdata_version().as_deref() != Some("2025c") {
        failures.retain(|f| !CHANGED_SINCE_2025C.iter().any(|z| f.starts_with(z)));
    }
    let mut zones: Vec<&str> = failures.iter().map(|f| f.split(' ').next().unwrap()).collect();
    zones.dedup();
    eprintln!("zones that differ: {zones:?}");
    failures.truncate(40);
    assert!(failures.is_empty(), "{failures:#?}");
}

const CHANGED_SINCE_2025C: [&str; 9] = [
    "Africa/Casablanca",
    "Africa/El_Aaiun",
    "America/Vancouver",
    "America/Edmonton",
    "America/Yellowknife",
    "America/Dawson_Creek",
    "America/Fort_Nelson",
    "Canada/Mountain",
    "Canada/Pacific",
];

/// The system's time zone data version, where it says.
fn tzdata_version() -> Option<String> {
    for path in ["/usr/share/zoneinfo/+VERSION", "/usr/share/zoneinfo/tzdata.zi"] {
        if let Ok(text) = std::fs::read_to_string(path) {
            let line = text.lines().next().unwrap_or("");
            return Some(line.trim_start_matches("# version ").trim().to_string());
        }
    }
    None
}

#[test]
fn a_url_with_three_slashes_is_a_host() {
    let url = Url::parse_with_base("///triple", "https://x.invalid");
    assert_eq!(url.map(|u| u.href()), Some("https://triple/".to_string()));
}

fn range_value(r: &time::Range) -> Value {
    obj! { "from" => r.from, "to" => r.to, "fromDate" => r.from_date.clone(), "toDate" => r.to_date.clone(), "interval" => r.interval }
}

fn range_of(v: &Value) -> time::Range {
    let interval = time::INTERVALS.iter().find(|i| v.at("interval").as_str() == Some(**i)).copied().unwrap();
    time::Range {
        from: v.at("from").as_f64().unwrap() as i64,
        to: v.at("to").as_f64().unwrap() as i64,
        from_date: s(v, "fromDate").into(),
        to_date: s(v, "toDate").into(),
        interval,
    }
}

#[test]
fn dates_ranges_and_buckets_match_the_sdk() {
    let f = fixture("time");
    let mut failures = Vec::new();
    for case in list(&f, "dates") {
        let date = s(case, "date");
        if Value::from(time::is_date(date)) != *case.at("isDate") {
            failures.push(format!("isDate {date}"));
        }
        if !case.at("plus").is_null() {
            let plus: Vec<Value> = [-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000]
                .iter()
                .map(|n| time::add_days(date, *n).into())
                .collect();
            let months: Vec<Value> =
                [-25, -12, -11, -1, 0, 1, 11, 12, 13].iter().map(|n| time::add_months(date, *n).into()).collect();
            if Value::Array(plus) != *case.at("plus") || Value::Array(months) != *case.at("months") {
                failures.push(format!("date math {date}"));
            }
        }
    }
    for case in list(&f, "ranges") {
        let input = case.at("input");
        let get = |k: &str| match input.get(k) {
            Some(Value::String(s)) => Some(s.clone()),
            _ => None,
        };
        let ri =
            time::RangeInput { period: get("period"), from: get("from"), to: get("to"), interval: get("interval") };
        let zone = s(case, "zone");
        let now = case.at("now").as_f64().unwrap() as i64;
        let first = case.at("firstDate").as_str();
        let range = time::resolve_range(&ri, zone, now, first);
        let mut got = obj! { "range" => range.as_ref().map(range_value) };
        let mut want = obj! { "range" => case.at("range").clone() };
        if let Some(range) = &range {
            let buckets = time::buckets(range, zone);
            let bucket_values: Vec<Value> =
                buckets.iter().map(|b| obj! { "start" => b.start, "end" => b.end }).collect();
            got.as_object_mut().unwrap().set(
                "buckets",
                obj! {
                    "count" => buckets.len(),
                    "first" => bucket_values.first().cloned(),
                    "sha256" => runlight::hash::sha256(&js::stringify(&Value::Array(bucket_values.clone()))),
                },
            );
            want.as_object_mut().unwrap().set("buckets", case.at("buckets").clone());
            if case.get("compare").is_some() {
                let mut compare = js::Object::new();
                for mode in ["previous", "year", "off", "custom", "nope"] {
                    let c = time::compare_range(range, mode, zone, Some("2025-02-28"), Some("2025-03-31"));
                    compare.set(mode, c.as_ref().map(range_value));
                }
                got.as_object_mut().unwrap().set("compare", compare);
                want.as_object_mut().unwrap().set("compare", case.at("compare").clone());
            }
        }
        if got != want {
            failures.push(format!("{} {now} {}: {} not {}", zone, input.to_json(), got.to_json(), want.to_json()));
        }
    }
    for case in list(&f, "compares") {
        let range = range_of(case.at("range"));
        let custom = case.at("custom");
        let c = time::compare_range(
            &range,
            s(case, "mode"),
            s(case, "zone"),
            custom.get("from").and_then(Value::as_str),
            custom.get("to").and_then(Value::as_str),
        );
        let got = c.as_ref().map_or(Value::Null, range_value);
        if got != *case.at("compare") {
            failures.push(format!("compare {}: {}", case.to_json(), got.to_json()));
        }
    }
    failures.truncate(20);
    assert!(failures.is_empty(), "{failures:#?}");
}

fn location_value(l: &geo::Location) -> Value {
    obj! { "country" => l.country.clone(), "region" => l.region.clone(), "city" => l.city.clone() }
}

fn headers_of(v: &Value) -> Headers {
    Headers::from_pairs(v.as_object().unwrap().iter().map(|(k, v)| (k.to_string(), js::js_string(v))))
}

#[tokio::test]
async fn places_match_the_sdk() {
    let f = fixture("geo");
    for case in list(&f, "headers") {
        let got =
            geo::location_from_headers(&headers_of(case.at("headers"))).map_or(Value::Null, |l| location_value(&l));
        assert_eq!(got, *case.at("location"), "{}", case.at("headers").to_json());
    }
    for case in list(&f, "located") {
        let found = case.at("found").clone();
        let throws = js::opt_truthy(case.get("throws"));
        let lookup = geo::geo_fn(move |_| {
            if throws {
                return None;
            }
            found.as_object().map(|o| Found {
                country: o.get("country").map(js::js_string),
                region: o.get("region").map(js::js_string),
                city: o.get("city").map(js::js_string),
            })
        });
        let use_lookup = !js::opt_truthy(case.get("noLookup"));
        let got = geo::locate(&headers_of(case.at("headers")), s(case, "ip"), use_lookup.then_some(&lookup)).await;
        assert_eq!(location_value(&got), *case.at("location"), "{}", case.to_json());
    }
    for db in list(&f, "databases") {
        let bytes = base64::engine::general_purpose::STANDARD.decode(s(db, "base64")).unwrap();
        let reader = runlight::mmdb::Mmdb::from_bytes(bytes).unwrap();
        assert_eq!(reader.metadata.at("ip_version"), db.at("ipVersion"));
        assert_eq!(reader.metadata.at("record_size"), db.at("recordSize"));
        for case in list(db, "records") {
            let record = reader.get(s(case, "ip")).unwrap().unwrap_or(Value::Null);
            assert_eq!(record.to_json(), case.at("record").to_json(), "{}", s(case, "ip"));
            let location = runlight::mmdb::found_in(&record).map_or(Value::Null, |f| {
                obj! { "country" => f.country, "region" => f.region, "city" => f.city }
            });
            assert_eq!(location, *case.at("location"), "{}", s(case, "ip"));
        }
    }
}

#[test]
fn urls_queries_and_numbers_read_as_javascript_reads_them() {
    let f = conformance("url");
    let mut failures = Vec::new();
    let mut check = |input: &str, base: Option<&str>, expect: &Value| {
        let url = match base {
            Some(b) => Url::parse_with_base(input, b),
            None => Url::parse(input),
        };
        let got = url.map_or(Value::Null, |u| {
            obj! {
                "href" => u.href(), "protocol" => u.protocol(), "username" => u.username(), "password" => u.password(),
                "hostname" => u.hostname(), "port" => u.port(), "host" => u.host(), "origin" => u.origin(),
                "pathname" => u.pathname(), "search" => u.search(), "hash" => u.hash(),
            }
        });
        if got != *expect {
            failures.push(format!("{input:?} {base:?}: {} not {}", got.to_json(), expect.to_json()));
        }
    };
    for case in list(&f, "urls") {
        check(s(case, "input"), None, case.at("expect"));
    }
    for case in list(&f, "relative") {
        check(s(case, "input"), Some(s(case, "base")), case.at("expect"));
    }
    for case in list(&f, "queries") {
        let p = SearchParams::parse(s(case, "input"));
        let pairs: Vec<Value> =
            p.pairs().iter().map(|(k, v)| Value::Array(vec![k.clone().into(), v.clone().into()])).collect();
        if Value::Array(pairs) != *case.at("pairs") || p.to_string() != s(case, "string") {
            failures.push(format!("query {}", s(case, "input")));
        }
    }
    for case in list(&f, "written") {
        let p = SearchParams::from_pairs(list(case, "pairs").iter().map(|pair| {
            let a = pair.as_array().unwrap();
            (js::js_string(&a[0]), js::js_string(&a[1]))
        }));
        if p.to_string() != s(case, "string") {
            failures.push(format!("written {}: {p}", s(case, "string")));
        }
    }
    for case in list(&f, "numbers") {
        let n = match case.at("n") {
            Value::String(t) => js::text_number(t),
            v => v.as_f64().unwrap(),
        };
        if js::format_number(n) != s(case, "text") {
            failures.push(format!("number {}", s(case, "text")));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

fn cell(v: &Value) -> String {
    if let Some(o) = v.as_object()
        && o.len() == 1
        && let Some(Value::String(j)) = o.get("js")
    {
        return match j.as_str() {
            "undefined" => String::new(),
            "-0" => "0".into(),
            other => other.into(),
        };
    }
    zip::cell(v)
}

#[test]
fn csv_and_zip_match_the_sdk() {
    let f = fixture("zip");
    for case in list(&f, "rows") {
        assert_eq!(zip::csv_row(&[cell(case.at("cell"))]), s(case, "row"), "{}", case.at("cell").to_json());
    }
    for case in list(&f, "csvs") {
        let header: Vec<String> = list(case, "header").iter().map(js::js_string).collect();
        let header: Vec<&str> = header.iter().map(String::as_str).collect();
        let rows: Vec<Vec<String>> =
            list(case, "rows").iter().map(|r| r.as_array().unwrap().iter().map(cell).collect()).collect();
        assert_eq!(zip::csv(&header, &rows), s(case, "csv"));
    }
    for case in list(&f, "zips") {
        let files: Vec<(String, String)> =
            list(case, "files").iter().map(|f| (s(f, "name").to_string(), s(f, "text").to_string())).collect();
        let got = zip::zip(&files, case.at("now").as_f64().unwrap() as i64);
        assert_eq!(base64::engine::general_purpose::STANDARD.encode(got), s(case, "base64"));
    }
}
