//! Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People APIs, under
//! the base path the routes answer at. The standalone server and an app with routes' accounts option share it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::auth::{
    AccountError, Accounts, AuthError, Invite, Role, SESSION_COOKIE, SESSION_MS, Throttle, User, otpauth_uri,
};
use super::crypto::{base64url, random_bytes, same_text};
use super::pages::{
    AUTH_CSS, AUTH_JS, CodePage, InvitePage, LoginPage, SetupPage, code_page, invite_gone_page, invite_page,
    login_page, role_text, setup_locked_page, setup_needs_token_page, setup_page,
};
use crate::error::Error;
use crate::http::{Headers, Request, Response, SearchParams, Url};
use crate::js::{self, Object, Value};
use crate::mail::Message;
use crate::routes::Access;
use crate::runlight::{Clock, Runlight};
use crate::sources::{decode_uri_component, encode_uri_component};
use crate::store::{SqlStore, TokenRow};
use crate::{BoxFuture, obj};

/// Who may create the first account: the server's printed one-time code, the app's token, or anyone (development).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FirstAccount {
    /// The server's printed one-time code.
    Code(String),
    /// The app's token, typed in.
    Token(String),
    /// Anyone, for development.
    Open,
    /// Nobody yet.
    Locked,
}

/// The install's public address, when known.
pub type Home = Arc<dyn Fn() -> BoxFuture<'static, Option<String>> + Send + Sync>;

/// How the accounts' web side is made.
#[derive(Clone)]
pub struct AccountsWebOptions {
    /// The Runlight whose store keeps the accounts and whose mail service sends invites.
    pub runlight: Runlight,
    /// Signs sessions and seals two-factor secrets. Keep it stable across restarts.
    pub secret: String,
    /// The path the routes answer under: "" on the standalone server, "/runlight" in an app.
    pub base: String,
    /// The clock.
    pub now: Clock,
    /// Who may create the first account.
    pub first_account: FirstAccount,
    /// The address emails link to: the install's public one when known. Without it, a locked account gets no link.
    pub home: Option<Home>,
    /// Where the sign-in page sends someone who forgot their password.
    pub forgot: String,
}

const HTML: [(&str, &str); 5] = [
    ("content-type", "text/html; charset=utf-8"),
    ("cache-control", "no-store"),
    (
        "content-security-policy",
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    ),
    ("x-frame-options", "DENY"),
    ("referrer-policy", "same-origin"),
];

const DEVICE_COOKIE: &str = "runlight_device";
/// Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them.
const MADE_BY: &str = "token-by:";

impl From<AuthError> for Error {
    fn from(e: AuthError) -> Error {
        match e {
            AuthError::Db(e) => Error::Db(e),
            AuthError::Account(e) => Error::Settings(e),
            other => Error::Other(other.to_string()),
        }
    }
}

fn read_cookie(request: &Request, name: &str) -> String {
    for part in request.headers.get("cookie").unwrap_or_default().split(';') {
        let mut pieces = js::trim(part).split('=');
        if pieces.next() == Some(name) {
            return pieces.collect::<Vec<_>>().join("=");
        }
    }
    String::new()
}

fn is_secure(request: &Request) -> bool {
    request.parsed_url().protocol() == "https:" || request.headers.get("x-forwarded-proto").as_deref() == Some("https")
}

fn headers(pairs: &[(&str, &str)], extra: &[(&str, &str)]) -> Headers {
    let mut h = Headers::new();
    for (k, v) in pairs.iter().chain(extra) {
        h.set(k, v);
    }
    h
}

/// An error the dashboard words in its own language, as the routes send them.
fn coded(error: &str, code: &str, status: u16, params: Option<Value>) -> Response {
    let mut body = Object::new();
    body.set("error", error);
    body.set("code", code);
    if let Some(params) = params {
        body.set("params", params);
    }
    Response::new(
        js::stringify(&Value::Object(body)),
        status,
        headers(
            &[
                ("content-type", "application/json; charset=utf-8"),
                ("cache-control", "no-store"),
                ("x-content-type-options", "nosniff"),
            ],
            &[],
        ),
    )
}

/// A refused account change as its coded answer, with its params.
fn refused(error: &AccountError, status: u16) -> Response {
    coded(&error.message, &error.code, status, Some(error.params_value()))
}

fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            other => out.push(other),
        }
    }
    out
}

fn html(body: String, status: u16) -> Response {
    Response::new(body, status, headers(&HTML, &[]))
}

fn redirect(location: &str, extra: &[(&str, &str)]) -> Response {
    Response::new(Vec::new(), 303, headers(&[("location", location), ("cache-control", "no-store")], extra))
}

fn reply(body: &Value, status: u16, extra: &[(&str, &str)]) -> Response {
    Response::new(
        js::stringify(body),
        status,
        headers(&[("content-type", "application/json; charset=utf-8"), ("cache-control", "no-store")], extra),
    )
}

fn person(u: &User) -> Value {
    obj! {
        "id" => u.id.as_str(), "email" => u.email.as_str(), "role" => u.role.as_str(), "createdAt" => u.created_at,
        "twoFactor" => u.two_factor, "recoveryLeft" => u.recovery_left,
    }
}

fn invite_view(i: &Invite) -> Value {
    i.to_value()
}

/// The media type of a request's body, which a cross-site form cannot make application/json.
fn media_type(request: &Request) -> String {
    js::trim(request.headers.get("content-type").unwrap_or_default().split(';').next().unwrap_or("")).to_lowercase()
}

/// A JSON body by its media type, which a cross-site form cannot send.
fn body(request: &Request) -> Option<Value> {
    if media_type(request) != "application/json" {
        return None;
    }
    request.json().ok().filter(|v| matches!(v, Value::Object(_)))
}

/// `String(input[field] ?? "")`.
fn field(input: &Value, name: &str) -> String {
    js::str_or_empty(input.get(name))
}

/// A path's 24 hex digits, as `[a-f0-9]{24}` matches them.
fn is_id(s: &str) -> bool {
    s.len() == 24 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
fn role_of(value: Option<&Value>) -> Option<Role> {
    match value.and_then(Value::as_str) {
        Some("admin") => Some(Role::Admin),
        Some("member") => Some(Role::Member),
        Some("viewer") => Some(Role::Viewer),
        _ => None,
    }
}

struct Inner {
    rl: Runlight,
    store: SqlStore,
    accounts: Accounts,
    base: String,
    now: Clock,
    first: FirstAccount,
    home: Option<Home>,
    forgot: String,
    cookie_path: String,
    home_path: String,
    asks_for_token: bool,
    existing: AtomicBool,
    // Wrong passwords are counted twice. Per account and address, ten tries;
    // per account from anywhere, fifty, so a caller who invents a new address
    // for every try still cannot guess on and on. Addresses come from
    // forwarding headers a client can write, so they never stand alone.
    // Each try counts before the password is checked, and a right one is taken back.
    per_address: Throttle,
    per_account: Throttle,
    // Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the first one.
    // Password re-checks in Account: ten.
    code_tries: Throttle,
    confirm_tries: Throttle,
    rechecks: Throttle,
    /// When each account was last sent a sign-in link, at most one a minute.
    link_sent: Mutex<HashMap<String, i64>>,
}

/// The accounts' web side: a cheap handle to clone.
#[derive(Clone)]
pub struct AccountsWeb(Arc<Inner>);

/// The accounts' web side over a Runlight.
pub fn accounts_web(options: AccountsWebOptions) -> AccountsWeb {
    let store = options.runlight.store().clone();
    let window = 15 * 60_000;
    AccountsWeb(Arc::new(Inner {
        accounts: Accounts::new(store.clone(), options.secret),
        store,
        rl: options.runlight,
        cookie_path: if options.base.is_empty() { "/".into() } else { options.base.clone() },
        home_path: format!("{}/", options.base),
        asks_for_token: matches!(options.first_account, FirstAccount::Token(_)),
        base: options.base,
        now: options.now,
        first: options.first_account,
        home: options.home,
        forgot: options.forgot,
        existing: AtomicBool::new(false),
        per_address: Throttle::new(10, window),
        per_account: Throttle::new(50, window),
        code_tries: Throttle::new(5, window),
        confirm_tries: Throttle::new(5, window),
        rechecks: Throttle::new(10, window),
        link_sent: Mutex::new(HashMap::new()),
    }))
}

/// A random one-time code, such as the one a server prints to unlock its first account.
pub fn setup_code() -> String {
    base64url(&random_bytes(9))
}

type R<T> = Result<T, Error>;

impl AccountsWeb {
    /// The accounts themselves.
    pub fn accounts(&self) -> &Accounts {
        &self.0.accounts
    }

    fn now(&self) -> i64 {
        (self.0.now)()
    }

    async fn home(&self) -> Option<String> {
        match &self.0.home {
            Some(home) => home().await,
            None => None,
        }
    }

    /// Whether any account exists yet.
    pub async fn has_account(&self) -> R<bool> {
        if self.0.existing.load(Ordering::Relaxed) {
            return Ok(true);
        }
        let any = self.0.accounts.count().await? > 0;
        if any {
            self.0.existing.store(true, Ordering::Relaxed);
        }
        Ok(any)
    }

    /// Only a path on this install, so a sign-in can never send someone elsewhere.
    /// Browsers drop tabs and newlines from a URL and read a backslash as a slash,
    /// so "/\t/evil.example" would leave; anything with those is refused outright,
    /// and what is left must resolve to this origin.
    pub fn safe_next(&self, value: Option<&str>) -> String {
        let home = &self.0.home_path;
        let Some(value) = value else { return home.clone() };
        if value.is_empty()
            || !value.starts_with('/')
            || value.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}' || c == '\\')
        {
            return home.clone();
        }
        match Url::parse_with_base(value, "http://runlight.invalid") {
            Some(url) if url.origin() == "http://runlight.invalid" => {
                format!("{}{}{}", url.pathname(), url.search(), url.hash())
            }
            _ => home.clone(),
        }
    }

    /// The account a request's session cookie signs in, or `None`.
    pub async fn signed_in(&self, request: &Request) -> R<Option<User>> {
        let value = read_cookie(request, SESSION_COOKIE);
        if value.is_empty() {
            return Ok(None);
        }
        // decodeURIComponent throws a URIError here in TypeScript.
        let decoded = decode_uri_component(&value).ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
        Ok(self.0.accounts.from_session(&decoded, self.now()).await?)
    }

    /// What a signed-in person may do: everything (owner and admin), "member", "read" (viewer), or nothing.
    pub async fn access(&self, request: &Request) -> R<Access> {
        let Some(user) = self.signed_in(request).await? else { return Ok(Access::Denied) };
        // A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
        Ok(match user.role {
            Role::Owner | Role::Admin => Access::Full,
            Role::Member => Access::Member,
            Role::Viewer => Access::Read,
        })
    }

    /// The id of the account a request is signed in to.
    pub async fn account_of(&self, request: &Request) -> R<Option<String>> {
        Ok(self.signed_in(request).await?.map(|u| u.id))
    }

    /// Notes who made a token. A viewer makes no tokens; someone removed or made a viewer since allowing an app
    /// gets none for it, and false takes the token back.
    pub async fn token_made(&self, token: &TokenRow, by: &str) -> R<bool> {
        match self.0.accounts.by_id(by).await?.map(|u| u.role) {
            None | Some(Role::Viewer) => Ok(false),
            Some(_) => {
                self.0.store.set_setting(&format!("{MADE_BY}{}", token.id), Some(by)).await?;
                Ok(true)
            }
        }
    }

    async fn drop_tokens_of(&self, id: &str) -> R<()> {
        for (key, value) in self.0.store.settings_starting_with(MADE_BY).await? {
            if value != id {
                continue;
            }
            self.0.store.delete_token(&key[MADE_BY.len()..]).await?;
            self.0.store.set_setting(&key, None).await?;
        }
        Ok(())
    }

    fn session_cookie(&self, request: &Request, value: &str, max_age: i64) -> String {
        format!(
            "{SESSION_COOKIE}={}; Path={}; HttpOnly; SameSite=Lax; Max-Age={max_age}{}",
            encode_uri_component(value),
            self.0.cookie_path,
            if is_secure(request) { "; Secure" } else { "" }
        )
    }

    fn fresh_session(&self, request: &Request, user: &User) -> R<String> {
        Ok(self.session_cookie(request, &self.0.accounts.session_for(user, self.now())?, SESSION_MS / 1000))
    }

    /// The redirect after signing in: a session, and the mark that this browser has signed in to the account.
    fn signed_in_to(&self, request: &Request, user: &User, next: &str) -> R<Response> {
        let mut h = headers(&[("location", next), ("cache-control", "no-store")], &[]);
        h.append("set-cookie", &self.fresh_session(request, user)?);
        h.append(
            "set-cookie",
            &format!(
                "{DEVICE_COOKIE}={}; Path={}; HttpOnly; SameSite=Lax; Max-Age={}{}",
                encode_uri_component(&self.0.accounts.device_for(user)?),
                self.0.cookie_path,
                365 * 86_400,
                if is_secure(request) { "; Secure" } else { "" }
            ),
        );
        Ok(Response::new(Vec::new(), 303, h))
    }

    /// The first account's gate: what the setup form must carry.
    fn setup_ok(&self, given: &str) -> bool {
        match &self.0.first {
            FirstAccount::Open => true,
            FirstAccount::Locked => false,
            FirstAccount::Code(c) | FirstAccount::Token(c) => same_text(given, c),
        }
    }

    /// Why there is no setup form.
    fn setup_locked(&self) -> Response {
        let base = &self.0.base;
        html(
            if self.0.first == FirstAccount::Locked { setup_needs_token_page(base) } else { setup_locked_page(base) },
            403,
        )
    }

    /// Emails an invite through the mail service when there is one. The link
    /// always comes back too, for the inviter to pass on another way.
    async fn send_invite(&self, request: &Request, invite: &Invite, code: &str, out: &mut Object) -> R<()> {
        let origin = match self.home().await {
            Some(home) => home,
            None => request.parsed_url().origin(),
        };
        let link = format!("{origin}{}/invite?code={code}", self.0.base);
        let host =
            Url::parse(&origin).map(|u| u.host()).ok_or_else(|| Error::Other("TypeError: Invalid URL".into()))?;
        let what = role_text(invite.role.as_str());
        out.set("link", link.as_str());
        if crate::routes::glue::mail_settings(&self.0.rl).await?.is_none() {
            out.set("emailed", false);
            return Ok(());
        }
        let message = Message {
            to: invite.email.clone(),
            subject: format!("{} invited you to Runlight", invite.invited_by),
            text: format!(
                "{} invited you to the Runlight at {host} as {what}.\n\nChoose a password to join:\n{link}\n\nThe link works for seven days.\n",
                invite.invited_by
            ),
            html: format!(
                "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>{} invited you to the Runlight at {} as {what}.</p><p><a href=\"{}\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">Choose a password and join</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>",
                esc(&invite.invited_by),
                esc(&host),
                esc(&link)
            ),
            ..Message::default()
        };
        match crate::routes::glue::send_mail(&self.0.rl, message).await {
            Ok(()) => out.set("emailed", true),
            Err(failed) => {
                // The mail service's code and its details too, so the dashboard can say what went wrong in its own language.
                out.set("emailed", false);
                out.set("mailError", failed.message.as_str());
                out.set("mailCode", failed.code.as_str());
                out.set("mailParams", failed.params_value());
            }
        }
        Ok(())
    }

    /// Emails a sign-in link to an account held up by others' failed tries, at
    /// most once a minute. Only to the install's own address, never the Host of
    /// the request, so without one known there is no link.
    async fn send_link(&self, user: &User, next: &str) -> R<bool> {
        let Some(origin) = self.home().await.filter(|o| !o.is_empty()) else { return Ok(false) };
        let now = self.now();
        {
            let mut sent = self.0.link_sent.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if now - sent.get(&user.id).copied().unwrap_or(0) < 60_000 {
                return Ok(true);
            }
            sent.insert(user.id.clone(), now);
        }
        let ticket = self.0.accounts.link_for(user, now)?;
        let query = SearchParams::from_pairs([("ticket", ticket.as_str()), ("next", next)]);
        let link = format!("{origin}{}/login/link?{query}", self.0.base);
        let host =
            Url::parse(&origin).map(|u| u.host()).ok_or_else(|| Error::Other("TypeError: Invalid URL".into()))?;
        let message = Message {
            to: user.email.clone(),
            subject: "Sign in to Runlight".into(),
            text: format!(
                "Someone, most likely you, signed in to Runlight at {host} with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n{link}\n\nIf this was not you, change your password, since someone knows it.\n"
            ),
            html: format!(
                "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>Someone, most likely you, signed in to Runlight at {} with your password while your account was held up by too many failed tries.</p><p><a href=\"{}\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">Sign in</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>",
                esc(&host),
                esc(&link)
            ),
            ..Message::default()
        };
        crate::routes::glue::send_mail(&self.0.rl, message).await.map_err(Error::Mail)?;
        Ok(true)
    }

    fn login_html(&self, error: &str, email: &str, next: &str, status: u16) -> Response {
        html(
            login_page(
                &self.0.base,
                &LoginPage { error: Some(error), email: Some(email), next: Some(next), forgot: &self.0.forgot },
            ),
            status,
        )
    }

    async fn pages(&self, request: &Request, path: &str) -> R<Option<Response>> {
        let url = request.parsed_url();
        let query = url.search_params();
        let method = request.method.as_str();
        let base = self.0.base.as_str();
        let asks = self.0.asks_for_token;
        if path == "/auth.css" {
            return Ok(Some(Response::new(
                AUTH_CSS,
                200,
                headers(&[("content-type", "text/css; charset=utf-8"), ("cache-control", "public, max-age=3600")], &[]),
            )));
        }
        if path == "/auth.js" {
            return Ok(Some(Response::new(
                AUTH_JS,
                200,
                headers(
                    &[
                        ("content-type", "application/javascript; charset=utf-8"),
                        ("cache-control", "public, max-age=3600"),
                    ],
                    &[],
                ),
            )));
        }

        if path == "/setup" {
            if self.has_account().await? {
                return Ok(Some(redirect(&format!("{base}/login"), &[])));
            }
            if method == "GET" {
                let code = query.get("code").unwrap_or("");
                if self.0.first == FirstAccount::Locked {
                    return Ok(Some(self.setup_locked()));
                }
                // The app's token is typed in; the server's code comes in the link it printed.
                if asks || self.0.first == FirstAccount::Open {
                    return Ok(Some(html(
                        setup_page(base, &SetupPage { code: "", ask_code: asks, ..SetupPage::default() }),
                        200,
                    )));
                }
                return Ok(Some(if self.setup_ok(code) {
                    html(setup_page(base, &SetupPage { code, ..SetupPage::default() }), 200)
                } else {
                    self.setup_locked()
                }));
            }
            if method == "POST" {
                let form = SearchParams::parse(&request.text());
                let code = form.get("code").unwrap_or("");
                let email = form.get("email").unwrap_or("");
                if !self.setup_ok(code) {
                    if asks {
                        let page = SetupPage {
                            code: "",
                            ask_code: true,
                            error: Some("That is not this app's RUNLIGHT_TOKEN."),
                            email: Some(email),
                        };
                        return Ok(Some(html(setup_page(base, &page), 403)));
                    }
                    return Ok(Some(self.setup_locked()));
                }
                let again = |error: &str, status: u16| {
                    html(
                        setup_page(
                            base,
                            &SetupPage {
                                code: if asks { "" } else { code },
                                ask_code: asks,
                                error: Some(error),
                                email: Some(email),
                            },
                        ),
                        status,
                    )
                };
                // Asked twice, since a typo here would lock the first owner out.
                if form.get("password").unwrap_or("") != form.get("again").unwrap_or("") {
                    return Ok(Some(again("The two passwords are not the same.", 400)));
                }
                return match self
                    .0
                    .accounts
                    .set_password(email, form.get("password").unwrap_or(""), self.now(), None)
                    .await
                {
                    Ok(user) => {
                        self.0.existing.store(true, Ordering::Relaxed);
                        Ok(Some(redirect(&self.0.home_path, &[("set-cookie", &self.fresh_session(request, &user)?)])))
                    }
                    Err(AuthError::Account(error)) => Ok(Some(again(&error.message, 400))),
                    Err(error) => Err(error.into()),
                };
            }
        }

        if path == "/login" {
            if !self.has_account().await? {
                return Ok(Some(match self.0.first {
                    FirstAccount::Locked => self.setup_locked(),
                    FirstAccount::Open | FirstAccount::Token(_) => redirect(&format!("{base}/setup"), &[]),
                    FirstAccount::Code(_) => self.setup_locked(),
                }));
            }
            if method == "GET" {
                let next = self.safe_next(query.get("next"));
                return Ok(Some(html(
                    login_page(base, &LoginPage { next: Some(&next), forgot: &self.0.forgot, ..LoginPage::default() }),
                    200,
                )));
            }
            if method == "POST" {
                return self.login(request).await.map(Some);
            }
        }

        // The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
        if path == "/login/link" && method == "GET" {
            let next = self.safe_next(query.get("next"));
            let Some(user) = self.0.accounts.from_link(query.get("ticket").unwrap_or(""), self.now()).await? else {
                let page = LoginPage {
                    error: Some("That sign-in link has run out. Sign in again."),
                    next: Some(&next),
                    forgot: &self.0.forgot,
                    ..LoginPage::default()
                };
                return Ok(Some(html(login_page(base, &page), 410)));
            };
            if user.two_factor {
                let pending = self.0.accounts.pending_for(&user, self.now())?;
                return Ok(Some(html(code_page(base, &CodePage { pending: &pending, next: &next, error: None }), 200)));
            }
            return self.signed_in_to(request, &user, &next).map(Some);
        }

        if path == "/login/code" && method == "POST" {
            let form = SearchParams::parse(&request.text());
            let next = self.safe_next(form.get("next"));
            let given = form.get("pending").unwrap_or("");
            let Some(pending) = self.0.accounts.from_pending(given, self.now()).await? else {
                return Ok(Some(redirect(&format!("{base}/login?next={}", encode_uri_component(&next)), &[])));
            };
            let user = pending.user;
            // Counted before the check, so a burst cannot get past five.
            if !self.0.code_tries.take(&user.id, self.now()) {
                let page = CodePage {
                    pending: given,
                    next: &next,
                    error: Some("Too many tries. Wait fifteen minutes and try again."),
                };
                return Ok(Some(html(code_page(base, &page), 429)));
            }
            if !pending.real
                || !self.0.accounts.check_second_factor(&user.id, form.get("code").unwrap_or(""), self.now()).await?
            {
                let page = CodePage {
                    pending: given,
                    next: &next,
                    error: Some("That code is not right. Check the time on your phone, or use a recovery code."),
                };
                return Ok(Some(html(code_page(base, &page), 401)));
            }
            self.0.code_tries.clear(&user.id);
            return self.signed_in_to(request, &user, &next).map(Some);
        }

        if path == "/logout" {
            return Ok(Some(redirect(
                &format!("{base}/login"),
                &[("set-cookie", &self.session_cookie(request, "", 0))],
            )));
        }

        if path == "/invite" {
            let host = url.host();
            if method == "GET" {
                let code = query.get("code").unwrap_or("");
                return Ok(Some(match self.0.accounts.invite_by_code(code, self.now()).await? {
                    Some(invite) => html(
                        invite_page(
                            base,
                            &InvitePage {
                                code,
                                email: &invite.email,
                                role: invite.role.as_str(),
                                host: &host,
                                error: None,
                            },
                        ),
                        200,
                    ),
                    None => html(invite_gone_page(base), 410),
                }));
            }
            if method == "POST" {
                let form = SearchParams::parse(&request.text());
                let code = form.get("code").unwrap_or("");
                let Some(invite) = self.0.accounts.invite_by_code(code, self.now()).await? else {
                    return Ok(Some(html(invite_gone_page(base), 410)));
                };
                let again = |error: &str| {
                    html(
                        invite_page(
                            base,
                            &InvitePage {
                                code,
                                email: &invite.email,
                                role: invite.role.as_str(),
                                host: &host,
                                error: Some(error),
                            },
                        ),
                        400,
                    )
                };
                if form.get("password").unwrap_or("") != form.get("again").unwrap_or("") {
                    return Ok(Some(again("The two passwords are not the same.")));
                }
                return match self.0.accounts.accept_invite(code, form.get("password").unwrap_or(""), self.now()).await {
                    Ok(user) => {
                        self.0.existing.store(true, Ordering::Relaxed);
                        Ok(Some(redirect(&self.0.home_path, &[("set-cookie", &self.fresh_session(request, &user)?)])))
                    }
                    Err(AuthError::Account(error)) => Ok(Some(again(&error.message))),
                    Err(error) => Err(error.into()),
                };
            }
        }
        Ok(None)
    }

    async fn login(&self, request: &Request) -> R<Response> {
        let base = self.0.base.as_str();
        let form = SearchParams::parse(&request.text());
        let email = form.get("email").unwrap_or("");
        let password = form.get("password").unwrap_or("");
        let next = self.safe_next(form.get("next"));
        let account = js::trim(email).to_lowercase();
        let ip = self.0.rl.client_ip(request);
        let pair = format!("{account}\n{}", if ip.is_empty() { "unknown" } else { ip.as_str() });
        let too_many = || self.login_html("Too many tries. Wait fifteen minutes and try again.", email, &next, 429);
        if !self.0.per_address.take(&pair, self.now()) {
            return Ok(too_many());
        }
        // A browser that signed in to the account before is never held up by others' failures.
        let known = self.0.accounts.by_email(&account).await?;
        let trusted = match &known {
            Some(known) => self.0.accounts.trusts_device(&read_cookie(request, DEVICE_COOKIE), known)?,
            None => false,
        };
        let over = !trusted && !self.0.per_account.take(&account, self.now());
        // Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
        // addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
        // where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
        if over && !known.as_ref().is_some_and(|k| k.two_factor) {
            if crate::routes::glue::mail_settings(&self.0.rl).await?.is_none()
                || self.home().await.is_none_or(|h| h.is_empty())
            {
                return Ok(too_many());
            }
            if let Some(user) = self.0.accounts.sign_in(email, password).await? {
                // Sent once the answer is out, so a right password takes no longer to answer than a wrong one.
                let web = self.clone();
                let next = next.clone();
                self.0.rl.later(async move {
                    if let Err(error) = web.send_link(&user, &next).await {
                        eprintln!("Runlight: could not send a sign-in link {error}");
                    }
                });
            }
            return Ok(self.login_html(
                "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.",
                email,
                &next,
                429,
            ));
        }
        let Some(user) = self.0.accounts.sign_in(email, password).await? else {
            if over && let Some(known) = &known {
                let pending = self.0.accounts.decoy_for(known, self.now())?;
                return Ok(html(code_page(base, &CodePage { pending: &pending, next: &next, error: None }), 200));
            }
            return Ok(self.login_html("That email and password do not match an account.", email, &next, 401));
        };
        self.0.per_address.clear(&pair);
        if !over && !trusted {
            self.0.per_account.forgive(&account);
        }
        // With two-factor on, the password only earns the second step.
        if user.two_factor {
            let pending = self.0.accounts.pending_for(&user, self.now())?;
            return Ok(html(code_page(base, &CodePage { pending: &pending, next: &next, error: None }), 200));
        }
        self.signed_in_to(request, &user, &next)
    }

    /// Asks for the password again before a change; an answer when it is refused.
    async fn recheck(&self, user: &User, input: &Value, name: &str, wrong: (&str, &str)) -> R<Option<Response>> {
        if !self.0.rechecks.take(&user.id, self.now()) {
            return Ok(Some(coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429, None)));
        }
        if self.0.accounts.sign_in(&user.email, &field(input, name)).await?.is_none() {
            return Ok(Some(coded(wrong.0, wrong.1, 400, None)));
        }
        self.0.rechecks.forgive(&user.id);
        Ok(None)
    }

    /// Your own account, and for the owner and admins, everyone else's.
    async fn api(&self, request: &Request, path: &str) -> R<Response> {
        let Some(user) = self.signed_in(request).await? else {
            return Ok(coded("Sign in first", "sign_in", 401, None));
        };
        let method = request.method.as_str();
        let send_json = || coded("Send JSON", "send_json", 415, None);
        // Writes must be JSON, which a form on another page cannot send, even those with no body.
        if method == "POST" && media_type(request) != "application/json" {
            return Ok(send_json());
        }
        if path == "/api/account" && method == "GET" {
            return Ok(reply(&obj! { "account" => person(&user) }, 200, &[]));
        }
        let password_wrong = ("Your password is not right", "password_wrong");
        if path == "/api/account/password" && method == "POST" {
            let Some(input) = body(request) else { return Ok(send_json()) };
            if let Some(refused) = self
                .recheck(&user, &input, "current", ("Your current password is not right", "password_current_wrong"))
                .await?
            {
                return Ok(refused);
            }
            return match self.0.accounts.set_password(&user.email, &field(&input, "next"), self.now(), None).await {
                // The new password ends every other sign-in; this browser gets a fresh one.
                Ok(updated) => {
                    Ok(reply(&obj! { "ok" => true }, 200, &[("set-cookie", &self.fresh_session(request, &updated)?)]))
                }
                Err(AuthError::Account(error)) => Ok(refused(&error, 400)),
                Err(error) => Err(error.into()),
            };
        }
        // Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off.
        // Each change asks for the password again, so a browser left signed in cannot quietly change it.
        if path.starts_with("/api/account/2fa") && method == "POST" {
            let Some(input) = body(request) else { return Ok(send_json()) };
            let action = &path["/api/account/2fa".len()..];
            // Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
            if action == "/confirm" {
                if !self.0.confirm_tries.take(&user.id, self.now()) {
                    self.0.accounts.cancel_two_factor_setup(&user.id).await?;
                    return Ok(coded(
                        "Too many wrong codes. Start turning on two-factor sign-in again.",
                        "twofactor_restart",
                        429,
                        None,
                    ));
                }
                let code: String = field(&input, "code").chars().filter(|c| !js::is_space(*c)).collect();
                let Some(codes) = self.0.accounts.confirm_two_factor(&user.id, &code, self.now()).await? else {
                    return Ok(coded(
                        "That code is not right. Check the time on your phone and try the next one.",
                        "code_wrong",
                        400,
                        None,
                    ));
                };
                self.0.confirm_tries.clear(&user.id);
                // Turning it on signs out every other browser; this one gets a new session.
                let updated =
                    self.0.accounts.by_id(&user.id).await?.ok_or_else(|| Error::Other("Unknown account".into()))?;
                let recovery = Value::Array(codes.into_iter().map(Value::from).collect());
                return Ok(reply(
                    &obj! { "recovery" => recovery },
                    200,
                    &[("set-cookie", &self.fresh_session(request, &updated)?)],
                ));
            }
            if let Some(refused) = self.recheck(&user, &input, "password", password_wrong).await? {
                return Ok(refused);
            }
            if action == "/start" {
                self.0.confirm_tries.clear(&user.id);
                let secret = self.0.accounts.start_two_factor(&user.id).await?;
                let uri = otpauth_uri(&secret, &user.email, &request.parsed_url().host());
                return Ok(reply(&obj! { "secret" => secret, "uri" => uri }, 200, &[]));
            }
            if action == "/recovery" {
                if !user.two_factor {
                    return Ok(coded("Turn on two-factor sign-in first", "twofactor_off", 400, None));
                }
                let codes = self.0.accounts.new_recovery_codes(&user.id).await?;
                return Ok(reply(
                    &obj! { "recovery" => Value::Array(codes.into_iter().map(Value::from).collect()) },
                    200,
                    &[],
                ));
            }
            if action == "/disable" {
                self.0.accounts.disable_two_factor(&user.id).await?;
                // Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
                let updated =
                    self.0.accounts.by_id(&user.id).await?.ok_or_else(|| Error::Other("Unknown account".into()))?;
                return Ok(reply(
                    &obj! { "ok" => true },
                    200,
                    &[("set-cookie", &self.fresh_session(request, &updated)?)],
                ));
            }
            return Ok(coded("Not found", "not_found", 404, None));
        }
        if user.role != Role::Owner && user.role != Role::Admin {
            return Ok(coded("Only the owner or an admin can manage people", "people_owner", 403, None));
        }
        let people_id = |suffix: &str| -> Option<String> {
            let rest = path.strip_prefix("/api/people/")?.strip_suffix(suffix)?;
            is_id(rest).then(|| rest.to_string())
        };
        // The owner or an admin can turn off someone else's two-factor, for a coworker who lost both phone and recovery
        // codes, though never the owner's. It asks for their password like every other two-factor change, and their own
        // goes through Account.
        if let Some(id) = people_id("/2fa")
            && method == "DELETE"
        {
            if id == user.id {
                return Ok(coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400, None));
            }
            let Some(input) = body(request) else { return Ok(send_json()) };
            if let Some(refused) = self.recheck(&user, &input, "password", password_wrong).await? {
                return Ok(refused);
            }
            let Some(target) = self.0.accounts.by_id(&id).await? else {
                return Ok(coded("Unknown account", "unknown_account", 404, None));
            };
            if target.role == Role::Owner {
                return Ok(coded("Only the owner can change the owner's account", "owner_protected", 403, None));
            }
            self.0.accounts.disable_two_factor(&id).await?;
            return Ok(reply(&obj! { "ok" => true }, 200, &[]));
        }
        // The owner hands ownership to an admin and becomes an admin, after typing their password again.
        if let Some(id) = people_id("/owner")
            && method == "POST"
        {
            if user.role != Role::Owner {
                return Ok(coded("Only the owner can hand over ownership", "owner_hand_over", 403, None));
            }
            let Some(input) = body(request) else { return Ok(send_json()) };
            if let Some(refused) = self.recheck(&user, &input, "password", password_wrong).await? {
                return Ok(refused);
            }
            return match self.0.accounts.hand_over(&user.id, &id).await {
                Ok(()) => Ok(reply(&obj! { "people" => self.people().await? }, 200, &[])),
                Err(AuthError::Account(error)) => {
                    Ok(refused(&error, if error.code == "unknown_account" { 404 } else { 400 }))
                }
                Err(error) => Err(error.into()),
            };
        }
        if path == "/api/people" && method == "GET" {
            let invites: Vec<Value> = self.0.accounts.invites(self.now()).await?.iter().map(invite_view).collect();
            return Ok(reply(&obj! { "people" => self.people().await?, "invites" => Value::Array(invites) }, 200, &[]));
        }
        if path == "/api/people" && method == "POST" {
            let Some(input) = body(request) else { return Ok(send_json()) };
            let Some(role) = role_of(input.get("role")) else {
                return Ok(coded("Pick admin, member, or viewer", "role_needed", 400, None));
            };
            let email = js::trim(&field(&input, "email")).to_lowercase();
            if self.0.accounts.by_email(&email).await?.is_some() {
                return Ok(coded(
                    &format!("{email} already has an account"),
                    "account_exists",
                    409,
                    Some(obj! { "email" => email.as_str() }),
                ));
            }
            return match self.0.accounts.invite(&email, role, &user.email, self.now()).await {
                Ok(made) => Ok(reply(&self.invite_answer(request, &made.invite, &made.code).await?, 201, &[])),
                Err(AuthError::Account(error)) => Ok(refused(&error, 400)),
                Err(error) => Err(error.into()),
            };
        }
        if let Some(rest) = path.strip_prefix("/api/invites/") {
            let (id, resend) = match rest.strip_suffix("/resend") {
                Some(id) => (id, true),
                None => (rest, false),
            };
            if is_id(id) {
                if method == "DELETE" && !resend {
                    return Ok(if self.0.accounts.cancel_invite(id).await? {
                        reply(&obj! { "ok" => true }, 200, &[])
                    } else {
                        coded("Unknown invite", "unknown_invite", 404, None)
                    });
                }
                if method == "POST" && resend {
                    let Some(old) = self.0.accounts.invites(self.now()).await?.into_iter().find(|i| i.id == id) else {
                        return Ok(coded("Unknown invite", "unknown_invite", 404, None));
                    };
                    // A new link replaces the old one, which stops working.
                    let made = self.0.accounts.invite(&old.email, old.role, &user.email, self.now()).await?;
                    return Ok(reply(&self.invite_answer(request, &made.invite, &made.code).await?, 200, &[]));
                }
            }
        }
        if let Some(id) = people_id("")
            && (method == "PATCH" || method == "DELETE")
        {
            let changed = if method == "DELETE" {
                if id == user.id {
                    return Ok(coded("You cannot remove yourself", "remove_self", 400, None));
                }
                self.0.accounts.remove(&id).await.map(|()| None)
            } else {
                let Some(input) = body(request) else { return Ok(send_json()) };
                let Some(role) = role_of(input.get("role")) else {
                    return Ok(coded("Pick admin, member, or viewer", "role_needed", 400, None));
                };
                self.0.accounts.set_role(&id, role).await.map(|changed| Some((changed, role)))
            };
            return match changed {
                Ok(None) => {
                    // The tokens they made, and the apps they connected, stop working with them.
                    self.drop_tokens_of(&id).await?;
                    Ok(reply(&obj! { "ok" => true }, 200, &[]))
                }
                Ok(Some((changed, role))) => {
                    // A viewer changes nothing, so the tokens they made before go too.
                    if role == Role::Viewer {
                        self.drop_tokens_of(&id).await?;
                    }
                    Ok(reply(&obj! { "person" => person(&changed) }, 200, &[]))
                }
                Err(AuthError::Account(error)) => {
                    let status = match error.code.as_str() {
                        "unknown_account" => 404,
                        "owner_protected" => 403,
                        _ => 400,
                    };
                    Ok(refused(&error, status))
                }
                Err(error) => Err(error.into()),
            };
        }
        Ok(coded("Not found", "not_found", 404, None))
    }

    async fn people(&self) -> R<Value> {
        Ok(Value::Array(self.0.accounts.list().await?.iter().map(person).collect()))
    }

    /// `{ invite, link, emailed, ... }` for a new invite.
    async fn invite_answer(&self, request: &Request, invite: &Invite, code: &str) -> R<Value> {
        let mut out = Object::new();
        out.set("invite", invite_view(invite));
        self.send_invite(request, invite, code, &mut out).await?;
        Ok(Value::Object(out))
    }

    /// Answers an account page or API request at a path under the base, or `None` for anything else.
    pub async fn handle(&self, request: &Request, path: &str) -> R<Option<Response>> {
        if path == "/api/account"
            || path.starts_with("/api/account/")
            || path == "/api/people"
            || path.starts_with("/api/people/")
            || path.starts_with("/api/invites/")
        {
            return self.api(request, path).await.map(Some);
        }
        if let Some(page) = self.pages(request, path).await? {
            return Ok(Some(page));
        }
        // The dashboard itself: straight to sign-in, or to setting up the first account.
        if (path == "/" || path.is_empty()) && request.method == "GET" && self.signed_in(request).await?.is_none() {
            let base = &self.0.base;
            if !self.has_account().await? {
                return Ok(Some(if self.0.first == FirstAccount::Open || self.0.asks_for_token {
                    redirect(&format!("{base}/setup"), &[])
                } else {
                    self.setup_locked()
                }));
            }
            let search = request.parsed_url().search();
            let next = if search.is_empty() {
                String::new()
            } else {
                format!("?next={}", encode_uri_component(&format!("{}{search}", self.0.home_path)))
            };
            return Ok(Some(redirect(&format!("{base}/login{next}"), &[])));
        }
        Ok(None)
    }
}
