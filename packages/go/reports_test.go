package runlight

import (
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/intl"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

func TestIntl(t *testing.T) {
	for _, set := range js.Arr(js.Dig(fixture.PHP(t, "reports.json"), "intl")) {
		lang := js.Str(js.Dig(set, "lang"))
		check := func(what, got string, want any) {
			t.Helper()
			if got != js.Str(want) {
				t.Errorf("%s %s: %q not %q", lang, what, got, want)
			}
		}
		for _, c := range js.Arr(js.Dig(set, "number")) {
			check("number "+js.String(js.Dig(c, 0)), intl.Number(lang, js.Num(js.Dig(c, 0)), 0, 3), js.Dig(c, 1))
		}
		for _, c := range js.Arr(js.Dig(set, "decimal")) {
			check("decimal "+js.String(js.Dig(c, 0)), intl.Number(lang, js.Num(js.Dig(c, 0)), 1, 1), js.Dig(c, 1))
		}
		for _, c := range js.Arr(js.Dig(set, "percent")) {
			check("percent "+js.String(js.Dig(c, 0)), intl.Percent(lang, js.Num(js.Dig(c, 0))), js.Dig(c, 1))
		}
		for _, c := range js.Arr(js.Dig(set, "currency")) {
			n := js.Num(js.Dig(c, 0))
			max := 2
			if js.IsInteger(n) {
				max = 0
			}
			check("currency "+js.Stringify(c), intl.Currency(lang, n, js.Str(js.Dig(c, 1)), max, js.FormatNumber(n)+" "+js.Str(js.Dig(c, 1))), js.Dig(c, 2))
		}
		for _, c := range js.Arr(js.Dig(set, "monthYear")) {
			check("month "+js.Str(js.Dig(c, 0)), intl.MonthYear(lang, js.Str(js.Dig(c, 0))), js.Dig(c, 1))
		}
		for _, c := range js.Arr(js.Dig(set, "shortDay")) {
			check("day "+js.Str(js.Dig(c, 0)), intl.ShortDay(lang, js.Str(js.Dig(c, 0)), false), js.Dig(c, 1))
			check("day "+js.Str(js.Dig(c, 0)), intl.ShortDay(lang, js.Str(js.Dig(c, 0)), true), js.Dig(c, 2))
		}
		for _, c := range js.Arr(js.Dig(set, "region")) {
			check("region "+js.Str(js.Dig(c, 0)), intl.Region(lang, js.Str(js.Dig(c, 0))), js.Dig(c, 1))
		}
	}
}

func TestIconLinksAndPublicAddresses(t *testing.T) {
	f := fixture.PHP(t, "outbound.json")
	for _, c := range js.Arr(js.Dig(f, "icons")) {
		same(t, "icons", IconLinks(js.Str(js.Dig(c, "html")), js.Str(js.Dig(c, "base"))), js.Dig(c, "links"))
	}
	for _, c := range js.Arr(js.Dig(f, "ips")) {
		if web.PublicAddress(js.Str(js.Dig(c, "ip"))) != js.Truthy(js.Dig(c, "public")) {
			t.Errorf("ip %v", js.Dig(c, "ip"))
		}
	}
}

func TestReportPeriods(t *testing.T) {
	for _, c := range js.Arr(js.Dig(fixture.PHP(t, "reports.json"), "periods")) {
		same(t, js.Stringify(c), LastPeriod(js.Str(js.Dig(c, "frequency")), int64(js.Num(js.Dig(c, "now"))), js.Str(js.Dig(c, "zone"))), js.Dig(c, "period"))
	}
}
