"""Email reports: the period each one covers, and the message itself, in the reader's language.

A ReportPeriod is a dict: `key` (w:<monday> or m:<yyyy-mm>, so each period is sent once), `fromDate`, `toDate`,
`previousFrom`, `previousTo`, and `dueAt` (reports go out from 8am the day after the period ends, in the site's
timezone). A BuiltReport is {subject, html, text}.
"""

from __future__ import annotations

import datetime
import re
from typing import Any

from . import _intl, _js
from .http import Url
from .messages import translator
from .time import add_days, add_months, local_date, start_of


def last_period(frequency: str, now: int, timezone: str) -> dict[str, Any]:
    """The last complete week (Monday to Sunday) or month before `now`, in a timezone."""
    today = local_date(now, timezone)
    if frequency == "monthly":
        first = f"{today[:8]}01"
        from_date = add_months(first, -1)
        return {
            "key": f"m:{from_date[:7]}",
            "fromDate": from_date,
            "toDate": add_days(first, -1),
            "previousFrom": add_months(from_date, -1),
            "previousTo": add_days(from_date, -1),
            "dueAt": start_of(first, timezone, 8),
        }
    weekday = datetime.date.fromisoformat(today).weekday()
    monday = add_days(today, -weekday)
    from_date = add_days(monday, -7)
    return {
        "key": f"w:{from_date}",
        "fromDate": from_date,
        "toDate": add_days(monday, -1),
        "previousFrom": add_days(from_date, -7),
        "previousTo": add_days(from_date, -1),
        "dueAt": start_of(monday, timezone, 8),
    }


_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}


def _esc(value: str) -> str:
    return re.sub(r"[&<>\"']", lambda m: _ESCAPES[m.group(0)], value)


def _duration(ms: int | float) -> str:
    seconds = int(_js.js_round(ms / 1000))
    if seconds < 60:
        return f"{seconds}s"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m {seconds % 60:02d}s"
    return f"{minutes // 60}h {minutes % 60:02d}m"


def build_report(runlight: Any, site: dict[str, Any], frequency: str, period: dict[str, Any], lang: str, links: dict[str, str]) -> dict[str, str]:
    """One site's report for a period, in a language. `links` are absolute: the dashboard and the recipient's
    unsubscribe page."""
    tr = translator(lang)
    t, tn, code = tr.t, tr.tn, tr.lang
    tz = site["timezone"]

    def range_(from_: str, to: str) -> dict[str, Any]:
        return {"site": site["id"], "from": start_of(from_, tz), "to": start_of(add_days(to, 1), tz), "filters": []}

    query = range_(period["fromDate"], period["toDate"])
    before = range_(period["previousFrom"], period["previousTo"])
    store = runlight.store
    now = store.stats(query)
    prev = store.stats(before)
    pages = store.breakdown(query, "page", 5, 0)
    sources = store.breakdown(query, "source", 5, 0)
    countries = store.breakdown(query, "country", 5, 0)
    goals = store.goals(site["id"])
    totals = store.goal_totals_all(query, goals)
    goal_rows = [{"goal": g, "totals": totals[g["id"]]} for g in goals]

    def number(n: int | float) -> str:
        return _intl.number(code, n)

    def percent(n: int | float) -> str:
        return _intl.percent(code, n)

    def decimal(n: int | float) -> str:
        return _intl.number(code, n, 1, 1)

    def money(n: int | float, currency: str) -> str:
        return _intl.currency(code, n, currency, 0 if _js.is_integer(n) else 2)

    def month_name(d: str) -> str:
        return _intl.month_year(code, d)

    # Each end formatted on its own, joined in the reader's language (never with a dash).
    def span(from_: str, to: str) -> str:
        same_year = from_[:4] == to[:4]
        return t("email.range", {"from": _intl.short_day(code, from_, not same_year), "to": _intl.short_day(code, to, True)})

    def country(code2: str) -> str:
        return _intl.region(code, code2)

    monthly = frequency == "monthly"
    when = t("email.when.month", {"month": month_name(period["fromDate"])}) if monthly else t("email.when.week")
    against = month_name(period["previousFrom"]) if monthly else t("email.before.week")
    who = tn("headline.who", now["visitors"], {"n": number(now["visitors"])})
    verb = tn("headline.visited", now["visitors"])
    change = (now["visitors"] - prev["visitors"]) / prev["visitors"] if prev["visitors"] else None
    if prev["visitors"] == 0 and now["visitors"] > 0:
        headline = t("headline.fromNone", {"who": who, "verb": verb, "when": when, "against": against})
    elif change is None:
        headline = t("headline.plain", {"who": who, "verb": verb, "when": when})
    else:
        headline = t(
            "headline.same" if abs(change) < 0.005 else "headline.up" if change > 0 else "headline.down",
            {
                "who": who,
                "verb": verb,
                "when": when,
                "against": against,
                "change": t("headline.more" if change > 0 else "headline.fewer", {"pct": abs(_js.js_round(change * 100))}),
            },
        )
    subject = t("email.subject.month" if monthly else "email.subject.week", {"site": site["name"], "who": who, "month": month_name(period["fromDate"])})
    dates = span(period["fromDate"], period["toDate"])

    metrics: list[dict[str, Any]] = [
        {"key": "visitors", "format": number, "lowerIsBetter": False},
        {"key": "visits", "format": number, "lowerIsBetter": False},
        {"key": "pageviews", "format": number, "lowerIsBetter": False},
        {"key": "viewsPerVisit", "format": decimal, "lowerIsBetter": False},
        {"key": "bounceRate", "format": percent, "lowerIsBetter": True},
        {"key": "visitDuration", "format": _duration, "lowerIsBetter": False},
    ]

    def delta(key: str, lower_is_better: bool) -> dict[str, str]:
        b = prev[key]
        if not b:
            return {"text": "", "color": "#6b7280", "tone": "flat"}
        c = (now[key] - b) / b
        if abs(c) < 0.005:
            return {"text": "0%", "color": "#6b7280", "tone": "flat"}
        good = c < 0 if lower_is_better else c > 0
        return {"text": f"{'↑' if c > 0 else '↓'} {percent(abs(c))}", "color": "#15803d" if good else "#b91c1c", "tone": "up" if good else "down"}

    lists: list[dict[str, Any]] = [
        {"title": t("email.pages"), "rows": [(r["value"] or "/", number(r["visitors"])) for r in pages]},
        {"title": t("email.sources"), "rows": [(r["value"] or t("goals.unknown"), number(r["visitors"])) for r in sources]},
        {"title": t("email.countries"), "rows": [(country(r["value"]), number(r["visitors"])) for r in countries]},
    ]
    if goal_rows:
        goal_rows.sort(key=lambda row: -row["totals"]["conversions"])
        lists.append(
            {
                "title": t("email.conversions"),
                "rows": [
                    (
                        f"{row['goal']['name']} ({money(row['totals']['revenue'], row['goal']['currency'])})"
                        if row["goal"]["valueMode"] != "none" and row["totals"]["revenue"]
                        else row["goal"]["name"],
                        number(row["totals"]["conversions"]),
                    )
                    for row in goal_rows
                ],
            }
        )

    font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"

    def cell(m: dict[str, Any]) -> str:
        d = delta(m["key"], m["lowerIsBetter"])
        return (
            '<td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">\n'
            f'<div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">{_esc(t("metric." + m["key"]))}</div>\n'
            f'<div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">{_esc(m["format"](now[m["key"]]))}</div>\n'
            f'<div class="rl-{d["tone"]}" style="font-size:12px;color:{d["color"]};margin-top:2px;min-height:16px">{_esc(d["text"])}</div></td>'
        )

    def table(lst: dict[str, Any]) -> str:
        if lst["rows"]:
            rows = "".join(
                '<tr><td class="rl-row rl-body-text" style="padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all">'
                f"{_esc(a)}"
                '</td><td align="right" class="rl-row rl-ink" style="padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap">'
                f"{_esc(b)}</td></tr>"
                for a, b in lst["rows"]
            )
        else:
            rows = f'<tr><td class="rl-muted" style="padding:7px 0;color:#6b7280">{_esc(t("panel.empty"))}</td></tr>'
        return (
            f'<h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">{_esc(lst["title"])}</h3>\n'
            f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">{rows}</table>'
        )

    # Where the dashboard lives, without the scheme or the site query, so a reader with several installs can tell
    # which one sent this.
    u = Url.parse(links["dashboard"])
    where = u.host + re.sub(r"/\Z", "", u.pathname) if u is not None else links["dashboard"]
    at = t("email.at", {"where": where})
    # The Runlight mark in table cells: mail apps block SVG and most inline images.
    mark = (
        '<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>\n'
        '<td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:'
        f'{font}">R</td>\n'
        f'<td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:{font}">Runlight</td></tr></table>'
    )

    footer = t("email.footer", {"frequency": t("email.monthly" if monthly else "email.weekly"), "site": site["name"]})
    at_line = _esc(t("email.at", {"where": "\u0000"})).replace(
        "\u0000", f'<a href="{_esc(links["dashboard"])}" class="rl-muted" style="color:#6b7280">{_esc(where)}</a>', 1
    )
    html = (
        f'<!doctype html><html lang="{code}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>{_esc(subject)}</title>\n'
        "<style>\n"
        "@media (prefers-color-scheme: dark) {\n"
        "  .rl-page { background: #09090b !important; }\n"
        "  .rl-card { background: #141417 !important; border-color: #27272a !important; }\n"
        "  .rl-line { border-color: #27272a !important; }\n"
        "  .rl-row { border-top-color: #1f1f23 !important; }\n"
        "  .rl-ink { color: #ffffff !important; }\n"
        "  .rl-body-text { color: #d4d4d8 !important; }\n"
        "  .rl-muted, .rl-flat { color: #a1a1aa !important; }\n"
        "  .rl-up { color: #4ade80 !important; }\n"
        "  .rl-down { color: #f87171 !important; }\n"
        "  .rl-button { background: #ffffff !important; color: #000000 !important; }\n"
        "  .rl-mark { background: #ffffff !important; color: #000000 !important; }\n"
        "  .rl-foot, .rl-foot a { color: #a1a1aa !important; }\n"
        "}\n"
        "</style></head>\n"
        f'<body class="rl-page" style="margin:0;padding:0;background:#f4f4f5;font-family:{font}">\n'
        f'<div style="display:none;max-height:0;overflow:hidden">{_esc(headline)}</div>\n'
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-page" style="background:#f4f4f5"><tr><td align="center" style="padding:32px 16px">\n'
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-card" style="max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb"><tr><td style="padding:32px">\n'
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 24px"><tr>\n'
        f'<td style="vertical-align:middle">{mark}</td>\n'
        f'<td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">{at_line}</td>\n'
        "</tr></table>\n"
        f'<div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">{_esc(site["name"])} · {_esc(dates)}</div>\n'
        f'<h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">{_esc(headline)}</h1>\n'
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">\n'
        f"<tr>{''.join(cell(m) for m in metrics[:3])}</tr><tr>{''.join(cell(m) for m in metrics[3:])}</tr></table>\n"
        f"{''.join(table(lst) for lst in lists)}\n"
        f'<p style="margin:32px 0 0"><a href="{_esc(links["dashboard"])}" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">{_esc(t("email.open"))}</a></p>\n'
        "</td></tr></table>\n"
        f'<p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">{_esc(footer)} <a href="{_esc(links["unsubscribe"])}" style="color:#6b7280">{_esc(t("email.unsubscribe"))}</a></p>\n'
        "</td></tr></table></body></html>"
    )

    # French sets a space before a colon, as its subject line does.
    colon = " :" if code == "fr" else ":"
    lines = [f"Runlight · {at}", "", f"{site['name']} · {dates}", "", headline, ""]
    for m in metrics:
        d = delta(m["key"], m["lowerIsBetter"])["text"]
        lines.append(f"{t('metric.' + m['key'])}{colon} {m['format'](now[m['key']])}{f' ({d})' if d else ''}")
    for lst in lists:
        lines.extend(["", lst["title"]])
        if lst["rows"]:
            lines.extend(f"  {a}{colon} {b}" for a, b in lst["rows"])
        else:
            lines.append(f"  {t('panel.empty')}")
    lines.extend(["", f"{t('email.open')}{colon} {links['dashboard']}", "", f"{footer} {t('email.unsubscribe')}{colon} {links['unsubscribe']}"])

    return {"subject": subject, "html": html, "text": "\n".join(lines)}
