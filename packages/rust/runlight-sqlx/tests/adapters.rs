//! The routes behind tower and axum: the request read as the SDK's adapters read it, the answer
//! written back, a mount found from axum's nesting, and the body cap.

#![cfg(all(feature = "sqlite", feature = "postgres", feature = "mysql"))]

use axum::body::Body;
use http_body_util::BodyExt;
use runlight::{RoutesOptions, Runlight, RunlightOptions, SiteOptions, TokenOption};
use tower::ServiceExt;

async fn runlight() -> Runlight {
    let store = runlight_sqlx::connect(":memory:").await.unwrap();
    let mut options = RunlightOptions::new(store);
    options.site = Some(SiteOptions { hostnames: Some(vec!["example.com".into()]), ..SiteOptions::default() });
    Runlight::new(options).unwrap()
}

fn options() -> RoutesOptions {
    RoutesOptions { token: TokenOption::Given("secret-token".into()), ..RoutesOptions::default() }
}

async fn text(response: axum::response::Response) -> (u16, String, String) {
    let status = response.status().as_u16();
    let kind = response.headers().get("content-type").map(|v| v.to_str().unwrap().to_string()).unwrap_or_default();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, kind, String::from_utf8_lossy(&body).into_owned())
}

#[tokio::test]
async fn the_routes_answer_through_an_axum_router() {
    let rl = runlight().await;
    let routes = rl.routes(options()).unwrap();
    let app: axum::Router = axum::Router::new().merge(routes.router()).merge(rl.link_router());
    let request = http::Request::get("http://example.com/runlight/api")
        .header("authorization", "Bearer secret-token")
        .body(Body::empty())
        .unwrap();
    let (status, kind, body) = text(app.clone().oneshot(request).await.unwrap()).await;
    assert_eq!((status, kind.as_str()), (200, "application/json; charset=utf-8"));
    assert_eq!(body, r#"{"name":"runlight","version":"0.0.0","api":1,"library":"runlight","language":"rust"}"#);

    let hit = r#"{"k":"pageview","u":"https://example.com/","s":""}"#;
    let request = http::Request::post("http://example.com/runlight/e")
        .header("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15")
        .header("x-forwarded-for", "203.0.113.9")
        .body(Body::from(hit))
        .unwrap();
    assert_eq!(text(app.clone().oneshot(request).await.unwrap()).await.0, 202);
    let request = http::Request::get("http://example.com/runlight/api/stats?period=today")
        .header("authorization", "Bearer secret-token")
        .body(Body::empty())
        .unwrap();
    let (_, _, body) = text(app.clone().oneshot(request).await.unwrap()).await;
    assert!(body.contains(r#""visitors":1"#), "{body}");

    let request = http::Request::get("http://example.com/go/nope").body(Body::empty()).unwrap();
    assert_eq!(
        text(app.clone().oneshot(request).await.unwrap()).await,
        (404, "text/plain; charset=utf-8".into(), "Not found".into())
    );
}

#[tokio::test]
async fn a_nested_service_finds_its_mount_and_a_large_body_is_refused() {
    let rl = runlight().await;
    let routes = rl.routes(options()).unwrap();
    let app: axum::Router = axum::Router::new().nest_service("/runlight", routes);
    let request = http::Request::get("http://example.com/runlight/api")
        .header("authorization", "Bearer secret-token")
        .body(Body::empty())
        .unwrap();
    assert_eq!(text(app.clone().oneshot(request).await.unwrap()).await.0, 200);
    let request = http::Request::post("http://example.com/runlight/e").body(Body::from(vec![b'x'; 20_000])).unwrap();
    let (status, _, body) = text(app.oneshot(request).await.unwrap()).await;
    assert_eq!((status, body.as_str()), (413, r#"{"error":"That request is too large"}"#));
}
