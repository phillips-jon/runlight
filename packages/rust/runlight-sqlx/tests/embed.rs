//! The dashboard inside a CMS's admin pages: embed keys, tickets, framing, and sessions, as
//! RoutesTest.php tests them, and the store's take_setting on every database at hand.

mod common;

use runlight::http::{Request, Response};
use runlight::js::Value;
use runlight::{Routes, RoutesOptions, Runlight, RunlightOptions, SiteOptions, TokenOption};

const APP: &str = "http://localhost:4000";

fn site(id: &str, host: &str) -> SiteOptions {
    SiteOptions {
        id: Some(id.into()),
        name: Some(format!("Site {}", id.to_uppercase())),
        hostnames: Some(vec![host.into()]),
        timezone: Some("UTC".into()),
    }
}

async fn routes() -> Routes {
    let mut options = RunlightOptions::new(runlight_sqlx::connect(":memory:").await.unwrap());
    options.sites = Some(vec![site("a", "a.com"), site("b", "b.com")]);
    let rl = Runlight::new(options).unwrap();
    rl.routes(RoutesOptions { token: TokenOption::Given("secret".into()), ..RoutesOptions::default() }).unwrap()
}

fn owner(method: &str, path: &str, body: &str, bearer: &str) -> Request {
    Request::new(method, format!("{APP}{path}"))
        .header("authorization", format!("Bearer {bearer}"))
        .header("content-type", "application/json")
        .body(body.to_string())
}

fn get(path: &str, headers: &[(&str, &str)]) -> Request {
    headers.iter().fold(Request::get(format!("{APP}{path}")), |r, (k, v)| r.header(k, v))
}

fn body(response: &Response) -> Value {
    response.json_body().unwrap()
}

fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

#[tokio::test]
async fn the_dashboard_inside_a_cms_opens_one_framed_page_once_whose_session_reads_one_site() {
    let routes = routes().await;
    let made = body(
        &routes
            .handle(owner("POST", "/runlight/api/tokens", r#"{"name":"CMS","site":"a","scope":"embed"}"#, "secret"))
            .await,
    );
    let secret = text(&made, "secret");
    let token_id = text(made.get("token").unwrap(), "id");
    assert_eq!(text(made.get("token").unwrap(), "scope"), "embed");
    let mint = |origin: &str| owner("POST", "/runlight/api/embed", &format!(r#"{{"origin":"{origin}"}}"#), &secret);
    assert_eq!(routes.handle(mint("https://b.com")).await.status, 400, "only an origin on the site's own domains");
    let minted = routes.handle(mint("https://www.a.com")).await;
    assert_eq!(minted.status, 201);
    let minted = body(&minted);
    let (ticket, path) = (text(&minted, "ticket"), text(&minted, "path"));
    assert_eq!(text(&minted, "site"), "a");
    assert_eq!(path, format!("/runlight/embed?ticket={ticket}"));
    assert!(!ticket.contains(&token_id), "a ticket never names its token");

    let page = routes.handle(get(&path, &[])).await;
    assert_eq!(page.status, 200);
    assert!(page.headers.get("content-security-policy").unwrap().ends_with("frame-ancestors https://www.a.com"));
    assert_eq!(page.headers.get("x-frame-options"), None);
    assert_eq!(page.headers.get("referrer-policy").as_deref(), Some("no-referrer"));
    let html = page.text();
    let start = html.find("data-embed=\"").expect("a session") + "data-embed=\"".len();
    let session = html[start..start + html[start..].find('"').unwrap()].to_string();
    let parts: Vec<&str> = session.split('.').collect();
    assert_eq!(parts.len(), 3);
    assert!(parts[0].chars().all(|c| c.is_ascii_digit()));
    assert!(parts[1].len() == 24 && parts[2].len() == 64);
    let again = routes.handle(get(&path, &[])).await;
    assert_eq!(again.status, 410, "a ticket works once");
    assert!(
        again.headers.get("content-security-policy").unwrap().ends_with("frame-ancestors https://www.a.com"),
        "a used ticket still says so inside its frame"
    );

    let read = routes.handle(get("/runlight/api/stats?site=b", &[("x-runlight-embed", &session)])).await;
    assert_eq!(text(&body(&read), "site"), "a", "pinned to its token's site whatever is asked");
    let links =
        get("/runlight/api/links?site=a", &[("x-runlight-embed", &session), ("authorization", "Bearer secret")]);
    assert_eq!(routes.handle(links).await.status, 403, "nothing a share cannot read, even beside the owner's token");
    assert_eq!(
        routes.handle(get("/runlight/", &[])).await.headers.get("x-frame-options").as_deref(),
        Some("DENY"),
        "every other page still refuses to be framed"
    );
    let reads = routes.handle(get("/runlight/api/stats", &[("authorization", &format!("Bearer {secret}"))])).await;
    assert_eq!(reads.status, 403, "the key itself reads nothing");

    let gone = routes.handle(owner("DELETE", &format!("/runlight/api/tokens/{token_id}"), "", "secret")).await;
    assert_eq!(gone.status, 200);
    let after = routes.handle(get("/runlight/api/stats", &[("x-runlight-embed", &session)])).await;
    assert_eq!(after.status, 401, "deleting the token ends its sessions at once");
}

#[tokio::test]
async fn a_setting_can_be_taken_once() {
    for (kind, url) in common::kinds() {
        let fresh = common::fresh(kind, &url).await;
        let store = fresh.store.clone();
        store.migrate().await.unwrap();
        store.set_setting("x", Some("1")).await.unwrap();
        assert_eq!(store.take_setting("x").await.unwrap().as_deref(), Some("1"), "{kind}");
        assert_eq!(store.take_setting("x").await.unwrap(), None, "{kind}");
        assert_eq!(store.setting("x").await.unwrap(), None, "{kind}");
        fresh.done().await;
    }
}
