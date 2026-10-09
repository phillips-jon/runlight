using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;

namespace Runlight;

/// <summary>
/// Email reports: the period each one covers, and the message itself, in the reader's language.
/// </summary>
/// <remarks>
/// A ReportPeriod is a JsObject: <c>key</c> (w:&lt;monday&gt; or m:&lt;yyyy-mm&gt;, so each period is
/// sent once), <c>fromDate</c>, <c>toDate</c>, <c>previousFrom</c>, <c>previousTo</c>, and
/// <c>dueAt</c> (reports go out from 8am the day after the period ends, in the site's timezone).
/// </remarks>
public static class Reports
{
    /// <summary>The last complete week (Monday to Sunday) or month before <paramref name="now"/>, in a timezone.</summary>
    public static JsObject LastPeriod(string frequency, long now, string timezone)
    {
        string today = Time.LocalDate(now, timezone);
        if (frequency == "monthly")
        {
            string first = today[..8] + "01";
            string from = Time.AddMonths(first, -1);
            return new JsObject
            {
                ["key"] = "m:" + from[..7],
                ["fromDate"] = from,
                ["toDate"] = Time.AddDays(first, -1),
                ["previousFrom"] = Time.AddMonths(from, -1),
                ["previousTo"] = Time.AddDays(from, -1),
                ["dueAt"] = Time.StartOf(first, timezone, 8),
            };
        }
        var date = DateTime.ParseExact(today, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        int weekday = ((int)date.DayOfWeek + 6) % 7;
        string monday = Time.AddDays(today, -weekday);
        string fromDate = Time.AddDays(monday, -7);
        return new JsObject
        {
            ["key"] = "w:" + fromDate,
            ["fromDate"] = fromDate,
            ["toDate"] = Time.AddDays(monday, -1),
            ["previousFrom"] = Time.AddDays(fromDate, -7),
            ["previousTo"] = Time.AddDays(fromDate, -1),
            ["dueAt"] = Time.StartOf(monday, timezone, 8),
        };
    }

    private static string Esc(string value)
    {
        var b = new StringBuilder(value.Length);
        foreach (char c in value)
        {
            b.Append(c switch
            {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                _ => c.ToString(),
            });
        }
        return b.ToString();
    }

    private static string Duration(double ms)
    {
        long seconds = Js.RoundLong(ms / 1000);
        if (seconds < 60)
        {
            return Js.Str(seconds) + "s";
        }
        long minutes = (long)Math.Floor(seconds / 60.0);
        if (minutes < 60)
        {
            return Js.Str(minutes) + "m " + Js.Str(seconds % 60).PadLeft(2, '0') + "s";
        }
        return Js.Str((long)Math.Floor(minutes / 60.0)) + "h " + Js.Str(minutes % 60).PadLeft(2, '0') + "m";
    }

    private sealed record Metric(string Key, Func<double, string> Format, bool LowerIsBetter);

    private sealed record Delta(string Text, string Color, string Tone);

    private sealed record Section(string Title, List<(string Label, string Value)> Rows);

    /// <summary>
    /// One site's report for a period, in a language. <paramref name="links"/> are absolute: the
    /// dashboard and the recipient's unsubscribe page.
    /// </summary>
    /// <param name="store">The Runlight's store.</param>
    /// <param name="site">The SiteRow: id, name, hostnames, and timezone.</param>
    /// <param name="frequency">"weekly" or "monthly".</param>
    /// <param name="period">The ReportPeriod, as <see cref="LastPeriod"/> gives it.</param>
    /// <param name="lang">The reader's language.</param>
    /// <param name="links">{ dashboard, unsubscribe }.</param>
    /// <param name="cancellationToken">Stops the store's reads.</param>
    /// <returns>{ subject, html, text }.</returns>
    public static async Task<JsObject> BuildReportAsync(SqlStore store, JsObject site, string frequency, JsObject period, string lang, JsObject links, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(site);
        ArgumentNullException.ThrowIfNull(period);
        ArgumentNullException.ThrowIfNull(links);
        var words = Messages.Translator(lang);
        string code = words.Lang;
        string T(string key, JsObject? vars = null) => words.T(key, vars);
        string tz = site.Str("timezone") ?? "UTC";
        string siteId = site.Str("id") ?? "";
        string siteName = site.Str("name") ?? "";
        JsObject Range(string from, string to) => new()
        {
            ["site"] = siteId,
            ["from"] = Time.StartOf(from, tz),
            ["to"] = Time.StartOf(Time.AddDays(to, 1), tz),
            ["filters"] = new List<object?>(),
        };
        string fromDate = period.Str("fromDate")!;
        var query = Range(fromDate, period.Str("toDate")!);
        var before = Range(period.Str("previousFrom")!, period.Str("previousTo")!);
        var now = await store.StatsAsync(query, cancellationToken).ConfigureAwait(false);
        var prev = await store.StatsAsync(before, cancellationToken).ConfigureAwait(false);
        var pages = await store.BreakdownAsync(query, "page", 5, 0, cancellationToken).ConfigureAwait(false);
        var sources = await store.BreakdownAsync(query, "source", 5, 0, cancellationToken).ConfigureAwait(false);
        var countries = await store.BreakdownAsync(query, "country", 5, 0, cancellationToken).ConfigureAwait(false);
        var goals = await store.GoalsAsync(siteId, cancellationToken).ConfigureAwait(false);
        var totals = await store.GoalTotalsAllAsync(query, goals, cancellationToken).ConfigureAwait(false);

        string Number(double n) => Intl.Number(code, n);
        string Percent(double n) => Intl.Percent(code, n);
        string DecimalOne(double n) => Intl.Number(code, n, 1, 1);
        string Money(double n, string currency) => Intl.Currency(code, n, currency, Js.IsInteger(n) ? 0 : 2);
        string MonthName(string d) => Intl.MonthYear(code, d);
        // Each end formatted on its own, joined in the reader's language (never with a dash).
        string Span(string from, string to)
        {
            bool sameYear = from[..4] == to[..4];
            return T("email.range", new JsObject { ["from"] = Intl.ShortDay(code, from, !sameYear), ["to"] = Intl.ShortDay(code, to, true) });
        }

        bool monthly = frequency == "monthly";
        double visitors = now.Num("visitors");
        double previous = prev.Num("visitors");
        string when = monthly ? T("email.when.month", new JsObject { ["month"] = MonthName(fromDate) }) : T("email.when.week");
        string against = monthly ? MonthName(period.Str("previousFrom")!) : T("email.before.week");
        string who = words.Tn("headline.who", visitors, new JsObject { ["n"] = Number(visitors) });
        string verb = words.Tn("headline.visited", visitors);
        double? change = Js.Truthy(previous) ? (visitors - previous) / previous : null;
        string headline;
        if (previous == 0 && visitors > 0)
        {
            headline = T("headline.fromNone", new JsObject { ["who"] = who, ["verb"] = verb, ["when"] = when, ["against"] = against });
        }
        else if (change == null)
        {
            headline = T("headline.plain", new JsObject { ["who"] = who, ["verb"] = verb, ["when"] = when });
        }
        else
        {
            double c = change.Value;
            headline = T(Math.Abs(c) < 0.005 ? "headline.same" : c > 0 ? "headline.up" : "headline.down", new JsObject
            {
                ["who"] = who,
                ["verb"] = verb,
                ["when"] = when,
                ["against"] = against,
                ["change"] = T(c > 0 ? "headline.more" : "headline.fewer", new JsObject { ["pct"] = Math.Abs(Js.Round(c * 100)) }),
            });
        }
        string subject = T(monthly ? "email.subject.month" : "email.subject.week", new JsObject { ["site"] = siteName, ["who"] = who, ["month"] = MonthName(fromDate) });
        string dates = Span(fromDate, period.Str("toDate")!);

        Metric[] metrics =
        [
            new("visitors", Number, false),
            new("visits", Number, false),
            new("pageviews", Number, false),
            new("viewsPerVisit", DecimalOne, false),
            new("bounceRate", Percent, true),
            new("visitDuration", Duration, false),
        ];
        Delta DeltaOf(string key, bool lowerIsBetter)
        {
            double b = prev.Num(key);
            if (!Js.Truthy(b))
            {
                return new Delta("", "#6b7280", "flat");
            }
            double c = (now.Num(key) - b) / b;
            if (Math.Abs(c) < 0.005)
            {
                return new Delta("0%", "#6b7280", "flat");
            }
            bool good = lowerIsBetter ? c < 0 : c > 0;
            return new Delta((c > 0 ? "↑" : "↓") + " " + Percent(Math.Abs(c)), good ? "#15803d" : "#b91c1c", good ? "up" : "down");
        }

        var lists = new List<Section>
        {
            new(T("email.pages"), pages.Select(r => (Js.Truthy(r.Get("value")) ? Js.String(r.Get("value")) : "/", Number(r.Num("visitors")))).ToList()),
            new(T("email.sources"), sources.Select(r => (Js.Truthy(r.Get("value")) ? Js.String(r.Get("value")) : T("goals.unknown"), Number(r.Num("visitors")))).ToList()),
            new(T("email.countries"), countries.Select(r => (Intl.Region(code, Js.String(r.Get("value") ?? "")), Number(r.Num("visitors")))).ToList()),
        };
        if (goals.Count > 0)
        {
            var goalRows = goals.Select(g => (Goal: g, Totals: totals[g.Str("id")!])).OrderByDescending(r => r.Totals.Num("conversions")).ToList();
            lists.Add(new Section(T("email.conversions"), goalRows.Select(row =>
            {
                string goalName = row.Goal.Str("name") ?? "";
                double revenue = row.Totals.Num("revenue");
                string label = row.Goal.Str("valueMode") != "none" && Js.Truthy(row.Totals.Get("revenue"))
                    ? goalName + " (" + Money(revenue, row.Goal.Str("currency") ?? "") + ")"
                    : goalName;
                return (label, Number(row.Totals.Num("conversions")));
            }).ToList()));
        }

        const string font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
        string Cell(Metric m)
        {
            var d = DeltaOf(m.Key, m.LowerIsBetter);
            string label = Esc(T("metric." + m.Key));
            string value = Esc(m.Format(now.Num(m.Key)));
            string text = Esc(d.Text);
            return $$"""
<td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">
<div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">{{label}}</div>
<div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">{{value}}</div>
<div class="rl-{{d.Tone}}" style="font-size:12px;color:{{d.Color}};margin-top:2px;min-height:16px">{{text}}</div></td>
""";
        }
        string Table(Section l)
        {
            string title = Esc(l.Title);
            string rows = l.Rows.Count > 0
                ? string.Concat(l.Rows.Select(r => "<tr><td class=\"rl-row rl-body-text\" style=\"padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all\">" + Esc(r.Label) + "</td><td align=\"right\" class=\"rl-row rl-ink\" style=\"padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap\">" + Esc(r.Value) + "</td></tr>"))
                : "<tr><td class=\"rl-muted\" style=\"padding:7px 0;color:#6b7280\">" + Esc(T("panel.empty")) + "</td></tr>";
            return $$"""
<h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">{{title}}</h3>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">{{rows}}</table>
""";
        }

        // Where the dashboard lives, without the scheme or the site query, so a reader
        // with several installs can tell which one sent this.
        string dashboard = links.Str("dashboard") ?? "";
        string unsubscribe = links.Str("unsubscribe") ?? "";
        var u = Url.Parse(dashboard);
        string where = u != null ? u.Host + (u.Pathname.EndsWith('/') ? u.Pathname[..^1] : u.Pathname) : dashboard;
        string at = T("email.at", new JsObject { ["where"] = where });
        // The Runlight mark in table cells: mail apps block SVG and most inline images.
        string mark = $$"""
<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>
<td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:{{font}}">R</td>
<td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:{{font}}">Runlight</td></tr></table>
""";

        string footer = T("email.footer", new JsObject { ["frequency"] = T(monthly ? "email.monthly" : "email.weekly"), ["site"] = siteName });
        string atLine = Esc(T("email.at", new JsObject { ["where"] = "\0" }));
        int hole = atLine.IndexOf('\0', StringComparison.Ordinal);
        if (hole >= 0)
        {
            atLine = atLine[..hole] + "<a href=\"" + Esc(dashboard) + "\" class=\"rl-muted\" style=\"color:#6b7280\">" + Esc(where) + "</a>" + atLine[(hole + 1)..];
        }
        string cells1 = string.Concat(metrics.Take(3).Select(Cell));
        string cells2 = string.Concat(metrics.Skip(3).Select(Cell));
        string tables = string.Concat(lists.Select(Table));
        string html = $$"""
<!doctype html><html lang="{{code}}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>{{Esc(subject)}}</title>
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
<body class="rl-page" style="margin:0;padding:0;background:#f4f4f5;font-family:{{font}}">
<div style="display:none;max-height:0;overflow:hidden">{{Esc(headline)}}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-page" style="background:#f4f4f5"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-card" style="max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb"><tr><td style="padding:32px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 24px"><tr>
<td style="vertical-align:middle">{{mark}}</td>
<td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">{{atLine}}</td>
</tr></table>
<div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">{{Esc(siteName)}} · {{Esc(dates)}}</div>
<h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">{{Esc(headline)}}</h1>
<table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">
<tr>{{cells1}}</tr><tr>{{cells2}}</tr></table>
{{tables}}
<p style="margin:32px 0 0"><a href="{{Esc(dashboard)}}" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">{{Esc(T("email.open"))}}</a></p>
</td></tr></table>
<p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">{{Esc(footer)}} <a href="{{Esc(unsubscribe)}}" style="color:#6b7280">{{Esc(T("email.unsubscribe"))}}</a></p>
</td></tr></table></body></html>
""";

        // French sets a space before a colon, as its subject line does.
        string colon = code == "fr" ? (char)0xA0 + ":" : ":";
        var lines = new List<string> { "Runlight · " + at, "", siteName + " · " + dates, "", headline, "" };
        foreach (var m in metrics)
        {
            string d = DeltaOf(m.Key, m.LowerIsBetter).Text;
            lines.Add(T("metric." + m.Key) + colon + " " + m.Format(now.Num(m.Key)) + (d.Length > 0 ? " (" + d + ")" : ""));
        }
        foreach (var l in lists)
        {
            lines.Add("");
            lines.Add(l.Title);
            if (l.Rows.Count > 0)
            {
                foreach (var (a, b) in l.Rows)
                {
                    lines.Add("  " + a + colon + " " + b);
                }
            }
            else
            {
                lines.Add("  " + T("panel.empty"));
            }
        }
        lines.AddRange(["", T("email.open") + colon + " " + dashboard, "", footer + " " + T("email.unsubscribe") + colon + " " + unsubscribe]);

        return new JsObject { ["subject"] = subject, ["html"] = html, ["text"] = string.Join('\n', lines) };
    }
}
