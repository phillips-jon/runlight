//! Connecting an install through its consent page, as hub.test.ts tests it,
//! with the install played by a Fetcher.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use runlight::BoxFuture;
use runlight::connect::{ConnectError, ConnectFailure, finish_connect, start_connect};
use runlight::http::{FetchError, FetchInit, Fetcher, Headers, Response, SearchParams, Url};
use runlight::js::{self, Value};
use runlight::{Runlight, RunlightOptions};

const APP: &str = "http://127.0.0.1:4100/runlight";
const START: i64 = 1_791_288_000_000;

/// An install that speaks OAuth, as an app's Runlight does: each route a URL suffix and its answer.
struct Router {
    routes: Vec<(&'static str, u16, String)>,
    requests: Mutex<Vec<(String, FetchInit)>>,
}

impl Fetcher for Router {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            self.requests.lock().unwrap().push((url.to_string(), init));
            match self.routes.iter().find(|(suffix, _, _)| url.ends_with(suffix)) {
                Some((_, status, body)) => {
                    Ok(Response::new(body.clone(), *status, Headers::new().with("content-type", "application/json")))
                }
                None => Err(FetchError::Failed("refused".into())),
            }
        })
    }
}

fn meta(authorize: &str, token: &str, register: &str, scopes: &str) -> String {
    format!(
        "{{\"authorization_endpoint\":\"{authorize}\",\"token_endpoint\":\"{token}\",\"registration_endpoint\":\"{register}\",\"scopes_supported\":{scopes}}}"
    )
}

fn install(meta_json: Option<String>, registered: &str, register_status: u16) -> Arc<Router> {
    let meta_json = meta_json.unwrap_or_else(|| {
        meta(
            &format!("{APP}/oauth/authorize"),
            &format!("{APP}/oauth/token"),
            &format!("{APP}/oauth/register"),
            "[\"read\",\"manage\"]",
        )
    });
    Arc::new(Router {
        routes: vec![
            ("/.well-known/oauth-authorization-server", 200, meta_json),
            ("/oauth/register", register_status, registered.to_string()),
            ("/oauth/token", 200, "{\"access_token\":\"rl_manage\",\"site\":\"blog\"}".into()),
            (
                "/api/sites",
                200,
                "{\"sites\":[{\"id\":\"shop\",\"name\":\"Shop\",\"timezone\":\"UTC\",\"hostnames\":[\"shop.example.com\"]},{\"id\":\"blog\",\"name\":\"Blog\",\"timezone\":\"Asia/Tokyo\",\"hostnames\":[\"blog.example.com\"]}]}".into(),
            ),
            ("/api/token", 200, "{\"scope\":\"manage\",\"site\":\"blog\"}".into()),
        ],
        requests: Mutex::new(vec![]),
    })
}

fn default_install() -> Arc<Router> {
    install(None, "{\"client_id\":\"c1\"}", 201)
}

async fn hub(router: Arc<Router>, now: Arc<AtomicI64>, managed: bool) -> Runlight {
    let mut options = RunlightOptions::new(runlight_sqlx::connect(":memory:").await.unwrap());
    options.managed_sites = managed;
    options.secret = Some("k".repeat(32));
    options.fetcher = Some(router);
    options.now = Some(Arc::new(move || now.load(Ordering::SeqCst)));
    let rl = Runlight::new(options).unwrap();
    rl.init().await.unwrap();
    rl
}

fn refused<T: std::fmt::Debug>(result: Result<T, ConnectFailure>, code: &str) -> ConnectError {
    match result {
        Err(ConnectFailure::Connect(e)) => {
            assert_eq!(e.code, code, "{e:?}");
            e
        }
        other => panic!("no {code}: {other:?}"),
    }
}

fn params(pairs: &[(&str, &str)]) -> SearchParams {
    SearchParams::from_pairs(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())))
}

#[tokio::test]
async fn a_hub_connects_an_app_through_its_consent_page_for_the_one_site_the_owner_picked() {
    let router = default_install();
    let now = Arc::new(AtomicI64::new(START));
    let hub = hub(router.clone(), now.clone(), true).await;
    let back = "http://localhost:4900/runlight/api/sites/connect/done";
    let consent =
        Url::parse(&start_connect(&hub, Some(&Value::from(format!("{APP}/"))), back, "").await.unwrap()).unwrap();
    assert_eq!(format!("{}{}", consent.origin(), consent.pathname()), "http://127.0.0.1:4100/runlight/oauth/authorize");
    let q = consent.search_params();
    let get = |k: &str| q.get(k).map(str::to_string);
    assert_eq!(
        [get("response_type"), get("client_id"), get("redirect_uri"), get("code_challenge_method"), get("scope")],
        [Some("code".into()), Some("c1".into()), Some(back.into()), Some("S256".into()), Some("manage".into())]
    );
    let state = get("state").unwrap();
    assert!(state.len() == 32 && state.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert_eq!(get("site"), None);
    let registration = {
        let requests = router.requests.lock().unwrap();
        js::parse(&String::from_utf8(requests[1].1.body.clone().unwrap()).unwrap()).unwrap()
    };
    assert_eq!(
        registration.to_json(),
        format!("{{\"client_name\":\"Runlight at localhost:4900\",\"redirect_uris\":[\"{back}\"]}}")
    );

    let pending = js::parse(&hub.store().setting(&format!("connect:{state}")).await.unwrap().unwrap()).unwrap();
    let verifier = pending.at("verifier").as_str().unwrap().to_string();
    let challenge = runlight::oauth::s256(&verifier);
    assert_eq!(get("code_challenge"), Some(challenge), "the challenge is the verifier hashed");
    assert_eq!(pending.at("expires").as_f64(), Some((START + 15 * 60_000) as f64));

    let id = finish_connect(&hub, &params(&[("state", &state), ("code", "the-code")])).await.unwrap();
    assert_eq!(id, "blog.example.com");
    let remote = hub.remote(&id).unwrap();
    assert_eq!((remote.url.as_str(), remote.token.as_str(), remote.site.as_str()), (APP, "rl_manage", "blog"));
    assert_eq!(
        (remote.hostnames.clone(), remote.scope.clone()),
        (vec!["blog.example.com".to_string()], Some("manage".to_string()))
    );
    let site = hub.site(Some(&id)).unwrap();
    assert_eq!((site.name.as_str(), site.timezone.as_str(), site.hostnames.len()), ("Blog", "Asia/Tokyo", 0));
    let exchange = {
        let requests = router.requests.lock().unwrap();
        let found = requests.iter().find(|(url, _)| url.ends_with("/oauth/token")).unwrap();
        (
            found.1.headers.get("content-type"),
            SearchParams::parse(&String::from_utf8(found.1.body.clone().unwrap()).unwrap()),
        )
    };
    assert_eq!(exchange.0.as_deref(), Some("application/x-www-form-urlencoded"));
    let form = exchange.1;
    assert_eq!(
        [
            form.get("grant_type"),
            form.get("code"),
            form.get("client_id"),
            form.get("redirect_uri"),
            form.get("code_verifier")
        ],
        [Some("authorization_code"), Some("the-code"), Some("c1"), Some(back), Some(verifier.as_str())]
    );

    // A code works once.
    refused(finish_connect(&hub, &params(&[("state", &state), ("code", "the-code")])).await, "expired");
}

#[tokio::test]
async fn what_went_wrong_comes_back_as_a_code() {
    let now = Arc::new(AtomicI64::new(START));
    let hub = hub(default_install(), now.clone(), true).await;
    let start = |site: &'static str| {
        let hub = hub.clone();
        async move {
            Url::parse(&start_connect(&hub, Some(&Value::from(APP)), "https://hub.example/done", site).await.unwrap())
                .unwrap()
                .search_params()
        }
    };
    assert_eq!(start("blog").await.get("site"), Some("blog"), "which of its sites to offer first");
    let denied = start("").await;
    refused(
        finish_connect(&hub, &params(&[("state", denied.get("state").unwrap()), ("error", "access_denied")])).await,
        "denied",
    );
    let other = start("").await;
    let e = refused(
        finish_connect(
            &hub,
            &params(&[
                ("state", other.get("state").unwrap()),
                ("error", "server_error"),
                ("error_description", "Sign in again"),
            ]),
        )
        .await,
        "refused",
    );
    assert_eq!(e.message, "Sign in again");
    refused(finish_connect(&hub, &params(&[("state", "not-a-state")])).await, "expired");
    // An attempt nobody came back from in time.
    let late = start("").await;
    now.fetch_add(16 * 60_000, Ordering::SeqCst);
    refused(finish_connect(&hub, &params(&[("state", late.get("state").unwrap())])).await, "expired");
    // Starting again clears the ones that ran out.
    let _ = start("").await;
    assert_eq!(hub.store().settings_starting_with("connect:").await.unwrap().len(), 1);
}

#[tokio::test]
async fn a_hub_only_follows_an_installs_own_endpoints_when_connecting() {
    let hostile = install(
        Some(meta(
            "http://127.0.0.1:1/authorize",
            "http://169.254.169.254/token",
            "http://169.254.169.254/register",
            "[\"read\",\"manage\"]",
        )),
        "{\"client_id\":\"c1\"}",
        201,
    );
    let hub = hub(hostile.clone(), Arc::new(AtomicI64::new(START)), true).await;
    let e = refused(
        start_connect(&hub, Some(&Value::from("http://127.0.0.1:4100")), "https://hub.example/done", "").await,
        "endpoints",
    );
    assert!(e.message.contains("named endpoints on another address"));
    assert_eq!(hostile.requests.lock().unwrap().len(), 1, "nothing else was asked");
}

#[tokio::test]
async fn an_install_that_cannot_connect_says_why() {
    let now = || Arc::new(AtomicI64::new(START));
    let back = "http://hub.example/done";
    let hub_on = |router: Arc<Router>| hub(router, now(), true);
    refused(start_connect(&hub_on(default_install()).await, Some(&Value::from("ftp://x")), back, "").await, "url");
    let nothing = Arc::new(Router { routes: vec![], requests: Mutex::new(vec![]) });
    let e = refused(start_connect(&hub_on(nothing).await, Some(&Value::from(APP)), back, "").await, "unreachable");
    assert_eq!(e.params, vec![("host".to_string(), "127.0.0.1:4100".to_string())]);
    let not_runlight = install(Some("{\"hello\":\"world\"}".into()), "{}", 201);
    refused(start_connect(&hub_on(not_runlight).await, Some(&Value::from(APP)), back, "").await, "not_runlight");
    let old = install(
        Some(meta(
            &format!("{APP}/oauth/authorize"),
            &format!("{APP}/oauth/token"),
            &format!("{APP}/oauth/register"),
            "[\"read\"]",
        )),
        "{}",
        201,
    );
    refused(start_connect(&hub_on(old).await, Some(&Value::from(APP)), back, "").await, "old");
    // scopes_supported that is not a list is an older install too.
    let odd = install(
        Some(meta(
            &format!("{APP}/oauth/authorize"),
            &format!("{APP}/oauth/token"),
            &format!("{APP}/oauth/register"),
            "\"read manage\"",
        )),
        "{}",
        201,
    );
    refused(start_connect(&hub_on(odd).await, Some(&Value::from(APP)), back, "").await, "old");
    let e = refused(
        start_connect(
            &hub_on(install(None, "{\"error_description\":\"redirect_uris must use https\"}", 400)).await,
            Some(&Value::from(APP)),
            back,
            "",
        )
        .await,
        "register",
    );
    assert_eq!(
        e.params,
        vec![("url".to_string(), APP.to_string()), ("reason".to_string(), "redirect_uris must use https.".to_string())]
    );
    let e = refused(
        start_connect(&hub_on(install(None, "{\"nope\":true}", 400)).await, Some(&Value::from(APP)), back, "").await,
        "register",
    );
    assert_eq!(e.params[1].1, "This server's address must use https.");
    let e = refused(
        start_connect(&hub_on(install(None, "{\"nope\":true}", 500)).await, Some(&Value::from(APP)), back, "").await,
        "register",
    );
    assert_eq!(e.message, format!("{APP} would not let this server connect. It answered 500."));
}
