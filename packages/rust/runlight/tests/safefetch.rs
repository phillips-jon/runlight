//! Fetches that stay on the public internet, and site icons over them: the
//! cases of the PHP port's SafefetchTest and IconTest, and the address checks
//! and icon links in outbound.json.

mod common;

use std::net::IpAddr;
use std::sync::{Arc, Mutex};

use common::{fixture, list, s};
use runlight::BoxFuture;
use runlight::http::{FetchError, FetchInit, Fetcher, Headers, Response};
use runlight::icon::{Icon, fetch_icon, icon_links};
use runlight::safefetch::{
    Lookup, PrivateAddressError, PublicFetchError, PublicFetchInit, public_address, public_addresses, public_fetch,
    resolves_privately,
};

type Answer = Box<dyn Fn(&str) -> Result<Response, FetchError> + Send + Sync>;

/// A Fetcher that answers from a function and remembers what it was asked.
struct Fake {
    answer: Answer,
    seen: Mutex<Vec<(String, FetchInit)>>,
}

impl Fake {
    fn new(answer: impl Fn(&str) -> Result<Response, FetchError> + Send + Sync + 'static) -> Arc<Fake> {
        Arc::new(Fake { answer: Box::new(answer), seen: Mutex::new(Vec::new()) })
    }

    fn urls(&self) -> Vec<String> {
        self.seen.lock().unwrap().iter().map(|(u, _)| u.clone()).collect()
    }

    fn init(&self, i: usize) -> FetchInit {
        self.seen.lock().unwrap()[i].1.clone()
    }
}

impl Fetcher for Fake {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        self.seen.lock().unwrap().push((url.to_string(), init));
        let out = (self.answer)(url);
        Box::pin(async move { out })
    }
}

/// Answers in turn, then "end".
fn hops(answers: Vec<Response>) -> Arc<Fake> {
    let queue = Mutex::new(answers);
    Fake::new(move |_| {
        let mut q = queue.lock().unwrap();
        Ok(if q.is_empty() { Response::new("end", 200, Headers::new()) } else { q.remove(0) })
    })
}

fn redirect(location: &str, status: u16) -> Response {
    Response::status(status).header("location", location)
}

/// A DNS stand-in.
fn dns(names: &[(&str, &[&str])]) -> Lookup {
    let names: Vec<(String, Vec<String>)> =
        names.iter().map(|(n, a)| (n.to_string(), a.iter().map(|s| s.to_string()).collect())).collect();
    Arc::new(move |name: &str| {
        let found = names.iter().find(|(n, _)| n == name).map(|(_, a)| a.clone()).unwrap_or_default();
        Box::pin(async move { found }) as BoxFuture<'static, Vec<String>>
    })
}

fn init(timeout_ms: u64, lookup: &Lookup) -> PublicFetchInit {
    PublicFetchInit { lookup: Some(lookup.clone()), ..PublicFetchInit::new(timeout_ms) }
}

fn private(what: &str) -> PublicFetchError {
    PublicFetchError::Private(PrivateAddressError(what.to_string()))
}

#[test]
fn only_addresses_on_the_public_internet_count_as_public() {
    for ip in ["93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e"] {
        assert!(public_address(ip), "{ip}");
    }
    for ip in [
        "127.0.0.1",
        "10.0.0.1",
        "172.16.5.4",
        "192.168.1.1",
        "169.254.169.254",
        "100.64.0.1",
        "0.0.0.0",
        "224.0.0.1",
        "255.255.255.255",
        "::1",
        "::",
        "fe80::1",
        "fd00::1",
        "ff02::1",
        "::ffff:127.0.0.1",
        "::ffff:7f00:1",
        "::ffff:169.254.169.254",
        "64:ff9b::a00:1",
        "2002:a00:1::",
        "2001:db8::1",
        "2001:0:4136:e378::1",
        "[::1]",
        "not an address",
        "1.2.3",
        "1.2.3.256",
    ] {
        assert!(!public_address(ip), "{ip}");
    }
}

#[test]
fn address_checks_match_typescript() {
    let f = fixture("outbound");
    let cases = list(&f, "ips");
    assert!(cases.len() > 50);
    for case in cases {
        assert_eq!(public_address(s(case, "ip")), case.at("public").as_bool().unwrap(), "{}", s(case, "ip"));
    }
}

#[tokio::test]
async fn a_public_fetch_never_reaches_the_installs_own_network_however_the_address_is_written() {
    // Something listening locally, which none of these may reach.
    let inside = (5440..5450).find_map(|p| std::net::TcpListener::bind(("127.0.0.1", p)).ok()).expect("a free port");
    inside.set_nonblocking(true).unwrap();
    let port = inside.local_addr().unwrap().port();
    let fetcher = runlight::http::default_fetcher();
    for url in [
        format!("http://127.0.0.1:{port}/"),
        format!("https://127.0.0.1:{port}/"),
        format!("https://[::1]:{port}/"),
        format!("https://[::ffff:127.0.0.1]:{port}/"),
        format!("https://localhost:{port}/"),
        format!("https://LOCALHOST.:{port}/"),
        format!("https://app.localhost:{port}/"),
    ] {
        match public_fetch(fetcher.as_ref(), &url, &PublicFetchInit::new(2000)).await {
            Err(PublicFetchError::Private(_)) => {}
            other => panic!("{url} should be refused: {other:?}"),
        }
    }
    assert!(inside.accept().is_err(), "nothing connected");
    assert!(resolves_privately("localhost", None).await);
    assert!(!resolves_privately("name.that.does.not.resolve.invalid", None).await);
    assert!(public_addresses("name.that.does.not.resolve.invalid", None).await.is_empty());
    assert_eq!(public_addresses("8.8.8.8", None).await, vec!["8.8.8.8"]);
    assert!(public_addresses("localhost", None).await.is_empty());
}

#[tokio::test]
async fn the_checked_addresses_are_pinned() {
    let fetcher = Fake::new(|_| Ok(Response::new("ok", 200, Headers::new())));
    let lookup = dns(&[("example.com", &["93.184.215.14", "2606:4700::1111"])]);
    let options = PublicFetchInit {
        headers: Headers::new().with("user-agent", "Runlight"),
        max_bytes: Some(10),
        ..init(2000, &lookup)
    };
    let answer = public_fetch(fetcher.as_ref(), "https://Example.com/icon", &options).await.unwrap();
    assert_eq!(answer.text(), "ok");
    let first = fetcher.init(0);
    let ips: Vec<IpAddr> = vec!["93.184.215.14".parse().unwrap(), "2606:4700::1111".parse().unwrap()];
    assert_eq!(first.resolve, vec![("example.com".to_string(), 443, ips)]);
    assert!(first.manual_redirect);
    assert_eq!(first.max_bytes, Some(10));
    assert_eq!(first.method, "GET");
    assert_eq!(first.headers.get("user-agent").as_deref(), Some("Runlight"));
    assert!(first.timeout_ms <= 2000);
    assert_eq!(fetcher.urls(), vec!["https://example.com/icon"]);

    let literal = Fake::new(|_| Ok(Response::new("ok", 200, Headers::new())));
    public_fetch(literal.as_ref(), "https://93.184.215.14:8443/", &init(2000, &dns(&[]))).await.unwrap();
    assert!(literal.init(0).resolve.is_empty(), "an address needs no pin");
}

#[tokio::test]
async fn a_name_with_any_private_address_is_refused() {
    let fetcher = Fake::new(|_| Ok(Response::new("ok", 200, Headers::new())));
    for (name, addresses) in [
        ("inside.example", &["10.0.0.5"][..]),
        ("mixed.example", &["93.184.215.14", "169.254.169.254"][..]),
        ("mapped.example", &["::ffff:127.0.0.1"][..]),
    ] {
        let lookup = dns(&[(name, addresses)]);
        let err = public_fetch(fetcher.as_ref(), &format!("https://{name}/"), &init(2000, &lookup)).await.unwrap_err();
        assert_eq!(err.to_string(), format!("{name} is not a public address"));
    }
    assert!(fetcher.urls().is_empty());
    let err = public_fetch(fetcher.as_ref(), "https://nowhere.example/", &init(2000, &dns(&[]))).await.unwrap_err();
    assert_eq!(err, PublicFetchError::Fetch(FetchError::Failed("getaddrinfo ENOTFOUND nowhere.example".into())));
}

#[tokio::test]
async fn redirects_are_followed_by_hand_under_the_same_rules() {
    let lookup =
        dns(&[("a.example", &["93.184.215.14"]), ("b.example", &["1.1.1.1"]), ("inside.example", &["192.168.0.2"])]);
    let three = PublicFetchInit { redirects: 3, ..init(2000, &lookup) };

    let fetcher = hops(vec![
        redirect("/next", 301),
        redirect("https://b.example/last", 302),
        Response::new("done", 200, Headers::new()),
    ]);
    let answer = public_fetch(fetcher.as_ref(), "https://a.example/", &three).await.unwrap();
    assert_eq!(answer.text(), "done");
    assert_eq!(fetcher.urls(), vec!["https://a.example/", "https://a.example/next", "https://b.example/last"]);
    assert_eq!(
        fetcher.init(2).resolve,
        vec![("b.example".to_string(), 443, vec!["1.1.1.1".parse::<IpAddr>().unwrap()])]
    );

    let fetcher = hops(vec![redirect("https://b.example/", 302)]);
    let answer = public_fetch(fetcher.as_ref(), "https://a.example/", &init(2000, &lookup)).await.unwrap();
    assert_eq!(answer.status, 302, "a redirect past the last comes back as it is");

    for (location, what) in [
        ("https://10.0.0.1/", "10.0.0.1"),
        ("https://inside.example/", "inside.example"),
        ("http://b.example/", "http://b.example/"),
        ("https://[fe80::1]/", "fe80::1"),
    ] {
        let fetcher = hops(vec![redirect(location, 302)]);
        let err = public_fetch(fetcher.as_ref(), "https://a.example/", &three).await.unwrap_err();
        assert_eq!(err, private(what), "{location}");
        assert_eq!(err.to_string(), format!("{what} is not a public address"));
    }
}

#[tokio::test]
async fn running_out_of_time_says_so() {
    let lookup = dns(&[("a.example", &["1.1.1.1"])]);
    let fetcher = Fake::new(|_| Err(FetchError::TimedOut));
    let err = public_fetch(fetcher.as_ref(), "https://a.example/", &init(2000, &lookup)).await.unwrap_err();
    assert_eq!(err, PublicFetchError::Fetch(FetchError::TimedOut));
    assert_eq!(err.to_string(), "The operation was aborted due to timeout");

    let refused = Fake::new(|_| Err(FetchError::Failed("Connection refused".into())));
    let err = public_fetch(refused.as_ref(), "https://a.example/", &init(2000, &lookup)).await.unwrap_err();
    assert_eq!(err.to_string(), "Connection refused");

    // A Fetcher that never answers is cut off at the time limit.
    struct Hangs;
    impl Fetcher for Hangs {
        fn fetch<'a>(&'a self, _: &'a str, _: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
            Box::pin(std::future::pending())
        }
    }
    let started = std::time::Instant::now();
    let err = public_fetch(&Hangs, "https://a.example/", &init(50, &lookup)).await.unwrap_err();
    assert_eq!(err, PublicFetchError::Fetch(FetchError::TimedOut));
    assert!(started.elapsed().as_millis() < 1000);
}

#[test]
fn icon_links_match_typescript() {
    let f = fixture("outbound");
    let cases = list(&f, "icons");
    assert!(!cases.is_empty());
    for case in cases {
        let want: Vec<String> = list(case, "links").iter().map(|v| v.as_str().unwrap().to_string()).collect();
        assert_eq!(icon_links(s(case, "html"), s(case, "base")), want, "{}", s(case, "html"));
    }
}

#[test]
fn icon_links_read_attributes_as_javascript_does() {
    // As the TypeScript reads it (checked against Node): data-rel is a name of its own, so the first
    // link is an icon; a quote that never closes starts an unquoted value; names, spaces around the
    // equals sign, and the tag itself are matched in any case.
    let html = "<link data-rel=\"stylesheet\" rel=\"icon\" href=/a.png\u{a0}x><link rel='apple-touch-icon' href=\"/t.png><LINK\nREL = ICON HREF = '/b.svg' >";
    assert_eq!(
        icon_links(html, "https://example.com"),
        vec!["https://example.com/%22/t.png", "https://example.com/b.svg", "https://example.com/a.png"]
    );
    // A name with an equals sign and no value reads as empty.
    assert!(icon_links("<link rel = \"icon\" href= >", "https://example.com").is_empty());
    // Unquoted values stop at JavaScript's whitespace, which includes a no-break space.
    assert_eq!(
        icon_links("<link rel=icon href=/a.png\u{a0}x>", "https://example.com"),
        vec!["https://example.com/a.png"]
    );
}

fn html(body: &str) -> Response {
    Response::new(body, 200, Headers::new().with("content-type", "text/html; charset=utf-8"))
}

#[tokio::test]
async fn the_best_linked_icon_is_fetched_with_its_caps() {
    // An address as the origin, so no name is looked up.
    let origin = "https://93.184.215.14";
    let fetcher = Fake::new(|url| {
        Ok(match url {
            "https://93.184.215.14/" => {
                html("<link rel=\"apple-touch-icon\" href=\"/touch.png\"><link rel=\"icon\" href=\"/i.svg\">")
            }
            "https://93.184.215.14/touch.png" => {
                Response::new("<html>", 200, Headers::new().with("content-type", "text/html"))
            }
            "https://93.184.215.14/i.svg" => {
                Response::new("<svg/>", 200, Headers::new().with("content-type", "Image/SVG+xml; charset=utf-8"))
            }
            _ => Response::new("", 404, Headers::new()),
        })
    });
    let now = 1_791_471_600_000;
    let icon = fetch_icon(fetcher.as_ref(), origin, now).await;
    assert_eq!(icon, Some(Icon { body: b"<svg/>".to_vec(), content_type: "image/svg+xml".into() }));
    assert_eq!(
        fetcher.urls(),
        vec!["https://93.184.215.14/", "https://93.184.215.14/touch.png", "https://93.184.215.14/i.svg"]
    );
    let page = fetcher.init(0);
    assert_eq!((page.max_bytes, page.truncate), (Some(200_000), true));
    let image = fetcher.init(1);
    assert_eq!((image.max_bytes, image.truncate), (Some(262_144), false), "an image must arrive whole");
    assert_eq!(page.headers.get("user-agent").as_deref(), Some("Runlight (+https://runlight.sh)"));
    assert!(page.timeout_ms <= 4000);

    // Cached for a day.
    assert_eq!(fetch_icon(fetcher.as_ref(), origin, now + 86_399_000).await, icon);
    assert_eq!(fetcher.urls().len(), 3);
    fetch_icon(fetcher.as_ref(), origin, now + 86_400_000).await;
    assert_eq!(fetcher.urls().len(), 6, "and looked up again after it");
}

#[tokio::test]
async fn favicon_is_the_fallback_and_no_icon_is_remembered_for_an_hour() {
    let origin = "https://1.1.1.1";
    let fetcher = Fake::new(|url| {
        Ok(if url == "https://1.1.1.1/favicon.ico" {
            Response::new("", 200, Headers::new().with("content-type", "image/x-icon"))
        } else {
            Response::new("nope", 500, Headers::new())
        })
    });
    let now = 1_791_471_600_000;
    assert_eq!(fetch_icon(fetcher.as_ref(), origin, now).await, None, "an empty image is no icon");
    assert_eq!(fetcher.urls(), vec!["https://1.1.1.1/", "https://1.1.1.1/favicon.ico"]);
    assert_eq!(fetch_icon(fetcher.as_ref(), origin, now + 3_599_000).await, None);
    assert_eq!(fetcher.urls().len(), 2);
    fetch_icon(fetcher.as_ref(), origin, now + 3_600_000).await;
    assert_eq!(fetcher.urls().len(), 4);
}

#[tokio::test]
async fn an_image_too_long_or_declared_too_long_is_no_icon() {
    let origin = "https://8.8.4.4";
    let fetcher = Fake::new(|url| {
        Ok(match url {
            "https://8.8.4.4/" => html("<link rel=icon href=/big.png><link rel=icon href=/said.png>"),
            "https://8.8.4.4/said.png" => Response::new(
                "x",
                200,
                Headers::new().with("content-type", "image/png").with("content-length", " 300000 "),
            ),
            "https://8.8.4.4/favicon.ico" => {
                Response::new("ico", 200, Headers::new().with("content-type", "image/x-icon"))
            }
            _ => return Err(FetchError::TooLong(262_144)),
        })
    });
    let icon = fetch_icon(fetcher.as_ref(), origin, 0).await;
    assert_eq!(icon, Some(Icon { body: b"ico".to_vec(), content_type: "image/x-icon".into() }));
    assert_eq!(
        fetcher.urls(),
        vec!["https://8.8.4.4/", "https://8.8.4.4/big.png", "https://8.8.4.4/said.png", "https://8.8.4.4/favicon.ico"]
    );
}

#[tokio::test]
async fn a_private_origin_is_never_fetched() {
    let fetcher = Fake::new(|_| Ok(Response::new("x", 200, Headers::new().with("content-type", "image/png"))));
    assert_eq!(fetch_icon(fetcher.as_ref(), "https://192.168.1.1", 0).await, None);
    assert!(fetcher.urls().is_empty());
}

#[tokio::test]
async fn dashboards_opening_at_once_share_one_lookup() {
    struct Slow(Mutex<usize>);
    impl Fetcher for Slow {
        fn fetch<'a>(&'a self, url: &'a str, _: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
            *self.0.lock().unwrap() += 1;
            let ico = url.ends_with("/favicon.ico");
            Box::pin(async move {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                Ok(if ico {
                    Response::new("i", 200, Headers::new().with("content-type", "image/x-icon"))
                } else {
                    Response::new("", 404, Headers::new())
                })
            })
        }
    }
    let fetcher = Slow(Mutex::new(0));
    let (a, b) = tokio::join!(fetch_icon(&fetcher, "https://9.9.9.9", 0), fetch_icon(&fetcher, "https://9.9.9.9", 0));
    assert_eq!(a, b);
    assert!(a.is_some());
    assert_eq!(*fetcher.0.lock().unwrap(), 2, "the page and the favicon, once");
}
