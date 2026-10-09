//! Accounts on the web through the routes, on SQLite in memory: the cases from the PHP port's WebTest that the
//! accounts conformance scenarios leave out, such as the sign-in link a held-up account is emailed after the answer.

#![cfg(feature = "sqlite")]

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use runlight::accounts::{AccountsWeb, AccountsWebOptions, FirstAccount, accounts_web, setup_code};
use runlight::http::{FetchError, FetchInit, Fetcher, Request, Response, SearchParams, Url};
use runlight::js::{self, Object, Value};
use runlight::{BoxFuture, Routes, RoutesOptions, Runlight, RunlightOptions, SiteOptions, TokenOption};

const NOW: i64 = 1_791_288_000_000;

/// A mail webhook that keeps what it was sent, or fails when told to.
#[derive(Default)]
struct Hook {
    sent: Mutex<Vec<Value>>,
    down: AtomicBool,
}

impl Fetcher for Hook {
    fn fetch<'a>(&'a self, _url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            if self.down.load(Ordering::SeqCst) {
                return Err(FetchError::Failed("fetch failed".into()));
            }
            let body = init.body.as_deref().map(runlight::http::utf8).unwrap_or_default();
            self.sent.lock().unwrap().push(js::parse(&body).unwrap());
            Ok(Response::new("", 200, Default::default()))
        })
    }
}

struct App {
    rl: Runlight,
    routes: Routes,
    now: Arc<AtomicI64>,
    hook: Arc<Hook>,
}

async fn app(mail: bool, origin: Option<&str>) -> App {
    let store = runlight_sqlx::connect(":memory:").await.unwrap();
    store.migrate().await.unwrap();
    let now = Arc::new(AtomicI64::new(NOW));
    let hook = Arc::new(Hook::default());
    let mut options = RunlightOptions::new(store);
    options.site = Some(SiteOptions { hostnames: Some(vec!["example.com".into()]), ..SiteOptions::default() });
    options.secret = Some("k".repeat(64));
    let clock = now.clone();
    options.now = Some(Arc::new(move || clock.load(Ordering::SeqCst)));
    options.fetcher = Some(hook.clone());
    if mail {
        let config = Object::new()
            .with("service", "webhook")
            .with("url", "https://hooks.example.net/mail")
            .with("from", "runlight@example.com");
        options.mail = Some(config);
    }
    let rl = Runlight::new(options).unwrap();
    let routes = rl
        .routes(RoutesOptions {
            token: TokenOption::Given("app-token".into()),
            accounts: true,
            origin: origin.map(str::to_string),
            ..RoutesOptions::default()
        })
        .unwrap();
    App { rl, routes, now, hook }
}

fn req(method: &str, path: &str) -> Request {
    Request::new(method, format!("https://example.com/runlight{path}"))
}

fn form(path: &str, fields: &[(&str, &str)]) -> Request {
    req("POST", path)
        .header("content-type", "application/x-www-form-urlencoded")
        .body(SearchParams::from_pairs(fields.iter().copied()).to_string())
}

fn json(cookie: &str, method: &str, path: &str, body: &Value) -> Request {
    req(method, path).header("cookie", cookie).header("content-type", "application/json").body(body.to_json())
}

fn cookie_of(response: &Response) -> String {
    response.headers.get_set_cookie().first().map(|c| c.split(';').next().unwrap().to_string()).unwrap_or_default()
}

impl App {
    async fn owner(&self) -> String {
        let made = self
            .routes
            .handle(form(
                "/setup",
                &[
                    ("code", "app-token"),
                    ("email", "jon@example.com"),
                    ("password", "a long password"),
                    ("again", "a long password"),
                ],
            ))
            .await;
        assert_eq!(made.status, 303);
        cookie_of(&made)
    }

    fn sent(&self) -> Vec<Value> {
        self.hook.sent.lock().unwrap().clone()
    }

    /// Fifty wrong passwords for the account, from five addresses so none is held up on its own.
    async fn hold_up(&self) {
        for i in 0..50 {
            let answer = self
                .routes
                .handle(
                    form("/login", &[("email", "jon@example.com"), ("password", "a wrong password")])
                        .header("x-forwarded-for", format!("203.0.113.{}", i / 10)),
                )
                .await;
            assert_eq!(answer.status, 401);
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_account_held_up_by_others_gets_a_sign_in_link_after_the_answer() {
    let app = app(true, Some("https://stats.example.com/somewhere")).await;
    app.owner().await;
    app.hold_up().await;
    let held = app
        .routes
        .handle(form(
            "/login",
            &[("email", "jon@example.com"), ("password", "a long password"), ("next", "/runlight/?a=1")],
        ))
        .await;
    assert_eq!(held.status, 429);
    assert!(held.text().contains("a link to sign in is on its way"));
    app.rl.idle().await;
    let sent = app.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].get("subject").and_then(Value::as_str), Some("Sign in to Runlight"));
    assert_eq!(sent[0].get("to").and_then(Value::as_str), Some("jon@example.com"));
    assert_eq!(sent[0].get("from").and_then(Value::as_str), Some("runlight@example.com"));
    let text = js::str_or_empty(sent[0].get("text"));
    assert!(
        text.starts_with("Someone, most likely you, signed in to Runlight at stats.example.com with your password")
    );
    let link =
        text.split('\n').find(|l| l.starts_with("https://stats.example.com/runlight/login/link?ticket=")).unwrap();
    let link = Url::parse(link).unwrap();
    assert_eq!(link.search_params().get("next"), Some("/runlight/?a=1"));
    assert!(
        js::str_or_empty(sent[0].get("html"))
            .contains("<a href=\"https://stats.example.com/runlight/login/link?ticket=")
    );

    app.routes.handle(form("/login", &[("email", "jon@example.com"), ("password", "a long password")])).await;
    app.rl.idle().await;
    assert_eq!(app.sent().len(), 1, "at most one link a minute");
    let wrong =
        app.routes.handle(form("/login", &[("email", "jon@example.com"), ("password", "a wrong password")])).await;
    assert_eq!(wrong.status, 429, "a wrong password gets the same answer");
    assert_eq!(wrong.text(), held.text().replace(" value=\"/runlight/?a=1\"", " value=\"/runlight/\""));

    let path = format!("/login/link{}", link.search());
    let signed = app.routes.handle(req("GET", &path)).await;
    assert_eq!(signed.status, 303);
    assert_eq!(signed.headers.get("location").as_deref(), Some("/runlight/?a=1"));
    assert_eq!(app.routes.handle(req("GET", &path)).await.status, 410, "a link works once");

    // A browser that signed in before is not held up by others' failures.
    let device = signed.headers.get_set_cookie()[1].split(';').next().unwrap().to_string();
    let trusted = app
        .routes
        .handle(
            form("/login", &[("email", "jon@example.com"), ("password", "a long password")]).header("cookie", &device),
        )
        .await;
    assert_eq!(trusted.status, 303);
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_mail_service_or_a_known_address_a_held_up_account_waits() {
    for (mail, origin) in [(false, Some("https://stats.example.com")), (true, None)] {
        let app = app(mail, origin).await;
        app.owner().await;
        app.hold_up().await;
        let held =
            app.routes.handle(form("/login", &[("email", "jon@example.com"), ("password", "a long password")])).await;
        assert_eq!(held.status, 429);
        assert!(held.text().contains("Too many tries. Wait fifteen minutes and try again."));
        app.rl.idle().await;
        assert!(app.sent().is_empty());
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn ten_wrong_passwords_from_one_address_wait() {
    let app = app(false, None).await;
    app.owner().await;
    let at = |r: Request, ip: &str| r.header("x-forwarded-for", ip);
    for _ in 0..10 {
        let answer = app
            .routes
            .handle(at(form("/login", &[("email", "jon@example.com"), ("password", "nope nope nope")]), "203.0.113.9"))
            .await;
        assert_eq!(answer.status, 401);
    }
    let right = [("email", "jon@example.com"), ("password", "a long password")];
    assert_eq!(
        app.routes.handle(at(form("/login", &right), "203.0.113.9")).await.status,
        429,
        "even the right password waits"
    );
    assert_eq!(
        app.routes.handle(at(form("/login", &right), "203.0.113.10")).await.status,
        303,
        "another address is not held up"
    );
    app.now.fetch_add(15 * 60_000, Ordering::SeqCst);
    assert_eq!(app.routes.handle(at(form("/login", &right), "203.0.113.9")).await.status, 303, "fifteen minutes later");
}

#[tokio::test(flavor = "multi_thread")]
async fn invites_are_emailed_and_a_failed_email_says_why() {
    let app = app(true, None).await;
    let owner = app.owner().await;
    let made = app
        .routes
        .handle(json(
            &owner,
            "POST",
            "/api/people",
            &runlight::obj! { "email" => "ada@example.com", "role" => "member" },
        ))
        .await;
    assert_eq!(made.status, 201);
    let body = made.json_body().unwrap();
    assert_eq!(body.as_object().unwrap().keys().collect::<Vec<_>>(), ["invite", "link", "emailed"]);
    assert_eq!(body.get("emailed"), Some(&Value::Bool(true)));
    assert!(js::str_or_empty(body.get("link")).starts_with("https://example.com/runlight/invite?code="));
    let sent = app.sent();
    assert_eq!(sent[0].get("subject").and_then(Value::as_str), Some("jon@example.com invited you to Runlight"));

    app.hook.down.store(true, Ordering::SeqCst);
    let failed = app
        .routes
        .handle(json(
            &owner,
            "POST",
            "/api/people",
            &runlight::obj! { "email" => "bo@example.com", "role" => "viewer" },
        ))
        .await;
    let body = failed.json_body().unwrap();
    assert_eq!(
        body.as_object().unwrap().keys().collect::<Vec<_>>(),
        ["invite", "link", "emailed", "mailError", "mailCode", "mailParams"]
    );
    assert_eq!(body.get("emailed"), Some(&Value::Bool(false)));
    assert_eq!(body.get("mailCode").and_then(Value::as_str), Some("mail_unreachable"));
}

#[tokio::test(flavor = "multi_thread")]
async fn tokens_made_by_someone_go_when_they_do() {
    let app = app(false, None).await;
    let owner = app.owner().await;
    let made = app
        .routes
        .handle(json(
            &owner,
            "POST",
            "/api/people",
            &runlight::obj! { "email" => "ada@example.com", "role" => "member" },
        ))
        .await;
    let link = js::str_or_empty(made.json_body().unwrap().get("link"));
    let code = Url::parse(&link).unwrap().search_params().get("code").unwrap().to_string();
    let joined = app
        .routes
        .handle(form(
            "/invite",
            &[("code", &code), ("password", "ada's long password"), ("again", "ada's long password")],
        ))
        .await;
    let ada = cookie_of(&joined);
    let token = app.routes.handle(json(&ada, "POST", "/api/tokens", &runlight::obj! { "name" => "Ada's" })).await;
    assert_eq!(token.status, 201);
    assert_eq!(app.rl.store().tokens().await.unwrap().len(), 1);
    let people = app.routes.handle(req("GET", "/api/account").header("cookie", &ada)).await.json_body().unwrap();
    let ada_id = js::str_or_empty(people.at("account").get("id"));
    assert_eq!(
        app.rl.store().setting(&format!("token-by:{}", app.rl.store().tokens().await.unwrap()[0].id)).await.unwrap(),
        Some(ada_id.clone())
    );

    // Made a viewer, Ada's tokens go, and she makes no more.
    let viewer = app
        .routes
        .handle(json(&owner, "PATCH", &format!("/api/people/{ada_id}"), &runlight::obj! { "role" => "viewer" }))
        .await;
    assert_eq!(viewer.status, 200);
    assert!(app.rl.store().tokens().await.unwrap().is_empty());
    let refused = app.routes.handle(json(&ada, "POST", "/api/tokens", &runlight::obj! { "name" => "Again" })).await;
    assert_eq!(refused.status, 403);
    assert!(app.rl.store().tokens().await.unwrap().is_empty());

    // The app's own token makes tokens for nobody in particular.
    let by_app = app
        .routes
        .handle(
            req("POST", "/api/tokens")
                .header("authorization", "Bearer app-token")
                .header("content-type", "application/json")
                .body("{\"name\":\"App\"}"),
        )
        .await;
    assert_eq!(by_app.status, 201);
}

fn web(first: FirstAccount, rl: &Runlight) -> AccountsWeb {
    let clock = rl.clone();
    accounts_web(AccountsWebOptions {
        runlight: rl.clone(),
        secret: "k".repeat(64),
        base: "/runlight".into(),
        now: Arc::new(move || clock.now()),
        first_account: first,
        home: None,
        forgot: "https://runlight.sh/docs/configuration/#accounts".into(),
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn cookies_codes_and_where_a_sign_in_goes() {
    let app = app(false, None).await;
    let owner = app.owner().await;
    let web = web(FirstAccount::Code("printed".into()), &app.rl);
    assert!(web.signed_in(&req("GET", "/").header("cookie", format!("a=b; {owner} ; c=d=e"))).await.unwrap().is_some());
    assert!(
        web.signed_in(&req("GET", "/").header("cookie", "runlight_session=%E0%A4%A")).await.is_err(),
        "decodeURIComponent throws"
    );
    assert_eq!(
        app.routes.handle(req("GET", "/api/account").header("cookie", "runlight_session=%E0%A4%A")).await.status,
        500
    );

    let plain = Request::new("POST", "http://example.com/runlight/login")
        .header("content-type", "application/x-www-form-urlencoded")
        .body("email=jon%40example.com&password=a+long+password");
    let answer = app.routes.handle(plain).await;
    assert!(!answer.headers.get_set_cookie()[0].contains("Secure"), "Secure only over https");
    let proxied = Request::new("GET", "http://example.com/runlight/logout").header("x-forwarded-proto", "https");
    let out = app.routes.handle(proxied).await;
    assert_eq!(
        out.headers.get_set_cookie()[0],
        "runlight_session=; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=0; Secure"
    );

    for (given, safe) in [
        (Some("/runlight/?site=a#b"), "/runlight/?site=a#b"),
        (Some("//evil.example/"), "/runlight/"),
        (Some("/\t/evil.example"), "/runlight/"),
        (Some("/\\evil.example"), "/runlight/"),
        (Some("https://evil.example/"), "/runlight/"),
        (Some("/a/../b?x=1"), "/b?x=1"),
        (None, "/runlight/"),
    ] {
        assert_eq!(web.safe_next(given), safe, "{given:?}");
    }
    let code = setup_code();
    assert_eq!(code.len(), 12);
    assert!(code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_server_code_open_and_locked_setups() {
    let store = runlight_sqlx::connect(":memory:").await.unwrap();
    store.migrate().await.unwrap();
    let rl = Runlight::new(RunlightOptions::new(store)).unwrap();
    let printed = web(FirstAccount::Code("printed".into()), &rl);
    let get = |path: &str| req("GET", path);
    assert_eq!(printed.handle(&get("/setup"), "/setup").await.unwrap().unwrap().status, 403);
    let opened = printed.handle(&get("/setup?code=printed"), "/setup").await.unwrap().unwrap();
    assert_eq!(opened.status, 200);
    assert!(opened.text().contains("value=\"printed\""));
    assert_eq!(printed.handle(&get("/"), "/").await.unwrap().unwrap().status, 403);
    assert_eq!(printed.handle(&get("/login"), "/login").await.unwrap().unwrap().status, 403);
    let locked = web(FirstAccount::Locked, &rl);
    assert!(locked.handle(&get("/setup"), "/setup").await.unwrap().unwrap().text().contains("RUNLIGHT_TOKEN"));
    let open = web(FirstAccount::Open, &rl);
    assert_eq!(
        open.handle(&get("/"), "/").await.unwrap().unwrap().headers.get("location").as_deref(),
        Some("/runlight/setup")
    );
    assert!(open.handle(&get("/elsewhere"), "/elsewhere").await.unwrap().is_none());
}
