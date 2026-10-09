//! The pieces of JavaScript's Intl the email reports use, for the dashboard's
//! languages (en, de, es, fr, and pt), written out so they read as Node's do:
//! Intl.NumberFormat for counts, percents, one decimal place, and money,
//! Intl.DateTimeFormat for a month and year or a short day, and
//! Intl.DisplayNames for region names. Region names and each currency's
//! symbol come from assets/intl.json, which scripts/rust-intl.mts writes from
//! Node's own ICU.
//!
//! Numbers round as ICU does, half away from zero on the number's shortest
//! decimal form, so 2.05 to one place is 2.1, though the double just under it
//! is what is stored.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::js::{self, Value};

const LANGS: [&str; 5] = ["en", "de", "es", "fr", "pt"];

fn group(lang: &str) -> &'static str {
    match lang {
        "de" | "es" | "pt" => ".",
        "fr" => "\u{202F}",
        _ => ",",
    }
}

fn decimal_mark(lang: &str) -> &'static str {
    if lang == "en" { "." } else { "," }
}

const MONTHS: [[&str; 12]; 5] = [
    [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ],
    [
        "Januar",
        "Februar",
        "März",
        "April",
        "Mai",
        "Juni",
        "Juli",
        "August",
        "September",
        "Oktober",
        "November",
        "Dezember",
    ],
    [
        "enero",
        "febrero",
        "marzo",
        "abril",
        "mayo",
        "junio",
        "julio",
        "agosto",
        "septiembre",
        "octubre",
        "noviembre",
        "diciembre",
    ],
    [
        "janvier",
        "février",
        "mars",
        "avril",
        "mai",
        "juin",
        "juillet",
        "août",
        "septembre",
        "octobre",
        "novembre",
        "décembre",
    ],
    [
        "janeiro",
        "fevereiro",
        "março",
        "abril",
        "maio",
        "junho",
        "julho",
        "agosto",
        "setembro",
        "outubro",
        "novembro",
        "dezembro",
    ],
];

const SHORT_MONTHS: [[&str; 12]; 5] = [
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."],
    ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"],
    ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."],
    ["jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."],
];

/// `{ month: "long", year: "numeric" }`, then `{ month: "short", day: "numeric" }` without and with the year.
const DATE_PATTERNS: [[&str; 3]; 5] = [
    ["{M} {y}", "{m} {d}", "{m} {d}, {y}"],
    ["{M} {y}", "{d}. {m}", "{d}. {m} {y}"],
    ["{M} de {y}", "{d} {m}", "{d} {m} {y}"],
    ["{M} {y}", "{d} {m}", "{d} {m} {y}"],
    ["{M} de {y}", "{d} de {m}", "{d} de {m} de {y}"],
];

/// The language's place in the tables, English for one not known.
fn index(lang: &str) -> usize {
    LANGS.iter().position(|l| *l == lang).unwrap_or(0)
}

fn lang_of(lang: &str) -> &'static str {
    LANGS[index(lang)]
}

/// How one language writes money: an unknown code's placement, the symbols
/// that differ from it, and the currencies whose digits are not two.
struct Money {
    unknown: (String, String),
    symbols: HashMap<String, (String, String)>,
    digits: HashMap<String, usize>,
}

struct Data {
    regions: HashMap<String, HashMap<String, String>>,
    money: HashMap<String, Money>,
}

static DATA: LazyLock<Data> = LazyLock::new(|| {
    let raw = js::parse(include_str!("../assets/intl.json")).expect("assets/intl.json is JSON");
    let pair = |v: &Value| -> (String, String) {
        let a = v.as_array().map(Vec::as_slice).unwrap_or(&[]);
        let side = |i: usize| a.get(i).and_then(Value::as_str).unwrap_or("").to_string();
        (side(0), side(1))
    };
    let mut regions = HashMap::new();
    if let Some(langs) = raw.get("regions").and_then(Value::as_object) {
        for (lang, names) in langs.iter() {
            let mut own = HashMap::new();
            for (code, name) in names.as_object().map(|o| o.iter().collect::<Vec<_>>()).unwrap_or_default() {
                own.insert(code.to_string(), name.as_str().unwrap_or(code).to_string());
            }
            regions.insert(lang.to_string(), own);
        }
    }
    let mut money = HashMap::new();
    if let Some(langs) = raw.get("currencies").and_then(Value::as_object) {
        for (lang, m) in langs.iter() {
            let symbols = m
                .get("symbols")
                .and_then(Value::as_object)
                .map(|o| o.iter().map(|(code, v)| (code.to_string(), pair(v))).collect())
                .unwrap_or_default();
            let digits = m
                .get("digits")
                .and_then(Value::as_object)
                .map(|o| o.iter().map(|(code, v)| (code.to_string(), v.as_f64().unwrap_or(2.0) as usize)).collect())
                .unwrap_or_default();
            money.insert(lang.to_string(), Money { unknown: pair(m.at("unknown")), symbols, digits });
        }
    }
    Data { regions, money }
});

/// `new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n)`; the
/// defaults are 0 and 3.
pub fn number(lang: &str, n: f64, min_fraction: usize, max_fraction: usize) -> String {
    let lang = lang_of(lang);
    if n.is_nan() {
        return "NaN".into();
    }
    if n.is_infinite() {
        return format!("{}∞", if n < 0.0 { "-" } else { "" });
    }
    let (negative, digits, point) = shortest(n);
    written(lang, negative, &digits, point, min_fraction, max_fraction)
}

/// `new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n)`.
pub fn percent(lang: &str, n: f64) -> String {
    let lang = lang_of(lang);
    let amount = if n.is_finite() {
        // n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5 and not 13.500000000000002.
        let (negative, digits, point) = shortest(n);
        written(lang, negative, &digits, point + 2, 0, 0)
    } else {
        number(lang, n, 0, 0)
    };
    match lang {
        "en" | "pt" => format!("{amount}%"),
        _ => format!("{amount}\u{A0}%"),
    }
}

/// `new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n)`, or
/// `${n} ${currency}` where Intl throws (a currency code that is not three letters).
pub fn currency(lang: &str, n: f64, currency: &str, max_fraction: usize) -> String {
    let lang = lang_of(lang);
    if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_alphabetic()) {
        return format!("{} {currency}", js::format_number(n));
    }
    let code = currency.to_ascii_uppercase();
    let Some(money) = DATA.money.get(lang) else {
        return format!("{} {currency}", js::format_number(n));
    };
    let (before, after) = money
        .symbols
        .get(&code)
        .cloned()
        .unwrap_or_else(|| (money.unknown.0.replace("{c}", &code), money.unknown.1.replace("{c}", &code)));
    // The currency's own digits are the least shown, unless fewer are the most.
    let min = money.digits.get(&code).copied().unwrap_or(2).min(max_fraction);
    let negative = n < 0.0 || (n == 0.0 && n.is_sign_negative());
    let amount = number(lang, n.abs(), min, max_fraction);
    format!("{}{before}{amount}{after}", if negative { "-" } else { "" })
}

/// A date, YYYY-MM-DD, as `{ month: "long", year: "numeric" }` writes it.
pub fn month_year(lang: &str, date: &str) -> String {
    date_text(lang, date, 0)
}

/// A date as `{ month: "short", day: "numeric" }` writes it, with `year: "numeric"` too when asked.
pub fn short_day(lang: &str, date: &str, with_year: bool) -> String {
    date_text(lang, date, if with_year { 2 } else { 1 })
}

fn date_text(lang: &str, date: &str, pattern: usize) -> String {
    let at = index(lang);
    let mut parts = date.split('-').map(|p| p.parse::<i64>().unwrap_or(0));
    let (y, m, d) = (parts.next().unwrap_or(0), parts.next().unwrap_or(1), parts.next().unwrap_or(1));
    let month = (m.clamp(1, 12) - 1) as usize;
    DATE_PATTERNS[at][pattern]
        .replace("{M}", MONTHS[at][month])
        .replace("{m}", SHORT_MONTHS[at][month])
        .replace("{d}", &d.to_string())
        .replace("{y}", &y.to_string())
}

/// `new Intl.DisplayNames(lang, { type: "region" }).of(code)`, or the code where that throws or has no
/// name. Only an upper case code is looked up; Intl gives any other back as it came.
pub fn region(lang: &str, code: &str) -> String {
    let b = code.as_bytes();
    let shaped =
        (b.len() == 2 && b.iter().all(u8::is_ascii_uppercase)) || (b.len() == 3 && b.iter().all(u8::is_ascii_digit));
    if !shaped {
        return code.to_string();
    }
    DATA.regions.get(lang_of(lang)).and_then(|names| names.get(code)).cloned().unwrap_or_else(|| code.to_string())
}

/// The shortest decimal form of a double: its sign, its significant digits,
/// and where the point goes (the number of digits before it, which may be
/// zero or negative).
fn shortest(n: f64) -> (bool, String, i64) {
    let negative = n < 0.0 || (n == 0.0 && n.is_sign_negative());
    if n == 0.0 {
        return (negative, "0".into(), 1);
    }
    // Rust's `{:e}` writes the shortest digits that read back as the number.
    let text = format!("{:e}", n.abs());
    let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
    let exponent: i64 = exponent.parse().unwrap_or(0);
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let trimmed = digits.trim_end_matches('0');
    let trimmed = if trimmed.is_empty() { "0" } else { trimmed };
    (negative, trimmed.to_string(), 1 + exponent)
}

/// Digits with the point after `point` of them, rounded half away from zero
/// to at most `max` places, padded to at least `min`, grouped and marked as
/// the language writes them.
fn written(lang: &str, negative: bool, digits: &str, point: i64, min: usize, max: usize) -> String {
    // Digits as a whole number of units of 10^-max.
    let keep = point + max as i64;
    let units = if keep < 0 {
        "0".to_string()
    } else if digits.len() as i64 > keep {
        let k = keep as usize;
        let head = if k == 0 { "0".to_string() } else { digits[..k].to_string() };
        if digits.as_bytes()[k] >= b'5' { crate::messages::increment(&head) } else { head }
    } else {
        format!("{digits}{}", "0".repeat(keep as usize - digits.len()))
    };
    let units = format!("{}{units}", "0".repeat((max + 1).saturating_sub(units.len())));
    let whole = units[..units.len() - max].trim_start_matches('0');
    let whole = if whole.is_empty() { "0" } else { whole };
    let fraction = if max > 0 { &units[units.len() - max..] } else { "" };
    let mut fraction = fraction.trim_end_matches('0').to_string();
    while fraction.len() < min {
        fraction.push('0');
    }
    // Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
    let grouped = if lang == "es" && whole.len() < 5 {
        whole.to_string()
    } else {
        let mut out = String::new();
        for (i, c) in whole.chars().enumerate() {
            if i > 0 && (whole.len() - i) % 3 == 0 {
                out.push_str(group(lang));
            }
            out.push(c);
        }
        out
    };
    format!(
        "{}{grouped}{}",
        if negative { "-" } else { "" },
        if fraction.is_empty() { String::new() } else { format!("{}{fraction}", decimal_mark(lang)) }
    )
}
