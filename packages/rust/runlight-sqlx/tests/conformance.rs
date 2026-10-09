//! Replays conformance/http.json against the Rust core on every database at hand, as
//! http-conformance.test.ts does against the TypeScript one: each step's answer must equal the one the
//! file holds. RUNLIGHT_SCENARIO narrows the run to scenarios whose name contains it.

#![cfg(all(feature = "sqlite", feature = "postgres", feature = "mysql"))]

mod common;

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use runlight::http::{FetchError, FetchInit, Fetcher, Headers, Request, Response, SearchParams, Url};
use runlight::js::{self, Object, Value};
use runlight::{BoxFuture, Routes, RoutesOptions, Runlight, RunlightOptions, SiteOptions, TokenOption};

/// Headers every implementation must send the same, where it sends them.
const HEADERS: [&str; 16] = [
    "content-type",
    "cache-control",
    "location",
    "set-cookie",
    "www-authenticate",
    "allow",
    "content-disposition",
    "content-security-policy",
    "x-frame-options",
    "referrer-policy",
    "x-content-type-options",
    "x-robots-tag",
    "access-control-allow-origin",
    "access-control-allow-methods",
    "access-control-allow-headers",
    "access-control-max-age",
];
const RANDOM: [&str; 8] = ["token", "secret", "hint", "version", "library", "language", "ticket", "recovery"];
const JS_SPACE: &str =
    r"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}";

fn re(pattern: &str) -> fancy_regex::Regex {
    fancy_regex::Regex::new(pattern).expect("a pattern")
}

/// Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and signatures.
fn scrub(text: &str) -> String {
    let a = re(&format!(r#"([?&](?:code|ticket|secret|code_challenge)=)[^&#{JS_SPACE}"'<>]+"#))
        .replace_all(text, "${1}<value>")
        .into_owned();
    let b = re(r"(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])").replace_all(&a, "<hex>").into_owned();
    re(r"(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])").replace_all(&b, "<key>").into_owned()
}

/// Ids and other random values become placeholders, so answers compare across runs and implementations.
fn normalize(value: &Value, key: &str) -> Value {
    match value {
        Value::Array(a) => Value::Array(a.iter().map(|v| normalize(v, key)).collect()),
        Value::Object(o) => {
            let mut out = Object::new();
            for (k, v) in o.iter() {
                out.set(k, normalize(v, k));
            }
            Value::Object(out)
        }
        Value::String(s) => {
            if RANDOM.contains(&key)
                || re(r"^rlo?_[A-Za-z0-9]+$").is_match(s).unwrap_or(false)
                || re(r"^[a-f0-9]{24}$").is_match(s).unwrap_or(false)
            {
                return Value::String(format!("<{}>", if key.is_empty() { "value" } else { key }));
            }
            Value::String(scrub(s))
        }
        other => other.clone(),
    }
}

/// A Set-Cookie header with its value as <value>, unless it clears the cookie.
fn cookie_shape(header: &str) -> String {
    re(r"^([^=;]+)=([^;]*)")
        .replacen(header, 1, |c: &fancy_regex::Captures| {
            format!("{}={}", &c[1], if c[2].is_empty() { "" } else { "<value>" })
        })
        .into_owned()
}

/// Answers as one text to compare: object keys sorted, as deepEqual ignores their order.
fn canonical(value: &Value) -> String {
    fn sorted(v: &Value) -> Value {
        match v {
            Value::Object(o) => {
                let mut keys: Vec<&str> = o.keys().collect();
                keys.sort();
                let mut out = Object::new();
                for k in keys {
                    out.set(k, sorted(o.get(k).unwrap()));
                }
                Value::Object(out)
            }
            Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    js::stringify(&sorted(value))
}

/// The servers a scenario stands in for: a request goes to the first upstream whose url its URL
/// starts with (and whose method matches, when one is given); a request none matches fails as a
/// network error does. Every request is recorded.
struct Upstream {
    entries: Vec<Value>,
    fetched: Mutex<Vec<(Value, String)>>,
}

fn sent_body(text: &str, kind: &str) -> Value {
    if kind.starts_with("application/x-www-form-urlencoded") {
        let mut o = Object::new();
        for (k, v) in SearchParams::parse(text).pairs() {
            o.set(k.clone(), v.clone());
        }
        return Value::Object(o);
    }
    js::parse(text).unwrap_or_else(|_| Value::String(text.to_string()))
}

impl Fetcher for Upstream {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            let method = init.method.to_ascii_uppercase();
            let mut given = Object::new();
            let entries = init.headers.entries();
            for (k, v) in &entries {
                given.set(k.clone(), v.clone());
            }
            let text = init.body.as_deref().map(runlight::http::utf8).unwrap_or_default();
            let mut seen = Object::new();
            seen.set("method", method.clone());
            seen.set("url", url);
            if !given.is_empty() {
                seen.set("headers", given.clone());
            }
            if !text.is_empty() {
                seen.set("body", sent_body(&text, given.get("content-type").and_then(Value::as_str).unwrap_or("")));
            }
            self.fetched.lock().unwrap().push((Value::Object(seen), text));
            let found = self.entries.iter().find(|u| {
                url.starts_with(&js::str_or_empty(u.get("url")))
                    && (u.get("method").and_then(Value::as_str).is_none_or(|m| m.is_empty() || m == method))
            });
            let Some(found) = found else { return Err(FetchError::Failed("fetch failed".into())) };
            let has_body = found.get("body").is_some();
            let body = match found.get("body") {
                None => String::new(),
                Some(Value::String(s)) => s.clone(),
                Some(v) => v.to_json(),
            };
            let mut headers = Headers::new();
            if has_body && !matches!(found.get("body"), Some(Value::String(_) | Value::Number(_) | Value::Bool(_))) {
                headers.set("content-type", "application/json");
            }
            if let Some(Value::Object(h)) = found.get("headers") {
                for (k, v) in h.iter() {
                    headers.set(k, &js::js_string(v));
                }
            }
            let mut bytes = body.into_bytes();
            if let Some(max) = init.max_bytes
                && bytes.len() > max
            {
                if !init.truncate {
                    return Err(FetchError::TooLong(max));
                }
                bytes.truncate(max);
            }
            let status = found.get("status").and_then(Value::as_f64).unwrap_or(200.0) as u16;
            Ok(Response::new(bytes, status, headers))
        })
    }
}

impl Upstream {
    fn take(&self) -> Vec<(Value, String)> {
        std::mem::take(&mut *self.fetched.lock().unwrap())
    }
}

fn site_options(v: &Value) -> SiteOptions {
    let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    SiteOptions {
        id: s("id"),
        name: s("name"),
        hostnames: v.get("hostnames").and_then(Value::as_array).map(|a| a.iter().map(js::js_string).collect()),
        timezone: s("timezone"),
    }
}

/// The ZIP's files, stored or deflated, by their local headers (stored only here).
fn unzip(bytes: &[u8]) -> Vec<Value> {
    let mut files = Vec::new();
    let mut at = 0;
    let u32le = |b: &[u8], i: usize| u32::from_le_bytes(b[i..i + 4].try_into().unwrap()) as usize;
    let u16le = |b: &[u8], i: usize| u16::from_le_bytes(b[i..i + 2].try_into().unwrap()) as usize;
    while at + 30 <= bytes.len() && u32le(bytes, at) == 0x0403_4b50 {
        let size = u32le(bytes, at + 18);
        let name_len = u16le(bytes, at + 26);
        let extra = u16le(bytes, at + 28);
        let name = runlight::http::utf8(&bytes[at + 30..at + 30 + name_len]);
        let start = at + 30 + name_len + extra;
        let data = &bytes[start..start + size];
        files.push(
            runlight::obj! { "name" => name, "text" => normalize(&Value::String(runlight::http::utf8(data)), "") },
        );
        at = start + size;
    }
    files
}

fn base32_decode(text: &str) -> Vec<u8> {
    const ALPHABET: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let (mut bits, mut value, mut out) = (0u32, 0u32, Vec::new());
    for c in text.trim_end_matches('=').to_uppercase().chars() {
        let Some(i) = ALPHABET.find(c) else { continue };
        value = ((value << 5) | i as u32) & 0xffff;
        bits += 5;
        if bits >= 8 {
            out.push(((value >> (bits - 8)) & 255) as u8);
            bits -= 8;
        }
    }
    out
}

fn totp(secret: &str, step: i64) -> String {
    use hmac::{Hmac, Mac};
    let mut mac = Hmac::<sha1::Sha1>::new_from_slice(&base32_decode(secret)).unwrap();
    mac.update(&step.to_be_bytes());
    let m = mac.finalize().into_bytes();
    let at = (m[19] & 15) as usize;
    let n = ((u32::from(m[at]) & 127) << 24)
        | (u32::from(m[at + 1]) << 16)
        | (u32::from(m[at + 2]) << 8)
        | u32::from(m[at + 3]);
    format!("{:06}", n % 1_000_000)
}

struct Player {
    now: Arc<AtomicI64>,
    kept: std::collections::HashMap<String, String>,
    jars: std::collections::HashMap<String, Vec<(String, String)>>,
}

impl Player {
    fn fill(&self, text: &str) -> String {
        let now = self.now.load(Ordering::SeqCst);
        let with_codes = re(r"\{\{totp:(\w+)\}\}")
            .replace_all(text, |c: &fancy_regex::Captures| {
                totp(self.kept.get(&c[1]).map_or("", String::as_str), now.div_euclid(30_000))
            })
            .into_owned();
        re(r"\{\{(\w+)\}\}")
            .replace_all(&with_codes, |c: &fancy_regex::Captures| self.kept.get(&c[1]).cloned().unwrap_or_default())
            .into_owned()
    }

    fn fill_deep(&self, v: &Value) -> Value {
        match v {
            Value::String(s) => Value::String(self.fill(s)),
            Value::Array(a) => Value::Array(a.iter().map(|x| self.fill_deep(x)).collect()),
            Value::Object(o) => {
                let mut out = Object::new();
                for (k, x) in o.iter() {
                    out.set(k, self.fill_deep(x));
                }
                Value::Object(out)
            }
            other => other.clone(),
        }
    }
}

fn dig(value: &Value, path: &str) -> Value {
    let mut v = value.clone();
    for k in path.split('.') {
        v = match &v {
            Value::Object(o) => o.get(k).cloned().unwrap_or(Value::Null),
            Value::Array(a) => k.parse::<usize>().ok().and_then(|i| a.get(i).cloned()).unwrap_or(Value::Null),
            _ => return Value::Null,
        };
    }
    v
}

fn capture(spec: &str, answer: &Response, text: &str, parsed: Option<&Value>, sent: &[(Value, String)]) -> String {
    let (source, pattern) = match spec.find('~') {
        Some(i) => (&spec[..i], Some(&spec[i + 1..])),
        None => (spec, None),
    };
    let value = if source == "text" {
        text.to_string()
    } else if source == "fetched" {
        sent.iter().map(|f| f.1.clone()).collect::<Vec<_>>().join("\n")
    } else if let Some(h) = source.strip_prefix("header:") {
        let h = h.to_lowercase();
        if h == "set-cookie" {
            answer.headers.get_set_cookie().join("\n")
        } else {
            answer.headers.get(&h).unwrap_or_default()
        }
    } else {
        let v = parsed.map_or(Value::Null, |p| dig(p, source));
        if v.is_null() { String::new() } else { js::js_string(&v) }
    };
    match pattern {
        None => value,
        Some(p) => re(p)
            .captures(&value)
            .ok()
            .flatten()
            .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
            .unwrap_or_default(),
    }
}

async fn play(scenario: &Value, store: runlight::store::SqlStore) -> Result<Vec<Value>, String> {
    let options = scenario.at("options");
    let start = scenario.at("start").as_f64().unwrap_or(0.0) as i64;
    let now = Arc::new(AtomicI64::new(start));
    let upstream = Arc::new(Upstream {
        entries: scenario.get("upstream").and_then(Value::as_array).cloned().unwrap_or_default(),
        fetched: Mutex::new(vec![]),
    });
    let mut rl_options = RunlightOptions::new(store);
    if js::opt_truthy(options.get("managedSites")) {
        rl_options.managed_sites = true;
    } else if let Some(Value::Array(sites)) = scenario.get("sites") {
        rl_options.sites = Some(sites.iter().map(site_options).collect());
    } else {
        rl_options.site = Some(site_options(scenario.at("site")));
    }
    if let Some(Value::String(secret)) = options.get("secret")
        && !secret.is_empty()
    {
        rl_options.secret = Some(secret.clone());
    }
    match options.get("rateLimit") {
        Some(Value::Bool(false)) => rl_options.rate_limit = Some(0.0),
        Some(Value::Number(n)) => rl_options.rate_limit = Some(*n),
        _ => {}
    }
    let clock = now.clone();
    rl_options.now = Some(Arc::new(move || clock.load(Ordering::SeqCst)));
    rl_options.fetcher = Some(upstream.clone());
    let rl = Runlight::new(rl_options).map_err(|e| format!("new Runlight: {e}"))?;
    let token = match scenario.get("token") {
        Some(Value::String(t)) => TokenOption::Given(t.clone()),
        _ => TokenOption::Open,
    };
    let routes_options = RoutesOptions {
        token,
        observe_key: Some(js::str_or_empty(options.get("observeKey"))),
        cron_secret: Some(js::str_or_empty(options.get("cronSecret"))),
        accounts: js::opt_truthy(options.get("accounts")),
        origin: options.get("origin").filter(|o| js::truthy(o)).map(js::js_string),
        ..RoutesOptions::default()
    };
    let routes: Routes = rl.routes(routes_options).map_err(|e| format!("routes(): {e}"))?;
    let mut player = Player { now: now.clone(), kept: Default::default(), jars: Default::default() };
    let mut answers = Vec::new();
    for step in scenario.at("steps").as_array().unwrap() {
        now.fetch_add(step.get("advance").and_then(Value::as_f64).unwrap_or(0.0) as i64, Ordering::SeqCst);
        let mut headers = Headers::new();
        if let Some(Value::Object(h)) = step.get("headers") {
            for (k, v) in h.iter() {
                headers.set(&k.to_lowercase(), &player.fill(&js::js_string(v)));
            }
        }
        let mut body: Option<String> = None;
        if let Some(form) = step.get("form") {
            let filled = player.fill_deep(form);
            let pairs: Vec<(String, String)> = filled
                .as_object()
                .map(|o| o.iter().map(|(k, v)| (k.to_string(), js::js_string(v))).collect())
                .unwrap_or_default();
            body = Some(SearchParams::from_pairs(pairs).to_string());
            if !headers.has("content-type") {
                headers.set("content-type", "application/x-www-form-urlencoded");
            }
        } else if let Some(b) = step.get("body") {
            body = Some(match b {
                Value::String(s) => player.fill(s),
                other => player.fill_deep(other).to_json(),
            });
        }
        if body.is_some() && !headers.has("content-type") {
            headers.set("content-type", "text/plain;charset=UTF-8");
        }
        let jar_name = match step.get("jar") {
            Some(Value::Bool(false)) => None,
            Some(v) => Some(js::js_string(v)),
            None => Some("main".to_string()),
        };
        if let Some(name) = &jar_name {
            let jar = player.jars.entry(name.clone()).or_default();
            if !jar.is_empty() && !headers.has("cookie") {
                headers.set("cookie", &jar.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "));
            }
        }
        let to = step.get("to").and_then(Value::as_str).unwrap_or("routes").to_string();
        let prefix = if to == "routes" && !js::opt_truthy(step.get("absolute")) { "/runlight" } else { "" };
        let host = step.get("host").and_then(Value::as_str).unwrap_or("example.com");
        let raw = format!("https://{host}{prefix}{}", player.fill(&js::js_string(step.at("path"))));
        let url = Url::parse(&raw).map_or(raw, |u| u.href());
        let method = js::js_string(step.at("method"));
        let request = Request {
            url,
            method: method.to_ascii_uppercase(),
            headers,
            body: body.unwrap_or_default().into_bytes(),
            remote_address: String::new(),
        };
        upstream.take();
        let answer = match to.as_str() {
            "links" => Some(
                rl.link_response(&request).await.map_err(|e| format!("{method} {}: {e}", step.at("path").to_json()))?,
            ),
            "linkDomain" => rl
                .link_domain_response(&request)
                .await
                .map_err(|e| format!("{method} {}: {e}", step.at("path").to_json()))?,
            _ => Some(routes.handle(request).await),
        };
        // Work the request started after answering (retention) finishes before the next one.
        rl.idle().await;
        let sent = upstream.take();
        let outbound: Vec<Value> = sent.iter().map(|f| normalize(&f.0, "")).collect();
        let Some(answer) = answer else {
            let mut out = Object::new();
            out.set("pass", true);
            if !outbound.is_empty() {
                out.set("fetched", Value::Array(outbound));
            }
            answers.push(Value::Object(out));
            continue;
        };
        let text = answer.text();
        let kind = js::trim(answer.headers.get("content-type").unwrap_or_default().split(';').next().unwrap_or(""))
            .to_string();
        let parsed = if kind != "application/zip" && !text.is_empty() { js::parse(&text).ok() } else { None };
        if let Some(Value::Object(c)) = step.get("capture") {
            for (name, spec) in c.iter() {
                let value = capture(&js::js_string(spec), &answer, &text, parsed.as_ref(), &sent);
                player.kept.insert(name.to_string(), value);
            }
        }
        if let Some(name) = &jar_name {
            let jar = player.jars.entry(name.clone()).or_default();
            for cookie in answer.headers.get_set_cookie() {
                let mut attributes = cookie.split(';');
                let pair = attributes.next().unwrap_or("");
                let (n, v) = match pair.find('=') {
                    Some(i) => (js::trim(&pair[..i]).to_string(), js::trim(&pair[i + 1..]).to_string()),
                    None => (js::trim(&js::slice16(pair, 0, -1)).to_string(), js::trim(pair).to_string()),
                };
                let clears = attributes.any(|a| re(r"(?i)^\s*max-age=0\s*$").is_match(a).unwrap_or(false));
                jar.retain(|(k, _)| *k != n);
                if !v.is_empty() && !clears {
                    jar.push((n, v));
                }
            }
        }
        let mut shown = Object::new();
        for name in HEADERS {
            if name == "set-cookie" {
                let cookies = answer.headers.get_set_cookie();
                if !cookies.is_empty() {
                    shown.set(name, Value::Array(cookies.iter().map(|c| Value::String(cookie_shape(c))).collect()));
                }
                continue;
            }
            if let Some(v) = answer.headers.get(name).filter(|v| !v.is_empty()) {
                shown.set(
                    name,
                    if name == "content-type" {
                        Value::String(js::trim(v.split(';').next().unwrap_or("")).to_string())
                    } else {
                        normalize(&Value::String(v), "")
                    },
                );
            }
        }
        let mut out = Object::new();
        out.set("status", i64::from(answer.status));
        if !shown.is_empty() {
            out.set("headers", shown);
        }
        if let Some(p) = &parsed {
            out.set("body", normalize(p, ""));
        }
        if parsed.is_none() && (kind == "text/plain" || kind == "text/csv") {
            out.set("text", normalize(&Value::String(text.clone()), ""));
        }
        if kind == "application/zip" {
            out.set("files", Value::Array(unzip(&answer.body)));
        }
        if let Some(Value::Array(look)) = step.get("look") {
            out.set(
                "found",
                Value::Array(look.iter().map(|s| Value::Bool(text.contains(&js::js_string(s)))).collect()),
            );
        }
        if !outbound.is_empty() {
            out.set("fetched", Value::Array(outbound));
        }
        answers.push(Value::Object(out));
    }
    Ok(answers)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_scenario_answers_as_the_typescript_sdk_does() {
    let file = common::conformance("http");
    let only = std::env::var("RUNLIGHT_SCENARIO").unwrap_or_default();
    let detail = std::env::var("RUNLIGHT_DETAIL").is_ok();
    let mut report = Vec::new();
    let mut failed = 0;
    let mut passed = 0;
    for (kind, url) in common::kinds() {
        for scenario in file.at("scenarios").as_array().unwrap() {
            let name = js::js_string(scenario.at("name"));
            if !name.contains(&only) {
                continue;
            }
            let fresh = common::fresh(kind, &url).await;
            let answers = play(scenario, fresh.store.clone()).await;
            fresh.done().await;
            let steps = scenario.at("steps").as_array().unwrap();
            let answers = match answers {
                Ok(a) => a,
                Err(e) => {
                    failed += 1;
                    report.push(format!("{kind}: {name}: {e}"));
                    continue;
                }
            };
            let differ: Vec<usize> = steps
                .iter()
                .enumerate()
                .filter(|(i, s)| canonical(s.at("expect")) != canonical(answers.get(*i).unwrap_or(&Value::Null)))
                .map(|(i, _)| i)
                .collect();
            if differ.is_empty() {
                passed += 1;
                continue;
            }
            failed += 1;
            let i = differ[0];
            let step = &steps[i];
            let mut line = format!(
                "{kind}: {name}: {} of {} steps differ, first step {} {} {}",
                differ.len(),
                steps.len(),
                i + 1,
                js::js_string(step.at("method")),
                js::js_string(step.at("path"))
            );
            if detail {
                line.push_str(&format!(
                    "\n  expected {}\n  actual   {}",
                    canonical(step.at("expect")),
                    canonical(&answers[i])
                ));
                for j in differ.iter().skip(1).take(8) {
                    line.push_str(&format!(
                        "\n  also step {} {} {}",
                        j + 1,
                        js::js_string(steps[*j].at("method")),
                        js::js_string(steps[*j].at("path"))
                    ));
                }
            }
            report.push(line);
        }
    }
    println!("conformance: {passed} scenarios pass, {failed} fail");
    assert!(report.is_empty(), "{}", report.join("\n"));
}
