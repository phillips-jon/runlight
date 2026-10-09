//! Email reports: the period one covers, and the subject, HTML, and text of
//! one site's report in a language.

use crate::http::Url;
use crate::intl;
use crate::js::{self, Value};
use crate::messages::translator;
use crate::obj;
use crate::query::Query;
use crate::store::{DbError, GoalRow, SiteRow, SqlStore, Stats};
use crate::time::{add_days, add_months, local_date, start_of};

/// The span of days a report covers, and the one before it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReportPeriod {
    /// `w:<monday>` or `m:<yyyy-mm>`, so each period is sent once.
    pub key: String,
    /// The first day, YYYY-MM-DD.
    pub from_date: String,
    /// The last day.
    pub to_date: String,
    /// The first day of the period before.
    pub previous_from: String,
    /// The last day of the period before.
    pub previous_to: String,
    /// Reports go out from 8am the day after the period ends, in the site's timezone.
    pub due_at: i64,
}

impl ReportPeriod {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        obj! {
            "key" => self.key.clone(),
            "fromDate" => self.from_date.clone(),
            "toDate" => self.to_date.clone(),
            "previousFrom" => self.previous_from.clone(),
            "previousTo" => self.previous_to.clone(),
            "dueAt" => self.due_at,
        }
    }
}

/// The last complete week (Monday to Sunday) or month before `now`, in a
/// timezone. `frequency` is `weekly` or `monthly`.
pub fn last_period(frequency: &str, now: i64, timezone: &str) -> ReportPeriod {
    let today = local_date(now, timezone);
    if frequency == "monthly" {
        let first = format!("{}01", js::head16(&today, 8));
        let from_date = add_months(&first, -1);
        return ReportPeriod {
            key: format!("m:{}", js::head16(&from_date, 7)),
            to_date: add_days(&first, -1),
            previous_from: add_months(&from_date, -1),
            previous_to: add_days(&from_date, -1),
            due_at: start_of(&first, timezone, 8),
            from_date,
        };
    }
    let (y, m, d) = ymd(&today);
    // getUTCDay counts from Sunday; this from Monday.
    let weekday = (js::days_from_civil(y, m, d) + 3).rem_euclid(7);
    let monday = add_days(&today, -weekday);
    let from_date = add_days(&monday, -7);
    ReportPeriod {
        key: format!("w:{from_date}"),
        to_date: add_days(&monday, -1),
        previous_from: add_days(&from_date, -7),
        previous_to: add_days(&from_date, -1),
        due_at: start_of(&monday, timezone, 8),
        from_date,
    }
}

fn ymd(date: &str) -> (i64, i64, i64) {
    let mut it = date.split('-').map(|p| p.parse::<i64>().unwrap_or(0));
    (it.next().unwrap_or(0), it.next().unwrap_or(1), it.next().unwrap_or(1))
}

/// Text made safe for HTML.
fn esc(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

fn duration(ms: f64) -> String {
    let seconds = js::round(ms / 1000.0);
    if seconds < 60.0 {
        return format!("{}s", js::format_number(seconds));
    }
    let minutes = (seconds / 60.0).floor();
    if minutes < 60.0 {
        return format!("{}m {:0>2}s", js::format_number(minutes), js::format_number(seconds % 60.0));
    }
    format!("{}h {:0>2}m", js::format_number((minutes / 60.0).floor()), js::format_number(minutes % 60.0))
}

/// A report, ready to send.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuiltReport {
    /// The subject line.
    pub subject: String,
    /// The HTML body.
    pub html: String,
    /// The plain text body.
    pub text: String,
}

struct Delta {
    text: String,
    color: &'static str,
    tone: &'static str,
}

/// One site's report for a period, in a language. The links are absolute:
/// the dashboard and the recipient's unsubscribe page.
pub async fn build_report(
    store: &SqlStore,
    site: &SiteRow,
    frequency: &str,
    period: &ReportPeriod,
    lang: &str,
    dashboard_link: &str,
    unsubscribe_link: &str,
) -> Result<BuiltReport, DbError> {
    let words = translator(lang);
    let code = words.lang.as_str();
    let t = |key: &str, vars: &[(&str, Value)]| words.t(key, vars);
    let tz = site.timezone.as_str();
    let range = |from: &str, to: &str| Query {
        site: site.id.clone(),
        from: start_of(from, tz, 0),
        to: start_of(&add_days(to, 1), tz, 0),
        filters: vec![],
    };
    let query = range(&period.from_date, &period.to_date);
    let before = range(&period.previous_from, &period.previous_to);
    let now = store.stats(&query).await?;
    let prev = store.stats(&before).await?;
    let pages = store.breakdown(&query, "page", 5, 0).await?;
    let sources = store.breakdown(&query, "source", 5, 0).await?;
    let countries = store.breakdown(&query, "country", 5, 0).await?;
    let goals = store.goals(Some(&site.id)).await?;
    let totals = store.goal_totals_all(&query, &goals).await?;
    let mut goal_rows: Vec<(&GoalRow, crate::store::GoalTotals)> =
        goals.iter().map(|g| (g, totals.get(&g.id).cloned().unwrap_or_default())).collect();

    let number = |n: f64| intl::number(code, n, 0, 3);
    let percent = |n: f64| intl::percent(code, n);
    let money = |n: f64, currency: &str| intl::currency(code, n, currency, if js::is_integer(n) { 0 } else { 2 });
    let month_name = |d: &str| intl::month_year(code, d);
    // Each end formatted on its own, joined in the reader's language (never with a dash).
    let span = |from: &str, to: &str| {
        let same_year = js::head16(from, 4) == js::head16(to, 4);
        t(
            "email.range",
            &[("from", intl::short_day(code, from, !same_year).into()), ("to", intl::short_day(code, to, true).into())],
        )
    };

    let monthly = frequency == "monthly";
    let when = if monthly {
        t("email.when.month", &[("month", month_name(&period.from_date).into())])
    } else {
        t("email.when.week", &[])
    };
    let against = if monthly { month_name(&period.previous_from) } else { t("email.before.week", &[]) };
    let who = words.tn("headline.who", now.visitors, &[("n", number(now.visitors).into())]);
    let verb = words.tn("headline.visited", now.visitors, &[]);
    let change = if prev.visitors != 0.0 && !prev.visitors.is_nan() {
        Some((now.visitors - prev.visitors) / prev.visitors)
    } else {
        None
    };
    let headline = if prev.visitors == 0.0 && now.visitors > 0.0 {
        t(
            "headline.fromNone",
            &[
                ("who", who.clone().into()),
                ("verb", verb.clone().into()),
                ("when", when.clone().into()),
                ("against", against.clone().into()),
            ],
        )
    } else {
        match change {
            None => t(
                "headline.plain",
                &[("who", who.clone().into()), ("verb", verb.clone().into()), ("when", when.clone().into())],
            ),
            Some(change) => {
                let key = if change.abs() < 0.005 {
                    "headline.same"
                } else if change > 0.0 {
                    "headline.up"
                } else {
                    "headline.down"
                };
                let pct = js::round(change * 100.0).abs();
                let change_text =
                    t(if change > 0.0 { "headline.more" } else { "headline.fewer" }, &[("pct", pct.into())]);
                t(
                    key,
                    &[
                        ("who", who.clone().into()),
                        ("verb", verb.clone().into()),
                        ("when", when.clone().into()),
                        ("against", against.clone().into()),
                        ("change", change_text.into()),
                    ],
                )
            }
        }
    };
    let subject = t(
        if monthly { "email.subject.month" } else { "email.subject.week" },
        &[
            ("site", site.name.clone().into()),
            ("who", who.clone().into()),
            ("month", month_name(&period.from_date).into()),
        ],
    );
    let dates = span(&period.from_date, &period.to_date);

    // Each metric: its key, how it is written, and whether lower is better.
    let metrics: [(&str, bool); 6] = [
        ("visitors", false),
        ("visits", false),
        ("pageviews", false),
        ("viewsPerVisit", false),
        ("bounceRate", true),
        ("visitDuration", false),
    ];
    let format = |key: &str, n: f64| match key {
        "viewsPerVisit" => intl::number(code, n, 1, 1),
        "bounceRate" => percent(n),
        "visitDuration" => duration(n),
        _ => number(n),
    };
    let delta = |key: &str, lower_is_better: bool, now: &Stats, prev: &Stats| -> Delta {
        let b = prev.get(key);
        if b == 0.0 || b.is_nan() {
            return Delta { text: String::new(), color: "#6b7280", tone: "flat" };
        }
        let c = (now.get(key) - b) / b;
        if c.abs() < 0.005 {
            return Delta { text: "0%".into(), color: "#6b7280", tone: "flat" };
        }
        let good = if lower_is_better { c < 0.0 } else { c > 0.0 };
        Delta {
            text: format!("{} {}", if c > 0.0 { "↑" } else { "↓" }, percent(c.abs())),
            color: if good { "#15803d" } else { "#b91c1c" },
            tone: if good { "up" } else { "down" },
        }
    };

    let value_of = |r: &Value| js::str_or_empty(r.get("value"));
    let visitors_of = |r: &Value| number(js::opt_number(r.get("visitors")));
    let mut lists: Vec<(String, Vec<(String, String)>)> = vec![
        (
            t("email.pages", &[]),
            pages
                .iter()
                .map(|r| {
                    let v = value_of(r);
                    (if v.is_empty() { "/".to_string() } else { v }, visitors_of(r))
                })
                .collect(),
        ),
        (
            t("email.sources", &[]),
            sources
                .iter()
                .map(|r| {
                    let v = value_of(r);
                    (if v.is_empty() { t("goals.unknown", &[]) } else { v }, visitors_of(r))
                })
                .collect(),
        ),
        (
            t("email.countries", &[]),
            countries.iter().map(|r| (intl::region(code, &value_of(r)), visitors_of(r))).collect(),
        ),
    ];
    if !goal_rows.is_empty() {
        goal_rows.sort_by(|a, b| b.1.conversions.partial_cmp(&a.1.conversions).unwrap_or(std::cmp::Ordering::Equal));
        lists.push((
            t("email.conversions", &[]),
            goal_rows
                .iter()
                .map(|(goal, totals)| {
                    let name = if goal.value_mode != "none" && totals.revenue != 0.0 && !totals.revenue.is_nan() {
                        format!("{} ({})", goal.name, money(totals.revenue, &goal.currency))
                    } else {
                        goal.name.clone()
                    };
                    (name, number(totals.conversions))
                })
                .collect(),
        ));
    }

    let font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
    let cell = |(key, lower): &(&str, bool)| {
        let d = delta(key, *lower, &now, &prev);
        format!(
            "<td width=\"33%\" class=\"rl-line\" style=\"padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top\">
<div class=\"rl-muted\" style=\"font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280\">{}</div>
<div class=\"rl-ink\" style=\"font-size:24px;font-weight:600;color:#111827;margin-top:4px\">{}</div>
<div class=\"rl-{}\" style=\"font-size:12px;color:{};margin-top:2px;min-height:16px\">{}</div></td>",
            esc(&t(&format!("metric.{key}"), &[])),
            esc(&format(key, now.get(key))),
            d.tone,
            d.color,
            esc(&d.text)
        )
    };
    let table = |(title, rows): &(String, Vec<(String, String)>)| {
        let body = if rows.is_empty() {
            format!(
                "<tr><td class=\"rl-muted\" style=\"padding:7px 0;color:#6b7280\">{}</td></tr>",
                esc(&t("panel.empty", &[]))
            )
        } else {
            rows.iter()
                .map(|(a, b)| {
                    format!(
                        "<tr><td class=\"rl-row rl-body-text\" style=\"padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all\">{}</td><td align=\"right\" class=\"rl-row rl-ink\" style=\"padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap\">{}</td></tr>",
                        esc(a),
                        esc(b)
                    )
                })
                .collect::<String>()
        };
        format!(
            "<h3 class=\"rl-ink\" style=\"font-size:14px;color:#111827;margin:28px 0 8px\">{}</h3>
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;font-size:14px\">{body}</table>",
            esc(title)
        )
    };

    // Where the dashboard lives, without the scheme or the site query, so a reader
    // with several installs can tell which one sent this.
    let place = match Url::parse(dashboard_link) {
        Some(u) => {
            let path = u.pathname();
            format!("{}{}", u.host(), path.strip_suffix('/').unwrap_or(&path))
        }
        None => dashboard_link.to_string(),
    };
    let at = t("email.at", &[("where", place.clone().into())]);
    // The Runlight mark in table cells: mail apps block SVG and most inline images.
    let mark = format!(
        "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse\"><tr>
<td class=\"rl-mark\" width=\"24\" height=\"24\" align=\"center\" style=\"width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:{font}\">R</td>
<td class=\"rl-ink\" style=\"padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:{font}\">Runlight</td></tr></table>"
    );

    let footer = t(
        "email.footer",
        &[
            ("frequency", t(if monthly { "email.monthly" } else { "email.weekly" }, &[]).into()),
            ("site", site.name.clone().into()),
        ],
    );
    let at_link = esc(&t("email.at", &[("where", "\u{0}".into())])).replacen(
        '\u{0}',
        &format!("<a href=\"{}\" class=\"rl-muted\" style=\"color:#6b7280\">{}</a>", esc(dashboard_link), esc(&place)),
        1,
    );
    let first_row: String = metrics[..3].iter().map(cell).collect();
    let second_row: String = metrics[3..].iter().map(cell).collect();
    let tables: String = lists.iter().map(table).collect();
    let html = format!(
        "<!doctype html><html lang=\"{code}\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><meta name=\"supported-color-schemes\" content=\"light dark\"><title>{subject_html}</title>
<style>
@media (prefers-color-scheme: dark) {{
  .rl-page {{ background: #09090b !important; }}
  .rl-card {{ background: #141417 !important; border-color: #27272a !important; }}
  .rl-line {{ border-color: #27272a !important; }}
  .rl-row {{ border-top-color: #1f1f23 !important; }}
  .rl-ink {{ color: #ffffff !important; }}
  .rl-body-text {{ color: #d4d4d8 !important; }}
  .rl-muted, .rl-flat {{ color: #a1a1aa !important; }}
  .rl-up {{ color: #4ade80 !important; }}
  .rl-down {{ color: #f87171 !important; }}
  .rl-button {{ background: #ffffff !important; color: #000000 !important; }}
  .rl-mark {{ background: #ffffff !important; color: #000000 !important; }}
  .rl-foot, .rl-foot a {{ color: #a1a1aa !important; }}
}}
</style></head>
<body class=\"rl-page\" style=\"margin:0;padding:0;background:#f4f4f5;font-family:{font}\">
<div style=\"display:none;max-height:0;overflow:hidden\">{headline_html}</div>
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" class=\"rl-page\" style=\"background:#f4f4f5\"><tr><td align=\"center\" style=\"padding:32px 16px\">
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" class=\"rl-card\" style=\"max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb\"><tr><td style=\"padding:32px\">
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;margin:0 0 24px\"><tr>
<td style=\"vertical-align:middle\">{mark}</td>
<td align=\"right\" class=\"rl-muted\" style=\"vertical-align:middle;font-size:12px;color:#6b7280\">{at_link}</td>
</tr></table>
<div class=\"rl-muted\" style=\"font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280\">{site_html} · {dates_html}</div>
<h1 class=\"rl-ink\" style=\"font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600\">{headline_html}</h1>
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"6\" style=\"border-collapse:separate;margin:0 -6px\">
<tr>{first_row}</tr><tr>{second_row}</tr></table>
{tables}
<p style=\"margin:32px 0 0\"><a href=\"{dashboard_html}\" class=\"rl-button\" style=\"display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600\">{open_html}</a></p>
</td></tr></table>
<p class=\"rl-foot\" style=\"max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0\">{footer_html} <a href=\"{unsubscribe_html}\" style=\"color:#6b7280\">{unsubscribe_text}</a></p>
</td></tr></table></body></html>",
        subject_html = esc(&subject),
        headline_html = esc(&headline),
        site_html = esc(&site.name),
        dates_html = esc(&dates),
        dashboard_html = esc(dashboard_link),
        open_html = esc(&t("email.open", &[])),
        footer_html = esc(&footer),
        unsubscribe_html = esc(unsubscribe_link),
        unsubscribe_text = esc(&t("email.unsubscribe", &[])),
    );

    // French sets a space before a colon, as its subject line does.
    let colon = if code == "fr" { "\u{a0}:" } else { ":" };
    let mut lines: Vec<String> = vec![
        format!("Runlight · {at}"),
        String::new(),
        format!("{} · {dates}", site.name),
        String::new(),
        headline.clone(),
        String::new(),
    ];
    for (key, lower) in &metrics {
        let d = delta(key, *lower, &now, &prev).text;
        let tail = if d.is_empty() { String::new() } else { format!(" ({d})") };
        lines.push(format!("{}{colon} {}{tail}", t(&format!("metric.{key}"), &[]), format(key, now.get(key))));
    }
    for (title, rows) in &lists {
        lines.push(String::new());
        lines.push(title.clone());
        if rows.is_empty() {
            lines.push(format!("  {}", t("panel.empty", &[])));
        } else {
            for (a, b) in rows {
                lines.push(format!("  {a}{colon} {b}"));
            }
        }
    }
    lines.push(String::new());
    lines.push(format!("{}{colon} {dashboard_link}", t("email.open", &[])));
    lines.push(String::new());
    lines.push(format!("{footer} {}{colon} {unsubscribe_link}", t("email.unsubscribe", &[])));

    Ok(BuiltReport { subject, html, text: lines.join("\n") })
}
