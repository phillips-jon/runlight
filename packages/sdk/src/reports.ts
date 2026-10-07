import type { Runlight } from "./runlight.js";
import { translator } from "./messages.js";
import type { GoalRow, ReportRow, SiteRow, Stats } from "./store.js";
import { addDays, addMonths, localDate, startOf } from "./time.js";

export interface ReportPeriod {
  /** w:<monday> or m:<yyyy-mm>, so each period is sent once. */
  key: string;
  fromDate: string;
  toDate: string;
  previousFrom: string;
  previousTo: string;
  /** Reports go out from 8am the day after the period ends, in the site's timezone. */
  dueAt: number;
}

/** The last complete week (Monday to Sunday) or month before `now`, in a timezone. */
export function lastPeriod(frequency: ReportRow["frequency"], now: number, timezone: string): ReportPeriod {
  const today = localDate(now, timezone);
  if (frequency === "monthly") {
    const first = `${today.slice(0, 8)}01`;
    const fromDate = addMonths(first, -1);
    return {
      key: `m:${fromDate.slice(0, 7)}`,
      fromDate,
      toDate: addDays(first, -1),
      previousFrom: addMonths(fromDate, -1),
      previousTo: addDays(fromDate, -1),
      dueAt: startOf(first, timezone, 8),
    };
  }
  const weekday = (new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7;
  const monday = addDays(today, -weekday);
  const fromDate = addDays(monday, -7);
  return {
    key: `w:${fromDate}`,
    fromDate,
    toDate: addDays(monday, -1),
    previousFrom: addDays(fromDate, -7),
    previousTo: addDays(fromDate, -1),
    dueAt: startOf(monday, timezone, 8),
  };
}

const esc = (value: string) => value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

function duration(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

export interface BuiltReport {
  subject: string;
  html: string;
  text: string;
}

/**
 * One site's report for a period, in a language. `links` are absolute: the
 * dashboard and the recipient's unsubscribe page.
 */
export async function buildReport(
  runlight: Runlight,
  site: SiteRow,
  frequency: ReportRow["frequency"],
  period: ReportPeriod,
  lang: string,
  links: { dashboard: string; unsubscribe: string },
): Promise<BuiltReport> {
  const { t, tn, lang: code } = translator(lang);
  const tz = site.timezone;
  const range = (from: string, to: string) => ({ site: site.id, from: startOf(from, tz), to: startOf(addDays(to, 1), tz), filters: [] });
  const query = range(period.fromDate, period.toDate);
  const before = range(period.previousFrom, period.previousTo);
  const store = runlight.store;
  const [now, prev, pages, sources, countries, goals] = await Promise.all([
    store.stats(query),
    store.stats(before),
    store.breakdown(query, "page", 5, 0),
    store.breakdown(query, "source", 5, 0),
    store.breakdown(query, "country", 5, 0),
    store.goals(site.id),
  ]);
  const totals = await store.goalTotalsAll(query, goals);
  const goalRows = goals.map((g) => ({ goal: g, totals: totals.get(g.id)! }));

  const number = new Intl.NumberFormat(code);
  const percent = new Intl.NumberFormat(code, { style: "percent", maximumFractionDigits: 0 });
  const decimal = new Intl.NumberFormat(code, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  const money = (n: number, currency: string) => {
    try {
      return new Intl.NumberFormat(code, { style: "currency", currency, maximumFractionDigits: Number.isInteger(n) ? 0 : 2 }).format(n);
    } catch {
      return `${n} ${currency}`;
    }
  };
  const day = (d: string, opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat(code, { ...opts, timeZone: "UTC" }).format(new Date(`${d}T00:00:00Z`));
  const monthName = (d: string) => day(d, { month: "long", year: "numeric" });
  // Each end formatted on its own, joined in the reader's language (never with a dash).
  const span = (from: string, to: string) => {
    const sameYear = from.slice(0, 4) === to.slice(0, 4);
    return t("email.range", {
      from: day(from, sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" }),
      to: day(to, { month: "short", day: "numeric", year: "numeric" }),
    });
  };
  const country = (code2: string) => {
    try {
      return new Intl.DisplayNames(code, { type: "region" }).of(code2) ?? code2;
    } catch {
      return code2;
    }
  };

  const monthly = frequency === "monthly";
  const when = monthly ? t("email.when.month", { month: monthName(period.fromDate) }) : t("email.when.week");
  const against = monthly ? monthName(period.previousFrom) : t("email.before.week");
  const who = tn("headline.who", now.visitors, { n: number.format(now.visitors) });
  const change = prev.visitors ? (now.visitors - prev.visitors) / prev.visitors : null;
  const headline =
    prev.visitors === 0 && now.visitors > 0
      ? t("headline.fromNone", { who, verb: t("headline.visited"), when, against })
      : change === null
        ? t("headline.plain", { who, verb: t("headline.visited"), when })
        : t(Math.abs(change) < 0.005 ? "headline.same" : change > 0 ? "headline.up" : "headline.down", {
            who,
            verb: t("headline.visited"),
            when,
            against,
            change: t(change > 0 ? "headline.more" : "headline.fewer", { pct: Math.abs(Math.round(change * 100)) }),
          });
  const subject = t(monthly ? "email.subject.month" : "email.subject.week", { site: site.name, who, month: monthName(period.fromDate) });
  const dates = span(period.fromDate, period.toDate);

  const metrics: Array<{ key: keyof Stats; format: (n: number) => string; lowerIsBetter?: boolean }> = [
    { key: "visitors", format: (n) => number.format(n) },
    { key: "visits", format: (n) => number.format(n) },
    { key: "pageviews", format: (n) => number.format(n) },
    { key: "viewsPerVisit", format: (n) => decimal.format(n) },
    { key: "bounceRate", format: (n) => percent.format(n), lowerIsBetter: true },
    { key: "visitDuration", format: duration },
  ];
  const delta = (key: keyof Stats, lowerIsBetter?: boolean) => {
    const b = prev[key];
    if (!b) return { text: "", color: "#6b7280", tone: "flat" };
    const c = (now[key] - b) / b;
    if (Math.abs(c) < 0.005) return { text: "0%", color: "#6b7280", tone: "flat" };
    const good = lowerIsBetter ? c < 0 : c > 0;
    return { text: `${c > 0 ? "↑" : "↓"} ${percent.format(Math.abs(c))}`, color: good ? "#15803d" : "#b91c1c", tone: good ? "up" : "down" };
  };

  const lists: Array<{ title: string; rows: Array<[string, string]> }> = [
    { title: t("email.pages"), rows: pages.map((r) => [r.value || "/", number.format(r.visitors)]) },
    { title: t("email.sources"), rows: sources.map((r) => [r.value || t("goals.unknown"), number.format(r.visitors)]) },
    { title: t("email.countries"), rows: countries.map((r) => [country(r.value), number.format(r.visitors)]) },
  ];
  if (goalRows.length) {
    lists.push({
      title: t("email.conversions"),
      rows: goalRows
        .sort((a, b) => b.totals.conversions - a.totals.conversions)
        .map(({ goal, totals }: { goal: GoalRow; totals: { conversions: number; revenue: number } }) => [
          goal.valueMode !== "none" && totals.revenue ? `${goal.name} (${money(totals.revenue, goal.currency)})` : goal.name,
          number.format(totals.conversions),
        ]),
    });
  }

  const font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
  const cell = (m: (typeof metrics)[number]) => {
    const d = delta(m.key, m.lowerIsBetter);
    return `<td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">
<div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">${esc(t(`metric.${m.key}`))}</div>
<div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">${esc(m.format(now[m.key]))}</div>
<div class="rl-${d.tone}" style="font-size:12px;color:${d.color};margin-top:2px;min-height:16px">${esc(d.text)}</div></td>`;
  };
  const table = (l: (typeof lists)[number]) =>
    `<h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">${esc(l.title)}</h3>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">${
      l.rows.length
        ? l.rows.map(([a, b]) => `<tr><td class="rl-row rl-body-text" style="padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all">${esc(a)}</td><td align="right" class="rl-row rl-ink" style="padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap">${esc(b)}</td></tr>`).join("")
        : `<tr><td class="rl-muted" style="padding:7px 0;color:#6b7280">${esc(t("panel.empty"))}</td></tr>`
    }</table>`;

  // Where the dashboard lives, without the scheme or the site query, so a reader
  // with several installs can tell which one sent this.
  const where = (() => {
    try {
      const u = new URL(links.dashboard);
      return `${u.host}${u.pathname.replace(/\/$/, "")}`;
    } catch {
      return links.dashboard;
    }
  })();
  const at = t("email.at", { where });
  // The Runlight mark in table cells: mail apps block SVG and most inline images.
  const mark = `<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>
<td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:${font}">R</td>
<td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:${font}">Runlight</td></tr></table>`;

  const footer = t("email.footer", { frequency: t(monthly ? "email.monthly" : "email.weekly"), site: site.name });
  const html = `<!doctype html><html lang="${code}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>${esc(subject)}</title>
<style>
@media (prefers-color-scheme: dark) {
  .rl-page { background: #09090b !important; }
  .rl-card { background: #141417 !important; border-color: #27272a !important; }
  .rl-line { border-color: #27272a !important; }
  .rl-row { border-top-color: #1f1f23 !important; }
  .rl-ink { color: #ffffff !important; }
  .rl-body-text { color: #d4d4d8 !important; }
  .rl-muted, .rl-flat { color: #a1a1aa !important; }
  .rl-up { color: #4ade80 !important; }
  .rl-down { color: #f87171 !important; }
  .rl-button { background: #ffffff !important; color: #000000 !important; }
  .rl-mark { background: #ffffff !important; color: #000000 !important; }
  .rl-foot, .rl-foot a { color: #a1a1aa !important; }
}
</style></head>
<body class="rl-page" style="margin:0;padding:0;background:#f4f4f5;font-family:${font}">
<div style="display:none;max-height:0;overflow:hidden">${esc(headline)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-page" style="background:#f4f4f5"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-card" style="max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb"><tr><td style="padding:32px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 24px"><tr>
<td style="vertical-align:middle">${mark}</td>
<td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">${esc(t("email.at", { where: "\u0000" })).replace("\u0000", `<a href="${esc(links.dashboard)}" class="rl-muted" style="color:#6b7280">${esc(where)}</a>`)}</td>
</tr></table>
<div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">${esc(site.name)} · ${esc(dates)}</div>
<h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">${esc(headline)}</h1>
<table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">
<tr>${metrics.slice(0, 3).map(cell).join("")}</tr><tr>${metrics.slice(3).map(cell).join("")}</tr></table>
${lists.map(table).join("")}
<p style="margin:32px 0 0"><a href="${esc(links.dashboard)}" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">${esc(t("email.open"))}</a></p>
</td></tr></table>
<p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">${esc(footer)} <a href="${esc(links.unsubscribe)}" style="color:#6b7280">${esc(t("email.unsubscribe"))}</a></p>
</td></tr></table></body></html>`;

  const text = [
    `Runlight · ${at}`,
    "",
    `${site.name} · ${dates}`,
    "",
    headline,
    "",
    ...metrics.map((m) => {
      const d = delta(m.key, m.lowerIsBetter).text;
      return `${t(`metric.${m.key}`)}: ${m.format(now[m.key])}${d ? ` (${d})` : ""}`;
    }),
    ...lists.flatMap((l) => ["", l.title, ...(l.rows.length ? l.rows.map(([a, b]) => `  ${a}: ${b}`) : [`  ${t("panel.empty")}`])]),
    "",
    `${t("email.open")}: ${links.dashboard}`,
    "",
    `${footer} ${t("email.unsubscribe")}: ${links.unsubscribe}`,
  ].join("\n");

  return { subject, html, text };
}
