//! JavaScript regular expressions without the `u` flag, as the SDK writes
//! them: matched over bytes, with `\d`, `\w`, `\b`, `\s`, and `/i` all
//! ASCII-only, as JavaScript has them without `u` (the regex crate's Unicode
//! classes would let the long s match `s`, or an Arabic digit `\d`). The
//! patterns here only name ASCII, so matching UTF-8 bytes finds what
//! matching UTF-16 code units finds.

use regex::bytes::Regex;

/// Compiles a pattern in ASCII mode. The patterns are the crate's own, so one
/// that does not compile is a bug.
pub(crate) fn ascii(pattern: &str) -> Regex {
    Regex::new(&format!("(?-u){pattern}")).unwrap_or_else(|e| panic!("bad pattern {pattern}: {e}"))
}

/// A pattern compiled once, on first use.
macro_rules! js_re {
    ($pattern:expr) => {{
        static RE: std::sync::LazyLock<regex::bytes::Regex> = std::sync::LazyLock::new(|| $crate::re::ascii($pattern));
        &*RE
    }};
}
pub(crate) use js_re;

/// A Unicode pattern compiled once, on first use, for the few the SDK writes
/// with `u`.
macro_rules! uni_re {
    ($pattern:expr) => {{
        static RE: std::sync::LazyLock<regex::Regex> =
            std::sync::LazyLock::new(|| regex::Regex::new($pattern).expect("a valid pattern"));
        &*RE
    }};
}
pub(crate) use uni_re;

/// `pattern.exec(text)?.[n]` for a Unicode pattern.
pub(crate) fn group_u(re: &regex::Regex, text: &str, n: usize) -> Option<String> {
    let caps = re.captures(text)?;
    Some(caps.get(n).map(|m| m.as_str().to_string()).unwrap_or_default())
}

/// `pattern.test(text)`.
pub(crate) fn test(re: &Regex, text: &str) -> bool {
    re.is_match(text.as_bytes())
}

/// `pattern.exec(text)?.[n]`, as text.
pub(crate) fn group(re: &Regex, text: &str, n: usize) -> Option<String> {
    let caps = re.captures(text.as_bytes())?;
    Some(caps.get(n).map(|m| String::from_utf8_lossy(m.as_bytes()).into_owned()).unwrap_or_default())
}

/// `text.replace(pattern_with_g, with)` for a literal replacement.
#[allow(dead_code)]
pub(crate) fn replace_all(re: &Regex, text: &str, with: &str) -> String {
    String::from_utf8_lossy(&re.replace_all(text.as_bytes(), regex::bytes::NoExpand(with.as_bytes()))).into_owned()
}

/// `text.replace(pattern_without_g, with)`: the first match only.
#[allow(dead_code)]
pub(crate) fn replace_first(re: &Regex, text: &str, with: &str) -> String {
    String::from_utf8_lossy(&re.replace(text.as_bytes(), regex::bytes::NoExpand(with.as_bytes()))).into_owned()
}
