//! OAuth for the MCP server, so apps that connect only through OAuth (the
//! Claude and ChatGPT web connectors) can reach it. Runlight is both the
//! resource and the authorization server:
//!
//! - /.well-known/oauth-protected-resource names the MCP endpoint and this server.
//! - /.well-known/oauth-authorization-server lists the endpoints below.
//! - POST /oauth/register lets a client register itself (public clients, no secret).
//! - /oauth/authorize asks the signed-in owner to allow the client, every site or one.
//! - POST /oauth/token swaps the one-time code, checked with PKCE, for a token.
//!
//! The token is an ordinary API token, so it appears in Settings, API and AI,
//! beside the others, and deleting it there disconnects the app. It reads
//! stats, or with the "manage" scope (asked for by a Runlight hub) it also
//! changes one site's settings.

use std::sync::{Arc, Mutex, Weak};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};

use crate::error::Error;
use crate::hash::{hmac, new_id, random_id, sha256};
use crate::http::{Headers, Request, Response, SearchParams, Url};
use crate::js::{self, Object, Value};
use crate::limit::RateLimit;
use crate::re::{js_re, test};
use crate::runlight::Runlight;
use crate::sources::encode_uri_component;
use crate::store::TokenRow;
use crate::{BoxFuture, arr, obj};

const CODE_MS: i64 = 5 * 60_000;
/// An app stored before client ids were signed, which never finished connecting within a day, is removed.
const UNUSED_CLIENT_MS: f64 = 86_400_000.0;
/// Registrations one address may make a minute.
const REGISTRATIONS_PER_MINUTE: f64 = 10.0;
/// The longest client id, which carries the app's name and redirect addresses.
const MAX_CLIENT_ID: usize = 2048;

/// What the routes give OAuth: who is asking, where to sign in, and the accounts' hooks.
pub trait OAuthHost: Send + Sync {
    /// The Runlight the routes serve.
    fn runlight(&self) -> &Runlight;
    /// Where the routes are mounted, "" at the root.
    fn base(&self) -> &str;
    /// Whether the request comes from the signed-in owner.
    fn is_owner<'a>(&'a self, request: &'a Request) -> BoxFuture<'a, bool>;
    /// Whether the request comes from someone signed in who may only read, such as a viewer.
    fn is_reader<'a>(&'a self, request: &'a Request) -> BoxFuture<'a, bool>;
    /// Where to send someone to sign in, when there is such a page (the standalone server's).
    fn sign_in(&self) -> Option<&str>;
    /// The account a request comes from, where the app has accounts.
    fn account_of<'a>(&'a self, request: &'a Request) -> BoxFuture<'a, Result<Option<String>, Error>>;
    /// Notes who made a token; false when they can no longer make one, which takes it back.
    fn token_made<'a>(&'a self, token: &'a TokenRow, by: &'a str) -> BoxFuture<'a, Result<bool, Error>>;
}

/// Per install, the per-address limit on registrations.
static REGISTRATIONS: Mutex<Vec<(Weak<crate::runlight::Inner>, Arc<RateLimit>)>> = Mutex::new(Vec::new());

fn registrations(runlight: &Runlight) -> Arc<RateLimit> {
    let mut all = REGISTRATIONS.lock().unwrap_or_else(|e| e.into_inner());
    all.retain(|(w, _)| w.strong_count() > 0);
    let me = Arc::downgrade(&runlight.0);
    if let Some((_, limit)) = all.iter().find(|(w, _)| w.ptr_eq(&me)) {
        return limit.clone();
    }
    let limit = Arc::new(RateLimit::new(REGISTRATIONS_PER_MINUTE));
    all.push((me, limit.clone()));
    limit
}

fn base64url(text: &str) -> String {
    URL_SAFE_NO_PAD.encode(text.as_bytes())
}

fn from_base64url(text: &str) -> Result<String, Error> {
    let standard = text.replace('-', "+").replace('_', "/");
    // atob takes text without its padding.
    let padded = format!("{standard}{}", "=".repeat((4 - standard.len() % 4) % 4));
    let bytes = STANDARD.decode(padded).map_err(|_| {
        Error::Other("InvalidCharacterError: The string to be decoded is not correctly encoded.".into())
    })?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// The key client ids are signed with, made on first use and kept in the database for every process.
async fn client_key(runlight: &Runlight) -> Result<String, Error> {
    if let Some(saved) = runlight.store().setting("oauth-key").await?
        && !saved.is_empty()
    {
        return Ok(saved);
    }
    let made = random_id(32);
    runlight.store().set_setting("oauth-key", Some(&made)).await?;
    Ok(made)
}

/// An app that registered: its name, its addresses, and when it was first given a token.
struct Client {
    /// The client as JSON, in its stored key order.
    value: Object,
    used_key: String,
}

impl Client {
    fn name(&self) -> Option<&Value> {
        self.value.get("name")
    }
    fn name_text(&self) -> String {
        self.name().map_or_else(|| "undefined".into(), js::js_string)
    }
    fn redirects(&self) -> Vec<Value> {
        self.value.get("redirects").and_then(Value::as_array).cloned().unwrap_or_default()
    }
    /// Until it is first given a token, a request it gets wrong ends on a page here.
    fn used(&self) -> bool {
        js::opt_truthy(self.value.get("usedAt"))
    }
}

/// The app a client id names, and where to note that it connected. A new id
/// carries the app's name and addresses, signed, so registering stores
/// nothing and a flood of registrations fills nothing. Ids from before that
/// were stored.
async fn client_for(runlight: &Runlight, id: &str) -> Result<Option<Client>, Error> {
    if test(js_re!(r"^[a-f0-9]{32}$"), id) {
        let key = format!("oauth-client:{id}");
        let Some(stored) = runlight.store().setting(&key).await? else { return Ok(None) };
        let value = parse(&stored)?;
        return Ok(Some(Client { value: value.as_object().cloned().unwrap_or_default(), used_key: key }));
    }
    let Some(caps) = js_re!(r"^([A-Za-z0-9_-]{1,2000})\.([a-f0-9]{64})$").captures(id.as_bytes()) else {
        return Ok(None);
    };
    if id.len() > MAX_CLIENT_ID {
        return Ok(None);
    }
    let payload = String::from_utf8_lossy(&caps[1]).into_owned();
    let signature = String::from_utf8_lossy(&caps[2]).into_owned();
    if !constant_time_equal(&signature, &hmac(&client_key(runlight).await?, &payload)) {
        return Ok(None);
    }
    let meta = parse(&from_base64url(&payload)?)?;
    let used_key = format!("oauth-used:{}", sha256(id));
    let used = runlight.store().setting(&used_key).await?;
    let mut value = Object::new();
    for (from, to) in [("n", "name"), ("r", "redirects"), ("t", "createdAt")] {
        if let Some(v) = meta.get(from) {
            value.set(to, v.clone());
        }
    }
    if let Some(used) = used.filter(|u| !u.is_empty()) {
        value.set("usedAt", js::text_number(&used));
    }
    Ok(Some(Client { value, used_key }))
}

/// `value.expires < now`, which is false for a missing or unreadable time, as JavaScript compares.
pub(crate) fn expired(expires: Option<&Value>, now: i64) -> bool {
    js::opt_number(expires) < now as f64
}

fn parse(text: &str) -> Result<Value, Error> {
    js::parse(text).map_err(|e| Error::Other(format!("SyntaxError: {e}")))
}

fn constant_time_equal(a: &str, b: &str) -> bool {
    let (a, b): (Vec<u16>, Vec<u16>) = (a.encode_utf16().collect(), b.encode_utf16().collect());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(&b).fold(0u16, |d, (x, y)| d | (x ^ y)) == 0
}

fn esc(value: &str) -> String {
    crate::routes::escape_html(value)
}

const CORS: [(&str, &str); 3] = [
    ("access-control-allow-origin", "*"),
    ("access-control-allow-headers", "authorization, content-type, mcp-protocol-version"),
    ("access-control-allow-methods", "GET, POST, OPTIONS"),
];

fn cors() -> Headers {
    Headers::from_pairs(CORS)
}

fn json(body: &Value, status: u16) -> Response {
    let mut headers =
        Headers::new().with("content-type", "application/json; charset=utf-8").with("cache-control", "no-store");
    for (k, v) in CORS {
        headers.set(k, v);
    }
    Response::new(js::stringify(body), status, headers)
}

fn oauth_error(error: &str, description: &str, status: u16) -> Response {
    json(&obj! { "error" => error, "error_description" => description }, status)
}

/// base64url of SHA-256, as PKCE's S256 method compares.
pub fn s256(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// Redirect addresses a client may register: https, or a local app's own loopback address.
fn allowed_redirect(value: &str) -> bool {
    test(js_re!(r"^https://[^/]+"), value) || test(js_re!(r"^http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?/"), value)
}

/// The URL that a 401 from the MCP endpoint points clients at, to start OAuth.
pub fn resource_metadata_url(origin: &str, base: &str) -> String {
    format!("{origin}{base}/.well-known/oauth-protected-resource")
}

fn see_other(location: &str) -> Response {
    Response::new(Vec::new(), 303, Headers::new().with("location", location).with("cache-control", "no-store"))
}

/// `text.split(/\s+/)`.
fn split_space(text: &str) -> Vec<&str> {
    text.split(js::is_space).collect()
}

/// `new URLSearchParams(Object.entries(json ?? {}))`, for a token request sent as JSON.
fn json_form(value: Option<Value>) -> SearchParams {
    let pairs: Vec<(String, String)> = match value {
        Some(Value::Object(o)) => o.iter().map(|(k, v)| (k.to_string(), js::js_string(v))).collect(),
        Some(Value::Array(a)) => a.iter().enumerate().map(|(i, v)| (i.to_string(), js::js_string(v))).collect(),
        Some(Value::String(s)) => {
            s.encode_utf16().enumerate().map(|(i, u)| (i.to_string(), String::from_utf16_lossy(&[u]))).collect()
        }
        _ => vec![],
    };
    SearchParams::from_pairs(pairs)
}

/// Answers the OAuth paths, or returns `None` for anything else. `path` is
/// relative to the routes' base; the two well-known documents are also answered
/// at the site's root (`/.well-known/...`) for clients that look there.
pub async fn oauth_response(
    host: &dyn OAuthHost,
    request: &Request,
    path: &str,
    url: &Url,
) -> Result<Option<Response>, Error> {
    let runlight = host.runlight();
    let base = host.base();
    let issuer = format!("{}{base}", url.origin());
    let method = request.method.as_str();
    if method == "OPTIONS"
        && (path.starts_with("/.well-known/oauth-")
            || path.starts_with("/.well-known/openid-configuration")
            || path.starts_with("/oauth/"))
    {
        return Ok(Some(Response::new(Vec::new(), 204, cors())));
    }

    if path.starts_with("/.well-known/oauth-protected-resource") {
        return Ok(Some(json(
            &obj! {
                "resource" => format!("{issuer}/mcp"),
                "authorization_servers" => arr![issuer.clone()],
                "scopes_supported" => arr!["read", "manage"],
                "bearer_methods_supported" => arr!["header"],
            },
            200,
        )));
    }
    if path.starts_with("/.well-known/oauth-authorization-server")
        || path.starts_with("/.well-known/openid-configuration")
    {
        return Ok(Some(json(
            &obj! {
                "issuer" => issuer.clone(),
                "authorization_endpoint" => format!("{issuer}/oauth/authorize"),
                "token_endpoint" => format!("{issuer}/oauth/token"),
                "registration_endpoint" => format!("{issuer}/oauth/register"),
                "response_types_supported" => arr!["code"],
                "grant_types_supported" => arr!["authorization_code"],
                "code_challenge_methods_supported" => arr!["S256"],
                "token_endpoint_auth_methods_supported" => arr!["none"],
                "scopes_supported" => arr!["read", "manage"],
            },
            200,
        )));
    }

    if path == "/oauth/register" && method == "POST" {
        runlight.init().await?;
        if !registrations(runlight).allow(&runlight.client_ip(request), runlight.now()) {
            return Ok(Some(oauth_error(
                "invalid_client_metadata",
                "Too many registrations from this address. Wait a minute and try again.",
                429,
            )));
        }
        let body = request.json().ok();
        let redirects: Vec<String> = match body.as_ref().and_then(|b| b.get("redirect_uris")) {
            Some(Value::Array(list)) => {
                list.iter().map(js::js_string).filter(|r| allowed_redirect(r)).take(10).collect()
            }
            _ => vec![],
        };
        if redirects.is_empty() {
            return Ok(Some(oauth_error("invalid_redirect_uri", "Register at least one https redirect address", 400)));
        }
        let name = match body.as_ref().and_then(|b| b.get("client_name")) {
            None | Some(Value::Null) => "An app".to_string(),
            Some(v) => js::js_string(v),
        };
        return Ok(Some(register(runlight, &name, redirects).await?));
    }

    if path == "/oauth/authorize" && (method == "GET" || method == "POST") {
        return authorize(host, request, url).await.map(Some);
    }

    if path == "/oauth/token" && method == "POST" {
        return token(host, request).await.map(Some);
    }

    Ok(None)
}

async fn authorize(host: &dyn OAuthHost, request: &Request, url: &Url) -> Result<Response, Error> {
    let runlight = host.runlight();
    let base = host.base();
    runlight.init().await?;
    let form = if request.method == "POST" { SearchParams::parse(&request.text()) } else { url.search_params() };
    let get = |k: &str| form.get(k).map(str::to_string);
    let client_id = get("client_id").unwrap_or_default();
    let client = client_for(runlight, &client_id).await?;
    let redirect = get("redirect_uri").unwrap_or_default();
    // Without a known client and one of its own addresses there is nowhere safe to send an answer.
    let Some(client) = client.filter(|c| c.redirects().iter().any(|r| r.as_str() == Some(redirect.as_str()))) else {
        return Ok(page("This app is not registered", "<p>Start connecting again from the app.</p>", 400));
    };
    let back = |params: &[(&str, &str)]| -> Result<Response, Error> {
        let mut to = Url::parse(&redirect).ok_or_else(|| Error::Other("TypeError: Invalid URL".into()))?;
        let mut search = to.search_params();
        for (k, v) in params {
            search.set(k, v);
        }
        if let Some(state) = form.get("state").filter(|s| !s.is_empty()) {
            search.set("state", state);
        }
        to.set_search_params(&search);
        Ok(see_other(&to.href()))
    };
    // Anyone can register an app with any address, so until an owner has allowed it once, a request
    // it got wrong ends on a page here rather than sending a visitor who is not signed in on to it.
    let refuse = |error: &str, description: Option<&str>| -> Result<Response, Error> {
        if client.used() {
            let mut params = vec![("error", error)];
            if let Some(d) = description {
                params.push(("error_description", d));
            }
            return back(&params);
        }
        Ok(page(
            "This app asked in a way Runlight does not support",
            &format!(
                "<p>{} sent {}. Start connecting again from the app.</p>",
                esc(&client.name_text()),
                esc(description.unwrap_or(error))
            ),
            400,
        ))
    };
    if form.get("response_type") != Some("code") {
        return refuse("unsupported_response_type", None);
    }
    let challenge = get("code_challenge").unwrap_or_default();
    if form.get("code_challenge_method") != Some("S256") || !test(js_re!(r"^[A-Za-z0-9_-]{43,128}$"), &challenge) {
        return refuse("invalid_request", Some("PKCE with S256 is required"));
    }
    let manage = split_space(form.get("scope").unwrap_or("")).contains(&"manage");
    let name = esc(&client.name_text());

    if !host.is_owner(request).await {
        // Someone signed in who may only read would be sent to sign in again and again.
        if host.is_reader(request).await {
            return Ok(page(
                "Ask an owner to connect this",
                &format!(
                    "<p>You are signed in as a viewer, and only an owner of this Runlight can connect {name}.</p>"
                ),
                403,
            ));
        }
        // The site stays, since on the way in it only says which one to offer first.
        let kept = SearchParams::from_pairs(form.pairs().iter().filter(|(k, _)| k != "decision").cloned());
        let here = format!("{}?{kept}", url.pathname());
        if let Some(sign_in) = host.sign_in() {
            return Ok(see_other(&format!("{sign_in}?next={}", encode_uri_component(&here))));
        }
        let home = if base.is_empty() { "/" } else { base };
        return Ok(page(
            "Sign in first",
            &format!(
                "<p>Open your Runlight dashboard at <a href=\"{}\">{}</a> and sign in, then connect {name} again.</p>",
                esc(home),
                esc(&format!("{}{home}", url.host()))
            ),
            401,
        ));
    }

    if request.method == "GET" {
        let hidden: String = [
            "response_type",
            "client_id",
            "redirect_uri",
            "code_challenge",
            "code_challenge_method",
            "state",
            "scope",
            "resource",
        ]
        .iter()
        .map(|k| {
            form.get(k)
                .map_or_else(String::new, |v| format!("<input type=\"hidden\" name=\"{k}\" value=\"{}\">", esc(v)))
        })
        .collect();
        // The app names itself, so the page also shows where the answer goes, which it cannot fake.
        let to_host = Url::parse(&redirect).ok_or_else(|| Error::Other("TypeError: Invalid URL".into()))?.host();
        let sends_to = format!(
            "<p class=\"note\">Allowing sends you back to <strong>{}</strong>. Only allow it if you started connecting there.</p>",
            esc(&to_host)
        );
        let action = esc(base);
        if manage {
            // Changing settings is for one site at a time, so there is no "every site" here.
            let wanted = form.get("site").unwrap_or("");
            let choices: String = runlight
                .sites()
                .into_iter()
                .filter(|s| !runlight.is_remote(&s.id))
                .map(|s| {
                    format!(
                        "<option value=\"{}\"{}>{}</option>",
                        esc(&s.id),
                        if s.id == wanted { " selected" } else { "" },
                        esc(&s.name)
                    )
                })
                .collect();
            return Ok(page(
                &format!("Connect {name}"),
                &format!(
                    "<p><strong>{name}</strong> wants to show this site\u{2019}s stats and change its settings, so you can manage it from there.</p>
<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>
{sends_to}
<form method=\"post\" action=\"{action}/oauth/authorize\">{hidden}
<label>Site<select name=\"site\">{choices}</select></label>
<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects {name}.</p>
<div class=\"buttons\"><button type=\"submit\" name=\"decision\" value=\"deny\" class=\"ghost\">Deny</button><button type=\"submit\" name=\"decision\" value=\"allow\">Allow</button></div></form>"
                ),
                200,
            ));
        }
        let sites = runlight.sites();
        let options: String = if sites.len() > 1 {
            sites.iter().map(|s| format!("<option value=\"{}\">{} only</option>", esc(&s.id), esc(&s.name))).collect()
        } else {
            String::new()
        };
        return Ok(page(
            &format!("Connect {name}"),
            &format!(
                "<p><strong>{name}</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>
{sends_to}
<form method=\"post\" action=\"{action}/oauth/authorize\">{hidden}
<label>Which sites it can read<select name=\"site\"><option value=\"\">Every site</option>{options}</select></label>
<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>
<div class=\"buttons\"><button type=\"submit\" name=\"decision\" value=\"deny\" class=\"ghost\">Deny</button><button type=\"submit\" name=\"decision\" value=\"allow\">Allow</button></div></form>"
            ),
            200,
        ));
    }
    // The consent form posts here from this page only; a form from another site is refused.
    if let Some(origin) = request.headers.get("origin")
        && !origin.is_empty()
        && origin != url.origin()
    {
        return Ok(page("This request came from another site", "<p>Start connecting again from the app.</p>", 403));
    }
    if form.get("decision") != Some("allow") {
        return back(&[("error", "access_denied")]);
    }
    let site = get("site").unwrap_or_default();
    if !site.is_empty() && runlight.site(Some(&site)).is_none() {
        return back(&[("error", "invalid_request"), ("error_description", "Unknown site")]);
    }
    if manage && (site.is_empty() || runlight.is_remote(&site)) {
        return back(&[("error", "invalid_request"), ("error_description", "Pick the site to manage")]);
    }
    let code = random_id(32);
    let by = host.account_of(request).await?.filter(|b| !b.is_empty());
    let mut grant = obj! {
        "client" => client_id.clone(),
        "redirect" => redirect.clone(),
        "challenge" => challenge,
        "site" => site,
        "scope" => if manage { "manage" } else { "read" },
        "expires" => runlight.now() + CODE_MS,
    };
    if let (Some(by), Value::Object(o)) = (by, &mut grant) {
        o.set("by", by);
    }
    runlight.store().set_setting(&format!("oauth-code:{}", sha256(&code)), Some(&grant.to_json())).await?;
    back(&[("code", &code)])
}

async fn token(host: &dyn OAuthHost, request: &Request) -> Result<Response, Error> {
    let runlight = host.runlight();
    let store = runlight.store();
    runlight.init().await?;
    let kind = request.headers.get("content-type").unwrap_or_default();
    let kind = js::trim(kind.split(';').next().unwrap_or(""));
    let form = if kind == "application/json" {
        json_form(request.json().ok().filter(|v| !v.is_null()))
    } else {
        SearchParams::parse(&request.text())
    };
    if form.get("grant_type") != Some("authorization_code") {
        return Ok(oauth_error("unsupported_grant_type", "Only authorization_code is supported", 400));
    }
    let key = format!("oauth-code:{}", sha256(form.get("code").unwrap_or("")));
    let stored = store.setting(&key).await?;
    // A code works once: it is gone before anything else is checked.
    if stored.as_deref().is_some_and(|s| !s.is_empty()) {
        store.set_setting(&key, None).await?;
    }
    let grant = match stored.filter(|s| !s.is_empty()) {
        Some(text) => Some(parse(&text)?),
        None => None,
    };
    let now = runlight.now();
    let Some(grant) = grant.filter(|g| !g.is_null() && !expired(g.get("expires"), now)) else {
        return Ok(oauth_error("invalid_grant", "The code has expired or was already used", 400));
    };
    let same =
        |v: Option<&Value>, given: Option<&str>| matches!((v, given), (Some(Value::String(a)), Some(b)) if a == b);
    if !same(grant.get("client"), form.get("client_id")) || !same(grant.get("redirect"), form.get("redirect_uri")) {
        return Ok(oauth_error("invalid_grant", "The code was issued to another app", 400));
    }
    if grant.get("challenge").and_then(Value::as_str) != Some(s256(form.get("code_verifier").unwrap_or("")).as_str()) {
        return Ok(oauth_error("invalid_grant", "The code verifier does not match", 400));
    }
    // The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
    let client_id = js::js_string(grant.at("client"));
    let found = client_for(runlight, &client_id).await?;
    if let Some(found) = &found
        && !found.used()
    {
        let value = if found.used_key.starts_with("oauth-client:") {
            let mut client = found.value.clone();
            client.set("usedAt", now);
            client.to_json()
        } else {
            js::format_number(now as f64)
        };
        store.set_setting(&found.used_key, Some(&value)).await?;
    }
    let secret = format!("rl_{}", random_id(20));
    let scope = if grant.get("scope").and_then(Value::as_str) == Some("manage") { "manage" } else { "read" };
    let name = match found.as_ref().and_then(Client::name) {
        None | Some(Value::Null) => "An app".to_string(),
        Some(v) => js::js_string(v),
    };
    let site = js::str_or_empty(grant.get("site"));
    let row = TokenRow {
        id: new_id(),
        name: js::head16(&format!("{name} (OAuth)"), 100),
        site: site.clone(),
        scope: scope.into(),
        hash: sha256(&secret),
        hint: js::tail16(&secret, 4),
        created_at: now,
        last_used_at: None,
    };
    store.insert_token(&row).await?;
    // Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
    if let Some(by) = grant.get("by").filter(|b| js::truthy(b))
        && !host.token_made(&row, &js::js_string(by)).await?
    {
        store.delete_token(&row.id).await?;
        return Ok(oauth_error("invalid_grant", "Whoever allowed this app can no longer connect it", 400));
    }
    // A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
    if scope == "manage" {
        let origin = Url::parse(&js::js_string(grant.at("redirect")))
            .ok_or_else(|| Error::Other("TypeError: Invalid URL".into()))?
            .origin();
        store.set_setting(&format!("token-origin:{}", row.id), Some(&origin)).await?;
    }
    // site is not part of OAuth, but a hub needs to know which site it was given.
    let mut answer = obj! { "access_token" => secret, "token_type" => "Bearer", "scope" => scope };
    if let (Some(site), Value::Object(o)) = (grant.get("site").filter(|s| js::truthy(s)), &mut answer) {
        o.set("site", site.clone());
    }
    Ok(json(&answer, 200))
}

/// Registers a client by signing its name and addresses into its id, so
/// nothing is stored until an owner allows it and the app swaps its code.
async fn register(runlight: &Runlight, name: &str, redirects: Vec<String>) -> Result<Response, Error> {
    let store = runlight.store();
    let now = runlight.now();
    // Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
    for (key, value) in store.settings_starting_with("oauth-client:").await? {
        let client = parse(&value)?;
        if !js::opt_truthy(client.get("usedAt"))
            && now as f64 - js::opt_number(client.get("createdAt")) >= UNUSED_CLIENT_MS
        {
            store.set_setting(&key, None).await?;
        }
    }
    for (key, value) in store.settings_starting_with("oauth-code:").await? {
        let code = parse(&value)?;
        let expires = match code.get("expires") {
            None | Some(Value::Null) => 0.0,
            Some(v) => js::js_number(v),
        };
        if expires < now as f64 {
            store.set_setting(&key, None).await?;
        }
    }
    let trimmed = js::head16(js::trim(name), 80);
    let name = if trimmed.is_empty() { "An app".to_string() } else { trimmed };
    let list = Value::Array(redirects.iter().map(|r| Value::from(r.as_str())).collect());
    let payload = base64url(&obj! { "n" => name.clone(), "r" => list.clone(), "t" => now }.to_json());
    let id = format!("{payload}.{}", hmac(&client_key(runlight).await?, &payload));
    if id.len() > MAX_CLIENT_ID {
        return Ok(oauth_error("invalid_client_metadata", "Register fewer or shorter redirect addresses", 400));
    }
    Ok(json(
        &obj! {
            "client_id" => id,
            "client_name" => name,
            "redirect_uris" => list,
            "token_endpoint_auth_method" => "none",
            "grant_types" => arr!["authorization_code"],
            "response_types" => arr!["code"],
        },
        201,
    ))
}

const STYLE: &str = r#"<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 6l4 4 4-4' fill='none' stroke='%238a8a93' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style>"#;

fn page(title: &str, body: &str, status: u16) -> Response {
    Response::new(
        format!(
            "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>{title} | Runlight</title>\n{STYLE}</head><body><main><h1>{title}</h1>{body}</main></body></html>"
        ),
        status,
        Headers::new()
            .with("content-type", "text/html; charset=utf-8")
            .with("cache-control", "no-store")
            // No form-action rule: browsers apply it to the redirect back to the app after Allow.
            .with(
                "content-security-policy",
                "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
            )
            .with("x-frame-options", "DENY")
            // same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check refuses.
            .with("referrer-policy", "same-origin"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn s256_is_base64url_of_sha256() {
        // RFC 7636's example.
        assert_eq!(s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn client_payloads_round_trip() {
        let text = "{\"n\":\"Caf\u{e9}\",\"r\":[\"https://a.example/cb\"],\"t\":1}";
        assert_eq!(from_base64url(&base64url(text)).unwrap(), text);
        assert!(!base64url(text).contains('='));
    }

    #[test]
    fn redirects_are_https_or_loopback() {
        assert!(allowed_redirect("https://claude.ai/cb"));
        assert!(allowed_redirect("http://localhost:8080/cb"));
        assert!(allowed_redirect("http://[::1]/cb"));
        assert!(!allowed_redirect("http://evil.example/cb"));
        assert!(!allowed_redirect("javascript:alert(1)"));
    }

    #[test]
    fn metadata_url_is_under_the_base() {
        assert_eq!(
            resource_metadata_url("https://example.com", "/runlight"),
            "https://example.com/runlight/.well-known/oauth-protected-resource"
        );
    }
}
