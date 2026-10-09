//! The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream,
//! JSON-RPC in and JSON out. Every tool is a read of the HTTP API, made with
//! the caller's own credentials, so the MCP server can see exactly what the
//! token can and nothing more.

use std::sync::LazyLock;

use crate::http::{Headers, Request, Response};
use crate::js::{self, Object, Value};
use crate::query::{MAX_FILTERS, dimensions};
use crate::sources::encode_uri_component;
use crate::version::VERSION;
use crate::{BoxError, BoxFuture, arr, obj};

/// Newest first; a client asking for one we do not know is answered with the newest.
pub const PROTOCOL_VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

/// What the MCP server tells a client about Runlight, and the assistant's
/// system prompt starts with.
pub const INSTRUCTIONS: &str = "Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example \"channel:is:Organic Search\" or \"page:contains:/blog\". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.";

/// A JSON-RPC error: `code` is the error's own JSON-RPC code (-32602 for an
/// unknown tool), answered with its message as it is; `None` is an error
/// thrown along the way (an API read that failed, a body of `null`), which
/// the MCP server answers as -32603 "Internal error" and the assistant
/// hands the model as its message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McpError {
    /// The message.
    pub message: String,
    /// The JSON-RPC code, when the error has one.
    pub code: Option<i64>,
}

impl McpError {
    fn coded(message: impl Into<String>, code: i64) -> McpError {
        McpError { message: message.into(), code: Some(code) }
    }

    fn thrown(message: impl Into<String>) -> McpError {
        McpError { message: message.into(), code: None }
    }
}

impl std::fmt::Display for McpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for McpError {}

/// Reads one API path with the caller's credentials: the path (such as
/// `/api/stats`) and the query's name and value pairs, in order.
pub trait ApiRead: Send + Sync {
    /// Reads the path and answers as the API does.
    fn read<'a>(&'a self, path: &'a str, params: &'a [(String, String)]) -> BoxFuture<'a, Result<Response, BoxError>>;
}

/// The API path and query a tool reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolRequest {
    /// The API path.
    pub path: String,
    /// The query's name and value pairs, in order.
    pub params: Vec<(String, String)>,
}

/// One tool.
pub struct Tool {
    /// The tool's name.
    pub name: &'static str,
    /// Its title.
    pub title: &'static str,
    /// What it reads, for the model.
    pub description: &'static str,
    /// Its arguments, as JSON Schema.
    pub input_schema: Value,
    request: fn(&Value) -> ToolRequest,
    shape: Option<Shape>,
}

/// Trims a tool's answer.
type Shape = fn(&Value) -> Result<Value, McpError>;

impl Tool {
    /// The API path and query to read, from the tool's arguments.
    pub fn request(&self, args: &Value) -> ToolRequest {
        (self.request)(args)
    }

    /// Trims an answer before it goes back, when the API's carries more than
    /// an assistant needs; the answer as it is otherwise.
    pub fn shape(&self, body: &Value) -> Result<Value, McpError> {
        match self.shape {
            Some(shape) => shape(body),
            None => Ok(body.clone()),
        }
    }
}

impl std::fmt::Debug for Tool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tool").field("name", &self.name).finish_non_exhaustive()
    }
}

const RANGE_KEYS: [&str; 5] = ["site", "period", "from", "to", "filters"];
const COMPARE_KEYS: [&str; 8] = ["site", "period", "from", "to", "filters", "compare", "compare_from", "compare_to"];

fn range() -> Vec<(&'static str, Value)> {
    vec![
        ("site", obj! { "type" => "string", "description" => "Site id from list_sites. Defaults to the first site." }),
        (
            "period",
            obj! {
                "type" => "string",
                "enum" => arr!["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"],
                "description" => "The date range. Defaults to 30d. Ignored when from and to are given.",
            },
        ),
        ("from", obj! { "type" => "string", "description" => "First day, YYYY-MM-DD, with to." }),
        ("to", obj! { "type" => "string", "description" => "Last day, YYYY-MM-DD, inclusive." }),
        (
            "filters",
            obj! {
                "type" => "array",
                "items" => obj! { "type" => "string" },
                "maxItems" => MAX_FILTERS,
                "description" => format!("Narrow to matching visits, up to {MAX_FILTERS} at once, each \"dimension:op:value\" with op is, not, or contains."),
            },
        ),
    ]
}

fn compare() -> Vec<(&'static str, Value)> {
    vec![
        (
            "compare",
            obj! {
                "type" => "string",
                "enum" => arr!["previous", "year", "custom", "off"],
                "description" => "What to compare with. Defaults to previous, the same length of time just before.",
            },
        ),
        ("compare_from", obj! { "type" => "string", "description" => "For compare custom: first day, YYYY-MM-DD." }),
        ("compare_to", obj! { "type" => "string", "description" => "For compare custom: last day, YYYY-MM-DD." }),
    ]
}

/// The properties object from groups of properties, in order.
fn properties(groups: &[Vec<(&'static str, Value)>]) -> Value {
    let mut o = Object::new();
    for group in groups {
        for (k, v) in group {
            o.set(*k, v.clone());
        }
    }
    Value::Object(o)
}

/// The one property of RANGE named.
fn range_one(key: &str) -> (&'static str, Value) {
    range().into_iter().find(|(k, _)| *k == key).expect("a RANGE key")
}

fn schema(properties: Value) -> Value {
    obj! { "type" => "object", "properties" => properties }
}

fn rpc_range_params(args: &Value, keys: &[&str]) -> Vec<(String, String)> {
    let mut params = Vec::new();
    for key in keys {
        let value = args.get(key);
        if *key == "filters" {
            if let Some(Value::Array(list)) = value {
                for f in list {
                    params.push(("filter".to_string(), js::js_string(f)));
                }
            }
        } else if let Some(v) = value
            && !v.is_null()
            && v.as_str() != Some("")
        {
            params.push(((*key).to_string(), js::js_string(v)));
        }
    }
    params
}

/// `String(Math.min(100, Math.max(1, Number(value) || fallback)))`.
fn limit(args: &Value, fallback: f64) -> (String, String) {
    let n = js::opt_number(args.get("limit"));
    let n = if n.is_nan() || n == 0.0 { fallback } else { n };
    ("limit".to_string(), js::format_number(n.clamp(1.0, 100.0)))
}

fn read(path: &str, args: &Value, keys: &[&str]) -> ToolRequest {
    ToolRequest { path: path.to_string(), params: rpc_range_params(args, keys) }
}

fn read_with(path: &str, args: &Value, keys: &[&str], extra: (String, String)) -> ToolRequest {
    let mut r = read(path, args, keys);
    r.params.push(extra);
    r
}

/// `body.key` as JavaScript reads it: a TypeError on `null`.
fn member<'a>(body: &'a Value, key: &str) -> Result<Option<&'a Value>, McpError> {
    if body.is_null() {
        return Err(McpError::thrown(format!("Cannot read properties of null (reading '{key}')")));
    }
    Ok(body.get(key))
}

fn visit_times_shape(body: &Value) -> Result<Value, McpError> {
    let mut o = Object::new();
    // A key whose value is undefined is left out, as JSON.stringify leaves it.
    if let Some(site) = member(body, "site")? {
        o.set("site", site.clone());
    }
    if let Some(range) = member(body, "range")? {
        o.set("range", range.clone());
    }
    o.set("weekdays", arr!["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]);
    if let Some(grid) = member(body, "grid")? {
        o.set("grid", grid.clone());
    }
    Ok(Value::Object(o))
}

/// The tools, in the order `tools/list` gives them.
pub static TOOLS: LazyLock<Vec<Tool>> = LazyLock::new(|| {
    let r = range();
    let c = compare();
    vec![
        Tool {
            name: "list_sites",
            title: "List sites",
            description: "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
            input_schema: schema(obj! {}),
            request: |_| ToolRequest { path: "/api/sites".into(), params: Vec::new() },
            shape: None,
        },
        Tool {
            name: "get_stats",
            title: "Headline numbers",
            description: "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",
            input_schema: schema(properties(&[r.clone(), c.clone()])),
            request: |args| read("/api/stats", args, &COMPARE_KEYS),
            shape: None,
        },
        Tool {
            name: "get_timeseries",
            title: "Numbers over time",
            description: "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",
            input_schema: schema(properties(&[
                r.clone(),
                c.clone(),
                vec![(
                    "interval",
                    obj! { "type" => "string", "enum" => arr!["hour", "day", "week", "month"], "description" => "Chosen from the range when left out." },
                )],
            ])),
            request: |args| {
                let mut keys = COMPARE_KEYS.to_vec();
                keys.push("interval");
                read("/api/series", args, &keys)
            },
            shape: None,
        },
        Tool {
            name: "get_breakdown",
            title: "Top values of a dimension",
            description: "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",
            input_schema: {
                let mut s = schema(properties(&[
                    r.clone(),
                    vec![
                        (
                            "dimension",
                            obj! { "type" => "string", "enum" => Value::Array(dimensions().into_iter().map(Value::from).collect()) },
                        ),
                        (
                            "limit",
                            obj! { "type" => "integer", "minimum" => 1, "maximum" => 100, "description" => "Rows to return. Defaults to 10." },
                        ),
                        (
                            "page",
                            obj! { "type" => "integer", "minimum" => 1, "description" => "For more rows: 2 is the next limit rows." },
                        ),
                    ],
                ]));
                s.as_object_mut().expect("an object").set("required", arr!["dimension"]);
                s
            },
            request: |args| {
                read_with(
                    "/api/breakdown",
                    args,
                    &["site", "period", "from", "to", "filters", "dimension", "page"],
                    limit(args, 10.0),
                )
            },
            shape: None,
        },
        Tool {
            name: "list_funnels",
            title: "Funnels",
            description: "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",
            input_schema: schema(properties(std::slice::from_ref(&r))),
            request: |args| read("/api/funnels", args, &RANGE_KEYS),
            shape: None,
        },
        Tool {
            name: "get_event_properties",
            title: "An event's properties",
            description: "The properties sent with one custom event and the values each took, most common first. Automatic events have their own: \"Outbound link\" and \"File download\" carry url, and \"404\" carries path. Leave key out to see every property name and the values of the most used one.",
            input_schema: {
                let mut s = schema(properties(&[
                    r.clone(),
                    vec![
                        (
                            "event",
                            obj! { "type" => "string", "description" => "The event's name, as get_breakdown with dimension event lists it." },
                        ),
                        (
                            "key",
                            obj! { "type" => "string", "description" => "Which property. Defaults to the most used one." },
                        ),
                        (
                            "limit",
                            obj! { "type" => "integer", "minimum" => 1, "maximum" => 100, "description" => "Values to return. Defaults to 25." },
                        ),
                    ],
                ]));
                s.as_object_mut().expect("an object").set("required", arr!["event"]);
                s
            },
            request: |args| {
                read_with(
                    "/api/event-props",
                    args,
                    &["site", "period", "from", "to", "filters", "event", "key"],
                    limit(args, 25.0),
                )
            },
            shape: None,
        },
        Tool {
            name: "get_visit_times",
            title: "When people visit",
            description: "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
            input_schema: schema(properties(std::slice::from_ref(&r))),
            request: |args| read("/api/rhythm", args, &RANGE_KEYS),
            shape: Some(visit_times_shape),
        },
        Tool {
            name: "get_realtime",
            title: "Right now",
            description: "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",
            input_schema: schema(properties(&[vec![range_one("site")]])),
            request: |args| read("/api/realtime", args, &["site"]),
            shape: None,
        },
        Tool {
            name: "list_goals",
            title: "Goals and conversions",
            description: "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",
            input_schema: schema(properties(&[r.clone(), c.clone()])),
            request: |args| read("/api/goals", args, &COMPARE_KEYS),
            shape: None,
        },
        Tool {
            name: "get_goal",
            title: "One goal in detail",
            description: "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
            input_schema: {
                let mut s = schema(properties(&[r.clone(), vec![("goal_id", obj! { "type" => "string" })]]));
                s.as_object_mut().expect("an object").set("required", arr!["goal_id"]);
                s
            },
            request: |args| ToolRequest {
                path: format!("/api/goals/{}", encode_uri_component(&js::str_or_empty(args.get("goal_id")))),
                params: rpc_range_params(args, &RANGE_KEYS),
            },
            shape: None,
        },
        Tool {
            name: "get_journeys",
            title: "Paths through the site",
            description: "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",
            input_schema: schema(properties(&[
                r.clone(),
                vec![
                    (
                        "steps",
                        obj! { "type" => "integer", "minimum" => 2, "maximum" => 8, "description" => "How many pages of each path. Defaults to 5." },
                    ),
                    (
                        "start",
                        obj! { "type" => "string", "description" => "Only paths from this page, such as /pricing." },
                    ),
                    (
                        "end",
                        obj! { "type" => "string", "description" => "Only paths that reach this page, cut there." },
                    ),
                ],
            ])),
            request: |args| {
                read("/api/journeys", args, &["site", "period", "from", "to", "filters", "steps", "start", "end"])
            },
            shape: None,
        },
        Tool {
            name: "list_links",
            title: "Short links",
            description: "Every short link with its destination and its clicks in the range.",
            input_schema: schema(properties(&[vec![
                range_one("site"),
                range_one("period"),
                range_one("from"),
                range_one("to"),
            ]])),
            request: |args| read("/api/links", args, &["site", "period", "from", "to"]),
            shape: None,
        },
    ]
});

fn rpc_error(id: Option<&Value>, code: i64, message: &str) -> Value {
    obj! { "jsonrpc" => "2.0", "id" => id.cloned().unwrap_or(Value::Null), "error" => obj! { "code" => code as f64, "message" => message } }
}

/// `value && typeof value === "object" ? value : {}`, arrays included.
fn object_or_empty(value: Option<&Value>) -> Value {
    match value {
        Some(v @ (Value::Object(_) | Value::Array(_))) => v.clone(),
        _ => obj! {},
    }
}

/// Runs one tool by name, as the MCP server does; the dashboard's assistant
/// calls it too. `params` holds `name` and `arguments`. An unknown tool is an
/// error with code -32602; an API read that fails is an error without one.
pub async fn call_tool(params: &Value, read_api: &dyn ApiRead) -> Result<Value, McpError> {
    let name = params.get("name");
    let Some(tool) = TOOLS.iter().find(|t| name.and_then(Value::as_str) == Some(t.name)) else {
        let named = name.map_or_else(|| "undefined".to_string(), js::js_string);
        return Err(McpError::coded(format!("Unknown tool \"{named}\""), -32602));
    };
    let args = object_or_empty(params.get("arguments"));
    let ToolRequest { path, params: query } = tool.request(&args);
    let answer = read_api.read(&path, &query).await.map_err(|e| McpError::thrown(e.to_string()))?;
    let body = answer.json_body().unwrap_or_else(|_| obj! {});
    if !answer.ok() {
        let text = match member(&body, "error")? {
            None | Some(Value::Null) => format!("Runlight answered {}", answer.status),
            Some(error) => js::js_string(error),
        };
        return Ok(obj! { "content" => arr![obj! { "type" => "text", "text" => text }], "isError" => true });
    }
    let shaped = tool.shape(&body)?;
    Ok(obj! { "content" => arr![obj! { "type" => "text", "text" => js::stringify(&shaped) }] })
}

/// One message's answer, or `None` for a notification. `Err` is the
/// TypeError JavaScript throws for a message of `null`.
async fn answer(message: &Value, read_api: &dyn ApiRead) -> Result<Option<Value>, BoxError> {
    if message.is_null() {
        return Err("Cannot read properties of null (reading 'id')".into());
    }
    let id = message.get("id");
    let is_notification = id.is_none();
    let method = match message.get("method") {
        Some(Value::String(m)) if message.get("jsonrpc").and_then(Value::as_str) == Some("2.0") => m.as_str(),
        _ => return Ok(if is_notification { None } else { Some(rpc_error(id, -32600, "Invalid request")) }),
    };
    let params = object_or_empty(message.get("params"));
    let result = match method {
        "initialize" => {
            let asked = js::str_or_empty(params.get("protocolVersion"));
            let version =
                if PROTOCOL_VERSIONS.contains(&asked.as_str()) { asked } else { PROTOCOL_VERSIONS[0].to_string() };
            Ok(obj! {
                "protocolVersion" => version,
                "capabilities" => obj! { "tools" => obj! { "listChanged" => false } },
                "serverInfo" => obj! { "name" => "runlight", "title" => "Runlight", "version" => VERSION },
                "instructions" => INSTRUCTIONS,
            })
        }
        "ping" => Ok(obj! {}),
        "tools/list" => Ok(obj! {
            "tools" => Value::Array(
                TOOLS
                    .iter()
                    .map(|t| {
                        obj! {
                            "name" => t.name,
                            "title" => t.title,
                            "description" => t.description,
                            "inputSchema" => t.input_schema.clone(),
                            "annotations" => obj! { "readOnlyHint" => true, "openWorldHint" => false },
                        }
                    })
                    .collect(),
            ),
        }),
        "tools/call" => call_tool(&params, read_api).await,
        _ => {
            if is_notification {
                return Ok(None);
            }
            return Ok(Some(rpc_error(id, -32601, &format!("Unknown method \"{method}\""))));
        }
    };
    if is_notification {
        return Ok(None);
    }
    Ok(Some(match result {
        Ok(result) => obj! { "jsonrpc" => "2.0", "id" => id.cloned().unwrap_or(Value::Null), "result" => result },
        Err(McpError { message, code: Some(code) }) if code != 0 => rpc_error(id, code, &message),
        Err(McpError { code, .. }) => rpc_error(id, code.unwrap_or(-32603), "Internal error"),
    }))
}

fn json_headers() -> Headers {
    Headers::new().with("content-type", "application/json; charset=utf-8").with("cache-control", "no-store")
}

/// Answers one POST to the MCP endpoint, already authorised. `Err` is what
/// the TypeScript throws rather than answers (a batch holding `null`), for
/// the routes to treat as any error they did not expect.
pub async fn mcp_response(request: &Request, read_api: &dyn ApiRead) -> Result<Response, BoxError> {
    let body = match request.json() {
        Ok(body @ (Value::Object(_) | Value::Array(_))) => body,
        _ => {
            let error = rpc_error(None, -32700, "Send a JSON-RPC message");
            return Ok(Response::new(js::stringify(&error), 400, json_headers()));
        }
    };
    // Batches were in the 2025-03-26 protocol; answering them costs nothing.
    if let Value::Array(messages) = &body {
        // Every message is answered, as Promise.all starts them all, before a failure is thrown.
        let mut answers = Vec::new();
        let mut failure = None;
        for message in messages {
            match answer(message, read_api).await {
                Ok(Some(one)) => answers.push(one),
                Ok(None) => {}
                Err(e) => {
                    failure.get_or_insert(e);
                }
            }
        }
        if let Some(e) = failure {
            return Err(e);
        }
        return Ok(if answers.is_empty() {
            Response::status(202)
        } else {
            Response::new(js::stringify(&Value::Array(answers)), 200, json_headers())
        });
    }
    Ok(match answer(&body, read_api).await? {
        Some(one) => Response::new(js::stringify(&one), 200, json_headers()),
        None => Response::status(202),
    })
}
