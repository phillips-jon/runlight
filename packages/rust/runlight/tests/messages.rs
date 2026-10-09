//! The translator, Intl, report periods, and the version, against the
//! fixtures written from the TypeScript SDK (messages.json, reports.json, and
//! version.json).

mod common;

use common::{fixture, list, s};
use runlight::js::{self, Value};
use runlight::{intl, messages, reports, version};

fn num(v: &Value) -> f64 {
    match v {
        Value::String(t) if t == "NaN" => f64::NAN,
        Value::String(t) if t == "Infinity" => f64::INFINITY,
        Value::String(t) if t == "-Infinity" => f64::NEG_INFINITY,
        other => js::js_number(other),
    }
}

#[test]
fn languages_are_the_dashboards() {
    let f = fixture("messages");
    let want: Vec<String> = list(&f, "languages").iter().map(|v| v.as_str().unwrap().to_string()).collect();
    assert_eq!(messages::languages(), want);
}

#[test]
fn plural_forms_match_intl() {
    let f = fixture("messages");
    let numbers = list(&f, "numbers");
    let mut checked = 0;
    for (lang, forms) in f.at("plural").as_object().unwrap().iter() {
        for (i, form) in forms.as_array().unwrap().iter().enumerate() {
            assert_eq!(
                messages::plural(lang, num(&numbers[i])),
                form.as_str().unwrap(),
                "{lang} {}",
                numbers[i].to_json()
            );
            checked += 1;
        }
    }
    assert!(checked > 1000);
    assert_eq!(messages::plural("fr", 0.0), "one");
    assert_eq!(messages::plural("fr", 1.5), "one");
    assert_eq!(messages::plural("fr", 1_000_000.0), "many");
    assert_eq!(messages::plural("en", 0.0), "other");
}

#[test]
fn words_match() {
    let f = fixture("messages");
    let mut checked = 0;
    for set in list(&f, "words") {
        let words = messages::translator(s(set, "lang"));
        assert_eq!(words.lang, s(set, "code"));
        for case in list(set, "t") {
            let vars: Vec<(&str, Value)> =
                case.at("vars").as_object().unwrap().iter().map(|(k, v)| (k, v.clone())).collect();
            assert_eq!(words.t(s(case, "key"), &vars), s(case, "text"), "{} {}", s(set, "lang"), s(case, "key"));
            checked += 1;
        }
        for case in list(set, "tn") {
            let n = case.at("n").clone();
            let vars = [("n", n.clone()), ("name", Value::from("x"))];
            assert_eq!(
                words.tn(s(case, "key"), num(&n), &vars),
                s(case, "text"),
                "{} {} {}",
                s(set, "lang"),
                s(case, "key"),
                n.to_json()
            );
            checked += 1;
        }
    }
    assert!(checked > 100);
}

fn intl_set(lang: &str) -> Value {
    list(&fixture("reports"), "intl").iter().find(|set| s(set, "lang") == lang).unwrap().clone()
}

#[test]
fn numbers_percents_currencies_dates_and_regions_are_written_as_intl_writes_them() {
    for lang in ["en", "de", "es", "fr", "pt"] {
        let set = intl_set(lang);
        let pairs = |key: &str| list(&set, key).iter().map(|p| p.as_array().unwrap().clone()).collect::<Vec<_>>();
        for p in pairs("number") {
            assert_eq!(
                intl::number(lang, num(&p[0]), 0, 3),
                p[1].as_str().unwrap(),
                "{lang} number {}",
                p[0].to_json()
            );
        }
        for p in pairs("decimal") {
            assert_eq!(
                intl::number(lang, num(&p[0]), 1, 1),
                p[1].as_str().unwrap(),
                "{lang} decimal {}",
                p[0].to_json()
            );
        }
        for p in pairs("percent") {
            assert_eq!(intl::percent(lang, num(&p[0])), p[1].as_str().unwrap(), "{lang} percent {}", p[0].to_json());
        }
        for p in pairs("currency") {
            let n = num(&p[0]);
            let max = if js::is_integer(n) { 0 } else { 2 };
            assert_eq!(
                intl::currency(lang, n, p[1].as_str().unwrap(), max),
                p[2].as_str().unwrap(),
                "{lang} {n} {}",
                p[1].to_json()
            );
        }
        for p in pairs("monthYear") {
            assert_eq!(
                intl::month_year(lang, p[0].as_str().unwrap()),
                p[1].as_str().unwrap(),
                "{lang} {}",
                p[0].to_json()
            );
        }
        for p in pairs("shortDay") {
            let day = p[0].as_str().unwrap();
            assert_eq!(intl::short_day(lang, day, false), p[1].as_str().unwrap(), "{lang} {day}");
            assert_eq!(intl::short_day(lang, day, true), p[2].as_str().unwrap(), "{lang} {day}");
        }
        let regions = pairs("region");
        assert!(regions.len() > 600);
        for p in regions {
            let code = p[0].as_str().unwrap();
            assert_eq!(intl::region(lang, code), p[1].as_str().unwrap(), "{lang} region {code}");
        }
    }
}

#[test]
fn intl_edges() {
    assert_eq!(intl::number("en", f64::NAN, 0, 3), "NaN");
    assert_eq!(intl::number("de", f64::NEG_INFINITY, 0, 3), "-∞");
    assert_eq!(intl::number("en", -1234.5, 0, 3), "-1,234.5");
    assert_eq!(intl::number("en", 1e21, 0, 3), "1,000,000,000,000,000,000,000");
    assert_eq!(intl::number("fr", 12345.0, 0, 3), "12\u{202f}345");
    assert_eq!(intl::number("es", 12345.0, 0, 3), "12.345");
    assert_eq!(intl::number("xx", 1234.0, 0, 3), "1,234", "an unknown language is English");
    assert_eq!(intl::currency("en", 2.5, "JPY", 2), "¥2.5", "fewer digits than the currency's own when it has none");
    assert_eq!(intl::currency("en", 1.5, "BHD", 2), "BHD\u{a0}1.50");
    assert_eq!(intl::currency("en", -5.0, "USD", 0), "-$5");
    assert_eq!(intl::currency("en", 5.0, "US1", 0), "5 US1");
    assert_eq!(intl::region("en", "gb"), "gb");
    // Node 24's answers for negative money, a three digit currency, a negative percent, a rounded away
    // negative, and a carry at one decimal.
    let node = [
        ("en", "-\u{20ac}1,234,567.89", "KWD\u{a0}12,345.50", "-12%", "-0", "123,456.8"),
        ("de", "-1.234.567,89\u{a0}\u{20ac}", "12.345,50\u{a0}KWD", "-12\u{a0}%", "-0", "123.456,8"),
        ("es", "-1.234.567,89\u{a0}\u{20ac}", "12.345,50\u{a0}KWD", "-12\u{a0}%", "-0", "123.456,8"),
        (
            "fr",
            "-1\u{202f}234\u{202f}567,89\u{a0}\u{20ac}",
            "12\u{202f}345,50\u{a0}KWD",
            "-12\u{a0}%",
            "-0",
            "123\u{202f}456,8",
        ),
        ("pt", "-\u{20ac}\u{a0}1.234.567,89", "KWD\u{a0}12.345,50", "-12%", "-0", "123.456,8"),
    ];
    for (lang, euros, dinars, pct, tiny, carry) in node {
        assert_eq!(intl::currency(lang, -1_234_567.891, "EUR", 2), euros, "{lang}");
        assert_eq!(intl::currency(lang, 12_345.5, "KWD", 2), dinars, "{lang}");
        assert_eq!(intl::percent(lang, -0.123), pct, "{lang}");
        assert_eq!(intl::number(lang, -0.0001, 0, 3), tiny, "{lang}");
        assert_eq!(intl::number(lang, 123_456.75, 1, 1), carry, "{lang}");
    }
}

#[test]
fn report_periods_match_for_every_zone_and_frequency() {
    let f = fixture("reports");
    let periods = list(&f, "periods");
    assert!(periods.len() > 3000);
    for case in periods {
        let got = reports::last_period(s(case, "frequency"), num(case.at("now")) as i64, s(case, "zone"));
        assert_eq!(got.to_value().to_json(), case.at("period").to_json(), "{}", case.to_json());
    }
}

#[test]
fn report_periods_are_last_monday_to_sunday_or_last_month() {
    // Wednesday 8 October 2026, 15:00 UTC (11:00 in Toronto).
    let now = js::date_utc(2026, 9, 8, 15, 0, 0, 0);
    let week = reports::last_period("weekly", now, "America/Toronto");
    assert_eq!(
        (week.key.as_str(), week.from_date.as_str(), week.to_date.as_str(), week.previous_from.as_str()),
        ("w:2026-09-28", "2026-09-28", "2026-10-04", "2026-09-21")
    );
    assert_eq!(week.due_at, js::date_utc(2026, 9, 5, 12, 0, 0, 0), "Monday 5 October, 8am Toronto");
    let month = reports::last_period("monthly", now, "America/Toronto");
    assert_eq!(
        (
            month.key.as_str(),
            month.from_date.as_str(),
            month.to_date.as_str(),
            month.previous_from.as_str(),
            month.previous_to.as_str()
        ),
        ("m:2026-09", "2026-09-01", "2026-09-30", "2026-08-01", "2026-08-31")
    );
}

#[test]
fn the_versions_are_the_typescript_sdks() {
    let f = fixture("version");
    assert_eq!(version::VERSION, s(&f, "version"));
    assert_eq!(f64::from(version::API_VERSION), f.at("apiVersion").as_f64().unwrap());
}
