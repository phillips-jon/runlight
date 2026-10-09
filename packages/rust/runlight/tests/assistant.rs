//! The assistant against packages/php/tests/fixtures/assistant.json: for each
//! provider and failure, the very requests the TypeScript sends (bodies
//! compared by SHA-256), the API reads its tools make, and what it answers.

mod common;

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use common::{fixture, list, s};
use runlight::assistant::{
    self, AssistantFailure, AssistantSettings, ChatContext, ChatMessage, ChatSite, PROVIDERS, locale_compare,
};
use runlight::hash::sha256;
use runlight::http::{FetchError, FetchInit, Fetcher, Headers, Response, SharedFetcher};
use runlight::js::{self, Value};
use runlight::mcp::ApiRead;
use runlight::{BoxError, BoxFuture, arr, obj};

/// Answers from a queue and keeps every request it was sent.
struct Recording {
    queue: Mutex<VecDeque<Result<Response, FetchError>>>,
    sent: Mutex<Vec<(String, FetchInit)>>,
}

impl Fetcher for Recording {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            self.sent.lock().unwrap().push((url.to_string(), init));
            self.queue.lock().unwrap().pop_front().unwrap_or_else(|| Err(FetchError::Failed("no answer queued".into())))
        })
    }
}

fn recording(responses: Vec<Result<Response, FetchError>>) -> Arc<Recording> {
    Arc::new(Recording { queue: Mutex::new(responses.into()), sent: Mutex::new(Vec::new()) })
}

fn json(status: u16, body: &str) -> Result<Response, FetchError> {
    Ok(Response::new(body, status, Headers::new().with("content-type", "application/json")))
}

/// A readApi that logs each read and answers from the fixture's canned API.
struct Canned {
    api: Value,
    log: Mutex<Vec<Value>>,
}

impl ApiRead for Canned {
    fn read<'a>(&'a self, path: &'a str, params: &'a [(String, String)]) -> BoxFuture<'a, Result<Response, BoxError>> {
        Box::pin(async move {
            let pairs: Vec<Value> = params.iter().map(|(k, v)| arr![k.as_str(), v.as_str()]).collect();
            self.log.lock().unwrap().push(obj! { "path" => path, "params" => Value::Array(pairs) });
            let headers = Headers::new().with("content-type", "application/json");
            Ok(match self.api.get(path) {
                Some(canned) => Response::new(s(canned, "body"), canned.at("status").as_f64().unwrap() as u16, headers),
                None => Response::new(format!("{{\"error\":\"Not found: {}\"}}", path.replace('"', "")), 404, headers),
            })
        })
    }
}

fn settings(v: &Value) -> AssistantSettings {
    AssistantSettings {
        provider: s(v, "provider").into(),
        model: s(v, "model").into(),
        base_url: s(v, "baseUrl").into(),
        key: s(v, "key").into(),
    }
}

fn context(v: &Value) -> ChatContext {
    let site = v.at("site");
    ChatContext {
        site: ChatSite { id: s(site, "id").into(), name: s(site, "name").into(), timezone: s(site, "timezone").into() },
        today: s(v, "today").into(),
        view: s(v, "view").into(),
        language: s(v, "language").into(),
    }
}

fn context_en() -> ChatContext {
    context(&obj! {
        "site" => obj! { "id" => "default", "name" => "Blog", "timezone" => "UTC" },
        "today" => "2026-10-08",
        "view" => "today",
        "language" => "en",
    })
}

fn messages(v: &Value) -> Vec<ChatMessage> {
    v.as_array()
        .map(|a| a.iter().map(|m| ChatMessage { role: s(m, "role").into(), content: s(m, "content").into() }).collect())
        .unwrap_or_default()
}

fn fixed() -> i64 {
    1_760_000_000_000
}

fn error_value(failure: &AssistantFailure) -> Value {
    match failure {
        AssistantFailure::Coded(e) => {
            obj! { "message" => e.message.clone(), "code" => e.code.clone(), "params" => e.params_value() }
        }
        AssistantFailure::Thrown(m) => obj! { "thrown" => m.clone() },
    }
}

#[tokio::test]
async fn scenarios_send_the_same_requests_and_answer_the_same() {
    let f = fixture("assistant");
    let scenarios = list(&f, "scenarios");
    assert_eq!(scenarios.len(), 36);
    for scenario in scenarios {
        let name = s(scenario, "name");
        let queue = list(scenario, "responses")
            .iter()
            .map(|c| match c.get("throws").and_then(Value::as_str) {
                Some("timeout") => Err(FetchError::TimedOut),
                Some(_) => Err(FetchError::Failed("fetch failed".into())),
                None => json(c.at("status").as_f64().unwrap() as u16, s(c, "body")),
            })
            .collect();
        let rec = recording(queue);
        let fetcher: SharedFetcher = rec.clone();
        let api = Canned { api: f.at("api").clone(), log: Mutex::new(Vec::new()) };
        let outcome = if s(scenario, "call") == "chat" {
            assistant::chat(
                &settings(scenario.at("settings")),
                &messages(scenario.at("messages")),
                &context(scenario.at("context")),
                &api,
                &fetcher,
                &fixed,
                None,
            )
            .await
            .map(|a| a.to_value())
        } else {
            assistant::list_models(&settings(scenario.at("settings")), &fetcher)
                .await
                .map(|models| Value::Array(models.iter().map(|m| m.to_value()).collect()))
        };
        match outcome {
            Ok(value) => {
                assert!(scenario.get("result").is_some(), "{name} answered {}", js::stringify(&value));
                assert_eq!(js::stringify(&value), js::stringify(scenario.at("result")), "{name}");
            }
            Err(failure) => {
                assert!(scenario.get("error").is_some(), "{name} threw {failure}");
                assert_eq!(js::stringify(&error_value(&failure)), js::stringify(scenario.at("error")), "{name}");
            }
        }
        let log = js::stringify(&Value::Array(api.log.lock().unwrap().clone()));
        assert_eq!(log, js::stringify(scenario.at("tools")), "{name} read the API differently");
        let sent = rec.sent.lock().unwrap();
        let expected = list(scenario, "requests");
        assert_eq!(sent.len(), expected.len(), "{name}");
        for (i, (want, (url, init))) in expected.iter().zip(sent.iter()).enumerate() {
            assert_eq!(url, s(want, "url"), "{name} request {i}");
            assert_eq!(init.method, s(want, "method"), "{name} request {i}");
            let mut headers = js::Object::new();
            for (k, v) in init.headers.all() {
                headers.set(k.clone(), v.join(", "));
            }
            assert_eq!(headers.to_json(), js::stringify(want.at("headers")), "{name} request {i} headers");
            let body = init.body.as_ref().map(|b| sha256(&String::from_utf8_lossy(b)));
            let want_body = want.get("bodySha256").and_then(Value::as_str).map(str::to_string);
            assert_eq!(
                body,
                want_body,
                "{name} request {i} body: {}",
                String::from_utf8_lossy(init.body.as_deref().unwrap_or_default())
            );
        }
    }
}

#[test]
fn acknowledgements_match() {
    let f = fixture("assistant");
    let cases = list(&f, "acknowledgements");
    assert_eq!(cases.len(), 264);
    for case in cases {
        let got = assistant::acknowledgement(s(case, "text"), s(case, "language"));
        assert_eq!(got.map(Value::from).unwrap_or(Value::Null), *case.at("reply"), "{}", js::stringify(case));
    }
}

#[test]
fn providers_keep_their_ids_and_order() {
    let ids: Vec<&str> = PROVIDERS.iter().map(|p| p.id).collect();
    assert_eq!(ids, ["anthropic", "openai", "gemini", "openrouter", "ollama", "lmstudio", "custom"]);
    assert_eq!(
        js::stringify(&PROVIDERS[0].to_value()),
        r#"{"id":"anthropic","name":"Anthropic (Claude)","protocol":"anthropic","baseUrl":"https://api.anthropic.com/v1","model":"claude-sonnet-5-5","key":"yes"}"#
    );
}

#[test]
fn model_ids_sort_as_node_sorts_them() {
    let mut ids =
        vec!["b", "B", "a", "é", "e", "E", "f", "10", "9", "a-b", "a_b", "a b", "a.b", "ab", "aB", "Ab", "ée", "eé"];
    ids.sort_by(|a, b| locale_compare(a, b));
    assert_eq!(
        ids,
        ["10", "9", "a", "a b", "a_b", "a-b", "a.b", "ab", "aB", "Ab", "b", "B", "e", "E", "é", "eé", "ée", "f"]
    );
}

fn answers_with_a_tool() -> Vec<Result<Response, FetchError>> {
    let call = r#"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"list_sites","input":{}}]}"#;
    vec![json(200, call), json(200, call), json(200, call)]
}

fn ask() -> Vec<ChatMessage> {
    vec![ChatMessage { role: "user".into(), content: "How many?".into() }]
}

fn anthropic() -> AssistantSettings {
    AssistantSettings { provider: "anthropic".into(), model: "m".into(), base_url: String::new(), key: "k".into() }
}

#[tokio::test]
async fn the_deadline_stops_before_the_next_request_or_tool() {
    let f = fixture("assistant");
    let api = Canned { api: f.at("api").clone(), log: Mutex::new(Vec::new()) };
    let clock = AtomicI64::new(0);
    // Each read of the clock is 50 seconds later: the deadline passes before the first round's tool.
    let now = || clock.fetch_add(50_000, Ordering::SeqCst);
    let rec = recording(answers_with_a_tool());
    let fetcher: SharedFetcher = rec.clone();
    let failure = assistant::chat(&anthropic(), &ask(), &context_en(), &api, &fetcher, &now, None).await.unwrap_err();
    let AssistantFailure::Coded(e) = failure else { panic!("a coded error") };
    assert_eq!(e.code, "assistant_slow");
    assert_eq!(e.message, "That question took too long to answer. Try asking something narrower.");
    assert_eq!(rec.sent.lock().unwrap().len(), 1);
    // The time left caps the request's own limit.
    assert_eq!(rec.sent.lock().unwrap()[0].1.timeout_ms, 20_000);
    assert!(api.log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn leaving_cancels_the_question() {
    let f = fixture("assistant");
    let api = Canned { api: f.at("api").clone(), log: Mutex::new(Vec::new()) };
    let gone = AtomicBool::new(false);
    let cancelled = || gone.load(Ordering::SeqCst);
    let rec = recording(answers_with_a_tool());
    let fetcher: SharedFetcher = rec.clone();
    gone.store(true, Ordering::SeqCst);
    let failure = assistant::chat(&anthropic(), &ask(), &context_en(), &api, &fetcher, &fixed, Some(&cancelled))
        .await
        .unwrap_err();
    assert_eq!(
        error_value(&failure),
        obj! { "message" => "The question was cancelled.", "code" => "assistant_cancelled", "params" => obj! {} }
    );
    assert!(rec.sent.lock().unwrap().is_empty());
}

/// A Fetcher that never answers.
struct Hanging;

impl Fetcher for Hanging {
    fn fetch<'a>(&'a self, _url: &'a str, _init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(std::future::pending())
    }
}

#[tokio::test]
async fn leaving_aborts_a_request_that_is_out() {
    let api = Canned { api: obj! {}, log: Mutex::new(Vec::new()) };
    let gone = Arc::new(AtomicBool::new(false));
    let flag = gone.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(120)).await;
        flag.store(true, Ordering::SeqCst);
    });
    let cancelled = move || gone.load(Ordering::SeqCst);
    let fetcher: SharedFetcher = Arc::new(Hanging);
    let failure = assistant::chat(&anthropic(), &ask(), &context_en(), &api, &fetcher, &fixed, Some(&cancelled))
        .await
        .unwrap_err();
    // fetch() rejects with an AbortError, which the TypeScript reports as a failed connection.
    assert_eq!(
        error_value(&failure),
        obj! {
            "message" => "Could not reach api.anthropic.com: the connection failed",
            "code" => "unreachable",
            "params" => obj! { "host" => "api.anthropic.com" },
        }
    );
}

#[tokio::test]
async fn answers_the_typescript_cannot_read_are_thrown() {
    let api = Canned { api: obj! {}, log: Mutex::new(Vec::new()) };
    let openai =
        AssistantSettings { provider: "openai".into(), model: "m".into(), base_url: String::new(), key: "k".into() };
    let claude = anthropic();
    let cases: Vec<(&AssistantSettings, &str, &str)> = vec![
        (&claude, r#"{"content":"text"}"#, "blocks.filter is not a function"),
        (&claude, r#"{"content":[null]}"#, "Cannot read properties of null (reading 'type')"),
        (&openai, r#"{"choices":[{"message":{"tool_calls":{"length":1}}}]}"#, "message.tool_calls is not iterable"),
        (
            &openai,
            r#"{"choices":[{"message":{"tool_calls":"ab"}}]}"#,
            "Cannot read properties of undefined (reading 'name')",
        ),
        (
            &openai,
            r#"{"choices":[{"message":{"tool_calls":[null]}}]}"#,
            "Cannot read properties of null (reading 'function')",
        ),
        (
            &openai,
            r#"{"choices":[{"message":{"tool_calls":[{"function":null}]}}]}"#,
            "Cannot read properties of null (reading 'name')",
        ),
    ];
    for (settings, body, thrown) in cases {
        let fetcher: SharedFetcher = recording(vec![json(200, body)]);
        let failure = assistant::chat(settings, &ask(), &context_en(), &api, &fetcher, &fixed, None).await.unwrap_err();
        assert_eq!(failure, AssistantFailure::Thrown(thrown.into()), "{body}");
    }
    // A tool_calls object without a length is no call at all.
    let fetcher: SharedFetcher =
        recording(vec![json(200, r#"{"choices":{"0":{"message":{"content":"Hi","tool_calls":{}}}}}"#)]);
    let answer = assistant::chat(&openai, &ask(), &context_en(), &api, &fetcher, &fixed, None).await.unwrap();
    assert_eq!(answer.reply, "Hi");
    // An address that is not a URL is a TypeError, with nothing sent.
    let bad = AssistantSettings {
        provider: "custom".into(),
        model: "m".into(),
        base_url: "not a url".into(),
        key: String::new(),
    };
    let rec = recording(vec![Err(FetchError::Failed("bad url".into()))]);
    let fetcher: SharedFetcher = rec.clone();
    let failure = assistant::chat(&bad, &ask(), &context_en(), &api, &fetcher, &fixed, None).await.unwrap_err();
    assert_eq!(failure, AssistantFailure::Thrown("Invalid URL".into()));
    let failure = assistant::list_models(&bad, &fetcher).await.unwrap_err();
    assert_eq!(failure, AssistantFailure::Thrown("Invalid URL".into()));
    let fetcher: SharedFetcher = recording(vec![json(200, r#"{"data":"x"}"#)]);
    let failure = assistant::list_models(&openai, &fetcher).await.unwrap_err();
    assert_eq!(failure, AssistantFailure::Thrown("(data?.data ?? []).filter is not a function".into()));
}

#[tokio::test]
async fn a_url_with_credentials_is_never_sent() {
    let api = Canned { api: obj! {}, log: Mutex::new(Vec::new()) };
    let settings = AssistantSettings {
        provider: "custom".into(),
        model: "m".into(),
        base_url: "https://u:p@llm.example.com/v1".into(),
        key: String::new(),
    };
    let rec = recording(vec![json(200, "{}")]);
    let fetcher: SharedFetcher = rec.clone();
    let failure = assistant::chat(&settings, &ask(), &context_en(), &api, &fetcher, &fixed, None).await.unwrap_err();
    assert_eq!(
        error_value(&failure),
        obj! {
            "message" => "Could not reach llm.example.com: the connection failed",
            "code" => "unreachable",
            "params" => obj! { "host" => "llm.example.com" },
        }
    );
    assert!(rec.sent.lock().unwrap().is_empty());
}

fn send<T: Send>(_: &T) {}

#[test]
fn the_futures_can_be_sent_between_threads() {
    let api = Canned { api: obj! {}, log: Mutex::new(Vec::new()) };
    let fetcher: SharedFetcher = recording(Vec::new());
    let (settings, messages, context) = (anthropic(), ask(), context_en());
    send(&assistant::chat(&settings, &messages, &context, &api, &fetcher, &fixed, None));
    send(&assistant::list_models(&settings, &fetcher));
    let request = runlight::http::Request::new("POST", "https://x.com/mcp");
    send(&runlight::mcp::mcp_response(&request, &api));
    send(&runlight::mcp::call_tool(&obj! {}, &api));
}
