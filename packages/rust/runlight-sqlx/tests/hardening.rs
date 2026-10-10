//! Hardening as hardening.test.ts tests it: trust_proxy left at its default with nothing in front.

use runlight::http::Request;
use runlight::{Runlight, RunlightOptions, SiteOptions, TrustProxy};

async fn runlight(trust_proxy: Option<TrustProxy>) -> Runlight {
    let mut options = RunlightOptions::new(runlight_sqlx::connect(":memory:").await.unwrap());
    options.site = Some(SiteOptions { hostnames: Some(vec!["example.com".into()]), ..SiteOptions::default() });
    options.trust_proxy = trust_proxy;
    Runlight::new(options).unwrap()
}

fn from(ip: &str) -> Request {
    let mut request = Request::get("https://example.com/e");
    request.remote_address = ip.into();
    request
}

#[tokio::test]
async fn with_trust_proxy_left_at_its_default_a_public_address_with_no_proxy_header_is_warned_about_once() {
    let quiet = runlight(Some(TrustProxy::On)).await;
    assert_eq!(quiet.client_ip(&from("8.8.8.8")), "8.8.8.8");
    assert_eq!(quiet.direct_warnings(), 0, "trust_proxy set on purpose is never second-guessed");

    let rl = runlight(None).await;
    rl.client_ip(&from("10.0.0.2").header("x-forwarded-for", "8.8.4.4"));
    rl.client_ip(&from("127.0.0.1"));
    rl.client_ip(&from("192.168.1.5"));
    assert_eq!(rl.direct_warnings(), 0, "a proxy's header, or a private or loopback address, says nothing");
    assert_eq!(rl.client_ip(&from("8.8.8.8")), "8.8.8.8");
    rl.client_ip(&from("1.1.1.1"));
    assert_eq!(rl.direct_warnings(), 1, "said once");
}
