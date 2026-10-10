//! The dashboard's assistant: questions about the stats, answered by a model
//! the owner chooses, through the same read-only tools as the MCP server. The
//! model runs on the server, so the key never reaches a browser, and each tool
//! reads the API with the asking person's own access.
//!
//! Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
//! Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
//! OpenRouter, Ollama, LM Studio, and most others speak. Plain HTTP through
//! the Fetcher it is given, no SDKs.

use std::cmp::Ordering;
use std::task::Poll;

use crate::goals::CodedError;
use crate::http::{FetchError, FetchInit, Response, SharedFetcher, Url};
use crate::js::{self, Value};
use crate::mcp::{ApiRead, INSTRUCTIONS, TOOLS, call_tool};
use crate::obj;
use crate::re::uni_re;

/// A service the assistant can ask.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Provider {
    /// Its id, as the settings keep it.
    pub id: &'static str,
    /// Its name, as the dashboard shows it.
    pub name: &'static str,
    /// `"anthropic"` or `"openai"`.
    pub protocol: &'static str,
    /// The API's address, filled in for known services and asked for otherwise.
    pub base_url: &'static str,
    /// A model to start with, or "" when the person picks one.
    pub model: &'static str,
    /// Whether it needs a key: "yes", "no" (a model on your own machine), or "optional".
    pub key: &'static str,
}

impl Provider {
    /// The provider as the TypeScript's object, keys in its order.
    pub fn to_value(&self) -> Value {
        obj! {
            "id" => self.id,
            "name" => self.name,
            "protocol" => self.protocol,
            "baseUrl" => self.base_url,
            "model" => self.model,
            "key" => self.key,
        }
    }
}

/// The services, in the order the dashboard lists them.
pub const PROVIDERS: [Provider; 7] = [
    Provider {
        id: "anthropic",
        name: "Anthropic (Claude)",
        protocol: "anthropic",
        base_url: "https://api.anthropic.com/v1",
        model: "claude-sonnet-5-5",
        key: "yes",
    },
    Provider {
        id: "openai",
        name: "OpenAI",
        protocol: "openai",
        base_url: "https://api.openai.com/v1",
        model: "",
        key: "yes",
    },
    Provider {
        id: "gemini",
        name: "Google Gemini",
        protocol: "openai",
        base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
        model: "",
        key: "yes",
    },
    Provider {
        id: "openrouter",
        name: "OpenRouter",
        protocol: "openai",
        base_url: "https://openrouter.ai/api/v1",
        model: "",
        key: "yes",
    },
    Provider {
        id: "ollama",
        name: "Ollama",
        protocol: "openai",
        base_url: "http://localhost:11434/v1",
        model: "",
        key: "no",
    },
    Provider {
        id: "lmstudio",
        name: "LM Studio",
        protocol: "openai",
        base_url: "http://localhost:1234/v1",
        model: "",
        key: "no",
    },
    Provider {
        id: "custom",
        name: "Another OpenAI-compatible service",
        protocol: "openai",
        base_url: "",
        model: "",
        key: "optional",
    },
];

/// What the owner chose in Settings, AI Assistant. `list_models` reads all
/// but `model`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AssistantSettings {
    /// A provider's id.
    pub provider: String,
    /// The model, or "" for the provider's own.
    pub model: String,
    /// The API's address, or "" for the provider's own.
    pub base_url: String,
    /// The key, or "".
    pub key: String,
}

/// What went wrong with the assistant, as a code the dashboard says in its
/// own words; a service's own text goes in the `detail` parameter.
pub type AssistantError = CodedError;

/// Why a question or a model list got no answer: an [`AssistantError`] the
/// routes answer with its code, or what the TypeScript throws as a plain
/// error (a service's answer of a shape it cannot read, an address that is
/// not a URL), which the routes treat as any error they did not expect.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AssistantFailure {
    /// Refused, with a code.
    Coded(AssistantError),
    /// Thrown, with JavaScript's message.
    Thrown(String),
}

impl From<AssistantError> for AssistantFailure {
    fn from(e: AssistantError) -> Self {
        AssistantFailure::Coded(e)
    }
}

impl std::fmt::Display for AssistantFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AssistantFailure::Coded(e) => f.write_str(&e.message),
            AssistantFailure::Thrown(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for AssistantFailure {}

/// One turn of the conversation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatMessage {
    /// `"user"` or `"assistant"`.
    pub role: String,
    /// What was said.
    pub content: String,
}

/// The site the person is looking at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatSite {
    /// Its id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// Its timezone.
    pub timezone: String,
}

/// What the person is looking at, so "this week" and "this page" mean what they see.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatContext {
    /// The site.
    pub site: ChatSite,
    /// Today, YYYY-MM-DD, in the site's timezone.
    pub today: String,
    /// The range on screen, in words.
    pub view: String,
    /// The dashboard's language code.
    pub language: String,
}

/// The reply and the tools the model used, by name (a name the model gave
/// as something other than text stays as it gave it; one it left out is
/// null, as JSON.stringify writes undefined in an array).
#[derive(Clone, Debug, PartialEq)]
pub struct ChatAnswer {
    /// The reply.
    pub reply: String,
    /// The tools used, in order.
    pub tools: Vec<Value>,
}

impl ChatAnswer {
    /// `{ reply, tools }`.
    pub fn to_value(&self) -> Value {
        obj! { "reply" => self.reply.clone(), "tools" => Value::Array(self.tools.clone()) }
    }
}

/// A model a service offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    /// The id to ask for.
    pub id: String,
    /// Its name, or the id when the service gives none.
    pub name: String,
}

impl Model {
    /// `{ id, name }`.
    pub fn to_value(&self) -> Value {
        obj! { "id" => self.id.clone(), "name" => self.name.clone() }
    }
}

/// The clock, in epoch milliseconds.
pub type Clock<'a> = &'a (dyn Fn() -> i64 + Send + Sync);

/// Whether the person has left, as the TypeScript's AbortSignal says.
pub type Cancelled<'a> = Option<&'a (dyn Fn() -> bool + Send + Sync)>;

const MAX_ROUNDS: usize = 8;
/// However many rounds a question takes, the answer comes within this long or the assistant stops.
pub const DEADLINE_MS: i64 = 120_000;
const MAX_TOKENS: i64 = 1500;

fn system(context: &ChatContext) -> String {
    format!(
        "{INSTRUCTIONS}

You are the assistant inside this Runlight dashboard. Today is {today} in {timezone}. The person is looking at the site \"{name}\" (id {id}) for {view}. Unless they ask about another site or range, use this site and these dates.

When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.

Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, \"great\", \"that helps\"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is \"{language}\".",
        today = context.today,
        timezone = context.site.timezone,
        name = context.site.name,
        id = context.site.id,
        view = context.view,
        language = context.language,
    )
}

const TOO_LONG: &str = "That question took too long to answer. Try asking something narrower.";
const TOO_MANY_STEPS: &str = "The assistant needed too many steps for that question. Try asking something narrower.";

/// Stops when the question's time is up or the person has left, before more work starts.
fn in_time(deadline: i64, now: Clock<'_>, cancelled: Cancelled<'_>) -> Result<(), AssistantFailure> {
    if cancelled.is_some_and(|c| c()) {
        return Err(AssistantError::new("The question was cancelled.", "assistant_cancelled", &[]).into());
    }
    if now() >= deadline {
        return Err(AssistantError::new(TOO_LONG, "assistant_slow", &[]).into());
    }
    Ok(())
}

/// The service's own message from an error answer, never the request (it
/// carries the key); "" when there is none.
fn service_message(data: &Value) -> String {
    let error = data.get("error");
    if let Some(Value::String(s)) = error {
        return s.clone();
    }
    match error.and_then(|e| e.get("message")) {
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

/// The refusal for an answer that is not ok.
fn refusal(host: &str, answer: &Response, data: &Value) -> AssistantFailure {
    let message = service_message(data);
    if message.is_empty() {
        let status = answer.status.to_string();
        return AssistantError::new(
            format!("{host}: it answered {status}"),
            "assistant_status",
            &[("host", host), ("status", &status)],
        )
        .into();
    }
    let detail = js::head16(&message, 300);
    AssistantError::new(format!("{host}: {detail}"), "assistant_refused", &[("host", host), ("detail", &detail)]).into()
}

/// A service that answered, but not in its protocol's shape.
fn unreadable(url: &str) -> AssistantFailure {
    let host = match parse_url(url) {
        Ok(u) => u.host(),
        Err(e) => return e,
    };
    let message = format!("{host} sent an answer Runlight could not read");
    AssistantError::new(message.clone(), "assistant_failed", &[("host", &host), ("detail", &message)]).into()
}

fn is_object(value: &Value) -> bool {
    matches!(value, Value::Object(_))
}

/// `new URL(url)`, or the TypeError it throws.
fn parse_url(url: &str) -> Result<Url, AssistantFailure> {
    Url::parse(url).ok_or_else(|| AssistantFailure::Thrown("Invalid URL".into()))
}

/// Sends the request, giving up as soon as the person has left (checked
/// every 50 milliseconds), as the TypeScript's signal aborts the fetch.
async fn fetch(
    fetcher: &SharedFetcher,
    url: &str,
    init: FetchInit,
    cancelled: Cancelled<'_>,
) -> Result<Response, FetchError> {
    // fetch() refuses a URL that carries credentials before sending anything.
    if let Some(u) = Url::parse(url)
        && (!u.username().is_empty() || !u.password().is_empty())
    {
        return Err(FetchError::Failed("Request cannot be constructed from a URL that includes credentials".into()));
    }
    let Some(cancelled) = cancelled else {
        return fetcher.fetch(url, init).await;
    };
    let mut request = fetcher.fetch(url, init);
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(50));
    std::future::poll_fn(|cx| {
        if let Poll::Ready(r) = request.as_mut().poll(cx) {
            return Poll::Ready(r);
        }
        while tick.poll_tick(cx).is_ready() {
            if cancelled() {
                return Poll::Ready(Err(FetchError::Failed("This operation was aborted".into())));
            }
        }
        Poll::Pending
    })
    .await
}

async fn post(
    fetcher: &SharedFetcher,
    url: &str,
    headers: &[(&str, &str)],
    body: &Value,
    deadline: i64,
    now: Clock<'_>,
    cancelled: Cancelled<'_>,
) -> Result<Value, AssistantFailure> {
    in_time(deadline, now, cancelled)?;
    let left = deadline - now();
    let mut init = FetchInit::method("POST").header("content-type", "application/json");
    for (name, value) in headers {
        init = init.header(name, value);
    }
    let init = init.body(js::stringify(body)).timeout(left.clamp(1, 90_000) as u64);
    let answer = match fetch(fetcher, url, init, cancelled).await {
        Ok(answer) => answer,
        Err(error) => {
            let host = parse_url(url)?.host();
            return Err(match error {
                FetchError::TimedOut => AssistantError::new(
                    format!("Could not reach {host}: it took too long to answer"),
                    "assistant_timeout",
                    &[("host", &host)],
                ),
                _ => AssistantError::new(
                    format!("Could not reach {host}: the connection failed"),
                    "unreachable",
                    &[("host", &host)],
                ),
            }
            .into());
        }
    };
    let data = answer.json_body().unwrap_or(Value::Null);
    if !answer.ok() {
        return Err(refusal(&parse_url(url)?.host(), &answer, &data));
    }
    Ok(if data.is_null() {
        obj! {}
    } else {
        data
    })
}

/// Runs one tool for the model: its text, and whether it is an error.
async fn tool_text(name: Option<&Value>, args: &Value, read_api: &dyn ApiRead) -> (String, bool) {
    let mut params = js::Object::new();
    if let Some(name) = name {
        params.set("name", name.clone());
    }
    let args = match args {
        Value::Object(_) | Value::Array(_) => args.clone(),
        _ => obj! {},
    };
    params.set("arguments", args);
    match call_tool(&Value::Object(params), read_api).await {
        Ok(result) => {
            let text = result
                .get("content")
                .and_then(|c| c.as_array())
                .and_then(|c| c.first())
                .and_then(|c| c.get("text"))
                .map(js::js_string)
                .unwrap_or_default();
            (text, result.get("isError") == Some(&Value::Bool(true)))
        }
        Err(error) => (error.message, true),
    }
}

/// Words that only acknowledge an answer, in the dashboard's languages; a
/// message of nothing else gets a reply without the model. The class is
/// JavaScript's `\s`, spelled out.
fn thanks() -> &'static regex::Regex {
    uni_re!(
        r"(?i)^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[\t\n\x0B\x0C\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}!.,]*)+$"
    )
}

fn welcome(language: &str) -> &'static str {
    match language {
        "fr" => "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
        "es" => "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
        "de" => "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
        "pt" => "De nada. Pergunte o que quiser sobre suas estatísticas.",
        _ => "You're welcome. Ask me anything else about your stats.",
    }
}

/// A short reply to a message that only says thanks or OK, or `None` when the message asks something.
pub fn acknowledgement(text: &str, language: &str) -> Option<&'static str> {
    let pictographs = uni_re!(r"\p{Extended_Pictographic}|\x{FE0F}");
    let replaced = pictographs.replace_all(text, regex::NoExpand(" "));
    let plain = js::trim(&replaced);
    if plain.is_empty() && !js::trim(text).is_empty() {
        return Some(welcome(language));
    }
    thanks().is_match(plain).then(|| welcome(language))
}

fn provider_of(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

/// `(settings.baseUrl || provider.baseUrl).replace(/\/+$/, "")`.
fn base_of(settings: &AssistantSettings, provider: &Provider) -> String {
    let base = if settings.base_url.is_empty() { provider.base_url } else { &settings.base_url };
    base.trim_end_matches('/').to_string()
}

/// `data.choices?.[0]?.message ?? {}`.
fn first_message(data: &Value) -> Value {
    let first = match data.get("choices") {
        Some(Value::Array(a)) => a.first(),
        Some(Value::Object(o)) => o.get("0"),
        _ => None,
    };
    match first.and_then(|f| f.get("message")) {
        None | Some(Value::Null) => obj! {},
        Some(m) => m.clone(),
    }
}

/// Answers the last question in `messages`, calling tools as the model asks.
/// Returns the reply and the tools it used. `now` is the clock; `cancelled`
/// says whether the person has left, checked before each request and tool and
/// while a request is out.
pub async fn chat(
    settings: &AssistantSettings,
    messages: &[ChatMessage],
    context: &ChatContext,
    read_api: &dyn ApiRead,
    fetcher: &SharedFetcher,
    now: Clock<'_>,
    cancelled: Cancelled<'_>,
) -> Result<ChatAnswer, AssistantFailure> {
    let Some(provider) = provider_of(&settings.provider) else {
        return Err(
            AssistantError::new("Choose a provider in Settings, AI Assistant", "assistant_provider", &[]).into()
        );
    };
    let base = base_of(settings, provider);
    if base.is_empty() {
        return Err(AssistantError::new(
            "Enter the service's address in Settings, AI Assistant",
            "assistant_address",
            &[],
        )
        .into());
    }
    let model = if settings.model.is_empty() { provider.model } else { &settings.model };
    if model.is_empty() {
        return Err(AssistantError::new("Enter a model in Settings, AI Assistant", "assistant_model", &[]).into());
    }
    let mut used: Vec<Value> = Vec::new();
    // "Thanks!" needs no model, no tools, and certainly not the last answer again.
    let last = messages.last().map_or("", |m| m.content.as_str());
    if let Some(thanks) = acknowledgement(last, &context.language) {
        return Ok(ChatAnswer { reply: thanks.to_string(), tools: Vec::new() });
    }
    let deadline = now() + DEADLINE_MS;
    // The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
    // and with unanswered questions in a row (a reply that never came) joined into one.
    let mut recent = &messages[messages.len().saturating_sub(20)..];
    while recent.first().is_some_and(|m| m.role != "user") {
        recent = &recent[1..];
    }
    let mut history: Vec<(String, String)> = Vec::new();
    for m in recent {
        let content = js::head16(&m.content, 8000);
        match history.last_mut() {
            Some(last) if last.0 == m.role => {
                last.1.push_str("\n\n");
                last.1.push_str(&content);
            }
            _ => history.push((m.role.clone(), content)),
        }
    }
    let history: Vec<Value> =
        history.into_iter().map(|(role, content)| obj! { "role" => role, "content" => content }).collect();

    if provider.protocol == "anthropic" {
        let tools: Vec<Value> = TOOLS
            .iter()
            .map(
                |t| obj! { "name" => t.name, "description" => t.description, "input_schema" => t.input_schema.clone() },
            )
            .collect();
        let headers = [("x-api-key", settings.key.as_str()), ("anthropic-version", "2023-06-01")];
        let mut convo = history;
        for _ in 0..MAX_ROUNDS {
            let body = obj! {
                "model" => model,
                "max_tokens" => MAX_TOKENS,
                "system" => system(context),
                "tools" => Value::Array(tools.clone()),
                "messages" => Value::Array(convo.clone()),
            };
            let data = post(fetcher, &format!("{base}/messages"), &headers, &body, deadline, now, cancelled).await?;
            let blocks = match data.get("content") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(a)) if a.iter().all(is_object) => a.clone(),
                Some(_) => return Err(unreadable(&base)),
            };
            let kind = |b: &Value| b.get("type").and_then(Value::as_str) == Some("tool_use");
            let calls: Vec<&Value> = blocks.iter().filter(|b| kind(b)).collect();
            if data.get("stop_reason").and_then(Value::as_str) != Some("tool_use") || calls.is_empty() {
                let texts: Vec<String> = blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                    .map(|b| js::str_or_empty(b.get("text")))
                    .collect();
                return Ok(ChatAnswer { reply: js::trim(&texts.join("\n")).to_string(), tools: used });
            }
            let mut results = Vec::new();
            for call in &calls {
                // The deadline covers the reading too, however many tools one answer asks for.
                in_time(deadline, now, cancelled)?;
                let name = match call.get("name") {
                    None | Some(Value::Null) => Value::from(""),
                    Some(n) => n.clone(),
                };
                used.push(name.clone());
                let (text, error) = tool_text(Some(&name), call.get("input").unwrap_or(&Value::Null), read_api).await;
                let mut result = js::Object::new().with("type", "tool_result");
                if let Some(id) = call.get("id") {
                    result.set("tool_use_id", id.clone());
                }
                result.set("content", text);
                if error {
                    result.set("is_error", true);
                }
                results.push(Value::Object(result));
            }
            convo.push(obj! { "role" => "assistant", "content" => Value::Array(blocks) });
            convo.push(obj! { "role" => "user", "content" => Value::Array(results) });
        }
        return Err(AssistantError::new(TOO_MANY_STEPS, "assistant_steps", &[]).into());
    }

    let tools: Vec<Value> = TOOLS
        .iter()
        .map(|t| {
            obj! {
                "type" => "function",
                "function" => obj! { "name" => t.name, "description" => t.description, "parameters" => t.input_schema.clone() },
            }
        })
        .collect();
    let mut convo = vec![obj! { "role" => "system", "content" => system(context) }];
    convo.extend(history);
    let auth = format!("Bearer {}", settings.key);
    let headers: Vec<(&str, &str)> =
        if settings.key.is_empty() { Vec::new() } else { vec![("authorization", auth.as_str())] };
    for _ in 0..MAX_ROUNDS {
        // OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
        let limit = if provider.id == "openai" { "max_completion_tokens" } else { "max_tokens" };
        let body = obj! {
            "model" => model,
            limit => MAX_TOKENS,
            "messages" => Value::Array(convo.clone()),
            "tools" => Value::Array(tools.clone()),
        };
        let data =
            post(fetcher, &format!("{base}/chat/completions"), &headers, &body, deadline, now, cancelled).await?;
        let message = first_message(&data);
        let content = message.get("content");
        let tool_calls = message.get("tool_calls");
        let any = match tool_calls {
            Some(Value::Array(a)) => !a.is_empty(),
            Some(Value::String(s)) => !s.is_empty(),
            Some(Value::Object(o)) => js::opt_truthy(o.get("length")),
            _ => false,
        };
        if !any {
            return Ok(ChatAnswer { reply: js::trim(&js::str_or_empty(content)).to_string(), tools: used });
        }
        let calls = match tool_calls {
            Some(Value::Array(a))
                if a.iter().all(|call| is_object(call) && call.get("function").is_some_and(is_object)) =>
            {
                a.clone()
            }
            _ => return Err(unreadable(&base)),
        };
        convo.push(obj! {
            "role" => "assistant",
            "content" => content.cloned().unwrap_or(Value::Null),
            "tool_calls" => Value::Array(calls.clone()),
        });
        for call in &calls {
            in_time(deadline, now, cancelled)?;
            let function = call.get("function");
            let name = function.and_then(|f| f.get("name"));
            used.push(name.cloned().unwrap_or(Value::Null));
            let given = function.and_then(|f| f.get("arguments"));
            let text = if js::opt_truthy(given) { js::js_string(given.expect("arguments")) } else { "{}".to_string() };
            let args = js::parse(&text).unwrap_or_else(|_| obj! {});
            let (text, _) = tool_text(name, &args, read_api).await;
            let mut out = js::Object::new().with("role", "tool");
            if let Some(id) = call.get("id") {
                out.set("tool_call_id", id.clone());
            }
            out.set("content", text);
            convo.push(Value::Object(out));
        }
    }
    Err(AssistantError::new(TOO_MANY_STEPS, "assistant_steps", &[]).into())
}

/// The models a service offers with a key, from its own list: Anthropic's
/// /models, or the /models of an OpenAI-compatible API. Newest or most
/// relevant first where the service orders them; otherwise by name. The
/// settings' `model` is not read.
pub async fn list_models(
    settings: &AssistantSettings,
    fetcher: &SharedFetcher,
) -> Result<Vec<Model>, AssistantFailure> {
    let Some(provider) = provider_of(&settings.provider) else {
        return Err(AssistantError::new("Choose a provider", "assistant_provider", &[]).into());
    };
    let base = base_of(settings, provider);
    if base.is_empty() {
        return Err(AssistantError::new("Enter the service's address first", "assistant_address", &[]).into());
    }
    if provider.key == "yes" && settings.key.is_empty() {
        return Err(AssistantError::new(
            format!("Enter your {} key first", provider.name),
            "assistant_key",
            &[("provider", provider.name)],
        )
        .into());
    }
    let anthropic = provider.protocol == "anthropic";
    let mut init = FetchInit::default().timeout(20_000);
    if anthropic {
        init = init.header("x-api-key", &settings.key).header("anthropic-version", "2023-06-01");
    } else if !settings.key.is_empty() {
        init = init.header("authorization", format!("Bearer {}", settings.key));
    }
    let url = format!("{base}/models{}", if anthropic { "?limit=100" } else { "" });
    let answer = match fetch(fetcher, &url, init, None).await {
        Ok(answer) => answer,
        Err(_) => {
            let host = parse_url(&base)?.host();
            return Err(
                AssistantError::new(format!("Could not reach {host}"), "unreachable", &[("host", &host)]).into()
            );
        }
    };
    let data = answer.json_body().unwrap_or(Value::Null);
    if !answer.ok() {
        return Err(refusal(&parse_url(&base)?.host(), &answer, &data));
    }
    let list = match data.get("data") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a.clone(),
        Some(_) => return Err(unreadable(&base)),
    };
    let mut models = Vec::new();
    for m in list.iter().filter(|m| is_object(m)) {
        let Some(Value::String(id)) = m.get("id") else { continue };
        if id.is_empty() {
            continue;
        }
        // Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
        let id = id.strip_prefix("models/").unwrap_or(id).to_string();
        let name = match m.get("display_name") {
            Some(Value::String(name)) => name.clone(),
            _ => id.clone(),
        };
        models.push(Model { id, name });
    }
    if models.is_empty() {
        let host = parse_url(&base)?.host();
        return Err(AssistantError::new(
            format!("{host} listed no models. Type the model's name instead."),
            "assistant_no_models",
            &[("host", &host)],
        )
        .into());
    }
    // Anthropic lists newest first already; others come in no useful order.
    if !anthropic {
        models.sort_by(|a, b| locale_compare(&a.id, &b.id));
    }
    Ok(models)
}

/// `a.localeCompare(b)` as Node's ICU has it with the root collation, for
/// the text model ids are made of: ASCII exactly, and the Latin letters with
/// diacritics as their letter with an accent. Other characters (ø, ß, CJK,
/// and so on) sort after the letters by code point, where ICU would place
/// them among the letters.
pub fn locale_compare(a: &str, b: &str) -> Ordering {
    let (ka, kb) = (collation::key(a), collation::key(b));
    ka.cmp(&kb)
}

mod collation {
    /// Whitespace, punctuation, symbols, digits, then letters, in the root
    /// collation's order (each letter's two cases share one weight).
    const ORDER: &str = "\t\n\u{b}\u{c}\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz";

    /// A Latin letter with diacritics: its base letter and its accents, as
    /// ranks in the root collation's order of combining marks (acute, grave,
    /// breve, circumflex, caron, ring, diaeresis, double acute, tilde, dot
    /// above, cedilla, ogonek, macron, double grave, inverted breve, horn,
    /// comma below).
    const LATIN: &[(char, u8, &[u16])] = &[
        ('\u{c0}', b'A', &[2]),
        ('\u{c1}', b'A', &[1]),
        ('\u{c2}', b'A', &[4]),
        ('\u{c3}', b'A', &[9]),
        ('\u{c4}', b'A', &[7]),
        ('\u{c5}', b'A', &[6]),
        ('\u{c7}', b'C', &[11]),
        ('\u{c8}', b'E', &[2]),
        ('\u{c9}', b'E', &[1]),
        ('\u{ca}', b'E', &[4]),
        ('\u{cb}', b'E', &[7]),
        ('\u{cc}', b'I', &[2]),
        ('\u{cd}', b'I', &[1]),
        ('\u{ce}', b'I', &[4]),
        ('\u{cf}', b'I', &[7]),
        ('\u{d1}', b'N', &[9]),
        ('\u{d2}', b'O', &[2]),
        ('\u{d3}', b'O', &[1]),
        ('\u{d4}', b'O', &[4]),
        ('\u{d5}', b'O', &[9]),
        ('\u{d6}', b'O', &[7]),
        ('\u{d9}', b'U', &[2]),
        ('\u{da}', b'U', &[1]),
        ('\u{db}', b'U', &[4]),
        ('\u{dc}', b'U', &[7]),
        ('\u{dd}', b'Y', &[1]),
        ('\u{e0}', b'a', &[2]),
        ('\u{e1}', b'a', &[1]),
        ('\u{e2}', b'a', &[4]),
        ('\u{e3}', b'a', &[9]),
        ('\u{e4}', b'a', &[7]),
        ('\u{e5}', b'a', &[6]),
        ('\u{e7}', b'c', &[11]),
        ('\u{e8}', b'e', &[2]),
        ('\u{e9}', b'e', &[1]),
        ('\u{ea}', b'e', &[4]),
        ('\u{eb}', b'e', &[7]),
        ('\u{ec}', b'i', &[2]),
        ('\u{ed}', b'i', &[1]),
        ('\u{ee}', b'i', &[4]),
        ('\u{ef}', b'i', &[7]),
        ('\u{f1}', b'n', &[9]),
        ('\u{f2}', b'o', &[2]),
        ('\u{f3}', b'o', &[1]),
        ('\u{f4}', b'o', &[4]),
        ('\u{f5}', b'o', &[9]),
        ('\u{f6}', b'o', &[7]),
        ('\u{f9}', b'u', &[2]),
        ('\u{fa}', b'u', &[1]),
        ('\u{fb}', b'u', &[4]),
        ('\u{fc}', b'u', &[7]),
        ('\u{fd}', b'y', &[1]),
        ('\u{ff}', b'y', &[7]),
        ('\u{100}', b'A', &[13]),
        ('\u{101}', b'a', &[13]),
        ('\u{102}', b'A', &[3]),
        ('\u{103}', b'a', &[3]),
        ('\u{104}', b'A', &[12]),
        ('\u{105}', b'a', &[12]),
        ('\u{106}', b'C', &[1]),
        ('\u{107}', b'c', &[1]),
        ('\u{108}', b'C', &[4]),
        ('\u{109}', b'c', &[4]),
        ('\u{10a}', b'C', &[10]),
        ('\u{10b}', b'c', &[10]),
        ('\u{10c}', b'C', &[5]),
        ('\u{10d}', b'c', &[5]),
        ('\u{10e}', b'D', &[5]),
        ('\u{10f}', b'd', &[5]),
        ('\u{112}', b'E', &[13]),
        ('\u{113}', b'e', &[13]),
        ('\u{114}', b'E', &[3]),
        ('\u{115}', b'e', &[3]),
        ('\u{116}', b'E', &[10]),
        ('\u{117}', b'e', &[10]),
        ('\u{118}', b'E', &[12]),
        ('\u{119}', b'e', &[12]),
        ('\u{11a}', b'E', &[5]),
        ('\u{11b}', b'e', &[5]),
        ('\u{11c}', b'G', &[4]),
        ('\u{11d}', b'g', &[4]),
        ('\u{11e}', b'G', &[3]),
        ('\u{11f}', b'g', &[3]),
        ('\u{120}', b'G', &[10]),
        ('\u{121}', b'g', &[10]),
        ('\u{122}', b'G', &[11]),
        ('\u{123}', b'g', &[11]),
        ('\u{124}', b'H', &[4]),
        ('\u{125}', b'h', &[4]),
        ('\u{128}', b'I', &[9]),
        ('\u{129}', b'i', &[9]),
        ('\u{12a}', b'I', &[13]),
        ('\u{12b}', b'i', &[13]),
        ('\u{12c}', b'I', &[3]),
        ('\u{12d}', b'i', &[3]),
        ('\u{12e}', b'I', &[12]),
        ('\u{12f}', b'i', &[12]),
        ('\u{130}', b'I', &[10]),
        ('\u{134}', b'J', &[4]),
        ('\u{135}', b'j', &[4]),
        ('\u{136}', b'K', &[11]),
        ('\u{137}', b'k', &[11]),
        ('\u{139}', b'L', &[1]),
        ('\u{13a}', b'l', &[1]),
        ('\u{13b}', b'L', &[11]),
        ('\u{13c}', b'l', &[11]),
        ('\u{13d}', b'L', &[5]),
        ('\u{13e}', b'l', &[5]),
        ('\u{143}', b'N', &[1]),
        ('\u{144}', b'n', &[1]),
        ('\u{145}', b'N', &[11]),
        ('\u{146}', b'n', &[11]),
        ('\u{147}', b'N', &[5]),
        ('\u{148}', b'n', &[5]),
        ('\u{14c}', b'O', &[13]),
        ('\u{14d}', b'o', &[13]),
        ('\u{14e}', b'O', &[3]),
        ('\u{14f}', b'o', &[3]),
        ('\u{150}', b'O', &[8]),
        ('\u{151}', b'o', &[8]),
        ('\u{154}', b'R', &[1]),
        ('\u{155}', b'r', &[1]),
        ('\u{156}', b'R', &[11]),
        ('\u{157}', b'r', &[11]),
        ('\u{158}', b'R', &[5]),
        ('\u{159}', b'r', &[5]),
        ('\u{15a}', b'S', &[1]),
        ('\u{15b}', b's', &[1]),
        ('\u{15c}', b'S', &[4]),
        ('\u{15d}', b's', &[4]),
        ('\u{15e}', b'S', &[11]),
        ('\u{15f}', b's', &[11]),
        ('\u{160}', b'S', &[5]),
        ('\u{161}', b's', &[5]),
        ('\u{162}', b'T', &[11]),
        ('\u{163}', b't', &[11]),
        ('\u{164}', b'T', &[5]),
        ('\u{165}', b't', &[5]),
        ('\u{168}', b'U', &[9]),
        ('\u{169}', b'u', &[9]),
        ('\u{16a}', b'U', &[13]),
        ('\u{16b}', b'u', &[13]),
        ('\u{16c}', b'U', &[3]),
        ('\u{16d}', b'u', &[3]),
        ('\u{16e}', b'U', &[6]),
        ('\u{16f}', b'u', &[6]),
        ('\u{170}', b'U', &[8]),
        ('\u{171}', b'u', &[8]),
        ('\u{172}', b'U', &[12]),
        ('\u{173}', b'u', &[12]),
        ('\u{174}', b'W', &[4]),
        ('\u{175}', b'w', &[4]),
        ('\u{176}', b'Y', &[4]),
        ('\u{177}', b'y', &[4]),
        ('\u{178}', b'Y', &[7]),
        ('\u{179}', b'Z', &[1]),
        ('\u{17a}', b'z', &[1]),
        ('\u{17b}', b'Z', &[10]),
        ('\u{17c}', b'z', &[10]),
        ('\u{17d}', b'Z', &[5]),
        ('\u{17e}', b'z', &[5]),
        ('\u{1a0}', b'O', &[16]),
        ('\u{1a1}', b'o', &[16]),
        ('\u{1af}', b'U', &[16]),
        ('\u{1b0}', b'u', &[16]),
        ('\u{1cd}', b'A', &[5]),
        ('\u{1ce}', b'a', &[5]),
        ('\u{1cf}', b'I', &[5]),
        ('\u{1d0}', b'i', &[5]),
        ('\u{1d1}', b'O', &[5]),
        ('\u{1d2}', b'o', &[5]),
        ('\u{1d3}', b'U', &[5]),
        ('\u{1d4}', b'u', &[5]),
        ('\u{1d5}', b'U', &[7, 13]),
        ('\u{1d6}', b'u', &[7, 13]),
        ('\u{1d7}', b'U', &[7, 1]),
        ('\u{1d8}', b'u', &[7, 1]),
        ('\u{1d9}', b'U', &[7, 5]),
        ('\u{1da}', b'u', &[7, 5]),
        ('\u{1db}', b'U', &[7, 2]),
        ('\u{1dc}', b'u', &[7, 2]),
        ('\u{1de}', b'A', &[7, 13]),
        ('\u{1df}', b'a', &[7, 13]),
        ('\u{1e0}', b'A', &[10, 13]),
        ('\u{1e1}', b'a', &[10, 13]),
        ('\u{1e6}', b'G', &[5]),
        ('\u{1e7}', b'g', &[5]),
        ('\u{1e8}', b'K', &[5]),
        ('\u{1e9}', b'k', &[5]),
        ('\u{1ea}', b'O', &[12]),
        ('\u{1eb}', b'o', &[12]),
        ('\u{1ec}', b'O', &[12, 13]),
        ('\u{1ed}', b'o', &[12, 13]),
        ('\u{1f0}', b'j', &[5]),
        ('\u{1f4}', b'G', &[1]),
        ('\u{1f5}', b'g', &[1]),
        ('\u{1f8}', b'N', &[2]),
        ('\u{1f9}', b'n', &[2]),
        ('\u{1fa}', b'A', &[6, 1]),
        ('\u{1fb}', b'a', &[6, 1]),
        ('\u{200}', b'A', &[14]),
        ('\u{201}', b'a', &[14]),
        ('\u{202}', b'A', &[15]),
        ('\u{203}', b'a', &[15]),
        ('\u{204}', b'E', &[14]),
        ('\u{205}', b'e', &[14]),
        ('\u{206}', b'E', &[15]),
        ('\u{207}', b'e', &[15]),
        ('\u{208}', b'I', &[14]),
        ('\u{209}', b'i', &[14]),
        ('\u{20a}', b'I', &[15]),
        ('\u{20b}', b'i', &[15]),
        ('\u{20c}', b'O', &[14]),
        ('\u{20d}', b'o', &[14]),
        ('\u{20e}', b'O', &[15]),
        ('\u{20f}', b'o', &[15]),
        ('\u{210}', b'R', &[14]),
        ('\u{211}', b'r', &[14]),
        ('\u{212}', b'R', &[15]),
        ('\u{213}', b'r', &[15]),
        ('\u{214}', b'U', &[14]),
        ('\u{215}', b'u', &[14]),
        ('\u{216}', b'U', &[15]),
        ('\u{217}', b'u', &[15]),
        ('\u{218}', b'S', &[17]),
        ('\u{219}', b's', &[17]),
        ('\u{21a}', b'T', &[17]),
        ('\u{21b}', b't', &[17]),
        ('\u{21e}', b'H', &[5]),
        ('\u{21f}', b'h', &[5]),
        ('\u{226}', b'A', &[10]),
        ('\u{227}', b'a', &[10]),
        ('\u{228}', b'E', &[11]),
        ('\u{229}', b'e', &[11]),
        ('\u{22a}', b'O', &[7, 13]),
        ('\u{22b}', b'o', &[7, 13]),
        ('\u{22c}', b'O', &[9, 13]),
        ('\u{22d}', b'o', &[9, 13]),
        ('\u{22e}', b'O', &[10]),
        ('\u{22f}', b'o', &[10]),
        ('\u{230}', b'O', &[10, 13]),
        ('\u{231}', b'o', &[10, 13]),
        ('\u{232}', b'Y', &[13]),
        ('\u{233}', b'y', &[13]),
    ];

    /// The three levels of a string's sort key: primary weights, then
    /// secondary (accents), then tertiary (case).
    pub(super) fn key(s: &str) -> (Vec<u32>, Vec<u16>, Vec<u8>) {
        let (mut p, mut sec, mut t) = (Vec::new(), Vec::new(), Vec::new());
        for c in s.chars() {
            let code = c as u32;
            if code < 0x80 {
                let lower = c.to_ascii_lowercase();
                if let Some(at) = ORDER.find(lower) {
                    p.push(at as u32 + 1);
                    sec.push(1);
                    t.push(u8::from(c.is_ascii_uppercase()));
                }
                // Other control characters are ignored at every level.
                continue;
            }
            if let Some((_, base, marks)) = LATIN.iter().find(|(l, _, _)| *l == c) {
                let lower = base.to_ascii_lowercase() as char;
                p.push(ORDER.find(lower).expect("a letter") as u32 + 1);
                sec.push(1);
                t.push(u8::from(base.is_ascii_uppercase()));
                sec.extend(marks.iter().map(|m| 1 + m));
                continue;
            }
            p.push(1000 + code);
            sec.push(1);
            t.push(0);
        }
        (p, sec, t)
    }
}
