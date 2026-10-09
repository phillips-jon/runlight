package dbtest

import (
	"context"
	"testing"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

const agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

// Email reports render as the TypeScript SDK renders them, in every language.
func TestReportsRender(t *testing.T) {
	ctx := context.Background()
	for _, c := range js.Arr(js.Dig(fixture.PHP(t, "reports.json"), "cases")) {
		t.Run(js.Str(js.Dig(c, "name")), func(t *testing.T) {
			now := int64(0)
			r, err := runlight.New(runlight.Options{Store: runlight.NewStore(Open(t, Kind{Name: "sqlite"})),
				Site: &runlight.SiteOptions{Name: "Example & Co", Hostnames: []string{"example.com"}, Timezone: js.Str(js.Dig(c, "timezone"))},
				Now:  func() int64 { return now }})
			if err != nil {
				t.Fatal(err)
			}
			if err := r.Init(ctx); err != nil {
				t.Fatal(err)
			}
			for _, g := range js.Arr(js.Dig(c, "goals")) {
				if err := r.Store.SaveGoal(ctx, goalOf(g), nil); err != nil {
					t.Fatal(err)
				}
			}
			for _, hit := range js.Arr(js.Dig(c, "hits")) {
				now = int64(js.Num(js.Dig(hit, "at")))
				headers := web.NewHeaders("user-agent", agent, "x-forwarded-for", js.Str(js.Dig(hit, "ip")))
				if country := js.Str(js.Dig(hit, "country")); country != "" {
					headers.Set("x-vercel-ip-country", country)
				}
				if err := r.Collect(ctx, web.NewRequest("POST", "https://example.com/runlight/e", headers, []byte(js.Stringify(js.Dig(hit, "body"))))); err != nil {
					t.Fatal(err)
				}
			}
			now = int64(js.Num(js.Dig(c, "at")))
			site, _ := r.Site("default")
			for _, want := range js.Arr(js.Dig(c, "reports")) {
				frequency, lang := js.Str(js.Dig(want, "frequency")), js.Str(js.Dig(want, "lang"))
				period := runlight.LastPeriod(frequency, now, site.Timezone)
				if js.Canonical(period) != js.Canonical(js.Dig(want, "period")) {
					t.Errorf("%s %s period %s", lang, frequency, js.Stringify(period))
				}
				built, err := runlight.BuildReport(ctx, r, site, frequency, period, lang, runlight.ReportLinks{Dashboard: js.Str(js.Dig(want, "links", "dashboard")), Unsubscribe: js.Str(js.Dig(want, "links", "unsubscribe"))})
				if err != nil {
					t.Fatal(err)
				}
				for _, part := range [][2]string{{"subject", built.Subject}, {"text", built.Text}, {"html", built.HTML}} {
					if part[1] != js.Str(js.Dig(want, part[0])) {
						t.Errorf("%s %s %s:\n got %q\nwant %q", lang, frequency, part[0], part[1], js.Str(js.Dig(want, part[0])))
					}
				}
			}
		})
	}
}
