//! The MCP server against packages/php/tests/fixtures/mcp.json: the
//! TypeScript's API reads and answers for the same JSON-RPC messages and tool
//! arguments, over canned API answers.

mod common;

use std::sync::Mutex;

use common::{fixture, list, s};
use runlight::http::{Headers, Request, Response};
use runlight::js::{self, Value};
use runlight::mcp::{self, ApiRead, McpError};
use runlight::{BoxError, BoxFuture, arr, obj};

/// A readApi that logs each read and answers from the fixture's canned API.
pub struct Canned {
    api: Value,
    log: Mutex<Vec<Value>>,
}

impl Canned {
    pub fn new(api: Value) -> Canned {
        Canned { api, log: Mutex::new(Vec::new()) }
    }

    pub fn log(&self) -> String {
        js::stringify(&Value::Array(self.log.lock().unwrap().clone()))
    }
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

/// An ApiRead whose every read fails.
struct Failing;

impl ApiRead for Failing {
    fn read<'a>(
        &'a self,
        _path: &'a str,
        _params: &'a [(String, String)],
    ) -> BoxFuture<'a, Result<Response, BoxError>> {
        Box::pin(async { Err("the database is gone".into()) })
    }
}

/// An ApiRead answering one body with one status.
struct Answering(u16, &'static str);

impl ApiRead for Answering {
    fn read<'a>(
        &'a self,
        _path: &'a str,
        _params: &'a [(String, String)],
    ) -> BoxFuture<'a, Result<Response, BoxError>> {
        Box::pin(async move { Ok(Response::new(self.1, self.0, Headers::new())) })
    }
}

fn post(body: impl Into<Vec<u8>>) -> Request {
    Request::new("POST", "https://example.com/runlight/mcp").body(body)
}

fn unhex(hex: &str) -> Vec<u8> {
    (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect()
}

#[tokio::test]
async fn tool_calls_read_the_same_api_and_answer_the_same() {
    let f = fixture("mcp");
    let cases = list(&f, "calls");
    assert_eq!(cases.len(), 320);
    for case in cases {
        let params = case.at("params");
        let label = js::stringify(params);
        let api = Canned::new(f.at("api").clone());
        match mcp::call_tool(params, &api).await {
            Ok(value) => {
                assert!(case.get("throws").is_none(), "{label} should throw");
                assert_eq!(api.log(), js::stringify(case.at("requests")), "{label}");
                assert_eq!(js::stringify(&value), js::stringify(case.at("value")), "{label}");
            }
            Err(error) => {
                assert!(case.get("throws").is_some(), "{label} threw {}", error.message);
                assert_eq!(error.message, s(case, "message"), "{label}");
                assert_eq!(error.code, Some(-32602), "{label}");
                assert_eq!(api.log(), "[]", "{label}");
            }
        }
    }
}

#[tokio::test]
async fn json_rpc_answers_match() {
    let f = fixture("mcp");
    let cases = list(&f, "rpcs");
    assert_eq!(cases.len(), 43);
    for case in cases {
        let body = match case.get("bodyHex") {
            Some(hex) => unhex(hex.as_str().unwrap()),
            None => s(case, "body").as_bytes().to_vec(),
        };
        let label = String::from_utf8_lossy(&body).into_owned();
        let api = Canned::new(f.at("api").clone());
        let answer = mcp::mcp_response(&post(body), &api).await;
        if case.get("throws").is_some() {
            assert!(answer.is_err(), "{label} should throw");
            continue;
        }
        let answer = answer.unwrap();
        assert_eq!(f64::from(answer.status), case.at("status").as_f64().unwrap(), "{label}");
        let mut headers = js::Object::new();
        for (k, v) in answer.headers.entries() {
            headers.set(k, v);
        }
        assert_eq!(headers.to_json(), js::stringify(case.at("headers")), "{label}");
        assert_eq!(answer.text(), s(case, "text"), "{label}");
        assert_eq!(api.log(), js::stringify(case.at("requests")), "{label}");
    }
}

#[tokio::test]
async fn tools_are_listed_read_only_in_order() {
    let f = fixture("mcp");
    let api = Canned::new(f.at("api").clone());
    let answer = mcp::mcp_response(&post(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#), &api).await.unwrap();
    let text = answer.text();
    let parsed = js::parse(&text).unwrap();
    let tools = parsed.at("result").at("tools").as_array().unwrap();
    let names: Vec<Value> = tools.iter().map(|t| t.at("name").clone()).collect();
    assert_eq!(js::stringify(&Value::Array(names)), js::stringify(f.at("tools")));
    for tool in tools {
        assert_eq!(tool.at("annotations").at("readOnlyHint"), &Value::Bool(true));
    }
    assert!(text.contains(r#""properties":{}"#), "an empty schema is an object");
    let names: Vec<&str> = mcp::TOOLS.iter().map(|t| t.name).collect();
    assert_eq!(names.len(), 12);
}

#[tokio::test]
async fn initialize_answers_the_asked_version_or_the_newest() {
    let api = Canned::new(obj! {});
    let ask = async |version: &str| {
        let body = js::stringify(
            &obj! { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => obj! { "protocolVersion" => version } },
        );
        let answer = mcp::mcp_response(&post(body), &api).await.unwrap();
        js::parse(&answer.text()).unwrap().at("result").clone()
    };
    assert_eq!(s(&ask("2025-06-18").await, "protocolVersion"), "2025-06-18");
    assert_eq!(s(ask("2025-06-18").await.at("serverInfo"), "name"), "runlight");
    assert_eq!(s(ask("2025-06-18").await.at("serverInfo"), "version"), runlight::version::VERSION);
    assert_eq!(s(&ask("1999-01-01").await, "protocolVersion"), "2025-11-25", "an unknown version gets the newest");
    let note =
        mcp::mcp_response(&post(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), &api).await.unwrap();
    assert_eq!(note.status, 202);
    assert_eq!(note.text(), "");
    assert!(note.headers.is_empty());
}

#[tokio::test]
async fn a_failed_read_is_an_internal_error_without_its_message() {
    let body = r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_stats"}}"#;
    let answer = mcp::mcp_response(&post(body), &Failing).await.unwrap();
    assert_eq!(answer.text(), r#"{"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"Internal error"}}"#);
    let error = mcp::call_tool(&obj! { "name" => "get_stats" }, &Failing).await.unwrap_err();
    assert_eq!(error, McpError { message: "the database is gone".into(), code: None });
}

#[tokio::test]
async fn a_refusal_of_null_throws_as_javascript_reads_it() {
    // `body.error` on a body of null is a TypeError in the TypeScript, which the
    // MCP server answers as an internal error.
    let error = mcp::call_tool(&obj! { "name" => "list_sites" }, &Answering(500, "null")).await.unwrap_err();
    assert_eq!(error.message, "Cannot read properties of null (reading 'error')");
    assert_eq!(error.code, None);
    let error = mcp::call_tool(&obj! { "name" => "get_visit_times" }, &Answering(200, "null")).await.unwrap_err();
    assert_eq!(error.message, "Cannot read properties of null (reading 'site')");
    // A shape leaves out what the answer does not have, as JSON.stringify does undefined.
    let ok = mcp::call_tool(&obj! { "name" => "get_visit_times" }, &Answering(200, "[1]")).await.unwrap();
    assert_eq!(
        s(&ok.at("content").as_array().unwrap()[0], "text"),
        r#"{"weekdays":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]}"#
    );
}

#[tokio::test]
async fn a_batch_reads_every_message_before_it_throws() {
    let f = fixture("mcp");
    let api = Canned::new(f.at("api").clone());
    let body = r#"[null,{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sites"}}]"#;
    assert!(mcp::mcp_response(&post(body), &api).await.is_err());
    assert_eq!(api.log(), r#"[{"path":"/api/sites","params":[]}]"#);
}
