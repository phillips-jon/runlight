//! Where a visit came from: the page's own tags, the referrer, and the
//! channel they add up to.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::data::sources::{KnownSource, SOURCE_PATTERNS, SOURCES, SourceKind};
use crate::http::Url;
use crate::js;
use crate::re::{js_re, test};

/// What a page's URL says: its host, its path, its campaign tags.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Page {
    /// The host, lower case, without `www.`.
    pub hostname: String,
    /// The path, with a hash route kept.
    pub path: String,
    /// The utm_ tags.
    pub utm: Utm,
    /// A `ref` or `source` query parameter, used when there is no utm_source.
    pub ref_: String,
    /// A click id such as gclid was present. The id itself is never kept.
    pub paid: bool,
}

/// The utm_ tags of a page's URL.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Utm {
    /// utm_source.
    pub source: String,
    /// utm_medium, lower case.
    pub medium: String,
    /// utm_campaign.
    pub campaign: String,
    /// utm_term.
    pub term: String,
    /// utm_content.
    pub content: String,
}

/// Where a visit came from.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Attribution {
    /// The referrer's host, when it is another site.
    pub referrer_host: String,
    /// The referrer's path.
    pub referrer_path: String,
    /// The source's name.
    pub source: String,
    /// The channel.
    pub channel: &'static str,
}

const CLICK_IDS: [&str; 10] =
    ["gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "ttclid", "twclid", "li_fat_id", "yclid"];

/// A known source, found or made from a host's shape.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    /// The source's name.
    pub name: String,
    /// What kind of place it is.
    pub kind: SourceKind,
}

impl From<&KnownSource> for Found {
    fn from(s: &KnownSource) -> Found {
        Found { name: s.name.to_string(), kind: s.kind }
    }
}

struct Maps {
    by_host: HashMap<&'static str, &'static KnownSource>,
    by_alias: HashMap<&'static str, &'static KnownSource>,
    patterns: Vec<(regex::bytes::Regex, Option<&'static str>, SourceKind)>,
}

static MAPS: LazyLock<Maps> = LazyLock::new(|| {
    let mut by_host = HashMap::new();
    let mut by_alias = HashMap::new();
    for source in SOURCES {
        for host in source.hosts {
            by_host.insert(*host, source);
        }
        for alias in source.aliases {
            by_alias.insert(*alias, source);
        }
    }
    let patterns = SOURCE_PATTERNS.iter().map(|(p, name, kind)| (crate::re::ascii(p), *name, *kind)).collect();
    Maps { by_host, by_alias, patterns }
});

/// `clip`: trimmed, at most `max` UTF-16 code units.
fn clip(value: Option<&str>, max: usize) -> String {
    js::head16(js::trim(value.unwrap_or("")), max)
}

/// The host lower case, without a leading `www.`.
pub fn strip_www(host: &str) -> String {
    let lower = host.to_lowercase();
    match lower.strip_prefix("www.") {
        Some(rest) => rest.to_string(),
        None => lower,
    }
}

/// The most specific known source for a host: mail.google.com before
/// google.com. Android apps send their package name as the referrer
/// (com.google.android.gm for Gmail), which is matched the same way. Hosts
/// known only by their shape (click trackers, webmail) come last.
pub fn source_for_host(host: &str) -> Option<Found> {
    let clean = strip_www(host);
    let mut candidate = clean.as_str();
    while candidate.contains('.') {
        if let Some(found) = MAPS.by_host.get(candidate) {
            return Some((*found).into());
        }
        candidate = &candidate[candidate.find('.').map_or(0, |i| i + 1)..];
    }
    for (pattern, name, kind) in &MAPS.patterns {
        if test(pattern, &clean) {
            return Some(Found { name: name.map_or_else(|| clean.clone(), str::to_string), kind: *kind });
        }
    }
    None
}

/// The known source a tag names, such as `utm_source=newsletter`.
pub fn source_for_alias(value: &str) -> Option<Found> {
    let key = js::trim(&value.to_lowercase()).to_string();
    if let Some(found) = MAPS.by_alias.get(key.as_str()) {
        return Some((*found).into());
    }
    MAPS.by_host.get(strip_www(&key).as_str()).map(|s| (*s).into())
}

/// A path a person wrote, in the form paths are recorded: the path of a
/// pasted URL, with a leading slash, percent-encoded as the browser's URL
/// parser encodes it, and with a hash route kept, as `parse_page` keeps it.
/// `None` when it is not a path or a URL.
pub fn recorded_path(input: &str) -> Option<String> {
    let url = if test(js_re!(r"(?i)^https?://"), input) {
        Url::parse(input)
    } else {
        let path = if input.starts_with('/') { input.to_string() } else { format!("/{input}") };
        Url::parse_with_base(&path, "https://x.invalid")
    }?;
    Some(parse_page(&url).path)
}

/// A recorded path as people write it, for showing and exporting:
/// `/caf%C3%A9` as `/café`. Only text is decoded; an encoded slash, space,
/// or other mark that would change the path's meaning stays as it is.
pub fn readable_path(path: &str) -> String {
    let re = js_re!(r"(?:%[0-9A-Fa-f]{2})+");
    let bytes = path.as_bytes();
    let mut out = String::new();
    let mut last = 0;
    for m in re.find_iter(bytes) {
        out.push_str(&path[last..m.start()]);
        let run = &path[m.start()..m.end()];
        match decode_uri_component(run) {
            Some(text)
                if !text.chars().any(|c| js::is_space(c) || matches!(c, '/' | '?' | '#' | '%') || is_other(c)) =>
            {
                out.push_str(&text)
            }
            _ => out.push_str(run),
        }
        last = m.end();
    }
    out.push_str(&path[last..]);
    out
}

/// Whether a character is in Unicode's "Other" category (`\p{C}`): control,
/// format, surrogate, private use, or unassigned.
fn is_other(c: char) -> bool {
    use std::sync::LazyLock;
    static OTHER: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"\p{C}").expect("a valid pattern"));
    let mut buf = [0u8; 4];
    OTHER.is_match(c.encode_utf8(&mut buf))
}

/// `decodeURIComponent`: `None` where it throws (a broken escape, or bytes
/// that are not UTF-8).
pub fn decode_uri_component(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let s = std::str::from_utf8(hex).ok()?;
            if !hex.iter().all(u8::is_ascii_hexdigit) {
                return None;
            }
            out.push(u8::from_str_radix(s, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `encodeURIComponent`.
pub fn encode_uri_component(text: &str) -> String {
    const SET: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'!')
        .remove(b'~')
        .remove(b'*')
        .remove(b'\'')
        .remove(b'(')
        .remove(b')');
    percent_encoding::utf8_percent_encode(text, SET).to_string()
}

/// What a page's URL says about the visit.
pub fn parse_page(url: &Url) -> Page {
    let q = url.search_params();
    let mut path = url.pathname();
    if path.is_empty() {
        path = "/".into();
    }
    // The tracker only sends a hash when the site asked for hash routing.
    let hash = url.hash();
    if js::len16(&hash) > 1 {
        path.push_str(&hash);
    }
    Page {
        hostname: strip_www(&url.hostname()),
        path: js::head16(&path, 1000),
        utm: Utm {
            source: clip(q.get("utm_source"), 200),
            medium: clip(q.get("utm_medium"), 200).to_lowercase(),
            campaign: clip(q.get("utm_campaign"), 200),
            term: clip(q.get("utm_term"), 200),
            content: clip(q.get("utm_content"), 200),
        },
        ref_: clip(q.get("ref").or_else(|| q.get("source")), 200),
        paid: CLICK_IDS.iter().any(|id| q.has(id)),
    }
}

/// Where a visit came from. `internal_hosts` are the site's own hostnames:
/// a referrer on one of them is navigation within the site, not a source.
pub fn attribute(page: &Page, referrer: &str, internal_hosts: &[String]) -> Attribution {
    let mut referrer_host = String::new();
    let mut referrer_path = String::new();
    if !referrer.is_empty()
        && let Some(url) = Url::parse(referrer)
    {
        let protocol = url.protocol();
        // Android apps refer as android-app://<package>/.
        if protocol == "http:" || protocol == "https:" || protocol == "android-app:" {
            let host = strip_www(&url.hostname());
            if host != page.hostname && !internal_hosts.contains(&host) {
                referrer_host = host;
                referrer_path =
                    if protocol == "android-app:" { String::new() } else { js::head16(&url.pathname(), 500) };
            }
        }
    }

    let tagged = if !page.utm.source.is_empty() { page.utm.source.as_str() } else { page.ref_.as_str() };
    let known = if !tagged.is_empty() {
        source_for_alias(tagged)
    } else if !referrer_host.is_empty() {
        source_for_host(&referrer_host)
    } else {
        None
    };
    let source = match &known {
        Some(k) => k.name.clone(),
        None if !tagged.is_empty() => tagged.to_string(),
        None => referrer_host.clone(),
    };
    let kind = match &known {
        Some(k) => Some(k.kind),
        None if !referrer_host.is_empty() => source_for_host(&referrer_host).map(|f| f.kind),
        None => None,
    };
    let medium = page.utm.medium.as_str();
    let paid = test(
        js_re!(r"^(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)$"),
        medium,
    );
    let email = test(js_re!(r"^(e-?mail|newsletter|mail)$"), medium);
    let social = test(
        js_re!(
            r"^(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)$"
        ),
        medium,
    );

    let channel = if (page.paid || paid) && kind == Some(SourceKind::Search) {
        "Paid Search"
    } else if kind == Some(SourceKind::Ai) {
        "AI"
    } else if email || kind == Some(SourceKind::Email) {
        "Email"
    } else if kind == Some(SourceKind::Search) {
        "Organic Search"
    } else if social || kind == Some(SourceKind::Social) {
        "Social"
    } else if !page.utm.source.is_empty() || !page.utm.medium.is_empty() || !page.utm.campaign.is_empty() {
        "Campaign"
    } else if !referrer_host.is_empty() || !page.ref_.is_empty() {
        "Referral"
    } else {
        "Direct"
    };

    Attribution { referrer_host, referrer_path, source, channel }
}
