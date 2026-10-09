//! User agents: AI agents, bots, and the browser, system, and device a
//! person uses.

use crate::data::agents::{AI_AGENTS, AiAgent, BOT_PATTERN};
use crate::js::{self, Value};
use crate::obj;
use crate::re::{group, group_u, js_re, test, uni_re};

/// The browser, system, and device read from a user agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Client {
    /// The browser's name, or `Other`.
    pub browser: String,
    /// Its major version, or empty.
    pub browser_version: String,
    /// The operating system, or `Other`.
    pub os: String,
    /// Its version, or empty.
    pub os_version: String,
    /// `desktop`, `mobile`, or `tablet`.
    pub device: &'static str,
}

impl Client {
    /// As the SDK's object writes it.
    pub fn to_value(&self) -> Value {
        obj! {
            "browser" => self.browser.clone(),
            "browserVersion" => self.browser_version.clone(),
            "os" => self.os.clone(),
            "osVersion" => self.os_version.clone(),
            "device" => self.device,
        }
    }
}

/// Low entropy client hints, sent by Chromium browsers on every request.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClientHints {
    /// `Sec-CH-UA`.
    pub brands: Option<String>,
    /// `Sec-CH-UA-Mobile`.
    pub mobile: Option<String>,
    /// `Sec-CH-UA-Platform`.
    pub platform: Option<String>,
}

/// The AI agent a user agent names, if any.
pub fn ai_agent(ua: &str) -> Option<&'static AiAgent> {
    let lower = ua.to_lowercase();
    AI_AGENTS.iter().find(|agent| lower.contains(agent.token))
}

/// Whether a user agent is anything but a person in a browser.
pub fn is_bot(ua: &str) -> bool {
    if js::len16(ua) < 20 || !test(js_re!(r"(?i)mozilla|opera"), ua) {
        return true;
    }
    if test(js_re!(BOT_PATTERN), ua) {
        return true;
    }
    // The pattern's two lookaheads: yandex(?!browser) and qwant(?!ify).
    let lower = ua.to_ascii_lowercase();
    followed_by_other(&lower, "yandex", "browser") || followed_by_other(&lower, "qwant", "ify")
}

/// Whether `word` appears anywhere not followed by `next`.
fn followed_by_other(text: &str, word: &str, next: &str) -> bool {
    let mut from = 0;
    while let Some(at) = text[from..].find(word) {
        let end = from + at + word.len();
        if !text[end..].starts_with(next) {
            return true;
        }
        from = from + at + 1;
    }
    false
}

fn unquote(value: Option<&str>) -> String {
    js::trim(&value.unwrap_or("").replace('"', "")).to_string()
}

/// The browser, system, and device a user agent names, with the client
/// hints and the screen's width where they say more.
pub fn parse_client(ua: &str, hints: &ClientHints, screen_width: Option<f64>) -> Client {
    let browsers: [(&str, &regex::bytes::Regex); 11] = [
        ("Edge", js_re!(r"(?:Edg|EdgA|EdgiOS|Edge)/(\d+)")),
        ("Opera", js_re!(r"(?:OPR|OPiOS|Opera)/(\d+)")),
        ("Samsung Internet", js_re!(r"SamsungBrowser/(\d+)")),
        ("Yandex Browser", js_re!(r"YaBrowser/(\d+)")),
        ("Vivaldi", js_re!(r"Vivaldi/(\d+)")),
        ("UC Browser", js_re!(r"UCBrowser/(\d+)")),
        ("DuckDuckGo", js_re!(r"(?:Ddg|DuckDuckGo)/(\d+)")),
        ("Facebook", js_re!(r"FB(?:AV|_IAB)/(\d+)")),
        ("Instagram", js_re!(r"Instagram (\d+)")),
        ("Firefox", js_re!(r"(?:Firefox|FxiOS)/(\d+)")),
        ("Chrome", js_re!(r"(?:CriOS|Chrome)/(\d+)")),
    ];
    // JavaScript's `.` stops at any line terminator, and its `\S` at any Unicode space.
    let unicode: [(&str, &regex::Regex); 2] = [
        (
            "Safari",
            uni_re!(
                r"Version/([0-9]+)[0-9.]* (?:Mobile/[^\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+ )?Safari/"
            ),
        ),
        ("Internet Explorer", uni_re!(r"(?:MSIE |Trident/[^\n\r\x{2028}\x{2029}]*rv:)([0-9]+)")),
    ];
    let mut browser = "Other".to_string();
    let mut browser_version = String::new();
    let found = browsers
        .iter()
        .find_map(|(name, pattern)| group(pattern, ua, 1).map(|v| (*name, v)))
        .or_else(|| unicode.iter().find_map(|(name, pattern)| group_u(pattern, ua, 1).map(|v| (*name, v))));
    if let Some((name, version)) = found {
        browser = name.to_string();
        browser_version = version;
    }
    if browser == "Chrome" && test(js_re!(r"; wv\)"), ua) {
        browser = "Android WebView".into();
    }
    // Brave looks like Chrome in the user agent but names itself in the hints.
    if browser == "Chrome" && hints.brands.as_deref().unwrap_or("").contains("\"Brave\"") {
        browser = "Brave".into();
    }

    let mut os = "Other".to_string();
    let mut os_version = String::new();
    if let Some(v) = group(js_re!(r"Windows NT (\d+\.\d+)"), ua, 1) {
        os = "Windows".into();
        os_version = match v.as_str() {
            "10.0" => "10",
            "6.3" => "8.1",
            "6.2" => "8",
            "6.1" => "7",
            "6.0" => "Vista",
            "5.1" => "XP",
            _ => "",
        }
        .into();
    } else if let Some(v) = group_u(uni_re!(r"(?:iPhone|iPad|iPod)[^\n\r\x{2028}\x{2029}]*? OS ([0-9]+)"), ua, 1) {
        os = "iOS".into();
        os_version = v;
    } else if let Some(v) = group(js_re!(r"Android (\d+)"), ua, 1) {
        os = "Android".into();
        os_version = v;
    } else if ua.contains("Android") {
        os = "Android".into();
    } else if ua.contains("CrOS") {
        os = "Chrome OS".into();
    } else if ua.contains("Mac OS X") || ua.contains("Macintosh") {
        // macOS froze its version in the user agent at 10.15, so it says nothing.
        os = "macOS".into();
    } else if ua.contains("Linux") || ua.contains("X11") {
        os = "Linux".into();
    }
    let platform = unquote(hints.platform.as_deref());
    if os == "Other" && !platform.is_empty() {
        os = platform;
    }

    let mut device = "desktop";
    if test(js_re!(r"iPad|Tablet|PlayBook|Silk"), ua) || (os == "Android" && !ua.contains("Mobile")) {
        device = "tablet";
    } else if test(js_re!(r"Mobi|iPhone|iPod|Opera Mini|IEMobile"), ua) || unquote(hints.mobile.as_deref()) == "?1" {
        device = "mobile";
    } else if os == "macOS" && screen_width.is_some_and(|w| [768.0, 810.0, 820.0, 834.0, 1024.0].contains(&w)) {
        // iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
        device = "tablet";
        os = "iOS".into();
    }

    Client { browser, browser_version, os, os_version, device }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookaheads_are_checked_by_hand() {
        let ua = |s: &str| format!("Mozilla/5.0 (X11; Linux x86_64) {s}");
        assert!(!is_bot(&ua("YandexBrowser/24")));
        assert!(is_bot(&ua("YandexSearch/24")));
        assert!(!is_bot(&ua("Qwantify/1")));
        assert!(is_bot(&ua("Qwant/1")));
        assert!(is_bot("short"));
    }
}
