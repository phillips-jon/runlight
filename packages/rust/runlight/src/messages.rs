//! The dashboard's translations, for text the server writes (email reports).
//! Same keys, same placeholders, so every language stays in one place.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::js::{self, Value};

/// Each language's table, in the order assets/locales.json lists them
/// (English first), parsed once.
static TABLES: LazyLock<Vec<(String, HashMap<String, String>)>> = LazyLock::new(|| {
    let raw = js::parse(include_str!("../assets/locales.json")).expect("assets/locales.json is JSON");
    let mut out = Vec::new();
    if let Some(langs) = raw.as_object() {
        for (code, text) in langs.iter() {
            let mut table = HashMap::new();
            if let Some(Value::Object(words)) = text.as_str().and_then(|t| js::parse(t).ok()) {
                for (key, word) in words.iter() {
                    if let Some(word) = word.as_str() {
                        table.insert(key.to_string(), word.to_string());
                    }
                }
            }
            out.push((code.to_string(), table));
        }
    }
    out
});

static EMPTY: LazyLock<HashMap<String, String>> = LazyLock::new(HashMap::new);

fn table(lang: &str) -> &'static HashMap<String, String> {
    TABLES.iter().find(|(code, _)| code == lang).map_or(&*EMPTY, |(_, table)| table)
}

/// The languages there are words for, English first.
pub fn languages() -> Vec<String> {
    let mut out = vec!["en".to_string()];
    out.extend(TABLES.iter().map(|(code, _)| code.clone()).filter(|code| code != "en"));
    out
}

/// The words for one language: `t(key, vars)` and `tn(key, n, vars)`, with
/// `lang` the language used, English when the one asked for is not known.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Translator {
    /// The language used.
    pub lang: String,
}

/// The words for a language, or English's.
pub fn translator(lang: &str) -> Translator {
    let code = if languages().iter().any(|l| l == lang) { lang } else { "en" };
    Translator { lang: code.to_string() }
}

/// `text.replace(/\{(\w+)\}/g, ...)`: each `{name}` with a var of that name
/// becomes the var as `String()` writes it; any other stays.
fn fill(text: &str, vars: &[(&str, Value)]) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let name_len = after.bytes().take_while(|b| b.is_ascii_alphanumeric() || *b == b'_').count();
        if name_len > 0 && after.as_bytes().get(name_len) == Some(&b'}') {
            let name = &after[..name_len];
            match vars.iter().find(|(k, _)| *k == name) {
                Some((_, v)) => out.push_str(&js::js_string(v)),
                None => out.push_str(&rest[open..open + name_len + 2]),
            }
            rest = &after[name_len + 1..];
        } else {
            out.push('{');
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

impl Translator {
    /// The text for a key with its placeholders filled: this language's,
    /// else English's, else the key itself.
    pub fn t(&self, key: &str, vars: &[(&str, Value)]) -> String {
        let text = table(&self.lang).get(key).or_else(|| table("en").get(key)).map_or(key, String::as_str);
        fill(text, vars)
    }

    /// The text for a count: the key with `_one`, `_other`, or the form
    /// Intl.PluralRules picks for `n` in this language.
    pub fn tn(&self, key: &str, n: f64, vars: &[(&str, Value)]) -> String {
        let form = plural(&self.lang, n);
        let own =
            table(&self.lang).get(&format!("{key}_{form}")).or_else(|| table(&self.lang).get(&format!("{key}_other")));
        match own {
            Some(text) if !text.is_empty() => fill(text, vars),
            _ => self.t(&format!("{key}_other"), vars),
        }
    }
}

/// `new Intl.PluralRules(lang).select(n)` for the dashboard's languages, by
/// CLDR's cardinal rules. As there, the number is first written with at most
/// three decimals (rounding half away from zero), and its integer digits i
/// and visible decimals v are read from that. Any other language answers
/// "other".
///
/// - en, de: one when i = 1 and v = 0
/// - es: one when n = 1; many when i is a non-zero multiple of a million and v = 0
/// - fr, pt: one when i is 0 or 1; many as in es
pub fn plural(lang: &str, n: f64) -> &'static str {
    if !n.is_finite() {
        return "other";
    }
    let (i, fraction) = plural_decimal(n.abs());
    let v = fraction.len();
    let million = i != "0" && i.len() >= 7 && i.ends_with("000000");
    match lang {
        "en" | "de" => {
            if i == "1" && v == 0 {
                "one"
            } else {
                "other"
            }
        }
        "es" => {
            if i == "1" && v == 0 {
                "one"
            } else if million && v == 0 {
                "many"
            } else {
                "other"
            }
        }
        "fr" | "pt" => {
            if i == "0" || i == "1" {
                "one"
            } else if million && v == 0 {
                "many"
            } else {
                "other"
            }
        }
        _ => "other",
    }
}

/// A non-negative number as its integer digits and up to three decimals
/// without trailing zeros, from the shortest decimal that reads back as the
/// number, as ICU formats it.
fn plural_decimal(n: f64) -> (String, String) {
    let mut text = js::format_number(n);
    // Plain digits, from JavaScript's exponent form where it uses one.
    if let Some(e) = text.find('e') {
        let (mantissa, exponent) = (&text[..e], &text[e + 1..]);
        let exponent: i64 = exponent.parse().unwrap_or(0);
        let (int, frac) = mantissa.split_once('.').unwrap_or((mantissa, ""));
        let digits = format!("{int}{frac}");
        let point = int.len() as i64 + exponent;
        text = if point <= 0 {
            format!("0.{}{digits}", "0".repeat((-point) as usize))
        } else if point as usize >= digits.len() {
            format!("{digits}{}", "0".repeat(point as usize - digits.len()))
        } else {
            format!("{}.{}", &digits[..point as usize], &digits[point as usize..])
        };
    }
    let (whole, fraction) = text.split_once('.').unwrap_or((&text, ""));
    let mut whole = whole.to_string();
    let mut fraction = fraction.to_string();
    if fraction.len() > 3 {
        let up = fraction.as_bytes()[3] >= b'5';
        fraction.truncate(3);
        if up {
            // Add one at the third decimal, carrying into the whole part.
            let all = increment(&format!("{whole}{fraction}"));
            whole = all[..all.len() - 3].to_string();
            fraction = all[all.len() - 3..].to_string();
        }
    }
    // ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so 1e21 has i = 0.
    let low = &whole[whole.len().saturating_sub(18)..];
    let low = low.trim_start_matches('0');
    (if low.is_empty() { "0".to_string() } else { low.to_string() }, fraction.trim_end_matches('0').to_string())
}

/// Adds one to a string of decimal digits.
pub(crate) fn increment(digits: &str) -> String {
    let mut bytes = digits.as_bytes().to_vec();
    let mut i = bytes.len();
    while i > 0 && bytes[i - 1] == b'9' {
        bytes[i - 1] = b'0';
        i -= 1;
    }
    if i == 0 {
        bytes.insert(0, b'1');
    } else {
        bytes[i - 1] += 1;
    }
    String::from_utf8(bytes).unwrap_or_default()
}
