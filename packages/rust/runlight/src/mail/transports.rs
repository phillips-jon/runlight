//! Every service Runlight can send mail through, and the one call that sends
//! a message through whichever is configured.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::goals::CodedError;
use crate::http::{FetchInit, SearchParams, SharedFetcher, Url};
use crate::js::{self, Object, Value};
use crate::{arr, obj};

/// One message to send.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Message {
    /// The address it goes to.
    pub to: String,
    /// The address it comes from.
    pub from: String,
    /// The name it comes from; `None` or empty for none.
    pub from_name: Option<String>,
    /// The subject.
    pub subject: String,
    /// The HTML body.
    pub html: String,
    /// The plain text body.
    pub text: String,
    /// Extra headers, such as List-Unsubscribe, in the order they are written.
    pub headers: Vec<(String, String)>,
}

impl Message {
    /// A message read from its JSON form (`to`, `from`, `fromName`, `subject`,
    /// `html`, `text`, and `headers`, an object), with missing strings empty.
    pub fn from_value(v: &Value) -> Message {
        let text = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        Message {
            to: text("to"),
            from: text("from"),
            from_name: v.get("fromName").and_then(Value::as_str).map(str::to_string),
            subject: text("subject"),
            html: text("html"),
            text: text("text"),
            headers: v
                .get("headers")
                .and_then(Value::as_object)
                .map(|o| o.iter().map(|(k, v)| (k.to_string(), js::js_string(v))).collect())
                .unwrap_or_default(),
        }
    }

    /// The name it comes from, when there is one (`m.fromName` truthy).
    pub fn name(&self) -> Option<&str> {
        self.from_name.as_deref().filter(|n| !n.is_empty())
    }

    /// The headers as a JSON object, as `m.headers ?? {}` is written.
    pub fn headers_object(&self) -> Object {
        let mut o = Object::new();
        for (k, v) in &self.headers {
            o.set(k.clone(), v.clone());
        }
        o
    }
}

/// A mail problem to show the person setting it up. `code` and `params` let the dashboard say it in
/// its own language; a service's own words, which only it can give, travel in `params.detail`.
pub type MailError = CodedError;

/// A MailError with the default code, `mail_failed`, and `{ detail: message }` as its params.
pub fn mail_error(message: impl Into<String>) -> MailError {
    let message = message.into();
    CodedError { params: vec![("detail".into(), message.clone())], message, code: "mail_failed".into() }
}

/// A service's settings: `service` plus its fields. Every value is a string, as typed in the dashboard.
pub type MailConfig = Object;

/// One setting a service needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ServiceField {
    /// The key in the config.
    pub name: &'static str,
    /// What the dashboard calls it.
    pub label: &'static str,
    /// Never sent back to the browser once saved.
    pub secret: bool,
    /// The values it may take, when it is a choice.
    pub options: Option<&'static [&'static str]>,
    /// Whether it may be left blank.
    pub optional: bool,
    /// An example of what goes in it.
    pub placeholder: Option<&'static str>,
}

/// A service Runlight can send through.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Service {
    /// The id kept in the config.
    pub id: &'static str,
    /// Its name.
    pub name: &'static str,
    /// What it needs.
    pub fields: &'static [ServiceField],
}

const fn field(name: &'static str, label: &'static str) -> ServiceField {
    ServiceField { name, label, secret: false, options: None, optional: false, placeholder: None }
}

impl ServiceField {
    const fn secret(mut self) -> Self {
        self.secret = true;
        self
    }
    const fn optional(mut self) -> Self {
        self.optional = true;
        self
    }
    const fn placeholder(mut self, text: &'static str) -> Self {
        self.placeholder = Some(text);
        self
    }
    const fn options(mut self, options: &'static [&'static str]) -> Self {
        self.options = Some(options);
        self
    }

    /// The field as the TypeScript literal writes it: `name`, `label`, then
    /// `secret`, `options`, `optional`, and `placeholder` where they are set.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new().with("name", self.name).with("label", self.label);
        if self.secret {
            o.set("secret", true);
        }
        if let Some(options) = self.options {
            o.set("options", Value::Array(options.iter().map(|x| Value::from(*x)).collect()));
        }
        if self.optional {
            o.set("optional", true);
        }
        if let Some(p) = self.placeholder {
            o.set("placeholder", p);
        }
        Value::Object(o)
    }
}

impl Service {
    /// `{ id, name, fields }`, as the routes send it to the dashboard.
    pub fn to_value(&self) -> Value {
        obj! { "id" => self.id, "name" => self.name, "fields" => Value::Array(self.fields.iter().map(ServiceField::to_value).collect()) }
    }
}

const US_EU: &[&str] = &["us", "eu"];

/// Every service Runlight can send through, and what each needs.
pub static SERVICES: &[Service] = &[
    Service {
        id: "ses",
        name: "Amazon SES",
        fields: &[
            field("region", "Region").placeholder("us-east-1"),
            field("accessKeyId", "Access key ID"),
            field("secretAccessKey", "Secret access key").secret(),
        ],
    },
    Service { id: "resend", name: "Resend", fields: &[field("apiKey", "API key").secret().placeholder("re_...")] },
    Service {
        id: "postmark",
        name: "Postmark",
        fields: &[
            field("serverToken", "Server API token").secret(),
            field("stream", "Message stream").optional().placeholder("outbound"),
        ],
    },
    Service { id: "sendgrid", name: "SendGrid", fields: &[field("apiKey", "API key").secret().placeholder("SG....")] },
    Service {
        id: "mailgun",
        name: "Mailgun",
        fields: &[
            field("domain", "Sending domain").placeholder("mg.example.com"),
            field("apiKey", "API key").secret(),
            field("region", "Region").options(US_EU),
        ],
    },
    Service { id: "brevo", name: "Brevo", fields: &[field("apiKey", "API key").secret().placeholder("xkeysib-...")] },
    Service {
        id: "mailjet",
        name: "Mailjet",
        fields: &[field("apiKey", "API key"), field("secretKey", "Secret key").secret()],
    },
    Service {
        id: "mailersend",
        name: "MailerSend",
        fields: &[field("apiKey", "API token").secret().placeholder("mlsn....")],
    },
    Service {
        id: "sparkpost",
        name: "SparkPost",
        fields: &[field("apiKey", "API key").secret(), field("region", "Region").options(US_EU)],
    },
    Service {
        id: "smtp",
        name: "SMTP",
        fields: &[
            field("host", "Host").placeholder("smtp.example.com"),
            field("port", "Port").placeholder("587"),
            field("security", "Security").options(&["starttls", "tls", "none"]),
            field("username", "Username").optional(),
            field("password", "Password").secret().optional(),
        ],
    },
    Service {
        id: "webhook",
        name: "Webhook",
        fields: &[
            field("url", "URL").placeholder("https://example.com/hooks/mail"),
            field("secret", "Signing secret").secret().optional(),
        ],
    },
];

/// SERVICES as JSON, as the routes send it to the dashboard.
pub fn services_value() -> Value {
    Value::Array(SERVICES.iter().map(Service::to_value).collect())
}

/// `config[name]`, when it is a string.
pub(crate) fn get<'a>(config: &'a MailConfig, name: &str) -> Option<&'a str> {
    config.get(name).and_then(Value::as_str)
}

/// `config[name]`, or empty.
pub(crate) fn get_or_empty<'a>(config: &'a MailConfig, name: &str) -> &'a str {
    get(config, name).unwrap_or("")
}

/// `fromName <from>` with the name's quotes, backslashes, and line breaks taken out, or the bare address.
pub fn address(m: &Message) -> String {
    match m.name() {
        Some(name) => {
            format!(
                "{} <{}>",
                name.chars().filter(|c| !matches!(c, '"' | '\\' | '\r' | '\n')).collect::<String>(),
                m.from
            )
        }
        None => m.from.clone(),
    }
}

/// The error a mail service explains itself with, from its JSON or XML reply,
/// and never the raw body: a reply is shown to the dashboard, so an address
/// that is not a mail service must not be able to put its page there.
pub fn service_message(reply: &str) -> String {
    fn first(v: Option<&Value>) -> String {
        match v {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Array(a)) => first(a.first()),
            Some(Value::Object(o)) => first(o.get("message")),
            _ => String::new(),
        }
    }
    match js::parse(reply) {
        // Reading a field of null throws in TypeScript, so the XML form is tried, as for text that is not JSON.
        Ok(Value::Null) | Err(_) => xml_message(reply),
        Ok(parsed) => {
            let at = |k: &str| match &parsed {
                Value::Object(o) => o.get(k),
                _ => None,
            };
            for name in ["message", "Message", "error", "errors", "ErrorMessage"] {
                let text = first(at(name));
                if !text.is_empty() {
                    return js::head16(&text, 200);
                }
            }
            String::new()
        }
    }
}

/// `/<Message>([^<]{1,200})<\/Message>/.exec(reply)?.[1]`, trimmed: the first
/// `<Message>` holding 1 to 200 UTF-16 code units and no `<` before its close.
fn xml_message(reply: &str) -> String {
    let mut rest = reply;
    while let Some(at) = rest.find("<Message>") {
        let after = &rest[at + "<Message>".len()..];
        let end = after.find('<').unwrap_or(after.len());
        let inner = &after[..end];
        if !inner.is_empty() && js::len16(inner) <= 200 && after[end..].starts_with("</Message>") {
            return js::trim(inner).to_string();
        }
        rest = &rest[at + 1..];
    }
    String::new()
}

/// POSTs to a service, with the errors the dashboard shows. `explains` says
/// whether the service's own words may come back from its reply.
async fn post(
    fetcher: &SharedFetcher,
    url: &str,
    headers: &[(&'static str, String)],
    body: String,
    explains: bool,
) -> Result<(), MailError> {
    // TypeScript's `new URL(url).host`, which throws a TypeError for a URL that does not parse.
    let host = Url::parse(url).map(|u| u.host()).ok_or_else(|| mail_error("Invalid URL"))?;
    let mut init = FetchInit::method("POST").body(body).timeout(20_000);
    for (k, v) in headers {
        init = init.header(k, v);
    }
    let response = fetcher.fetch(url, init).await.map_err(|e| {
        let detail = e.to_string();
        CodedError::new(
            format!("Could not reach {host}: {detail}"),
            "mail_unreachable",
            &[("host", &host), ("detail", &detail)],
        )
    })?;
    if response.ok() {
        return Ok(());
    }
    let message = if explains { service_message(&response.text()) } else { String::new() };
    let status = response.status;
    let (said, detail) = if message.is_empty() {
        (String::new(), status.to_string())
    } else {
        (format!(": {message}"), format!("{status} {message}"))
    };
    Err(CodedError::new(
        format!("{host} answered {status}{said}"),
        "mail_refused",
        &[("host", &host), ("detail", &detail)],
    ))
}

/// `{ "content-type": "application/json", ...headers }`.
fn json(headers: Vec<(&'static str, String)>) -> Vec<(&'static str, String)> {
    let mut out = vec![("content-type", "application/json".to_string())];
    out.extend(headers);
    out
}

/// `btoa(text)`: base64 of Latin-1, refusing a character past U+00FF as the browser's does.
fn btoa(text: &str) -> Result<String, MailError> {
    let mut bytes = Vec::with_capacity(text.len());
    for c in text.chars() {
        let n = c as u32;
        if n > 0xff {
            // TypeScript throws a DOMException here, which is not a MailError.
            return Err(mail_error("Invalid character"));
        }
        bytes.push(n as u8);
    }
    Ok(STANDARD.encode(bytes))
}

fn basic(user: &str, pass: &str) -> Result<String, MailError> {
    Ok(format!("Basic {}", btoa(&format!("{user}:{pass}"))?))
}

/// Checks a config has what its service needs, before anything is saved or sent.
pub fn check_config(config: &MailConfig) -> Result<(), MailError> {
    let id = get(config, "service");
    let Some(service) = SERVICES.iter().find(|s| Some(s.id) == id) else {
        return Err(CodedError::new("Pick a mail service", "mail_service", &[]));
    };
    for f in service.fields {
        let value = get(config, f.name);
        if !f.optional && value.is_none_or(|v| js::trim(v).is_empty()) {
            return Err(CodedError::new(
                format!("Enter the {}", f.label.to_lowercase()),
                "mail_field",
                &[("field", f.name)],
            ));
        }
        if let (Some(options), Some(v)) = (f.options, value)
            && !v.is_empty()
            && !options.contains(&v)
        {
            let list = options.join(", ");
            return Err(CodedError::new(
                format!("{} must be one of {list}", f.label),
                "mail_option",
                &[("field", f.name), ("options", &list)],
            ));
        }
    }
    let url = get_or_empty(config, "url");
    if service.id == "webhook" && !url.starts_with("https://") && !local_http(url) {
        return Err(CodedError::new("The webhook URL must use https", "mail_https", &[]));
    }
    Ok(())
}

/// `/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/`.
fn local_http(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("http://") else { return false };
    let Some(rest) = rest.strip_prefix("localhost").or_else(|| rest.strip_prefix("127.0.0.1")) else { return false };
    let rest = match rest.strip_prefix(':') {
        Some(port) => {
            let digits = port.bytes().take_while(u8::is_ascii_digit).count();
            if digits == 0 {
                return false;
            }
            &port[digits..]
        }
        None => rest,
    };
    rest.is_empty() || rest.starts_with('/')
}

/// `{ email, name }`, with the name only when there is one, under these keys.
fn sender(m: &Message, email: &str, name: &str) -> Value {
    let mut o = Object::new().with(email, m.from.as_str());
    if let Some(n) = m.name() {
        o.set(name, n);
    }
    Value::Object(o)
}

/// `[{ [name]: k, [value]: v }, ...]` of the headers.
fn header_list(m: &Message, name: &str, value: &str) -> Value {
    Value::Array(
        m.headers_object()
            .iter()
            .map(|(k, v)| Value::Object(Object::new().with(name, k).with(value, v.clone())))
            .collect(),
    )
}

/// Sends one message through the configured service. HTTP services post
/// through `fetcher`; `now` (epoch milliseconds) is the time Amazon SES's
/// signature and an SMTP message's Date are written with.
pub async fn send(config: &MailConfig, m: &Message, fetcher: &SharedFetcher, now: i64) -> Result<(), MailError> {
    check_config(config)?;
    let headers = Value::Object(m.headers_object());
    let c = |k: &str| get_or_empty(config, k).to_string();
    match get_or_empty(config, "service") {
        "resend" => {
            let body = obj! {
                "from" => address(m), "to" => arr![m.to.as_str()], "subject" => m.subject.as_str(),
                "html" => m.html.as_str(), "text" => m.text.as_str(), "headers" => headers,
            };
            post(
                fetcher,
                "https://api.resend.com/emails",
                &json(vec![("authorization", format!("Bearer {}", c("apiKey")))]),
                js::stringify(&body),
                true,
            )
            .await
        }
        "postmark" => {
            let stream = c("stream");
            let body = obj! {
                "From" => address(m), "To" => m.to.as_str(), "Subject" => m.subject.as_str(), "HtmlBody" => m.html.as_str(), "TextBody" => m.text.as_str(),
                "MessageStream" => if stream.is_empty() { "outbound".to_string() } else { stream },
                "Headers" => header_list(m, "Name", "Value"),
            };
            post(
                fetcher,
                "https://api.postmarkapp.com/email",
                &json(vec![("accept", "application/json".into()), ("x-postmark-server-token", c("serverToken"))]),
                js::stringify(&body),
                true,
            )
            .await
        }
        "sendgrid" => {
            let body = obj! {
                "personalizations" => arr![obj! { "to" => arr![obj! { "email" => m.to.as_str() }] }],
                "from" => sender(m, "email", "name"),
                "subject" => m.subject.as_str(),
                "content" => arr![obj! { "type" => "text/plain", "value" => m.text.as_str() }, obj! { "type" => "text/html", "value" => m.html.as_str() }],
                "headers" => headers,
            };
            post(
                fetcher,
                "https://api.sendgrid.com/v3/mail/send",
                &json(vec![("authorization", format!("Bearer {}", c("apiKey")))]),
                js::stringify(&body),
                true,
            )
            .await
        }
        "mailgun" => {
            let mut form = SearchParams::from_pairs([
                ("from", address(m)),
                ("to", m.to.clone()),
                ("subject", m.subject.clone()),
                ("html", m.html.clone()),
                ("text", m.text.clone()),
            ]);
            for (k, v) in m.headers_object().iter() {
                form.set(&format!("h:{k}"), &js::js_string(v));
            }
            let host = if c("region") == "eu" { "api.eu.mailgun.net" } else { "api.mailgun.net" };
            let url = format!("https://{host}/v3/{}/messages", crate::sources::encode_uri_component(&c("domain")));
            post(
                fetcher,
                &url,
                &[
                    ("authorization", basic("api", &c("apiKey"))?),
                    ("content-type", "application/x-www-form-urlencoded".into()),
                ],
                form.to_string(),
                true,
            )
            .await
        }
        "brevo" => {
            let body = obj! {
                "sender" => sender(m, "email", "name"), "to" => arr![obj! { "email" => m.to.as_str() }], "subject" => m.subject.as_str(),
                "htmlContent" => m.html.as_str(), "textContent" => m.text.as_str(), "headers" => headers,
            };
            post(
                fetcher,
                "https://api.brevo.com/v3/smtp/email",
                &json(vec![("api-key", c("apiKey")), ("accept", "application/json".into())]),
                js::stringify(&body),
                true,
            )
            .await
        }
        "mailjet" => {
            let body = obj! {
                "Messages" => arr![obj! {
                    "From" => sender(m, "Email", "Name"), "To" => arr![obj! { "Email" => m.to.as_str() }], "Subject" => m.subject.as_str(),
                    "TextPart" => m.text.as_str(), "HTMLPart" => m.html.as_str(), "Headers" => headers,
                }],
            };
            let auth = basic(&c("apiKey"), &c("secretKey"))?;
            post(
                fetcher,
                "https://api.mailjet.com/v3.1/send",
                &json(vec![("authorization", auth)]),
                js::stringify(&body),
                true,
            )
            .await
        }
        "mailersend" => {
            let mut body = Object::new()
                .with("from", sender(m, "email", "name"))
                .with("to", arr![obj! { "email" => m.to.as_str() }])
                .with("subject", m.subject.as_str())
                .with("html", m.html.as_str())
                .with("text", m.text.as_str());
            if !m.headers_object().is_empty() {
                body.set("headers", header_list(m, "name", "value"));
            }
            post(
                fetcher,
                "https://api.mailersend.com/v1/email",
                &json(vec![("authorization", format!("Bearer {}", c("apiKey")))]),
                body.to_json(),
                true,
            )
            .await
        }
        "sparkpost" => {
            let from = match m.name() {
                Some(n) => obj! { "email" => m.from.as_str(), "name" => n },
                None => Value::from(m.from.as_str()),
            };
            let body = obj! {
                "recipients" => arr![obj! { "address" => obj! { "email" => m.to.as_str() } }],
                "content" => obj! { "from" => from, "subject" => m.subject.as_str(), "html" => m.html.as_str(), "text" => m.text.as_str(), "headers" => headers },
            };
            let host = if c("region") == "eu" { "api.eu.sparkpost.com" } else { "api.sparkpost.com" };
            post(
                fetcher,
                &format!("https://{host}/api/v1/transmissions"),
                &json(vec![("authorization", c("apiKey"))]),
                js::stringify(&body),
                true,
            )
            .await
        }
        "ses" => super::ses::ses_send(config, m, &address(m), fetcher, now).await,
        "smtp" => {
            let mut uuid = super::smtp::random_uuid;
            super::smtp::smtp_send(config, m, &address(m), super::smtp::DEADLINE_MS, now, &mut uuid).await
        }
        "webhook" => {
            let body = js::stringify(&obj! {
                "to" => m.to.as_str(), "from" => m.from.as_str(), "fromName" => m.from_name.clone().unwrap_or_default(),
                "subject" => m.subject.as_str(), "html" => m.html.as_str(), "text" => m.text.as_str(), "headers" => headers,
            });
            let secret = c("secret");
            let signature: Vec<(&'static str, String)> = if secret.is_empty() {
                Vec::new()
            } else {
                vec![("x-runlight-signature", format!("sha256={}", crate::hash::hmac(&secret, &body)))]
            };
            // A webhook can be any address, so only its status comes back.
            post(fetcher, &c("url"), &json(signature), body, false).await
        }
        other => Err(CodedError::new(format!("Unknown mail service \"{other}\""), "mail_service", &[])),
    }
}
