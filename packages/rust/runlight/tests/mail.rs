//! Ports mail.test.ts, and replays packages/php/tests/fixtures/outbound.json:
//! every service sends the TypeScript SDK's exact requests, SigV4 signs as it
//! does, MIME is written byte for byte, a fake SMTP relay receives the same
//! conversation, and keys sealed by TypeScript open here.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::{fixture, list, s};
use runlight::http::{FetchError, FetchInit, Fetcher, Response, SharedFetcher, Url};
use runlight::js::{self, Object, Value};
use runlight::mail::ses::{SignInput, sign_v4};
use runlight::mail::smtp::{mime, smtp_send};
use runlight::mail::transports::services_value;
use runlight::mail::{MailConfig, MailError, Message, SERVICES, check_config, seal, send, service_message, unseal};
use runlight::{BoxFuture, obj};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

const NOW: i64 = 1_791_471_845_678;

fn message() -> Message {
    Message {
        to: "jon@example.com".into(),
        from: "reports@example.com".into(),
        from_name: Some("Runlight".into()),
        subject: "Hello".into(),
        html: "<p>Hi</p>".into(),
        text: "Hi".into(),
        headers: vec![("List-Unsubscribe".into(), "<https://x/u>".into())],
    }
}

fn config(v: Value) -> MailConfig {
    v.as_object().cloned().expect("a config is an object")
}

/// A UUID stand-in that counts from 1, as the fixture script's does.
fn uuids() -> impl FnMut() -> String + Send {
    let mut n = 0;
    move || {
        n += 1;
        format!("00000000-0000-4000-8000-{n:012}")
    }
}

fn error_value(e: &MailError) -> Value {
    obj! { "message" => e.message.as_str(), "code" => e.code.as_str(), "params" => e.params_value() }
}

/// What a fake service answers.
#[derive(Clone)]
enum Answer {
    Reply(u16, String),
    Unreachable,
}

/// A Fetcher that records each request as the fixture script does and gives one answer.
struct Recorder {
    answer: Answer,
    requests: Mutex<Vec<Value>>,
    timeouts: AtomicUsize,
}

impl Recorder {
    fn new(answer: Answer) -> Arc<Recorder> {
        Arc::new(Recorder { answer, requests: Mutex::new(Vec::new()), timeouts: AtomicUsize::new(0) })
    }

    fn requests(&self) -> Vec<Value> {
        self.requests.lock().unwrap().clone()
    }
}

impl Fetcher for Recorder {
    fn fetch<'a>(&'a self, url: &'a str, init: FetchInit) -> BoxFuture<'a, Result<Response, FetchError>> {
        Box::pin(async move {
            let mut headers = Object::new();
            for (k, v) in init.headers.entries() {
                headers.set(k, v);
            }
            self.timeouts.store(init.timeout_ms as usize, Ordering::SeqCst);
            self.requests.lock().unwrap().push(obj! {
                "method" => init.method.as_str(),
                "url" => url,
                "headers" => headers,
                "body" => String::from_utf8(init.body.unwrap_or_default()).unwrap(),
            });
            match &self.answer {
                Answer::Unreachable => Err(FetchError::Failed("fetch failed".into())),
                Answer::Reply(status, body) => Ok(Response::new(body.clone(), *status, Default::default())),
            }
        })
    }
}

fn shared(r: &Arc<Recorder>) -> SharedFetcher {
    r.clone()
}

#[test]
fn sealed_keys_open_only_with_the_same_secret() {
    let sealed = seal(r#"{"apiKey":"re_123"}"#, Some("server secret"));
    assert!(sealed.starts_with("v1:") && !sealed.contains("re_123"));
    assert_eq!(unseal(&sealed, Some("server secret")).as_deref(), Some(r#"{"apiKey":"re_123"}"#));
    assert_eq!(unseal(&sealed, Some("another secret")), None);
    assert_eq!(seal("x", None), "plain:x");
    assert_eq!(seal("x", Some("")), "plain:x", "an empty secret is no secret");
    assert_eq!(unseal(&seal("x", None), None).as_deref(), Some("x"), "with no secret the value is kept as typed");
    assert_eq!(unseal("v1:AAAA:AAAA", Some("server secret")), None, "damaged");
    assert_eq!(unseal("v2:a:b", Some("server secret")), None);
    assert_eq!(unseal("v1::b", Some("server secret")), None);
    assert_eq!(unseal("v1:a!:b", Some("server secret")), None, "not base64");
    assert_eq!(unseal(&sealed, None), None);
    assert_eq!(unseal(&sealed, Some("")), None);
}

#[test]
fn keys_sealed_by_typescript_open_here() {
    let f = fixture("outbound");
    let cases = list(&f, "sealed");
    assert_eq!(cases.len(), 5);
    for case in cases {
        let (secret, sealed) = (s(case, "secret"), s(case, "sealed"));
        let Some(value) = case.at("value").as_str() else {
            // A sealed form TypeScript cannot open (an IV under 12 bytes), so there is nothing to seal again.
            assert_eq!(unseal(sealed, Some(secret)), None, "{sealed}");
            continue;
        };
        assert_eq!(unseal(sealed, Some(secret)).as_deref(), Some(value));
        assert_eq!(unseal(sealed, Some(&format!("{secret}!"))), None);
        assert_eq!(unseal(&seal(value, Some(secret)), Some(secret)).as_deref(), Some(value));
        // Padding left off and whitespace added still open, as atob reads them.
        let loose = sealed.trim_end_matches('=').replace(':', ": ");
        let loose = loose.replacen("v1: ", "v1:", 1);
        assert_eq!(unseal(&loose, Some(secret)).as_deref(), Some(value));
    }
}

#[test]
fn a_key_sealed_here_opens_in_typescript() {
    // Sealed by this port (with a random IV, so the vector is fixed here) and opened by
    // packages/sdk/src/mail/secret.ts's unseal under Node 24.
    let sealed = "v1:Inu7sTk524sGkNO+:Iju8mx4oZrMSa0efPlTl6zC2V/9PNTRMGSUBMexhAe4ChKRCzOA4528=";
    assert_eq!(unseal(sealed, Some("rust secret")).as_deref(), Some("café 😀 sealed by Rust"));
}

#[test]
fn sig_v4_matches_aws_published_example() {
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html (the IAM ListUsers example)
    let url = Url::parse("https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08").unwrap();
    let headers = sign_v4(&SignInput {
        method: "GET",
        url: &url,
        body: "",
        region: "us-east-1",
        service: "iam",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        now: js::date_utc(2015, 7, 30, 12, 36, 0, 0),
        headers: &Object::new().with("content-type", "application/x-www-form-urlencoded; charset=utf-8"),
    })
    .unwrap();
    assert_eq!(
        headers.get("authorization").and_then(Value::as_str),
        Some(
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
        )
    );
}

#[test]
fn sig_v4_matches_typescript() {
    let f = fixture("outbound");
    let cases = list(&f, "signatures");
    assert_eq!(cases.len(), 2);
    for case in cases {
        let input = case.at("input");
        let url = Url::parse(s(input, "url")).unwrap();
        let headers = sign_v4(&SignInput {
            method: s(input, "method"),
            url: &url,
            body: s(input, "body"),
            region: s(input, "region"),
            service: s(input, "service"),
            access_key_id: s(input, "accessKeyId"),
            secret_access_key: s(input, "secretAccessKey"),
            now: input.at("now").as_f64().unwrap() as i64,
            headers: input.at("headers").as_object().unwrap(),
        })
        .unwrap();
        assert_eq!(headers.to_json(), js::stringify(case.at("headers")), "{}", s(input, "url"));
    }
}

#[test]
fn sig_v4_refuses_a_path_that_does_not_decode() {
    let url = Url::parse("https://example.amazonaws.com/%zz").unwrap();
    let input = SignInput {
        method: "GET",
        url: &url,
        body: "",
        region: "us-east-1",
        service: "ses",
        access_key_id: "K",
        secret_access_key: "S",
        now: NOW,
        headers: &Object::new(),
    };
    assert_eq!(sign_v4(&input).unwrap_err(), "URI malformed");
}

#[tokio::test]
async fn each_service_gets_the_request_it_documents() {
    let m = message();
    let calls = Recorder::new(Answer::Reply(200, "{}".into()));
    send(&config(obj! { "service" => "resend", "apiKey" => "re_1" }), &m, &shared(&calls), NOW).await.unwrap();
    let r = &calls.requests()[0];
    assert_eq!(s(r, "url"), "https://api.resend.com/emails");
    assert_eq!(s(r.at("headers"), "authorization"), "Bearer re_1");
    let body = js::parse(s(r, "body")).unwrap();
    assert_eq!(js::stringify(body.at("to")), r#"["jon@example.com"]"#);
    assert_eq!(s(&body, "from"), "Runlight <reports@example.com>");
    assert_eq!(calls.timeouts.load(Ordering::SeqCst), 20_000, "each request is given 20 s");

    let calls = Recorder::new(Answer::Reply(200, "{}".into()));
    let cfg =
        config(obj! { "service" => "mailgun", "apiKey" => "key", "domain" => "mg.example.com", "region" => "eu" });
    send(&cfg, &m, &shared(&calls), NOW).await.unwrap();
    let r = &calls.requests()[0];
    assert_eq!(s(r, "url"), "https://api.eu.mailgun.net/v3/mg.example.com/messages");
    assert_eq!(s(r.at("headers"), "authorization"), "Basic YXBpOmtleQ==");
    assert_eq!(runlight::http::SearchParams::parse(s(r, "body")).get("h:List-Unsubscribe"), Some("<https://x/u>"));

    let calls = Recorder::new(Answer::Reply(200, "{}".into()));
    let cfg = config(obj! { "service" => "webhook", "url" => "https://hooks.example.com/mail", "secret" => "s" });
    send(&cfg, &m, &shared(&calls), NOW).await.unwrap();
    let signature = s(calls.requests()[0].at("headers"), "x-runlight-signature").to_string();
    assert!(signature.starts_with("sha256=") && signature.len() == 71);
    assert_eq!(signature, format!("sha256={}", runlight::hash::hmac("s", s(&calls.requests()[0], "body"))));
}

#[tokio::test]
async fn every_service_sends_the_typescript_requests_exactly() {
    let f = fixture("outbound");
    let now = f.at("now").as_f64().unwrap() as i64;
    assert_eq!(now, NOW);
    let cases = list(&f, "mail");
    assert_eq!(cases.len(), 56);
    for (i, case) in cases.iter().enumerate() {
        let answer = match case.at("answer") {
            Value::String(_) => Answer::Unreachable,
            a => Answer::Reply(a.at("status").as_f64().unwrap() as u16, s(a, "body").to_string()),
        };
        let calls = Recorder::new(answer);
        let cfg = config(case.at("config").clone());
        let result = send(&cfg, &Message::from_value(case.at("message")), &shared(&calls), now).await;
        let label = format!("case {i}: {}", js::stringify(case.at("config")));
        assert_eq!(js::stringify(&Value::Array(calls.requests())), js::stringify(case.at("requests")), "{label}");
        let error = match &result {
            Ok(()) => Value::Null,
            Err(e) => error_value(e),
        };
        assert_eq!(js::stringify(&error), js::stringify(case.at("error")), "{label}");
    }
}

#[test]
fn service_messages_match_typescript() {
    let f = fixture("outbound");
    let cases = list(&f, "replies");
    assert_eq!(cases.len(), 18);
    for case in cases {
        assert_eq!(service_message(s(case, "reply")), s(case, "message"), "{}", s(case, "reply"));
    }
    // The XML form takes the first <Message> that fits, past one that is too long.
    let long = format!("<Message>{}</Message><Message>short</Message>", "y".repeat(201));
    assert_eq!(service_message(&long), "short");
    assert_eq!(service_message("<Message></Message>"), "");
}

#[test]
fn mime_matches_typescript() {
    let f = fixture("outbound");
    let cases = list(&f, "mimes");
    assert_eq!(cases.len(), 4);
    for case in cases {
        let mut uuid = uuids();
        let raw = mime(
            &Message::from_value(case.at("message")),
            s(case, "from"),
            case.at("now").as_f64().unwrap() as i64,
            &mut uuid,
        );
        assert_eq!(raw, s(case, "mime"));
    }
    let m = Message { subject: "Caf\u{e9} report".into(), ..message() };
    let raw = mime(&m, "Runlight <reports@example.com>", NOW, &mut runlight::mail::smtp::random_uuid);
    assert!(raw.contains("Subject: =?UTF-8?B?"));
    let at = raw.find("boundary=\"rl-").unwrap() + "boundary=\"rl-".len();
    let boundary = &raw[at..at + 36];
    assert!(boundary.bytes().enumerate().all(|(i, b)| if [8, 13, 18, 23].contains(&i) {
        b == b'-'
    } else {
        b.is_ascii_hexdigit()
    }));
}

#[test]
fn services_keep_their_ids_names_fields_and_order() {
    assert_eq!(SERVICES[0].id, "ses");
    let ids: Vec<&str> = SERVICES.iter().map(|s| s.id).collect();
    assert_eq!(
        ids,
        [
            "ses",
            "resend",
            "postmark",
            "sendgrid",
            "mailgun",
            "brevo",
            "mailjet",
            "mailersend",
            "sparkpost",
            "smtp",
            "webhook"
        ]
    );
    // The list as GET /api/mail sends it, in conformance/http.json.
    fn find(v: &Value) -> Option<&Value> {
        match v {
            Value::Object(o) => {
                if let Some(services) = o.get("services").filter(|x| x.is_array()) {
                    return Some(services);
                }
                o.iter().find_map(|(_, v)| find(v))
            }
            Value::Array(a) => a.iter().find_map(find),
            _ => None,
        }
    }
    let http = common::conformance("http");
    let expected = find(&http).expect("conformance/http.json sends the services");
    assert_eq!(js::stringify(&services_value()), js::stringify(expected));
}

#[test]
fn configs_are_checked_before_anything_is_sent() {
    let check = |v: Value| check_config(&config(v)).map_err(|e| (e.message, e.code));
    assert!(
        check(obj! { "service" => "postmark", "serverToken" => "pm" }).is_ok(),
        "an optional field may be left out"
    );
    assert!(check(obj! { "service" => "webhook", "url" => "http://127.0.0.1:8080" }).is_ok());
    assert!(check(obj! { "service" => "webhook", "url" => "http://localhost" }).is_ok());
    assert_eq!(
        check(obj! { "service" => "webhook", "url" => "http://localhost.example.com/" }).unwrap_err().1,
        "mail_https"
    );
    assert_eq!(check(obj! { "service" => "webhook", "url" => "http://localhost:/" }).unwrap_err().1, "mail_https");
    assert_eq!(
        check(obj! { "service" => "smtp", "host" => "h", "port" => "1", "security" => "ssl" }).unwrap_err().0,
        "Security must be one of starttls, tls, none"
    );
    assert_eq!(
        check(obj! { "service" => "ses", "region" => "us-east-1", "accessKeyId" => "A" }).unwrap_err().0,
        "Enter the secret access key"
    );
}

#[test]
fn errors_carry_codes_and_params() {
    let e = runlight::mail::transports::mail_error("Something");
    assert_eq!(e.code, "mail_failed");
    assert_eq!(js::stringify(&e.params_value()), r#"{"detail":"Something"}"#);
}

// SMTP, against a fake relay on 127.0.0.1 in ports 5400 to 5449.

/// A listener on the first free port from `start`.
async fn listen(start: u16) -> TcpListener {
    for port in start..5450 {
        if let Ok(l) = TcpListener::bind(("127.0.0.1", port)).await {
            return l;
        }
    }
    panic!("no free port from {start} to 5449");
}

/// A fake relay, as the TS tests' is: AUTH PLAIN checks jon/pw, no STARTTLS.
/// Sends every byte each connection received once it closes.
async fn relay(start: u16) -> (u16, mpsc::UnboundedReceiver<String>) {
    let listener = listen(start).await;
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else { return };
            let _ = tx.send(serve(socket).await);
        }
    });
    (port, rx)
}

async fn serve(mut socket: TcpStream) -> String {
    let mut received = Vec::new();
    let mut buffer = Vec::new();
    let mut in_data = false;
    let mut chunk = [0u8; 8192];
    socket.write_all(b"220 test ESMTP\r\n").await.unwrap();
    'outer: loop {
        let n = match socket.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        received.extend_from_slice(&chunk[..n]);
        buffer.extend_from_slice(&chunk[..n]);
        while let Some(at) = buffer.windows(2).position(|w| w == b"\r\n") {
            let line = String::from_utf8_lossy(&buffer[..at]).into_owned();
            buffer.drain(..at + 2);
            if in_data {
                if line == "." {
                    in_data = false;
                    socket.write_all(b"250 queued\r\n").await.unwrap();
                }
                continue;
            }
            let answer: &[u8] = if line.starts_with("EHLO") {
                b"250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n"
            } else if let Some(auth) = line.strip_prefix("AUTH PLAIN ") {
                use base64::Engine;
                let given = base64::engine::general_purpose::STANDARD.decode(auth).unwrap_or_default();
                if given == b"\0jon\0pw" { b"235 ok\r\n" } else { b"535 no\r\n" }
            } else if line == "DATA" {
                in_data = true;
                b"354 go\r\n"
            } else if line == "QUIT" {
                socket.write_all(b"221 bye\r\n").await.unwrap();
                // Whatever the client still sends before it hangs up.
                loop {
                    match tokio::time::timeout(Duration::from_secs(1), socket.read(&mut chunk)).await {
                        Ok(Ok(n)) if n > 0 => received.extend_from_slice(&chunk[..n]),
                        _ => break 'outer,
                    }
                }
            } else {
                b"250 ok\r\n"
            };
            socket.write_all(answer).await.unwrap();
        }
    }
    String::from_utf8(received).unwrap()
}

async fn next(rx: &mut mpsc::UnboundedReceiver<String>) -> String {
    tokio::time::timeout(Duration::from_secs(5), rx.recv()).await.expect("a conversation within 5 s").unwrap()
}

fn smtp_config(port: u16, more: Value) -> MailConfig {
    let mut c = config(obj! { "service" => "smtp", "host" => "127.0.0.1", "port" => port.to_string() });
    for (k, v) in more.as_object().unwrap().iter() {
        c.set(k, v.clone());
    }
    c
}

#[tokio::test]
async fn smtp_sends_the_typescript_conversation() {
    let (port, mut rx) = relay(5400).await;
    let f = fixture("outbound");
    let cases = list(&f, "smtp");
    assert_eq!(cases.len(), 4);
    for case in cases {
        let cfg = smtp_config(port, case.at("config").clone());
        let mut uuid = uuids();
        let result =
            smtp_send(&cfg, &Message::from_value(case.at("message")), s(case, "from"), 60_000, NOW, &mut uuid).await;
        let error = match &result {
            Ok(()) => Value::Null,
            Err(e) => error_value(e),
        };
        assert_eq!(js::stringify(&error), js::stringify(case.at("error")));
        assert_eq!(next(&mut rx).await, s(case, "received"));
    }
}

#[tokio::test]
async fn smtp_through_transports_sends_too() {
    let (port, mut rx) = relay(5410).await;
    let fetcher = Recorder::new(Answer::Unreachable);
    send(&smtp_config(port, obj! { "security" => "none" }), &message(), &shared(&fetcher), NOW).await.unwrap();
    let received = next(&mut rx).await;
    assert!(received.contains("From: Runlight <reports@example.com>\r\n"));
    assert!(received.contains("Date: Thu, 08 Oct 2026 15:04:05 +0000\r\n"));
    assert!(fetcher.requests().is_empty(), "SMTP never goes through the fetcher");
}

#[tokio::test]
async fn smtp_server_that_trickles_is_cut_off_at_the_deadline() {
    let listener = listen(5420).await;
    let port = listener.local_addr().unwrap().port();
    let (tx, mut rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        loop {
            if socket.write_all(b"220-still here\r\n").await.is_err() {
                break;
            }
            let mut chunk = [0u8; 64];
            match tokio::time::timeout(Duration::from_millis(100), socket.read(&mut chunk)).await {
                Ok(Ok(0)) | Ok(Err(_)) => break,
                _ => {}
            }
        }
        let _ = tx.send(());
    });
    let started = Instant::now();
    let error = smtp_send(
        &smtp_config(port, obj! { "security" => "none" }),
        &message(),
        "reports@example.com",
        600,
        NOW,
        &mut uuids(),
    )
    .await
    .unwrap_err();
    let took = started.elapsed();
    assert_eq!(error.code, "mail_slow");
    assert_eq!(error.message, format!("SMTP: 127.0.0.1:{port} took longer than 1 s"));
    assert_eq!(js::stringify(&error.params_value()), format!(r#"{{"host":"127.0.0.1:{port}"}}"#));
    assert!(took >= Duration::from_millis(550) && took < Duration::from_millis(2000), "gave up after {took:?}");
    tokio::time::timeout(Duration::from_secs(5), rx.recv()).await.expect("the connection is closed");
}

#[tokio::test]
async fn smtp_that_cannot_connect_says_so() {
    // A port that was free a moment ago.
    let port = listen(5430).await.local_addr().unwrap().port();
    let error = smtp_send(
        &smtp_config(port, obj! { "security" => "none" }),
        &message(),
        "reports@example.com",
        60_000,
        NOW,
        &mut uuids(),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "mail_unreachable");
    assert_eq!(
        error.message,
        format!("SMTP: could not connect to 127.0.0.1:{port}: connect ECONNREFUSED 127.0.0.1:{port}")
    );
    assert_eq!(
        js::stringify(&error.params_value()),
        format!(r#"{{"host":"127.0.0.1:{port}","detail":"connect ECONNREFUSED 127.0.0.1:{port}"}}"#)
    );
}

#[tokio::test]
async fn smtp_that_hangs_up_or_answers_nonsense_says_so() {
    let listener = listen(5435).await;
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        // First a server that hangs up after its greeting, then one whose greeting is not a number.
        let (mut a, _) = listener.accept().await.unwrap();
        a.write_all(b"220 hi\r\n").await.unwrap();
        let mut chunk = [0u8; 256];
        let _ = a.read(&mut chunk).await;
        drop(a);
        let (mut b, _) = listener.accept().await.unwrap();
        b.write_all(b"hello there\r\n").await.unwrap();
        let _ = b.read(&mut chunk).await;
    });
    let cfg = smtp_config(port, obj! { "security" => "none" });
    let error = smtp_send(&cfg, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!(
        (error.message.as_str(), error.code.as_str()),
        ("SMTP: the server closed the connection", "mail_failed")
    );
    let error = smtp_send(&cfg, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!(error.message, "SMTP greeting: NaN o there");
}

#[tokio::test]
async fn smtp_port_that_is_not_one_is_refused() {
    let cfg = smtp_config(0, obj! { "security" => "none", "port" => "70000" });
    let error = smtp_send(&cfg, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!(error.code, "mail_unreachable");
    assert!(error.message.starts_with("SMTP: could not connect to 127.0.0.1:70000: Port should be >= 0 and < 65536"));
}

#[cfg(feature = "transport")]
#[tokio::test]
async fn smtp_tls_that_fails_its_handshake_says_so() {
    let listener = listen(5440).await;
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let mut chunk = [0u8; 4096];
        // Implicit TLS, met by a server that speaks plain SMTP.
        let (mut a, _) = listener.accept().await.unwrap();
        let _ = a.read(&mut chunk).await;
        let _ = a.write_all(b"220 plain\r\n").await;
        drop(a);
        // STARTTLS offered and accepted, then no TLS at all.
        let (mut b, _) = listener.accept().await.unwrap();
        b.write_all(b"220 test ESMTP\r\n").await.unwrap();
        let _ = b.read(&mut chunk).await;
        b.write_all(b"250-test\r\n250 STARTTLS\r\n").await.unwrap();
        let _ = b.read(&mut chunk).await;
        b.write_all(b"220 go ahead\r\n").await.unwrap();
        let _ = b.read(&mut chunk).await;
        let _ = b.write_all(b"not tls at all, just words\r\n").await;
    });
    let tls = smtp_config(port, obj! { "security" => "tls" });
    let error = smtp_send(&tls, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!(error.code, "mail_unreachable");
    assert!(error.message.starts_with(&format!("SMTP: could not connect to 127.0.0.1:{port}: ")), "{}", error.message);
    let starttls = smtp_config(port, obj! { "security" => "starttls" });
    let error = smtp_send(&starttls, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!(error.code, "mail_failed");
    assert!(error.message.starts_with("SMTP: TLS failed: "), "{}", error.message);
}

#[tokio::test]
async fn smtp_reply_just_before_the_server_closes_is_the_error_not_the_close() {
    let listener = listen(5445).await;
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (mut a, _) = listener.accept().await.unwrap();
        a.write_all(b"535 no\r\n").await.unwrap();
        drop(a);
    });
    let cfg = smtp_config(port, obj! { "security" => "none" });
    let error = smtp_send(&cfg, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!((error.message.as_str(), error.code.as_str()), ("SMTP greeting: 535 no", "mail_failed"));
}

#[tokio::test]
async fn smtp_character_split_across_two_reads_comes_through_whole() {
    let listener = listen(5447).await;
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (mut a, _) = listener.accept().await.unwrap();
        a.set_nodelay(true).unwrap();
        // A byte order mark first, which a TextDecoder drops, then a character cut in two.
        let bytes = "\u{feff}554 caf\u{e9} ok\r\n".as_bytes();
        let split = bytes.iter().position(|b| *b == 0xc3).unwrap() + 1;
        a.write_all(&bytes[..2]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        a.write_all(&bytes[2..split]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        a.write_all(&bytes[split..]).await.unwrap();
        let mut chunk = [0u8; 256];
        let _ = a.read(&mut chunk).await;
    });
    let cfg = smtp_config(port, obj! { "security" => "none" });
    let error = smtp_send(&cfg, &message(), "reports@example.com", 60_000, NOW, &mut uuids()).await.unwrap_err();
    assert_eq!(error.message, "SMTP greeting: 554 caf\u{e9} ok");
}
