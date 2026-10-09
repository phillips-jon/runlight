package runlight

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"

	"runlight.sh/go/internal/intl"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
)

// Period is one report's period.
type Period struct {
	// Key is w:<monday> or m:<yyyy-mm>, so each period is sent once.
	Key          string `json:"key"`
	FromDate     string `json:"fromDate"`
	ToDate       string `json:"toDate"`
	PreviousFrom string `json:"previousFrom"`
	PreviousTo   string `json:"previousTo"`
	// DueAt: reports go out from 8am the day after the period ends, in the site's timezone.
	DueAt int64 `json:"dueAt"`
}

// LastPeriod is the last complete week (Monday to Sunday) or month before now, in a timezone.
func LastPeriod(frequency string, now int64, timezone string) Period {
	today := LocalDate(now, timezone)
	if frequency == "monthly" {
		first := today[:8] + "01"
		fromDate := AddMonths(first, -1)
		return Period{Key: "m:" + fromDate[:7], FromDate: fromDate, ToDate: AddDays(first, -1), PreviousFrom: AddMonths(fromDate, -1), PreviousTo: AddDays(fromDate, -1), DueAt: StartOf(first, timezone, 8)}
	}
	monday := AddDays(today, -((weekday(today) + 6) % 7))
	fromDate := AddDays(monday, -7)
	return Period{Key: "w:" + fromDate, FromDate: fromDate, ToDate: AddDays(monday, -1), PreviousFrom: AddDays(fromDate, -7), PreviousTo: AddDays(fromDate, -1), DueAt: StartOf(monday, timezone, 8)}
}

func durationText(ms float64) string {
	seconds := int64(js.Round(ms / 1000))
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	minutes := seconds / 60
	if minutes < 60 {
		return fmt.Sprintf("%dm %02ds", minutes, seconds%60)
	}
	return fmt.Sprintf("%dh %02dm", minutes/60, minutes%60)
}

// BuiltReport is one email report.
type BuiltReport struct {
	Subject string
	HTML    string
	Text    string
}

// ReportLinks are a report's absolute links: the dashboard and the recipient's unsubscribe page.
type ReportLinks struct {
	Dashboard   string
	Unsubscribe string
}

type metric struct {
	key           string
	value         float64
	before        float64
	format        func(float64) string
	lowerIsBetter bool
}

type delta struct{ text, color, tone string }

// BuildReport is one site's report for a period, in a language.
func BuildReport(ctx context.Context, r *Runlight, site SiteRow, frequency string, period Period, lang string, links ReportLinks) (BuiltReport, error) {
	tr := NewTranslator(lang)
	code := tr.Lang
	tz := site.Timezone
	rangeOf := func(from, to string) Query {
		return Query{Site: site.ID, From: StartOf(from, tz, 0), To: StartOf(AddDays(to, 1), tz, 0), Filters: []Filter{}}
	}
	query := rangeOf(period.FromDate, period.ToDate)
	before := rangeOf(period.PreviousFrom, period.PreviousTo)
	store := r.Store
	now, err := store.Stats(ctx, query)
	if err != nil {
		return BuiltReport{}, err
	}
	prev, err := store.Stats(ctx, before)
	if err != nil {
		return BuiltReport{}, err
	}
	pages, err := store.Breakdown(ctx, query, "page", 5, 0)
	if err != nil {
		return BuiltReport{}, err
	}
	sources, err := store.Breakdown(ctx, query, "source", 5, 0)
	if err != nil {
		return BuiltReport{}, err
	}
	countries, err := store.Breakdown(ctx, query, "country", 5, 0)
	if err != nil {
		return BuiltReport{}, err
	}
	goals, err := store.Goals(ctx, site.ID)
	if err != nil {
		return BuiltReport{}, err
	}
	totals, err := store.GoalTotalsAll(ctx, query, goals)
	if err != nil {
		return BuiltReport{}, err
	}

	number := func(n float64) string { return intl.Number(code, n, 0, 3) }
	percent := func(n float64) string { return intl.Percent(code, n) }
	oneDecimal := func(n float64) string { return intl.Number(code, n, 1, 1) }
	money := func(n float64, currency string) string {
		max := 2
		if n == math.Trunc(n) {
			max = 0
		}
		return intl.Currency(code, n, currency, max, js.FormatNumber(n)+" "+currency)
	}
	monthName := func(d string) string { return intl.MonthYear(code, d) }
	// Each end formatted on its own, joined in the reader's language (never with a dash).
	span := func(from, to string) string {
		sameYear := from[:4] == to[:4]
		return tr.T("email.range", Vars{"from": intl.ShortDay(code, from, !sameYear), "to": intl.ShortDay(code, to, true)})
	}

	monthly := frequency == "monthly"
	when := tr.T("email.when.week", nil)
	against := tr.T("email.before.week", nil)
	if monthly {
		when = tr.T("email.when.month", Vars{"month": monthName(period.FromDate)})
		against = monthName(period.PreviousFrom)
	}
	visitors := float64(now.Visitors)
	who := tr.TN("headline.who", visitors, Vars{"n": number(visitors)})
	verb := tr.TN("headline.visited", visitors, nil)
	var headline string
	switch {
	case prev.Visitors == 0 && now.Visitors > 0:
		headline = tr.T("headline.fromNone", Vars{"who": who, "verb": verb, "when": when, "against": against})
	case prev.Visitors == 0:
		headline = tr.T("headline.plain", Vars{"who": who, "verb": verb, "when": when})
	default:
		change := (visitors - float64(prev.Visitors)) / float64(prev.Visitors)
		key := "headline.down"
		if math.Abs(change) < 0.005 {
			key = "headline.same"
		} else if change > 0 {
			key = "headline.up"
		}
		more := "headline.fewer"
		if change > 0 {
			more = "headline.more"
		}
		headline = tr.T(key, Vars{"who": who, "verb": verb, "when": when, "against": against,
			"change": tr.T(more, Vars{"pct": math.Abs(js.Round(change * 100))})})
	}
	subjectKey := "email.subject.week"
	if monthly {
		subjectKey = "email.subject.month"
	}
	subject := tr.T(subjectKey, Vars{"site": site.Name, "who": who, "month": monthName(period.FromDate)})
	dates := span(period.FromDate, period.ToDate)

	metrics := []metric{
		{"visitors", float64(now.Visitors), float64(prev.Visitors), number, false},
		{"visits", float64(now.Visits), float64(prev.Visits), number, false},
		{"pageviews", float64(now.Pageviews), float64(prev.Pageviews), number, false},
		{"viewsPerVisit", now.ViewsPerVisit, prev.ViewsPerVisit, oneDecimal, false},
		{"bounceRate", now.BounceRate, prev.BounceRate, percent, true},
		{"visitDuration", float64(now.VisitDuration), float64(prev.VisitDuration), durationText, false},
	}
	deltaOf := func(m metric) delta {
		if m.before == 0 {
			return delta{"", "#6b7280", "flat"}
		}
		c := (m.value - m.before) / m.before
		if math.Abs(c) < 0.005 {
			return delta{"0%", "#6b7280", "flat"}
		}
		good := c > 0
		if m.lowerIsBetter {
			good = c < 0
		}
		arrow := "↓"
		if c > 0 {
			arrow = "↑"
		}
		if good {
			return delta{arrow + " " + percent(math.Abs(c)), "#15803d", "up"}
		}
		return delta{arrow + " " + percent(math.Abs(c)), "#b91c1c", "down"}
	}

	type list struct {
		title string
		rows  [][2]string
	}
	rowsOf := func(rows []BreakdownRow, label func(string) string) [][2]string {
		out := [][2]string{}
		for _, row := range rows {
			out = append(out, [2]string{label(row.Value), number(float64(row.Visitors))})
		}
		return out
	}
	lists := []list{
		{tr.T("email.pages", nil), rowsOf(pages, func(v string) string { return firstNonEmpty(v, "/") })},
		{tr.T("email.sources", nil), rowsOf(sources, func(v string) string { return firstNonEmpty(v, tr.T("goals.unknown", nil)) })},
		{tr.T("email.countries", nil), rowsOf(countries, func(v string) string { return intl.Region(code, v) })},
	}
	if len(goals) > 0 {
		sorted := append([]GoalRow(nil), goals...)
		sort.SliceStable(sorted, func(i, j int) bool { return totals[sorted[i].ID].Conversions > totals[sorted[j].ID].Conversions })
		rows := [][2]string{}
		for _, g := range sorted {
			t := totals[g.ID]
			name := g.Name
			if g.ValueMode != "none" && t.Revenue != 0 {
				name = g.Name + " (" + money(t.Revenue, g.Currency) + ")"
			}
			rows = append(rows, [2]string{name, number(float64(t.Conversions))})
		}
		lists = append(lists, list{tr.T("email.conversions", nil), rows})
	}

	const font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
	cell := func(m metric) string {
		d := deltaOf(m)
		return `<td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">
<div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">` + escapeHTML(tr.T("metric."+m.key, nil)) + `</div>
<div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">` + escapeHTML(m.format(m.value)) + `</div>
<div class="rl-` + d.tone + `" style="font-size:12px;color:` + d.color + `;margin-top:2px;min-height:16px">` + escapeHTML(d.text) + `</div></td>`
	}
	table := func(l list) string {
		var body string
		if len(l.rows) > 0 {
			for _, row := range l.rows {
				body += `<tr><td class="rl-row rl-body-text" style="padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all">` + escapeHTML(row[0]) + `</td><td align="right" class="rl-row rl-ink" style="padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap">` + escapeHTML(row[1]) + `</td></tr>`
			}
		} else {
			body = `<tr><td class="rl-muted" style="padding:7px 0;color:#6b7280">` + escapeHTML(tr.T("panel.empty", nil)) + `</td></tr>`
		}
		return `<h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">` + escapeHTML(l.title) + `</h3>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">` + body + `</table>`
	}

	// Where the dashboard lives, without the scheme or the site query, so a reader with several installs
	// can tell which one sent this.
	where := links.Dashboard
	if u, err := whatwg.Parse(links.Dashboard); err == nil {
		where = u.Host() + strings.TrimSuffix(u.Pathname, "/")
	}
	at := tr.T("email.at", Vars{"where": where})
	// The Runlight mark in table cells: mail apps block SVG and most inline images.
	mark := `<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>
<td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:` + font + `">R</td>
<td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:` + font + `">Runlight</td></tr></table>`

	frequencyWord := tr.T("email.weekly", nil)
	if monthly {
		frequencyWord = tr.T("email.monthly", nil)
	}
	footer := tr.T("email.footer", Vars{"frequency": frequencyWord, "site": site.Name})
	atLink := strings.Replace(escapeHTML(tr.T("email.at", Vars{"where": "\x00"})), "\x00", `<a href="`+escapeHTML(links.Dashboard)+`" class="rl-muted" style="color:#6b7280">`+escapeHTML(where)+`</a>`, 1)
	cells := func(ms []metric) string {
		out := ""
		for _, m := range ms {
			out += cell(m)
		}
		return out
	}
	tables := ""
	for _, l := range lists {
		tables += table(l)
	}
	html := `<!doctype html><html lang="` + code + `"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>` + escapeHTML(subject) + `</title>
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
<body class="rl-page" style="margin:0;padding:0;background:#f4f4f5;font-family:` + font + `">
<div style="display:none;max-height:0;overflow:hidden">` + escapeHTML(headline) + `</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-page" style="background:#f4f4f5"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-card" style="max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb"><tr><td style="padding:32px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 24px"><tr>
<td style="vertical-align:middle">` + mark + `</td>
<td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">` + atLink + `</td>
</tr></table>
<div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">` + escapeHTML(site.Name) + ` · ` + escapeHTML(dates) + `</div>
<h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">` + escapeHTML(headline) + `</h1>
<table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">
<tr>` + cells(metrics[:3]) + `</tr><tr>` + cells(metrics[3:]) + `</tr></table>
` + tables + `
<p style="margin:32px 0 0"><a href="` + escapeHTML(links.Dashboard) + `" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">` + escapeHTML(tr.T("email.open", nil)) + `</a></p>
</td></tr></table>
<p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">` + escapeHTML(footer) + ` <a href="` + escapeHTML(links.Unsubscribe) + `" style="color:#6b7280">` + escapeHTML(tr.T("email.unsubscribe", nil)) + `</a></p>
</td></tr></table></body></html>`

	// French sets a space before a colon, as its subject line does.
	colon := ":"
	if code == "fr" {
		colon = " :"
	}
	lines := []string{"Runlight · " + at, "", site.Name + " · " + dates, "", headline, ""}
	for _, m := range metrics {
		line := tr.T("metric."+m.key, nil) + colon + " " + m.format(m.value)
		if d := deltaOf(m).text; d != "" {
			line += " (" + d + ")"
		}
		lines = append(lines, line)
	}
	for _, l := range lists {
		lines = append(lines, "", l.title)
		if len(l.rows) == 0 {
			lines = append(lines, "  "+tr.T("panel.empty", nil))
		}
		for _, row := range l.rows {
			lines = append(lines, "  "+row[0]+colon+" "+row[1])
		}
	}
	lines = append(lines, "", tr.T("email.open", nil)+colon+" "+links.Dashboard, "", footer+" "+tr.T("email.unsubscribe", nil)+colon+" "+links.Unsubscribe)
	return BuiltReport{Subject: subject, HTML: html, Text: strings.Join(lines, "\n")}, nil
}

// SendReports sends every report that is due: last week's on Monday from
// 8am, last month's on the 1st, in each site's timezone. Safe to run often;
// each period goes out once. Called by Check.
func (r *Runlight) SendReports(ctx context.Context) (ReportsCount, error) {
	result := ReportsCount{}
	if err := r.Init(ctx); err != nil {
		return result, err
	}
	reports, err := r.Store.Reports(ctx, "")
	if err != nil || len(reports) == 0 {
		return result, err
	}
	settings, err := r.MailSettings(ctx)
	if err != nil || settings == nil {
		return result, err
	}
	now := r.now()
	for _, report := range reports {
		site, ok := r.Site(report.Site)
		if !ok {
			continue
		}
		period := LastPeriod(report.Frequency, now, site.Timezone)
		if now < period.DueAt || report.LastPeriod == period.Key {
			continue
		}
		claimed, err := r.Store.ClaimReport(ctx, report.ID, period.Key, now)
		if err != nil {
			return result, err
		}
		if !claimed {
			continue
		}
		if err := r.DeliverReport(ctx, report, site, &period); err != nil {
			if err := r.Store.ReleaseReport(ctx, report.ID, period.Key, report.LastPeriod); err != nil {
				return result, err
			}
			r.logf("Runlight: could not send the %s report for %s to %s: %s", report.Frequency, site.Name, report.Email, err.Error())
			result.Failed++
			continue
		}
		result.Sent++
	}
	return result, nil
}

// DeliverReport builds and sends one report, for its last period when period is nil. Also used by "Send a sample now".
func (r *Runlight) DeliverReport(ctx context.Context, report ReportRow, site SiteRow, period *Period) error {
	if period == nil {
		p := LastPeriod(report.Frequency, r.now(), site.Timezone)
		period = &p
	}
	unsubscribe := report.Origin + "/unsubscribe/" + report.Token
	built, err := BuildReport(ctx, r, site, report.Frequency, *period, report.Lang, ReportLinks{Dashboard: report.Origin + "/?site=" + encodeURIComponent(site.ID), Unsubscribe: unsubscribe})
	if err != nil {
		return err
	}
	return r.SendMail(ctx, MailMessage{To: report.Email, Subject: built.Subject, HTML: built.HTML, Text: built.Text,
		Headers: js.NewObject("List-Unsubscribe", "<"+unsubscribe+">", "List-Unsubscribe-Post", "List-Unsubscribe=One-Click")})
}
