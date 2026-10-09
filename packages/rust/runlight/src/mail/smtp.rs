//! A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
//! relays), with AUTH PLAIN, on tokio. TLS comes with the `transport`
//! feature (tokio-rustls, with the platform's roots); without it only plain
//! relays can be used.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::transports::{MailConfig, MailError, Message, get, get_or_empty, mail_error};
use crate::goals::CodedError;
use crate::js;

/// The whole send's limit, in milliseconds.
pub const DEADLINE_MS: u64 = 60_000;

/// Each reply must come within this long.
const REPLY_TIMEOUT: Duration = Duration::from_millis(20_000);

/// How long the goodbye is waited for.
const QUIT_WAIT: Duration = Duration::from_millis(2000);

fn b64(text: &str) -> String {
    STANDARD.encode(text.as_bytes())
}

/// `text.replace(/.{1,76}/g, "$&\r\n")` for base64, which has no line breaks.
fn wrap(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + text.len() / 38 + 2);
    for chunk in text.as_bytes().chunks(76) {
        out.push_str(std::str::from_utf8(chunk).expect("base64 is ASCII"));
        out.push_str("\r\n");
    }
    out
}

/// The text as it is, when it is printable ASCII, or as a base64 encoded word.
fn encode_word(text: &str) -> String {
    if text.bytes().all(|b| (0x20..=0x7e).contains(&b)) {
        text.to_string()
    } else {
        format!("=?UTF-8?B?{}?=", b64(text))
    }
}

/// A random version 4 UUID, as `crypto.randomUUID()` gives.
pub fn random_uuid() -> String {
    let mut b = crate::hash::random_bytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = crate::hash::hex(&b);
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

/// `new Date(ms).toUTCString()`, with `+0000` for GMT.
fn utc_date(ms: i64) -> String {
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let days = js::floor_div(ms, 86_400_000);
    let rest = ms.rem_euclid(86_400_000);
    let (y, m, d) = js::civil_from_days(days);
    let year = if y < 0 { format!("-{:06}", -y) } else { format!("{y:04}") };
    format!(
        "{}, {d:02} {} {year} {:02}:{:02}:{:02} +0000",
        DAYS[(days + 4).rem_euclid(7) as usize],
        MONTHS[(m - 1) as usize],
        rest / 3_600_000,
        rest / 60_000 % 60,
        rest / 1000 % 60
    )
}

/// `/^(.*)<(.+)>$/.exec(from)`: the name and the address of `Name <address>`.
fn named(from: &str) -> Option<(&str, &str)> {
    if from.chars().any(|c| matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')) {
        return None;
    }
    let body = from.strip_suffix('>')?;
    // The last `<` that leaves at least one character before the closing `>`.
    let at = body.char_indices().filter(|(i, c)| *c == '<' && i + 1 < body.len()).map(|(i, _)| i).next_back()?;
    Some((&body[..at], &body[at + 1..]))
}

/// The message as MIME: text and HTML alternatives, both base64. Public for
/// its test; `now` (epoch milliseconds) is its Date, and `uuid` gives the
/// boundary and then the Message-ID, as `crypto.randomUUID()` does.
pub fn mime(m: &Message, from: &str, now: i64, uuid: &mut dyn FnMut() -> String) -> String {
    let boundary = format!("rl-{}", uuid());
    let domain = m.from.split('@').nth(1).unwrap_or("runlight.local");
    let from_header = match named(from) {
        Some((name, address)) => format!("{} <{address}>", encode_word(js::trim(name))),
        None => from.to_string(),
    };
    let mut headers = vec![
        format!("From: {from_header}"),
        format!("To: {}", m.to),
        format!("Subject: {}", encode_word(&m.subject)),
        format!("Date: {}", utc_date(now)),
        format!("Message-ID: <{}@{domain}>", uuid()),
        "MIME-Version: 1.0".to_string(),
    ];
    for (k, v) in m.headers_object().iter() {
        headers.push(format!("{k}: {}", js::js_string(v).replace(['\r', '\n'], "")));
    }
    headers.push(format!("Content-Type: multipart/alternative; boundary=\"{boundary}\""));
    [
        headers.join("\r\n"),
        String::new(),
        format!("--{boundary}"),
        "Content-Type: text/plain; charset=utf-8".into(),
        "Content-Transfer-Encoding: base64".into(),
        String::new(),
        wrap(&b64(&m.text)),
        format!("--{boundary}"),
        "Content-Type: text/html; charset=utf-8".into(),
        "Content-Transfer-Encoding: base64".into(),
        String::new(),
        wrap(&b64(&m.html)),
        format!("--{boundary}--"),
        String::new(),
    ]
    .join("\r\n")
}

/// An io error in the words Node gives it, where it has some: `connect
/// ECONNREFUSED 127.0.0.1:25`, `read ECONNRESET`.
fn node_message(e: &io::Error, syscall: &str, address: Option<SocketAddr>) -> String {
    let code = match e.kind() {
        io::ErrorKind::ConnectionRefused => "ECONNREFUSED",
        io::ErrorKind::ConnectionReset => "ECONNRESET",
        io::ErrorKind::ConnectionAborted => "ECONNABORTED",
        io::ErrorKind::TimedOut => "ETIMEDOUT",
        io::ErrorKind::BrokenPipe => "EPIPE",
        io::ErrorKind::AddrNotAvailable => "EADDRNOTAVAIL",
        io::ErrorKind::HostUnreachable => "EHOSTUNREACH",
        io::ErrorKind::NetworkUnreachable => "ENETUNREACH",
        _ => return e.to_string(),
    };
    match address {
        Some(a) => format!("{syscall} {code} {}:{}", a.ip(), a.port()),
        None => format!("{syscall} {code}"),
    }
}

/// The connection, plain or under TLS.
enum Conn {
    Plain(TcpStream),
    #[cfg(feature = "transport")]
    Tls(Box<tokio_rustls::client::TlsStream<TcpStream>>),
}

impl Conn {
    async fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Conn::Plain(s) => s.read(buf).await,
            #[cfg(feature = "transport")]
            Conn::Tls(s) => s.read(buf).await,
        }
    }

    async fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        match self {
            Conn::Plain(s) => s.write_all(data).await,
            #[cfg(feature = "transport")]
            Conn::Tls(s) => s.write_all(data).await,
        }
    }

    async fn shutdown(&mut self) {
        let _ = match self {
            Conn::Plain(s) => s.shutdown().await,
            #[cfg(feature = "transport")]
            Conn::Tls(s) => s.shutdown().await,
        };
    }
}

#[cfg(feature = "transport")]
fn tls_config() -> Result<std::sync::Arc<tokio_rustls::rustls::ClientConfig>, String> {
    use rustls_platform_verifier::BuilderVerifierExt;
    use std::sync::{Arc, OnceLock};
    use tokio_rustls::rustls;
    static CONFIG: OnceLock<Result<Arc<rustls::ClientConfig>, String>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            let config = rustls::ClientConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .map_err(|e| e.to_string())?
                .with_platform_verifier()
                .with_no_client_auth();
            Ok(Arc::new(config))
        })
        .clone()
}

/// TLS over the connection, with `host` as the name the certificate must carry.
#[cfg(feature = "transport")]
async fn secure(stream: TcpStream, host: &str) -> Result<Conn, String> {
    use tokio_rustls::rustls::pki_types::ServerName;
    let config = tls_config()?;
    let name = ServerName::try_from(host.to_string()).map_err(|e| e.to_string())?;
    let secured = tokio_rustls::TlsConnector::from(config).connect(name, stream).await.map_err(|e| e.to_string())?;
    Ok(Conn::Tls(Box::new(secured)))
}

#[cfg(not(feature = "transport"))]
async fn secure(_stream: TcpStream, _host: &str) -> Result<Conn, String> {
    Err("Runlight was built without the transport feature, so it has no TLS".to_string())
}

/// One reply: its code (NaN when the line does not start with a number) and
/// its lines' text joined with spaces.
struct Reply {
    code: f64,
    text: String,
}

/// One SMTP connection and the replies read from it, multi-line included, one at a time.
struct Session {
    conn: Option<Conn>,
    buffer: Vec<u8>,
    lines: Vec<String>,
}

fn closed() -> MailError {
    mail_error("SMTP: the server closed the connection")
}

impl Session {
    async fn write(&mut self, line: &str) -> Result<(), MailError> {
        self.write_raw(format!("{line}\r\n").as_bytes()).await
    }

    async fn write_raw(&mut self, data: &[u8]) -> Result<(), MailError> {
        let conn = self.conn.as_mut().ok_or_else(closed)?;
        match tokio::time::timeout(REPLY_TIMEOUT, conn.write_all(data)).await {
            Err(_) => Err(mail_error("SMTP: timed out")),
            Ok(Err(e)) => Err(mail_error(format!("SMTP: {}", node_message(&e, "write", None)))),
            Ok(Ok(())) => Ok(()),
        }
    }

    /// The next whole reply; each read must come within `timeout`.
    async fn next(&mut self, timeout: Duration) -> Result<Reply, MailError> {
        loop {
            while let Some(at) = self.buffer.windows(2).position(|w| w == b"\r\n") {
                let line = String::from_utf8_lossy(&self.buffer[..at]).into_owned();
                self.buffer.drain(..at + 2);
                let units = js::units(&line);
                self.lines.push(js::slice16(&line, 4, units.len() as i64));
                if units.get(3) != Some(&u16::from(b'-')) {
                    let code = js::text_number(&js::slice16(&line, 0, 3));
                    let text = std::mem::take(&mut self.lines).join(" ");
                    return Ok(Reply { code, text });
                }
            }
            let conn = self.conn.as_mut().ok_or_else(closed)?;
            let mut chunk = [0u8; 8192];
            match tokio::time::timeout(timeout, conn.read(&mut chunk)).await {
                Err(_) => return Err(mail_error("SMTP: timed out")),
                Ok(Err(e)) => return Err(mail_error(format!("SMTP: {}", node_message(&e, "read", None)))),
                Ok(Ok(0)) => return Err(closed()),
                Ok(Ok(n)) => self.buffer.extend_from_slice(&chunk[..n]),
            }
        }
    }

    async fn expect(&mut self, codes: &[f64], what: &str) -> Result<Reply, MailError> {
        let reply = self.next(REPLY_TIMEOUT).await?;
        if !codes.contains(&reply.code) {
            return Err(mail_error(js::head16(
                &format!("SMTP {what}: {} {}", js::format_number(reply.code), reply.text),
                300,
            )));
        }
        Ok(reply)
    }

    /// Turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new reader would.
    async fn start_tls(&mut self, host: &str) -> Result<(), MailError> {
        self.buffer.clear();
        self.lines.clear();
        let stream = match self.conn.take() {
            Some(Conn::Plain(s)) => s,
            _ => return Err(closed()),
        };
        match tokio::time::timeout(REPLY_TIMEOUT, secure(stream, host)).await {
            Err(_) => Err(mail_error("SMTP: TLS failed: timed out")),
            Ok(Err(e)) => Err(mail_error(format!("SMTP: TLS failed: {e}"))),
            Ok(Ok(conn)) => {
                self.conn = Some(conn);
                Ok(())
            }
        }
    }
}

/// Sends one message. Each reply must come within 20 s, and the whole send
/// within the deadline (60 s, [`DEADLINE_MS`]), so a server that trickles a
/// line now and then cannot hold the scheduled check that sends reports. Its
/// deadline is a parameter for its test, as are the time (epoch milliseconds)
/// and the UUIDs the MIME is written with.
pub async fn smtp_send(
    config: &MailConfig,
    m: &Message,
    from: &str,
    deadline_ms: u64,
    now: i64,
    uuid: &mut (dyn FnMut() -> String + Send),
) -> Result<(), MailError> {
    let host = js::trim(get_or_empty(config, "host")).to_string();
    let security = match get_or_empty(config, "security") {
        "" => "starttls",
        s => s,
    };
    let number = js::opt_number(config.get("port"));
    let port = if number.is_nan() || number == 0.0 { if security == "tls" { 465.0 } else { 587.0 } } else { number };
    let place = format!("{host}:{}", js::format_number(port));
    let work = converse(config, m, from, &host, port, security, now, uuid);
    match tokio::time::timeout(Duration::from_millis(deadline_ms), work).await {
        Ok(result) => result,
        Err(_) => Err(CodedError::new(
            format!("SMTP: {place} took longer than {} s", (deadline_ms + 500) / 1000),
            "mail_slow",
            &[("host", &place)],
        )),
    }
}

#[allow(clippy::too_many_arguments)]
async fn converse(
    config: &MailConfig,
    m: &Message,
    from: &str,
    host: &str,
    port: f64,
    security: &str,
    now: i64,
    uuid: &mut (dyn FnMut() -> String + Send),
) -> Result<(), MailError> {
    let place = format!("{host}:{}", js::format_number(port));
    let unreachable = |detail: String| {
        CodedError::new(
            format!("SMTP: could not connect to {place}: {detail}"),
            "mail_unreachable",
            &[("host", &place), ("detail", &detail)],
        )
    };
    // net.connect refuses a port that is not a whole number from 0 to 65535.
    if !(port.fract() == 0.0 && (0.0..=65535.0).contains(&port)) {
        return Err(unreachable(format!(
            "Port should be >= 0 and < 65536. Received type number ({}).",
            js::format_number(port)
        )));
    }
    let port = port as u16;
    let conn = match tokio::time::timeout(REPLY_TIMEOUT, connect(host, port, security == "tls")).await {
        Err(_) => return Err(unreachable("timed out".into())),
        Ok(Err(detail)) => return Err(unreachable(detail)),
        Ok(Ok(conn)) => conn,
    };
    let mut s = Session { conn: Some(conn), buffer: Vec::new(), lines: Vec::new() };
    let result = talk(&mut s, config, m, from, host, security, now, uuid).await;
    if let Some(conn) = s.conn.as_mut() {
        conn.shutdown().await;
    }
    result
}

/// Connects, under TLS from the start for `tls`, with Node's words for what goes wrong.
async fn connect(host: &str, port: u16, tls: bool) -> Result<Conn, String> {
    let addresses: Vec<SocketAddr> =
        tokio::net::lookup_host((host, port)).await.map_err(|_| format!("getaddrinfo ENOTFOUND {host}"))?.collect();
    let mut failure = format!("getaddrinfo ENOTFOUND {host}");
    for address in addresses {
        match TcpStream::connect(address).await {
            Ok(stream) => {
                return if tls { secure(stream, host).await } else { Ok(Conn::Plain(stream)) };
            }
            Err(e) => failure = node_message(&e, "connect", Some(address)),
        }
    }
    Err(failure)
}

#[allow(clippy::too_many_arguments)]
async fn talk(
    s: &mut Session,
    config: &MailConfig,
    m: &Message,
    from: &str,
    host: &str,
    security: &str,
    now: i64,
    uuid: &mut (dyn FnMut() -> String + Send),
) -> Result<(), MailError> {
    s.expect(&[220.0], "greeting").await?;
    let name = match from.split('@').nth(1) {
        Some(part) => part.strip_suffix('>').unwrap_or(part),
        None => "",
    };
    let name = if name.is_empty() { "localhost" } else { name };
    s.write(&format!("EHLO {name}")).await?;
    let ehlo = s.expect(&[250.0], "EHLO").await?;
    if security == "starttls" {
        if !ehlo.text.to_ascii_uppercase().contains("STARTTLS") {
            return Err(CodedError::new(
                "SMTP: the server does not offer STARTTLS; pick tls or none",
                "smtp_starttls",
                &[],
            ));
        }
        s.write("STARTTLS").await?;
        s.expect(&[220.0], "STARTTLS").await?;
        s.start_tls(host).await?;
        s.write(&format!("EHLO {name}")).await?;
        s.expect(&[250.0], "EHLO").await?;
    }
    if let Some(user) = get(config, "username").filter(|u| !u.is_empty()) {
        let password = get(config, "password").unwrap_or("");
        s.write(&format!("AUTH PLAIN {}", b64(&format!("\0{user}\0{password}")))).await?;
        s.expect(&[235.0], "sign-in").await?;
    }
    s.write(&format!("MAIL FROM:<{}>", m.from)).await?;
    s.expect(&[250.0], "MAIL FROM").await?;
    s.write(&format!("RCPT TO:<{}>", m.to)).await?;
    s.expect(&[250.0, 251.0], "RCPT TO").await?;
    s.write("DATA").await?;
    s.expect(&[354.0], "DATA").await?;
    // A line starting with a dot gets a second one, so it is not read as the end.
    let data = format!("{}\r\n.\r\n", mime(m, from, now, uuid).replace("\r\n.", "\r\n.."));
    s.write_raw(data.as_bytes()).await?;
    s.expect(&[250.0], "message").await?;
    s.write("QUIT").await?;
    // Wait for the goodbye, but never fail a sent message over it.
    let _ = s.next(QUIT_WAIT).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_read_as_the_pattern_reads_them() {
        assert_eq!(named("Runlight <a@b>"), Some(("Runlight ", "a@b")));
        assert_eq!(named("a@b"), None);
        assert_eq!(named("<a@b>"), Some(("", "a@b")));
        assert_eq!(named("x <a<b>"), Some(("x <a", "b")));
        assert_eq!(named("x <a<>"), Some(("x ", "a<")));
        assert_eq!(named("<>"), None);
        assert_eq!(named("x\n <a@b>"), None);
    }

    #[test]
    fn dates_are_written_as_to_utc_string_writes_them() {
        assert_eq!(utc_date(1_791_471_845_678), "Thu, 08 Oct 2026 15:04:05 +0000");
        assert_eq!(utc_date(0), "Thu, 01 Jan 1970 00:00:00 +0000");
        assert_eq!(utc_date(-1), "Wed, 31 Dec 1969 23:59:59 +0000");
    }

    #[test]
    fn base64_is_wrapped_at_76() {
        assert_eq!(wrap(""), "");
        assert_eq!(wrap("ab"), "ab\r\n");
        let long = "x".repeat(80);
        assert_eq!(wrap(&long), format!("{}\r\n{}\r\n", "x".repeat(76), "xxxx"));
    }

    #[test]
    fn uuids_are_version_4() {
        let u = random_uuid();
        assert_eq!(u.len(), 36);
        assert_eq!(&u[14..15], "4");
        assert!(matches!(&u[19..20], "8" | "9" | "a" | "b"));
    }
}
