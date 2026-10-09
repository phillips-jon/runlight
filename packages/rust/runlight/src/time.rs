//! Dates in a site's timezone. Ranges are computed here as epoch
//! milliseconds so the database only ever compares integers.
//!
//! The TypeScript reads local times through `Intl.DateTimeFormat`, which
//! knows ICU's zone names. jiff reads the system's time zone database, which
//! knows nearly the same ones, and the differences are settled here as the
//! PHP port settles them: a name is matched without regard to case, the few
//! that the database keeps as old fixed rules (CET, EST, MST) go to the zone
//! ICU reads them as, ICU's own extra names (PST, SystemV/EST5EDT) are
//! added, "Factory", which ICU refuses, is refused, and an offset such as
//! `+05:30` is a zone, as ECMA-402 takes one.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use jiff::tz::{Offset, TimeZone};

use crate::js::{self, date_utc, iso_string};
use crate::re::{js_re, test};

/// The named periods a range may be.
pub const PERIODS: [&str; 10] =
    ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"];
/// The intervals a chart may be bucketed by.
pub const INTERVALS: [&str; 4] = ["hour", "day", "week", "month"];

const MAX_BUCKETS: usize = 1000;
/// A month of hours. Longer hourly ranges are cut off rather than refused.
const MAX_HOURS: usize = 744;

/// A span of time in a site's timezone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Range {
    /// Inclusive.
    pub from: i64,
    /// Exclusive.
    pub to: i64,
    /// The first local date covered, YYYY-MM-DD, inclusive.
    pub from_date: String,
    /// The last local date covered, YYYY-MM-DD, inclusive.
    pub to_date: String,
    /// `hour`, `day`, `week`, or `month`.
    pub interval: &'static str,
}

/// One chart bucket.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bucket {
    /// Inclusive.
    pub start: i64,
    /// Exclusive.
    pub end: i64,
}

/// Names Intl reads as another zone where the database has no name, or keeps
/// an old fixed rule.
const ALIASES: &[(&str, &str)] = &[
    ("cet", "Europe/Brussels"),
    ("eet", "Europe/Athens"),
    ("est", "America/Panama"),
    ("gmt", "UTC"),
    ("gmt+0", "UTC"),
    ("gmt-0", "UTC"),
    ("hst", "Pacific/Honolulu"),
    ("met", "Europe/Brussels"),
    ("mst", "America/Phoenix"),
    ("uct", "UTC"),
    ("wet", "Europe/Lisbon"),
    ("act", "Australia/Darwin"),
    ("aet", "Australia/Sydney"),
    ("agt", "America/Argentina/Buenos_Aires"),
    ("art", "Africa/Cairo"),
    ("ast", "America/Anchorage"),
    ("bet", "America/Sao_Paulo"),
    ("bst", "Asia/Dhaka"),
    ("cat", "Africa/Maputo"),
    ("cnt", "America/St_Johns"),
    ("cst", "America/Chicago"),
    ("ctt", "Asia/Shanghai"),
    ("eat", "Africa/Nairobi"),
    ("ect", "Europe/Paris"),
    ("iet", "America/Indiana/Indianapolis"),
    ("ist", "Asia/Kolkata"),
    ("jst", "Asia/Tokyo"),
    ("mit", "Pacific/Apia"),
    ("net", "Asia/Yerevan"),
    ("nst", "Pacific/Auckland"),
    ("plt", "Asia/Karachi"),
    ("pnt", "America/Phoenix"),
    ("prt", "America/Puerto_Rico"),
    ("pst", "America/Los_Angeles"),
    ("sst", "Pacific/Guadalcanal"),
    ("vst", "Asia/Ho_Chi_Minh"),
    ("systemv/ast4", "Etc/GMT+4"),
    ("systemv/ast4adt", "America/Halifax"),
    ("systemv/est5", "Etc/GMT+5"),
    ("systemv/est5edt", "America/New_York"),
    ("systemv/cst6", "Etc/GMT+6"),
    ("systemv/cst6cdt", "America/Chicago"),
    ("systemv/mst7", "Etc/GMT+7"),
    ("systemv/mst7mdt", "America/Denver"),
    ("systemv/pst8", "Etc/GMT+8"),
    ("systemv/pst8pdt", "America/Los_Angeles"),
    ("systemv/yst9", "Etc/GMT+9"),
    ("systemv/yst9ydt", "America/Anchorage"),
    ("systemv/hst10", "Etc/GMT+10"),
    ("canada/east-saskatchewan", "America/Regina"),
    ("us/pacific-new", "America/Los_Angeles"),
];

static ZONES: LazyLock<Mutex<HashMap<String, Option<TimeZone>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// The zone `Intl.DateTimeFormat` would use for a `timeZone` option, or
/// `None` where it throws a RangeError.
fn zone(timezone: &str) -> Option<TimeZone> {
    let mut zones = ZONES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(found) = zones.get(timezone) {
        return found.clone();
    }
    let opened = open(timezone);
    zones.insert(timezone.to_string(), opened.clone());
    opened
}

fn open(timezone: &str) -> Option<TimeZone> {
    // An offset, as ECMA-402 takes one: a sign (a minus sign too), two digit hours, and optional minutes.
    let offset = regex::Regex::new(r"^([+\-]|\x{2212})([01][0-9]|2[0-3])(?::?([0-5][0-9]))?$").ok()?;
    if let Some(m) = offset.captures(timezone) {
        let sign = if &m[1] == "+" { 1 } else { -1 };
        let hours: i32 = m[2].parse().ok()?;
        let minutes: i32 = m.get(3).map_or(Some(0), |x| x.as_str().parse().ok())?;
        return Some(TimeZone::fixed(Offset::from_seconds(sign * (hours * 3600 + minutes * 60)).ok()?));
    }
    if !timezone.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
        return None;
    }
    let key = timezone.to_ascii_lowercase();
    // Names the system's database has and ICU does not.
    if matches!(
        key.as_str(),
        "factory" | "localtime" | "posixrules" | "etc/unknown" | "asia/riyadh87" | "mideast/riyadh87"
    ) || key.starts_with("posix/")
        || key.starts_with("right/")
    {
        return None;
    }
    if let Some((_, name)) = ALIASES.iter().find(|(k, _)| *k == key) {
        return TimeZone::get(name).ok();
    }
    TimeZone::get(timezone).ok()
}

/// Whether `Intl` takes the name as a time zone.
pub fn is_timezone(value: &str) -> bool {
    zone(value).is_some()
}

/// Year, month, day, hour, minute, and second of an instant in a zone, as
/// Intl formats them. An unknown zone reads as UTC.
fn parts(ts: i64, timezone: &str) -> [i64; 6] {
    let tz = zone(timezone).unwrap_or(TimeZone::UTC);
    let seconds = ts.div_euclid(1000);
    let Ok(at) = jiff::Timestamp::from_second(seconds) else {
        return [1970, 1, 1, 0, 0, 0];
    };
    let dt = tz.to_datetime(at);
    [
        i64::from(dt.year()),
        i64::from(dt.month()),
        i64::from(dt.day()),
        i64::from(dt.hour()),
        i64::from(dt.minute()),
        i64::from(dt.second()),
    ]
}

/// Milliseconds the zone is ahead of UTC at an instant.
fn offset(ts: i64, timezone: &str) -> i64 {
    let [y, mo, d, h, mi, s] = parts(ts, timezone);
    date_utc(y, mo - 1, d, h, mi, s, 0) - (ts - ts % 1000)
}

fn ymd(date: &str) -> (i64, i64, i64) {
    let mut it = date.split('-').map(|p| js::text_number(p) as i64);
    (it.next().unwrap_or(0), it.next().unwrap_or(0), it.next().unwrap_or(0))
}

/// The instant a local date (and hour) begins in a zone.
pub fn start_of(date: &str, timezone: &str, hour: i64) -> i64 {
    let (y, m, d) = ymd(date);
    let guess = date_utc(y, m - 1, d, hour, 0, 0, 0);
    let first = guess - offset(guess, timezone);
    let mut at = guess - offset(first, timezone);
    // Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
    // happens, and the sum above lands before it; the day then begins when the clocks land, at most a
    // few quarter hours on.
    for _ in 0..8 {
        let [ly, lm, ld, lh, _, _] = parts(at, timezone);
        if date_utc(ly, lm - 1, ld, lh, 0, 0, 0) >= guess {
            break;
        }
        at += 15 * 60_000;
    }
    at
}

/// The local date of an instant, YYYY-MM-DD.
pub fn local_date(ts: i64, timezone: &str) -> String {
    let [y, m, d, ..] = parts(ts, timezone);
    format!("{y:04}-{m:02}-{d:02}")
}

/// `new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10)`.
pub fn add_days(date: &str, days: i64) -> String {
    let (y, m, d) = ymd(date);
    js::head16(&iso_string(date_utc(y, m - 1, d + days, 0, 0, 0, 0)), 10)
}

/// The first of the month `months` from the date's.
pub fn add_months(date: &str, months: i64) -> String {
    let (y, m, _) = ymd(date);
    js::head16(&iso_string(date_utc(y, m - 1 + months, 1, 0, 0, 0, 0)), 10)
}

/// Whether the text is a date from 1900 to 9998 that exists.
pub fn is_date(value: &str) -> bool {
    // Years from 1900 to 9998, so the day after any date is a date too.
    if !test(js_re!(r"^\d{4}-\d{2}-\d{2}$"), value) || !("1900".."9999").contains(&value) {
        return false;
    }
    // A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
    let (y, m, d) = ymd(value);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return false;
    }
    js::head16(&iso_string(date_utc(y, m - 1, d, 0, 0, 0, 0)), 10) == value
}

fn date_ms(date: &str) -> i64 {
    let (y, m, d) = ymd(date);
    date_utc(y, m - 1, d, 0, 0, 0, 0)
}

fn days_between(from: &str, to: &str) -> i64 {
    js::round_i64((date_ms(to) - date_ms(from)) as f64 / 86_400_000.0)
}

fn default_interval(from_date: &str, to_date: &str) -> &'static str {
    let days = days_between(from_date, to_date);
    if days < 1 {
        "hour"
    } else if days <= 92 {
        "day"
    } else {
        "month"
    }
}

/// What a range is asked for with: a period, or custom dates, and an
/// interval.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RangeInput {
    /// A named period.
    pub period: Option<String>,
    /// Custom dates.
    pub from: Option<String>,
    /// Custom dates.
    pub to: Option<String>,
    /// The interval.
    pub interval: Option<String>,
}

fn filled(v: &Option<String>) -> Option<&str> {
    v.as_deref().filter(|s| !s.is_empty())
}

/// A named period or custom dates as a range in the site's timezone.
/// `first_date` is the earliest local date with data, used by "all".
pub fn resolve_range(input: &RangeInput, timezone: &str, now: i64, first_date: Option<&str>) -> Option<Range> {
    let today = local_date(now, timezone);
    let (from_date, to_date);
    if filled(&input.from).is_some() || filled(&input.to).is_some() {
        let (from, to) = (filled(&input.from)?, filled(&input.to)?);
        if !is_date(from) || !is_date(to) || from > to {
            return None;
        }
        from_date = from.to_string();
        to_date = to.to_string();
    } else {
        let period = input.period.as_deref().unwrap_or("30d");
        let month_start = format!("{}01", js::head16(&today, 8));
        (from_date, to_date) = match period {
            "today" => (today.clone(), today.clone()),
            "yesterday" => (add_days(&today, -1), add_days(&today, -1)),
            "7d" => (add_days(&today, -6), today.clone()),
            "30d" => (add_days(&today, -29), today.clone()),
            "90d" => (add_days(&today, -89), today.clone()),
            "month" => (month_start, today.clone()),
            "last_month" => (add_months(&today, -1), add_days(&month_start, -1)),
            "year" => (format!("{}-01-01", js::head16(&today, 4)), today.clone()),
            "12mo" => (add_months(&today, -11), today.clone()),
            "all" => (
                match first_date {
                    Some(f) if !f.is_empty() && f < today.as_str() => f.to_string(),
                    _ => today.clone(),
                },
                today.clone(),
            ),
            _ => return None,
        };
    }
    let interval = INTERVALS
        .iter()
        .find(|i| input.interval.as_deref() == Some(**i))
        .copied()
        .unwrap_or_else(|| default_interval(&from_date, &to_date));
    Some(Range {
        from: start_of(&from_date, timezone, 0),
        to: start_of(&add_days(&to_date, 1), timezone, 0),
        from_date,
        to_date,
        interval,
    })
}

fn add_years(date: &str, years: i64) -> String {
    let (y, m, d) = ymd(date);
    let mut shifted = date_utc(y + years, m - 1, d, 0, 0, 0, 0);
    // Feb 29 in a year without one becomes Feb 28, not Mar 1.
    let (sy, sm, _) = js::civil_from_days(shifted.div_euclid(86_400_000));
    if sm != m {
        shifted = date_utc(sy, sm - 1, 0, 0, 0, 0, 0);
    }
    js::head16(&iso_string(shifted), 10)
}

/// The range a period is compared with: the same number of days just
/// before it, the same dates a year earlier, or custom dates. `None` for
/// "off" or bad custom dates.
pub fn compare_range(
    range: &Range,
    mode: &str,
    timezone: &str,
    custom_from: Option<&str>,
    custom_to: Option<&str>,
) -> Option<Range> {
    let (from_date, to_date);
    match mode {
        "off" => return None,
        "year" => {
            from_date = add_years(&range.from_date, -1);
            to_date = add_years(&range.to_date, -1);
        }
        "custom" => {
            let from = custom_from.filter(|s| !s.is_empty())?;
            let to = custom_to.filter(|s| !s.is_empty())?;
            if !is_date(from) || !is_date(to) || from > to {
                return None;
            }
            from_date = from.to_string();
            to_date = to.to_string();
        }
        _ => {
            let days = days_between(&range.from_date, &range.to_date) + 1;
            from_date = add_days(&range.from_date, -days);
            to_date = add_days(&range.from_date, -1);
        }
    }
    Some(Range {
        from: start_of(&from_date, timezone, 0),
        to: start_of(&add_days(&to_date, 1), timezone, 0),
        from_date,
        to_date,
        interval: range.interval,
    })
}

fn weekday_of(date: &str) -> i64 {
    // getUTCDay: 0 is Sunday; 1970-01-01 was a Thursday.
    (date_ms(date).div_euclid(86_400_000) + 4).rem_euclid(7)
}

/// Chart buckets covering a range, each starting on a local boundary.
pub fn buckets(range: &Range, timezone: &str) -> Vec<Bucket> {
    let mut starts: Vec<i64> = Vec::new();
    if range.interval == "hour" {
        let mut t = range.from;
        while t < range.to && starts.len() < MAX_HOURS {
            starts.push(t);
            t += 3_600_000;
        }
    } else {
        let mut date = range.from_date.clone();
        if range.interval == "week" {
            let weekday = (weekday_of(&date) + 6) % 7;
            date = add_days(&date, -weekday);
        } else if range.interval == "month" {
            date = format!("{}01", js::head16(&date, 8));
        }
        while date <= range.to_date && starts.len() < MAX_BUCKETS {
            starts.push(start_of(&date, timezone, 0));
            date = match range.interval {
                "day" => add_days(&date, 1),
                "week" => add_days(&date, 7),
                _ => add_months(&date, 1),
            };
        }
    }
    (0..starts.len())
        .map(|i| Bucket {
            start: starts[i].max(range.from),
            end: starts.get(i + 1).copied().unwrap_or(range.to).min(range.to),
        })
        .collect()
}

/// The local weekday (Monday is 0) and hour of an instant.
pub fn local_weekday_hour(ts: i64, timezone: &str) -> (i64, i64) {
    let [y, m, d, h, ..] = parts(ts, timezone);
    let days = date_utc(y, m - 1, d, 0, 0, 0, 0).div_euclid(86_400_000);
    // getUTCDay counts from Sunday, and 1970-01-01 was a Thursday.
    (((days + 4).rem_euclid(7) + 6) % 7, h)
}
