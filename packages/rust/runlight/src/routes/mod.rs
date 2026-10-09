//! The dashboard, its HTTP API, the tracker endpoint, and the pages around
//! them (routes.ts), framework-free: `Routes::handle(Request) -> Response`.

mod api;
mod glue;
mod parts;
mod wired;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::assets::{self, BUILD_INFO, DASHBOARD_CSS, DASHBOARD_JS, PICKER, TRACKER, WORLD_JSON};
use crate::goals::{CodedError, click_rules};
use crate::hash::{hmac, random_id, sha256};
use crate::http::{Headers, Request, Response, Url};
use crate::js::{self, Value};
use crate::re::{js_re, test};
use crate::runlight::{Runlight, env_value};
use crate::store::TokenRow;
use crate::{BoxFuture, obj};

pub use glue::RoutesExtras;

/// What a check of the app's own says a request may do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    /// Full access.
    Full,
    /// Everything but the install-wide controls.
    Member,
    /// Read every site's stats and change nothing.
    Read,
    /// Refused.
    Denied,
}

/// The token routes() checks.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum TokenOption {
    /// RUNLIGHT_TOKEN, the default.
    #[default]
    FromEnv,
    /// Open everywhere, for example behind the app's own auth middleware (the SDK's `null`).
    Open,
    /// This token; empty means none.
    Given(String),
}

/// Checks a request the app's own way.
pub type Authorize = Arc<dyn Fn(&Request) -> BoxFuture<'static, Access> + Send + Sync>;

/// How routes() is set up. The option names are the SDK's.
#[derive(Clone, Default)]
pub struct RoutesOptions {
    /// Where the routes are mounted. Default "/runlight".
    pub base_path: Option<String>,
    /// Required to read stats.
    pub token: TokenOption,
    /// The app's own check instead of a token.
    pub authorize: Option<Authorize>,
    /// Also accepted as a bearer token on POST /api/check. `None` reads CRON_SECRET.
    pub cron_secret: Option<String>,
    /// Lets another site report AI agent fetches to POST /api/observe. `None` reads RUNLIGHT_OBSERVE_KEY.
    pub observe_key: Option<String>,
    /// A link to sign out, shown in the dashboard's footer.
    pub sign_out: Option<String>,
    /// Where to sign in.
    pub sign_in: Option<String>,
    /// Sign-in accounts for the dashboard.
    pub accounts: bool,
    /// Credits DB-IP in the dashboard's footer.
    pub geo_credit: bool,
    /// The address people open the app at, such as https://example.com.
    pub origin: Option<String>,
    /// What the standalone server adds: more names the dashboard is reached at, and its accounts' hooks.
    pub extras: RoutesExtras,
}

pub(crate) const COOKIE: &str = "runlight_token";
/// API tokens start with this, so they are told apart from the main token.
pub(crate) const TOKEN_PREFIX: &str = "rl_";
/// The header a shared dashboard sends its share id in.
pub(crate) const SHARE_HEADER: &str = "x-runlight-share";
/// Where the tracker's click rules go; the script ships with this string in their place.
const RULES_PLACEHOLDER: &str = "\"__RUNLIGHT_RULES__\"";
/// Where the picker's one allowed receiver goes.
const PICK_TARGET_PLACEHOLDER: &str = "\"__RUNLIGHT_PICK_TARGET__\"";
/// Where the hostnames of the site its ticket names go, as JSON inside a string.
const PICK_HOSTS_PLACEHOLDER: &str = "\"__RUNLIGHT_PICK_HOSTS__\"";
/// How long a picker ticket works.
const PICK_TICKET_MS: i64 = 30 * 60_000;
pub(crate) const DASHBOARD_CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

/// HTML's special characters escaped.
pub(crate) fn escape_html(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

fn escape_attr(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' | '"' | '<' | '>' => out.push_str(&format!("&#{};", c as u32)),
            _ => out.push(c),
        }
    }
    out
}

/// The discovery documents OAuth clients read.
pub(crate) fn is_oauth_document(path: &str) -> bool {
    path.starts_with("/.well-known/oauth-") || path.starts_with("/.well-known/openid-configuration")
}

pub(crate) fn is_development() -> bool {
    env_value("NODE_ENV").as_deref() == Some("development")
}

/// A JSON answer, never cached or sniffed.
pub(crate) fn json(body: &Value, status: u16, extra: &[(&str, &str)]) -> Response {
    let mut headers = Headers::new()
        .with("content-type", "application/json; charset=utf-8")
        .with("cache-control", "no-store")
        .with("x-content-type-options", "nosniff");
    for (k, v) in extra {
        headers.set(k, v);
    }
    Response::new(js::stringify(body), status, headers)
}

/// An error the dashboard can show in its own language: `code` names it and `params` fill its
/// placeholders, while `error` stays the English message.
pub(crate) fn coded(error: &str, code: &str, status: u16, params: Option<&[(&str, &str)]>) -> Response {
    coded_with(error, code, status, params, &[])
}

pub(crate) fn coded_with(
    error: &str,
    code: &str,
    status: u16,
    params: Option<&[(&str, &str)]>,
    extra: &[(&str, &str)],
) -> Response {
    let mut o = js::Object::new();
    o.set("error", error);
    o.set("code", code);
    if let Some(params) = params {
        let mut p = js::Object::new();
        for (k, v) in params {
            p.set(*k, *v);
        }
        o.set("params", p);
    }
    json(&Value::Object(o), status, extra)
}

/// A coded error's own code and params as an answer.
pub(crate) fn coded_error(error: &CodedError, status: u16) -> Response {
    let mut o = js::Object::new();
    o.set("error", error.message.clone());
    o.set("code", error.code.clone());
    o.set("params", error.params_value());
    json(&Value::Object(o), status, &[])
}

/// A refusal from a check elsewhere, with its own code and params.
pub(crate) fn refused(error: &CodedError, status: u16) -> Response {
    coded_error(error, status)
}

/// A refusal whose error carries no code: `fallback` with its English words as `detail`.
pub(crate) fn refused_plain(message: &str, fallback: &str, status: u16) -> Response {
    coded(message, fallback, status, Some(&[("detail", message)]))
}

/// Whether a request's body is JSON by its media type.
pub(crate) fn is_json(request: &Request) -> bool {
    js::trim(request.headers.get("content-type").unwrap_or_default().split(';').next().unwrap_or("")).to_lowercase()
        == "application/json"
}

/// A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www.
pub fn host_name(value: &str) -> String {
    let first = js::trim(value.split(',').next().unwrap_or("")).to_lowercase();
    let name = if first.starts_with('[') {
        match first.find(']') {
            Some(i) => first[..=i].to_string(),
            None => String::new(),
        }
    } else {
        crate::re::replace_first(js_re!(r":\d*$"), &first, "")
    };
    let name = name.trim_end_matches('.');
    name.strip_prefix("www.").unwrap_or(name).to_string()
}

/// Whether a domain name is one kept for private networks or tests, or has an IPv4 address inside it.
pub(crate) fn private_name(domain: &str) -> bool {
    if test(js_re!(r"(^|\.)\d{1,3}(\.\d{1,3}){3}(\.|$)"), domain) {
        return true;
    }
    test(
        js_re!(
            r"\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)$"
        ),
        domain,
    )
}

/// A plain page in a visitor's language, for unsubscribing and for a share link that is gone.
pub(crate) fn small_page(lang: &str, body: &str, status: u16) -> Response {
    Response::new(
        format!(
            "<!doctype html><html lang=\"{lang}\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>Runlight</title>
<style>body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif;color:#111827}}main{{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}}h1{{font-size:20px;margin:0 0 12px}}p{{margin:0 0 20px;color:#4b5563}}button{{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}}</style></head><body><main>{body}</main></body></html>"
        ),
        status,
        Headers::new()
            .with("content-type", "text/html; charset=utf-8")
            .with("cache-control", "no-store")
            .with("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
            .with("referrer-policy", "no-referrer"),
    )
}

/// The first language a browser asks for that the dashboard speaks, else English.
pub(crate) fn accepted_language(request: &Request) -> String {
    let languages = glue::languages();
    for part in request.headers.get("accept-language").unwrap_or_default().split(',') {
        let code = js::head16(js::trim(part.split(';').next().unwrap_or("")), 2).to_lowercase();
        if languages.contains(&code) {
            return code;
        }
    }
    "en".into()
}

/// A file to save, never shown in the browser or kept in a shared cache.
pub(crate) fn download(name: &str, body: Vec<u8>, kind: &str) -> Response {
    let safe = crate::re::replace_all(js_re!(r"[^A-Za-z0-9._-]"), name, "-");
    Response::new(
        body,
        200,
        Headers::new()
            .with("content-type", kind)
            .with("content-disposition", format!("attachment; filename=\"{safe}\""))
            .with("cache-control", "private, no-store"),
    )
}

/// Compares two strings in time that does not depend on where they differ, as UTF-16 units.
pub(crate) fn constant_time_equal(a: &str, b: &str) -> bool {
    let (a, b): (Vec<u16>, Vec<u16>) = (a.encode_utf16().collect(), b.encode_utf16().collect());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(&b).fold(0u16, |d, (x, y)| d | (x ^ y)) == 0
}

pub(crate) fn cookie_value(token: &str) -> String {
    sha256(&format!("runlight-cookie:{token}"))
}

pub(crate) fn read_cookie(request: &Request, name: &str) -> String {
    for part in request.headers.get("cookie").unwrap_or_default().split(';') {
        let mut pieces = js::trim(part).split('=');
        if pieces.next() == Some(name) {
            return pieces.collect::<Vec<_>>().join("=");
        }
    }
    String::new()
}

pub(crate) fn bearer(request: &Request) -> String {
    let header = request.headers.get("authorization").unwrap_or_default();
    if header.to_lowercase().starts_with("bearer ") {
        js::trim(&js::slice16(&header, 7, i64::MAX)).to_string()
    } else {
        String::new()
    }
}

fn normalise_base(path: &str) -> String {
    let trimmed = format!("/{}", path.trim_matches('/'));
    if trimmed == "/" { String::new() } else { trimmed }
}

fn locale_urls(base: &str) -> String {
    let mut o = js::Object::new();
    for (code, _) in assets::locales() {
        o.set(code.clone(), format!("{base}/assets/locale.{code}.{}.json", BUILD_INFO.locales_hash));
    }
    o.to_json()
}

fn dashboard_page(base: &str, share: &str, sign_out: &str, geo_credit: bool, accounts: bool, sign_in: &str) -> String {
    let b = escape_attr(base);
    let hash = &BUILD_INFO.dashboard_hash;
    let mut attrs = String::new();
    if !share.is_empty() {
        attrs.push_str(&format!(" data-share=\"{}\"", escape_attr(share)));
    }
    if !sign_out.is_empty() {
        attrs.push_str(&format!(" data-sign-out=\"{}\"", escape_attr(sign_out)));
    }
    if !sign_in.is_empty() {
        attrs.push_str(&format!(" data-sign-in=\"{}\"", escape_attr(sign_in)));
    }
    if geo_credit {
        attrs.push_str(" data-geo-credit=\"\"");
    }
    if accounts {
        attrs.push_str(" data-accounts=\"\"");
    }
    format!(
        "<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<meta name=\"robots\" content=\"noindex\">
<title>Runlight</title>
<link rel=\"icon\" href=\"{}\">
<link rel=\"stylesheet\" href=\"{b}/assets/app.{hash}.css\">
</head>
<body>
<div id=\"app\" data-base=\"{b}\"{attrs} data-world=\"{b}/assets/world.{}.json\" data-locales=\"{}\"></div>
<script type=\"module\" src=\"{b}/assets/app.{hash}.js\"></script>
</body>
</html>
",
        crate::brand::RUNLIGHT_ICON,
        BUILD_INFO.world_hash,
        escape_attr(&locale_urls(base))
    )
}

/// What a manage token, held by a Runlight hub, may read and change.
pub fn manage_path(method: &str, path: &str) -> bool {
    if path.starts_with("/api/links/import") {
        return false;
    }
    if test(js_re!(r"^/api/(links|link-domains|reports|goals|funnels|shares)(/|$)"), path) {
        return true;
    }
    if path == "/api/pick" {
        return method == "POST";
    }
    if path == "/api/mail" {
        return method == "GET";
    }
    if test(js_re!(r"^/api/sites/[^/]+$"), path) {
        return method == "PATCH";
    }
    false
}

/// What a share can read: one site's reports, nothing that changes anything.
pub(crate) fn shared_path(path: &str) -> bool {
    matches!(
        path,
        "/api/sites"
            | "/api/icon"
            | "/api/realtime"
            | "/api/stats"
            | "/api/series"
            | "/api/rhythm"
            | "/api/breakdown"
            | "/api/goals"
            | "/api/event-props"
            | "/api/export"
            | "/api/funnels"
            | "/api/journeys"
    ) || test(js_re!(r"^/api/goals/[a-f0-9]{24}$"), path)
}

/// Who a request is, worked out once per request: a manage token's row, and whether it is a member.
#[derive(Default)]
pub(crate) struct Call {
    pub(crate) managed: Mutex<Option<TokenRow>>,
    pub(crate) member: std::sync::atomic::AtomicBool,
}

impl Call {
    pub(crate) fn managed(&self) -> Option<TokenRow> {
        self.managed.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    pub(crate) fn is_managed(&self) -> bool {
        self.managed().is_some()
    }
    pub(crate) fn is_member(&self) -> bool {
        self.member.load(std::sync::atomic::Ordering::Relaxed)
    }
}

/// What a reader of stats is: the owner, an API token (or a read-only sign-in, as a token with no id), or nobody.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Reader {
    Owner,
    Token(TokenRow),
    No,
    Unconfigured,
}

/// What can_read answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CanRead {
    Yes,
    No,
    Unconfigured,
    Read,
}

pub(crate) struct Tracker {
    body: String,
    etag: String,
    at: i64,
}

pub(crate) struct Inner {
    pub(crate) runlight: Runlight,
    pub(crate) base: String,
    pub(crate) token: Option<String>,
    pub(crate) open: bool,
    pub(crate) cron_secret: Option<String>,
    pub(crate) observe_key: Option<String>,
    pub(crate) origin: Option<String>,
    pub(crate) options: RoutesOptions,
    pub(crate) web: Option<glue::Web>,
    pub(crate) sign_in: Option<String>,
    pub(crate) sign_out: Option<String>,
    warned: std::sync::atomic::AtomicBool,
    pub(crate) sample_sent: Mutex<HashMap<String, i64>>,
    pub(crate) asked: Mutex<HashMap<String, (Vec<i64>, i64)>>,
    trackers: Mutex<HashMap<String, Tracker>>,
}

/// The routes: one handler for every request under the base path.
#[derive(Clone)]
pub struct Routes(pub(crate) Arc<Inner>);

impl Runlight {
    /// The dashboard, its API, the tracker endpoint, and the pages around them.
    pub fn routes(&self, options: RoutesOptions) -> Result<Routes, String> {
        Routes::new(self.clone(), options)
    }
}

impl Routes {
    /// Routes over a Runlight. Refuses an origin that is not a URL.
    pub fn new(runlight: Runlight, options: RoutesOptions) -> Result<Routes, String> {
        let base = normalise_base(options.base_path.as_deref().unwrap_or("/runlight"));
        let (token, open) = match &options.token {
            TokenOption::FromEnv => (env_value("RUNLIGHT_TOKEN"), false),
            TokenOption::Open => (None, true),
            TokenOption::Given(t) => (Some(t.clone()), false),
        };
        let cron_secret = match &options.cron_secret {
            None => env_value("CRON_SECRET"),
            Some(s) => Some(s.clone()),
        }
        .filter(|s| !s.is_empty());
        let observe_key = match &options.observe_key {
            None => env_value("RUNLIGHT_OBSERVE_KEY"),
            Some(s) => Some(s.clone()),
        }
        .filter(|s| !s.is_empty());
        let origin = match &options.origin {
            Some(o) if !o.is_empty() => {
                Some(Url::parse(o).ok_or_else(|| "TypeError: Invalid URL".to_string())?.origin())
            }
            _ => None,
        };
        // A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
        {
            let mut bases = runlight.0.route_bases.lock().unwrap_or_else(|e| e.into_inner());
            let b = if base.is_empty() { "/".to_string() } else { base.clone() };
            if !bases.contains(&b) {
                bases.push(b);
            }
        }
        let token_set = token.as_deref().is_some_and(|t| !t.is_empty());
        // An app left open on purpose (token: null) is treated like development here.
        let open_setup = open || (!token_set && is_development());
        let account_secret = runlight.secret().map(str::to_string).or_else(|| open_setup.then(|| random_id(32)));
        let web = if options.accounts {
            account_secret.map(|secret| {
                glue::web(
                    &runlight,
                    &secret,
                    &base,
                    token.as_deref().filter(|t| !t.is_empty()),
                    open_setup,
                    options.origin.as_deref(),
                )
            })
        } else {
            None
        };
        let sign_in = options.sign_in.clone().or_else(|| web.as_ref().map(|_| format!("{base}/login")));
        let sign_out = options.sign_out.clone().or_else(|| web.as_ref().map(|_| format!("{base}/logout")));
        Ok(Routes(Arc::new(Inner {
            runlight,
            base,
            token,
            open,
            cron_secret,
            observe_key,
            origin,
            options,
            web,
            sign_in,
            sign_out,
            warned: std::sync::atomic::AtomicBool::new(false),
            sample_sent: Mutex::new(HashMap::new()),
            asked: Mutex::new(HashMap::new()),
            trackers: Mutex::new(HashMap::new()),
        })))
    }

    /// Where the routes are mounted, such as "/runlight", or "" at the root.
    pub fn base_path(&self) -> &str {
        &self.0.base
    }

    /// The token in use, if any.
    pub fn token(&self) -> Option<&str> {
        self.0.token.as_deref().filter(|t| !t.is_empty())
    }

    pub(crate) fn rl(&self) -> &Runlight {
        &self.0.runlight
    }

    /// Whether this request acts as the owner.
    pub(crate) async fn can_read(&self, request: &Request, call: &Call) -> CanRead {
        if call.is_managed() {
            return CanRead::Yes;
        }
        let inner = &self.0;
        if inner.options.authorize.is_some() || inner.web.is_some() {
            // A script's bearer token still has full access beside the sign-ins.
            let given = bearer(request);
            if inner.options.authorize.is_none()
                && let Some(token) = self.token()
                && !given.is_empty()
                && constant_time_equal(&given, token)
            {
                return CanRead::Yes;
            }
            let answer = match &inner.options.authorize {
                Some(authorize) => authorize(request).await,
                None => glue::web_access(inner.web.as_ref().expect("accounts"), request).await,
            };
            // A member changes things like an owner, apart from the few controls admin_only() names.
            if answer == Access::Member {
                call.member.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            return match answer {
                Access::Read => CanRead::Read,
                Access::Full | Access::Member => CanRead::Yes,
                Access::Denied => CanRead::No,
            };
        }
        if inner.open {
            return CanRead::Yes;
        }
        let Some(token) = self.token() else {
            // Fails closed: only a process that says it is in development runs open.
            if !is_development() {
                return CanRead::Unconfigured;
            }
            if !inner.warned.swap(true, std::sync::atomic::Ordering::Relaxed) {
                eprintln!(
                    "Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set."
                );
            }
            return CanRead::Yes;
        };
        let given = bearer(request);
        if !given.is_empty() && constant_time_equal(&given, token) {
            return CanRead::Yes;
        }
        let cookie = read_cookie(request, COOKIE);
        if !cookie.is_empty() && constant_time_equal(&cookie, &cookie_value(token)) {
            CanRead::Yes
        } else {
            CanRead::No
        }
    }

    /// An API token from the bearer header: read-only, and maybe limited to one site.
    pub(crate) async fn api_token(&self, request: &Request) -> Result<Option<TokenRow>, crate::Error> {
        let given = bearer(request);
        if !given.starts_with(TOKEN_PREFIX) {
            return Ok(None);
        }
        self.rl().init().await?;
        let store = self.rl().store();
        let Some(row) = store.token_by_hash(&sha256(&given)).await? else { return Ok(None) };
        let now = self.rl().now();
        // At most once a minute, so a busy assistant does not write on every call.
        if row.last_used_at.is_none_or(|l| now - l > 60_000) {
            store.touch_token(&row.id, now).await?;
        }
        Ok(Some(row))
    }

    /// Who may read stats: the owner, an API token or a read-only sign-in, or nobody.
    pub(crate) async fn reader(&self, request: &Request, call: &Call) -> Result<Reader, crate::Error> {
        if let Some(token) = self.api_token(request).await? {
            return Ok(Reader::Token(token));
        }
        let access = self.can_read(request, call).await;
        if self.0.options.authorize.is_some() || self.0.web.is_some() {
            // A read-only sign-in reads like an API token for every site.
            return Ok(match access {
                CanRead::Read => Reader::Token(TokenRow {
                    id: String::new(),
                    name: String::new(),
                    site: String::new(),
                    scope: "read".into(),
                    hash: String::new(),
                    hint: String::new(),
                    created_at: 0,
                    last_used_at: None,
                }),
                CanRead::Yes => Reader::Owner,
                _ => Reader::No,
            });
        }
        Ok(match access {
            CanRead::Yes => Reader::Owner,
            CanRead::Unconfigured => Reader::Unconfigured,
            _ => Reader::No,
        })
    }

    pub(crate) fn denied(&self, result: CanRead) -> Response {
        match result {
            CanRead::Read => coded("Only an owner can change this", "owner_only", 403, None),
            CanRead::Unconfigured => coded(
                "Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.",
                "token_unset",
                503,
                None,
            ),
            _ => coded("Unauthorized", "unauthorized", 401, None),
        }
    }

    pub(crate) fn denied_reader(&self, reader: &Reader) -> Response {
        self.denied(if *reader == Reader::Unconfigured { CanRead::Unconfigured } else { CanRead::No })
    }

    /// The key picker tickets are signed with, made on first use and kept in the database.
    async fn pick_key(&self) -> Result<String, crate::Error> {
        self.rl().init().await?;
        let store = self.rl().store();
        if let Some(saved) = store.setting("pick-key").await? {
            return Ok(saved);
        }
        let made = random_id(32);
        store.set_setting("pick-key", Some(&made)).await?;
        Ok(made)
    }

    /// A ticket that lets the picker, on `site`'s pages, send its choice to `origin` for half an hour.
    pub(crate) async fn pick_ticket(&self, origin: &str, site: &str) -> Result<String, crate::Error> {
        let payload = format!(
            "{}.{}.{}",
            self.rl().now() + PICK_TICKET_MS,
            crate::hash::hex(site.as_bytes()),
            crate::hash::hex(origin.as_bytes())
        );
        let sig = hmac(&self.pick_key().await?, &payload);
        Ok(format!("{payload}.{sig}"))
    }

    /// The dashboard origin and site a picker ticket names, or `None`.
    async fn pick_target(&self, ticket: &str) -> Result<Option<(String, String)>, crate::Error> {
        let re = js_re!(r"^(\d+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})$");
        let Some(caps) = re.captures(ticket.as_bytes()) else { return Ok(None) };
        let part = |i: usize| String::from_utf8_lossy(caps.get(i).map_or(&[][..], |m| m.as_bytes())).into_owned();
        if js::text_number(&part(1)) < self.rl().now() as f64 {
            return Ok(None);
        }
        let expected = hmac(&self.pick_key().await?, &format!("{}.{}.{}", part(1), part(2), part(3)));
        if !constant_time_equal(&part(4), &expected) {
            return Ok(None);
        }
        let origin = unhex(&part(3));
        Ok(test(js_re!(r"^https?://[^/?#\s]+$"), &origin).then(|| (origin, unhex(&part(2)))))
    }

    /// The tracker with click rules inside, rebuilt when goals change.
    async fn tracker_script(&self, site_id: Option<String>) -> Result<(String, String), crate::Error> {
        let key = site_id.clone().unwrap_or_default();
        let now = self.rl().now();
        if let Some(t) = self.0.trackers.lock().unwrap_or_else(|e| e.into_inner()).get(&key)
            && now - t.at < 60_000
        {
            return Ok((t.body.clone(), t.etag.clone()));
        }
        self.rl().init().await?;
        let sites = match &site_id {
            Some(id) => self.rl().sites().into_iter().filter(|s| &s.id == id).collect(),
            None if self.rl().managed_sites() => vec![],
            None => self.rl().sites(),
        };
        let rules = click_rules(&sites, &self.rl().store().goals(None).await?).to_json();
        let body = TRACKER.replacen(RULES_PLACEHOLDER, &rules, 1);
        let etag = format!("\"{}-{}\"", BUILD_INFO.tracker_hash, &sha256(&rules)[..8]);
        // One entry per site at most; a query naming no real site gets the empty script without filling the map.
        if site_id.is_none() || !sites.is_empty() {
            self.0
                .trackers
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(key, Tracker { body: body.clone(), etag: etag.clone(), at: self.rl().now() });
        }
        Ok((body, etag))
    }

    pub(crate) fn forget_trackers(&self) {
        self.0.trackers.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    /// Answers one request.
    pub async fn handle(&self, request: Request) -> Response {
        let Some(url) = Url::parse(&request.url) else { return coded("Internal error", "internal", 500, None) };
        let base = self.0.base.clone();
        let pathname = url.pathname();
        // OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
        if !base.is_empty() && is_oauth_document(&pathname) {
            return match glue::oauth_response(self, &request, &pathname, &url).await {
                Ok(Some(answer)) => answer,
                Ok(None) => coded("Not found", "not_found", 404, None),
                Err(error) => internal(error),
            };
        }
        if !base.is_empty() && pathname != base && !pathname.starts_with(&format!("{base}/")) {
            return coded("Not found", "not_found", 404, None);
        }
        let path = {
            let rest = &pathname[base.len().min(pathname.len())..];
            if rest.is_empty() { "/".to_string() } else { rest.to_string() }
        };
        match self.route(&request, &path, url).await {
            Ok(response) => response,
            Err(error) => internal(error),
        }
    }

    async fn route(&self, request: &Request, path: &str, mut url: Url) -> Result<Response, crate::Error> {
        let call = Call::default();
        let method = request.method.as_str();
        // Checked before any route, so a connected site's pass-through to its install is held to it too.
        if admin_only(path, method) && self.can_read(request, &call).await == CanRead::Yes && call.is_member() {
            return Ok(coded("Only an owner or admin can change this", "admin_only", 403, None));
        }
        // Sign-in, setup, invites, and the Account and People APIs.
        if let Some(web) = &self.0.web
            && let Some(answered) = glue::web_handle(web, request, path).await?
        {
            return Ok(answered);
        }
        if path == "/s.js" && method == "GET" {
            let (body, etag) = self.tracker_script(url.search_params().get("site").map(str::to_string)).await?;
            let headers = Headers::new()
                .with("content-type", "application/javascript; charset=utf-8")
                // Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
                .with("cache-control", "public, max-age=300")
                .with("etag", &etag);
            if request.headers.get("if-none-match").as_deref() == Some(etag.as_str()) {
                return Ok(Response::new(Vec::new(), 304, headers));
            }
            return Ok(Response::new(body, 200, headers));
        }
        if path == "/pick.js" && method == "GET" {
            // The picker sends what it picked only to the dashboard its ticket names.
            let target = self.pick_target(url.search_params().get("runlight_ticket").unwrap_or("")).await?;
            if target.is_some() {
                self.rl().init().await?;
            }
            let hosts: Option<Vec<String>> = match &target {
                Some((_, site)) => self.rl().site(Some(site)).map(|s| s.hostnames),
                None => Some(vec![]),
            };
            let target_json =
                js::quote(if hosts.is_some() { target.as_ref().map_or("", |t| t.0.as_str()) } else { "" });
            let hosts_json =
                js::quote(&Value::Array(hosts.unwrap_or_default().into_iter().map(Value::from).collect()).to_json());
            let script = PICKER.replacen(PICK_TARGET_PLACEHOLDER, &target_json, 1).replacen(
                PICK_HOSTS_PLACEHOLDER,
                &hosts_json,
                1,
            );
            return Ok(Response::new(
                script,
                200,
                Headers::new()
                    .with("content-type", "application/javascript; charset=utf-8")
                    .with("cache-control", "no-store"),
            ));
        }
        if path == format!("/assets/world.{}.json", BUILD_INFO.world_hash) && method == "GET" {
            return Ok(Response::new(
                WORLD_JSON,
                200,
                Headers::new()
                    .with("content-type", "application/json; charset=utf-8")
                    .with("cache-control", "public, max-age=31536000, immutable"),
            ));
        }
        if let Some(caps) = js_re!(r"^/assets/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json$").captures(path.as_bytes()) {
            let code = String::from_utf8_lossy(&caps[1]).into_owned();
            let hash = String::from_utf8_lossy(&caps[2]).into_owned();
            if hash == BUILD_INFO.locales_hash
                && method == "GET"
                && let Some((_, text)) = assets::locales().find(|(k, _)| *k == code)
            {
                return Ok(Response::new(
                    text.clone(),
                    200,
                    Headers::new()
                        .with("content-type", "application/json; charset=utf-8")
                        .with("cache-control", "public, max-age=31536000, immutable"),
                ));
            }
        }
        if path.starts_with("/assets/app.") && method == "GET" {
            let hash = &BUILD_INFO.dashboard_hash;
            let asset = if path == format!("/assets/app.{hash}.js") {
                DASHBOARD_JS
            } else if path == format!("/assets/app.{hash}.css") {
                DASHBOARD_CSS
            } else {
                return Ok(coded("Not found", "not_found", 404, None));
            };
            return Ok(Response::new(
                asset,
                200,
                Headers::new()
                    .with(
                        "content-type",
                        if path.ends_with(".js") {
                            "application/javascript; charset=utf-8"
                        } else {
                            "text/css; charset=utf-8"
                        },
                    )
                    .with("cache-control", "public, max-age=31536000, immutable"),
            ));
        }
        if path == "/e" {
            if method == "OPTIONS" {
                return Ok(Response::new(
                    Vec::new(),
                    204,
                    Headers::new()
                        .with("access-control-allow-origin", "*")
                        .with("access-control-allow-methods", "POST")
                        .with("access-control-max-age", "86400"),
                ));
            }
            if method != "POST" {
                return Ok(coded("Method not allowed", "method_not_allowed", 405, None));
            }
            if let Err(error) = self.rl().collect(request).await {
                eprintln!("Runlight: could not record an event {error}");
            }
            // The same answer whatever happened, so the endpoint reveals nothing.
            return Ok(Response::new(Vec::new(), 202, Headers::new().with("access-control-allow-origin", "*")));
        }
        if path == "/api" || path.starts_with("/api/") {
            return self.api(request, path, &mut url, &call).await;
        }
        if (path.starts_with("/oauth/") || is_oauth_document(path))
            && let Some(answer) = glue::oauth_response(self, request, path, &url).await?
        {
            return Ok(answer);
        }
        if path == "/mcp" {
            // No server-sent stream and no sessions: every message is one POST.
            if method != "POST" {
                return Ok(coded_with("Method not allowed", "method_not_allowed", 405, None, &[("allow", "POST")]));
            }
            let reader = self.reader(request, &call).await?;
            if matches!(reader, Reader::No | Reader::Unconfigured) {
                let mut refused = self.denied_reader(&reader);
                // Points an OAuth client at the metadata that starts the sign-in.
                refused.headers.set(
                    "www-authenticate",
                    &format!(
                        "Bearer realm=\"runlight\", resource_metadata=\"{}\"",
                        glue::resource_metadata_url(&url.origin(), &self.0.base)
                    ),
                );
                return Ok(refused);
            }
            return glue::mcp_response(self, request, &url).await;
        }
        if let Some(token) = crate::re::group(js_re!(r"^/unsubscribe/([^/]+)/?$"), path, 1)
            && (method == "GET" || method == "POST")
        {
            return self.unsubscribe_page(request, &token).await;
        }
        if let Some(id) = crate::re::group(js_re!(r"^/share/([^/]+)/?$"), path, 1)
            && method == "GET"
        {
            self.rl().init().await?;
            let share =
                if test(js_re!(r"^[a-f0-9]{32}$"), &id) { self.rl().store().share_by_id(&id).await? } else { None };
            let Some(share) = share else {
                let lang = accepted_language(request);
                let (t, lang) = glue::translator(&lang);
                return Ok(small_page(
                    &lang,
                    &format!(
                        "<h1>{}</h1><p>{}</p>",
                        escape_html(&t("share.goneTitle", &[])),
                        escape_html(&t("share.gone", &[]))
                    ),
                    404,
                ));
            };
            return Ok(Response::new(
                dashboard_page(&self.0.base, &share.id, "", self.0.options.geo_credit, false, ""),
                200,
                Headers::new()
                    .with("content-type", "text/html; charset=utf-8")
                    .with("cache-control", "no-store")
                    .with("content-security-policy", DASHBOARD_CSP)
                    .with("x-frame-options", "DENY")
                    // The share id is the key; never send it on to another site.
                    .with("referrer-policy", "no-referrer")
                    .with("x-robots-tag", "noindex"),
            ));
        }
        if (path == "/" || path.is_empty()) && method == "GET" {
            let mut params = url.search_params();
            if let Some(given) = params.get("token").map(str::to_string)
                && !given.is_empty()
                && let Some(token) = self.token()
                && constant_time_equal(&given, token)
            {
                params.delete("token");
                url.set_search_params(&params);
                let secure = if url.protocol() == "https:" { "; Secure" } else { "" };
                let base = if self.0.base.is_empty() { "/" } else { self.0.base.as_str() };
                return Ok(Response::new(
                    Vec::new(),
                    303,
                    Headers::new().with("location", format!("{}{}", url.pathname(), url.search())).with(
                        "set-cookie",
                        format!(
                            "{COOKIE}={}; Path={base}; HttpOnly; SameSite=Lax; Max-Age=2592000{secure}",
                            cookie_value(token)
                        ),
                    ),
                ));
            }
            // The page itself holds no data; the API it calls checks access.
            return Ok(Response::new(
                dashboard_page(
                    &self.0.base,
                    "",
                    self.0.sign_out.as_deref().unwrap_or(""),
                    self.0.options.geo_credit,
                    self.0.web.is_some(),
                    self.0.sign_in.as_deref().unwrap_or(""),
                ),
                200,
                Headers::new()
                    .with("content-type", "text/html; charset=utf-8")
                    .with("cache-control", "no-store")
                    .with("content-security-policy", DASHBOARD_CSP)
                    .with("x-frame-options", "DENY")
                    .with("referrer-policy", "same-origin"),
            ));
        }
        Ok(coded("Not found", "not_found", 404, None))
    }
}

/// The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site.
fn admin_only(path: &str, method: &str) -> bool {
    (path == "/api/mail" && (method == "PUT" || method == "DELETE"))
        || (path == "/api/assistant" && (method == "PUT" || method == "DELETE"))
        || (path == "/api/assistant/limits" && method == "PUT")
        || (path == "/api/assistant/models" && method == "POST")
        || (test(js_re!(r"^/api/sites/[^/]+$"), path) && method == "DELETE")
}

fn internal(error: crate::Error) -> Response {
    eprintln!("Runlight: {error}");
    coded("Internal error", "internal", 500, None)
}

fn unhex(text: &str) -> String {
    let bytes: Vec<u8> =
        (0..text.len() / 2).filter_map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).ok()).collect();
    crate::http::utf8(&bytes)
}

/// A JSON body as an object, or the answer refusing it.
pub(crate) fn read_json(request: &Request) -> Result<js::Object, Response> {
    // A form posted from another site cannot carry this content type without CORS.
    if !is_json(request) {
        return Err(coded("Send JSON", "send_json", 415, None));
    }
    match request.json() {
        Ok(Value::Object(o)) => Ok(o),
        _ => Err(coded("Send a JSON object", "send_object", 400, None)),
    }
}
