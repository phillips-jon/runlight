//! The routes as a tower `Service`, for hyper, axum, and most Rust HTTP stacks (node.ts's adapter,
//! for Rust): the request read into a `runlight::http::Request`, with its body capped, and the answer
//! written back as an `http::Response`.

use std::convert::Infallible;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::Bytes;
use http_body::Body;
use http_body_util::{BodyExt, Full, Limited};

use crate::http::{Headers, Request, Response};
use crate::js;
use crate::routes::Routes;
use crate::runlight::Runlight;

/// The collect endpoint's limit; its payloads are under 8 KB.
const MAX_COLLECT_BODY: usize = 16 * 1024;
/// Everything else, such as a link import of 5,000 rows.
const MAX_BODY: usize = 10 * 1024 * 1024;

/// The client's address, when the server put it in the request's extensions as a `SocketAddr` or as
/// axum's `ConnectInfo`.
fn remote_address<B>(request: &http::Request<B>) -> String {
    #[cfg(feature = "axum")]
    if let Some(axum::extract::ConnectInfo(addr)) =
        request.extensions().get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
    {
        return addr.ip().to_string();
    }
    request.extensions().get::<std::net::SocketAddr>().map(|a| a.ip().to_string()).unwrap_or_default()
}

/// The URL as the request was sent, before a router took its mount off the path.
fn sent_uri<B>(request: &http::Request<B>) -> http::Uri {
    #[cfg(feature = "axum")]
    if let Some(axum::extract::OriginalUri(uri)) = request.extensions().get::<axum::extract::OriginalUri>() {
        return uri.clone();
    }
    request.uri().clone()
}

/// An `http::Request` as Runlight's, its body read whole up to the cap. `Err` is the answer when the
/// body is too large.
pub async fn to_request<B>(request: http::Request<B>) -> Result<Request, Response>
where
    B: Body + Send,
    B::Data: Send,
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    let uri = sent_uri(&request);
    let remote = remote_address(&request);
    let method = request.method().as_str().to_ascii_uppercase();
    let mut headers = Headers::new();
    for (name, value) in request.headers() {
        headers.append(name.as_str(), &String::from_utf8_lossy(value.as_bytes()));
    }
    let forwarded = headers.get("x-forwarded-proto").unwrap_or_default();
    let proto = js::trim(forwarded.split(',').next().unwrap_or("")).to_lowercase();
    let proto = if proto.is_empty() { uri.scheme_str().unwrap_or("http").to_lowercase() } else { proto };
    let host =
        headers.get("host").or_else(|| uri.authority().map(|a| a.to_string())).unwrap_or_else(|| "localhost".into());
    let target = uri.path_and_query().map_or("/", |p| p.as_str()).to_string();
    let base = format!("{}://{host}", if proto == "https" { "https" } else { "http" });
    let url =
        crate::http::Url::parse_with_base(&target, &base).map_or_else(|| "http://localhost/".to_string(), |u| u.href());
    let mut body = Vec::new();
    if method != "GET" && method != "HEAD" {
        let limit = if uri.path().ends_with("/e") { MAX_COLLECT_BODY } else { MAX_BODY };
        match Limited::new(request.into_body(), limit).collect().await {
            Ok(collected) => body = collected.to_bytes().to_vec(),
            Err(_) => {
                // An upload cut off part way leaves the connection unfit for another request.
                return Err(Response::new(
                    crate::obj! { "error" => "That request is too large" }.to_json(),
                    413,
                    Headers::new().with("connection", "close").with("content-type", "application/json; charset=utf-8"),
                ));
            }
        }
    }
    Ok(Request { url, method, headers, body, remote_address: remote })
}

/// Runlight's answer as an `http::Response`.
pub fn to_http(response: Response) -> http::Response<Full<Bytes>> {
    let mut builder = http::Response::builder().status(response.status);
    for (name, values) in response.headers.all() {
        for value in values {
            builder = builder.header(name.as_str(), value.as_str());
        }
    }
    builder.body(Full::new(Bytes::from(response.body))).unwrap_or_else(|_| {
        let mut r = http::Response::new(Full::new(Bytes::new()));
        *r.status_mut() = http::StatusCode::INTERNAL_SERVER_ERROR;
        r
    })
}

type Answer = Pin<Box<dyn Future<Output = Result<http::Response<Full<Bytes>>, Infallible>> + Send>>;

impl<B> tower_service::Service<http::Request<B>> for Routes
where
    B: Body + Send + 'static,
    B::Data: Send,
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    type Response = http::Response<Full<Bytes>>;
    type Error = Infallible;
    type Future = Answer;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, request: http::Request<B>) -> Self::Future {
        let routes = self.clone();
        Box::pin(async move {
            Ok(to_http(match to_request(request).await {
                Ok(request) => routes.handle(request).await,
                Err(refused) => refused,
            }))
        })
    }
}

/// Short links on the app's own domain, `{link_path}/{slug}`, as a tower `Service`.
#[derive(Clone)]
pub struct LinkService(pub Runlight);

impl<B> tower_service::Service<http::Request<B>> for LinkService
where
    B: Body + Send + 'static,
    B::Data: Send,
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    type Response = http::Response<Full<Bytes>>;
    type Error = Infallible;
    type Future = Answer;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, request: http::Request<B>) -> Self::Future {
        let runlight = self.0.clone();
        Box::pin(async move {
            let answer = match to_request(request).await {
                Ok(request) => runlight.link_response(&request).await.unwrap_or_else(|error| {
                    eprintln!("Runlight: {error}");
                    Response::new("Not found", 404, Headers::new().with("content-type", "text/plain; charset=utf-8"))
                }),
                Err(refused) => refused,
            };
            Ok(to_http(answer))
        })
    }
}

impl Runlight {
    /// Short links on the app's own domain as a tower `Service`: mount it at `{link_path}/{slug}`.
    pub fn link_service(&self) -> LinkService {
        LinkService(self.clone())
    }
}

/// axum: the routes mounted at their base path and the short links at their link path, as one
/// `Router` to merge into the app's. Link domains and AI agent fetches go through `middleware`.
#[cfg(feature = "axum")]
pub mod axum_support {
    use super::*;

    impl Routes {
        /// A `Router` serving the routes at their base path (and, at the root, the OAuth discovery
        /// documents an app may route here).
        pub fn router<S: Clone + Send + Sync + 'static>(&self) -> axum::Router<S> {
            let base = self.base_path().to_string();
            let mut router = axum::Router::new();
            if base.is_empty() {
                return router.fallback_service(self.clone());
            }
            router =
                router.route_service(&base, self.clone()).route_service(&format!("{base}/{{*path}}"), self.clone());
            router
        }
    }

    impl Runlight {
        /// A `Router` serving short links at `{link_path}/{slug}`.
        pub fn link_router<S: Clone + Send + Sync + 'static>(&self) -> axum::Router<S> {
            axum::Router::new().route_service(&format!("{}/{{slug}}", self.link_path()), self.link_service())
        }
    }

    /// Middleware for every request: answers a link domain's requests with its redirects, and records
    /// AI agent fetches of the app's pages. Use with `axum::middleware::from_fn_with_state`.
    pub async fn middleware(
        axum::extract::State(runlight): axum::extract::State<Runlight>,
        request: axum::extract::Request,
        next: axum::middleware::Next,
    ) -> axum::response::Response {
        let (parts, body) = request.into_parts();
        let head = http::Request::from_parts(parts.clone(), http_body_util::Empty::<Bytes>::new());
        if let Ok(probe) = to_request(head).await {
            if let Ok(Some(answer)) = runlight.link_domain_response(&probe).await {
                let (p, b) = to_http(answer).into_parts();
                return axum::response::Response::from_parts(p, axum::body::Body::new(b));
            }
            if probe.method == "GET" {
                let observer = runlight.clone();
                tokio::spawn(async move {
                    observer.observe(&probe, None).await;
                });
            }
        }
        next.run(axum::extract::Request::from_parts(parts, body)).await
    }
}
