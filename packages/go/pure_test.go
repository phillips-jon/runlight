package runlight

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
	"runlight.sh/go/mmdb"
)

func same(t *testing.T, label string, got, want any) bool {
	t.Helper()
	if g, w := js.Canonical(got), js.Canonical(want); g != w {
		t.Errorf("%s:\n got %s\nwant %s", label, g, w)
		return false
	}
	return true
}

func optStr(v any) *string {
	s, ok := v.(string)
	if !ok {
		return nil
	}
	return &s
}

func hintsOf(v any) ClientHints {
	return ClientHints{Brands: optStr(js.Dig(v, "brands")), Mobile: optStr(js.Dig(v, "mobile")), Platform: optStr(js.Dig(v, "platform"))}
}

func widthOf(v any) *int {
	n, ok := v.(float64)
	if !ok {
		return nil
	}
	i := int(n)
	return &i
}

func TestUserAgents(t *testing.T) {
	for _, c := range js.Arr(js.Dig(fixture.JSON(t, "conformance", "ua.json"), "cases")) {
		ua := js.Str(js.Dig(c, "ua"))
		agent := AiAgentOf(ua)
		if want := js.Dig(c, "agent"); want != nil {
			if agent == nil || agent.Name != js.Str(js.Dig(want, "name")) || agent.Kind != js.Str(js.Dig(want, "kind")) {
				t.Errorf("%s: agent %v", ua, agent)
			}
			continue
		}
		if agent != nil {
			t.Errorf("%s: not an AI agent", ua)
		}
		if IsBot(ua) != js.Truthy(js.Dig(c, "bot")) {
			t.Errorf("%s: bot %v", ua, IsBot(ua))
		}
		if want := js.Dig(c, "client"); want != nil {
			same(t, ua, ParseClient(ua, hintsOf(js.Dig(c, "hints")), widthOf(js.Dig(c, "screenWidth"))), want)
		}
	}
	for _, c := range js.Arr(js.Dig(fixture.PHP(t, "ua.json"), "cases")) {
		ua := js.Str(js.Dig(c, "ua"))
		var agent any
		if a := AiAgentOf(ua); a != nil {
			agent = a
		}
		got := js.NewObject("agent", agent, "bot", IsBot(ua), "client", ParseClient(ua, hintsOf(js.Dig(c, "hints")), widthOf(js.Dig(c, "screenWidth"))))
		want := js.NewObject("agent", js.Dig(c, "agent"), "bot", js.Dig(c, "bot"), "client", js.Dig(c, "client"))
		same(t, ua, got, want)
	}
}

func TestSources(t *testing.T) {
	f := fixture.PHP(t, "sources.json")
	for _, c := range js.Arr(js.Dig(f, "hosts")) {
		var got any
		if s := SourceForHost(js.Str(js.Dig(c, "host"))); s != nil {
			got = s
		}
		same(t, "host "+js.Str(js.Dig(c, "host")), got, js.Dig(c, "source"))
	}
	for _, c := range js.Arr(js.Dig(f, "aliases")) {
		var got any
		if s := SourceForAlias(js.Str(js.Dig(c, "alias"))); s != nil {
			got = s
		}
		same(t, "alias "+js.Str(js.Dig(c, "alias")), got, js.Dig(c, "source"))
	}
	for _, c := range js.Arr(js.Dig(f, "pages")) {
		u := whatwg.MustParse(js.Str(js.Dig(c, "url")))
		same(t, "page "+u.Href(), ParsePage(u), js.Dig(c, "page"))
	}
	for _, c := range js.Arr(js.Dig(f, "visits")) {
		u := whatwg.MustParse(js.Str(js.Dig(c, "url")))
		internal := []string{}
		for _, h := range js.Arr(js.Dig(c, "internal")) {
			internal = append(internal, js.Str(h))
		}
		same(t, "visit "+u.Href()+" "+js.Str(js.Dig(c, "referrer")), Attribute(ParsePage(u), js.Str(js.Dig(c, "referrer")), internal), js.Dig(c, "attribution"))
	}
	for _, c := range js.Arr(js.Dig(f, "recordedPaths")) {
		var got any
		if p, ok := RecordedPath(js.Str(js.Dig(c, "input"))); ok {
			got = p
		}
		same(t, "recorded "+js.Str(js.Dig(c, "input")), got, js.Dig(c, "path"))
	}
	for _, c := range js.Arr(js.Dig(f, "readablePaths")) {
		same(t, "readable "+js.Str(js.Dig(c, "input")), ReadablePath(js.Str(js.Dig(c, "input"))), js.Dig(c, "path"))
	}
	for _, c := range js.Arr(js.Dig(f, "stripWww")) {
		same(t, "strip", StripWww(js.Str(js.Dig(c, "input"))), js.Dig(c, "host"))
	}
}

func payloadValue(p *Payload) any {
	if p == nil {
		return nil
	}
	num := func(n *int) any {
		if n == nil {
			return nil
		}
		return *n
	}
	var props any
	if p.Props != nil {
		props = js.Stringify(p.Props)
	}
	return js.NewObject("kind", p.Kind, "site", p.Site, "url", p.URL.Href(), "referrer", p.Referrer, "title", p.Title,
		"screenWidth", num(p.ScreenWidth), "screenHeight", num(p.ScreenHeight), "language", p.Language, "name", p.Name,
		"props", props, "pageviewId", p.PageviewID, "engagedMs", p.EngagedMs, "scroll", num(p.Scroll))
}

func TestPayloads(t *testing.T) {
	f := fixture.PHP(t, "payload.json")
	if js.Num(js.Dig(f, "maxBody")) != MaxBody {
		t.Errorf("MaxBody")
	}
	for _, c := range js.Arr(js.Dig(f, "cases")) {
		same(t, js.Str(js.Dig(c, "text")), payloadValue(ParsePayload(js.Str(js.Dig(c, "text")))), js.Dig(c, "payload"))
	}
}

func TestQueries(t *testing.T) {
	f := fixture.PHP(t, "query.json")
	same(t, "dimensions", Dimensions, js.Dig(f, "dimensions"))
	if js.Num(js.Dig(f, "maxFilters")) != MaxFilters {
		t.Errorf("MaxFilters")
	}
	for _, c := range js.Arr(js.Dig(f, "dimensionTests")) {
		v := js.Str(js.Dig(c, "value"))
		same(t, "dimension "+v, js.NewObject("value", v, "isDimension", IsDimension(v), "isSessionDimension", IsSessionDimension(v), "isEventDimension", IsEventDimension(v)), c)
	}
	for _, c := range js.Arr(js.Dig(f, "filters")) {
		var got any
		if filter := ParseFilter(js.Str(js.Dig(c, "text"))); filter != nil {
			got = filter
		}
		same(t, "filter "+js.Str(js.Dig(c, "text")), got, js.Dig(c, "filter"))
	}
}

// systemVSummer are zones whose summer time ICU and the time zone database disagree on.
var systemVSummer = map[string]bool{"systemv/ast4adt": true, "systemv/est5edt": true, "systemv/cst6cdt": true, "systemv/mst7mdt": true, "systemv/pst8pdt": true, "systemv/yst9ydt": true}

// changedSince2025c are zones whose rules changed after the time zone data the fixture was written
// with (Morocco's summer time, British Columbia and Alberta keeping summer time), so their answers
// follow whichever data this machine has, and are not compared.
var changedSince2025c = map[string]bool{"africa/casablanca": true, "africa/el_aaiun": true, "america/vancouver": true, "america/edmonton": true, "america/yellowknife": true, "canada/pacific": true, "canada/mountain": true}

func localOf(ts int64, zone string) string {
	w, h := LocalWeekdayHour(ts, zone)
	return fmt.Sprintf("%s %d %d", LocalDate(ts, zone), w, h)
}

func TestTimeZones(t *testing.T) {
	f := fixture.PHP(t, "time.json")
	samples := js.Arr(js.Dig(f, "sampleTimes"))
	var failures []string
	for _, z := range js.Arr(js.Dig(f, "zones")) {
		name := js.Str(js.Dig(z, "name"))
		valid := IsTimezone(name)
		if valid != js.Truthy(js.Dig(z, "valid")) {
			failures = append(failures, fmt.Sprintf("%s valid %v", name, valid))
			continue
		}
		if !valid || systemVSummer[strings.ToLower(name)] || changedSince2025c[strings.ToLower(name)] {
			continue
		}
		for i, ts := range samples {
			// Before 1970 ICU follows backzone history, which the system's database may not hold.
			if js.Num(ts) < 0 {
				continue
			}
			if got, want := localOf(int64(js.Num(ts)), name), js.Str(js.Dig(z, "local", i)); got != want {
				failures = append(failures, fmt.Sprintf("%s at %v: %s not %s", name, ts, got, want))
			}
		}
	}
	for _, c := range js.Arr(js.Dig(f, "instants")) {
		zone, ts := js.Str(js.Dig(c, 0)), int64(js.Num(js.Dig(c, 1)))
		if changedSince2025c[strings.ToLower(zone)] {
			continue
		}
		want := fmt.Sprintf("%s %v %v", js.Dig(c, 2), js.Dig(c, 3), js.Dig(c, 4))
		if got := localOf(ts, zone); got != want {
			failures = append(failures, fmt.Sprintf("%s %d: %s not %s", zone, ts, got, want))
		}
	}
	for _, c := range js.Arr(js.Dig(f, "starts")) {
		zone, date, hour, start := js.Str(js.Dig(c, 0)), js.Str(js.Dig(c, 1)), int64(js.Num(js.Dig(c, 2))), int64(js.Num(js.Dig(c, 3)))
		if changedSince2025c[strings.ToLower(zone)] {
			continue
		}
		if got := StartOf(date, zone, hour); got != start {
			failures = append(failures, fmt.Sprintf("start %s %s %d: %d not %d", zone, date, hour, got, start))
		}
	}
	for _, c := range js.Arr(js.Dig(f, "dayStarts")) {
		zone, year := js.Str(js.Dig(c, 0)), int(js.Num(js.Dig(c, 1)))
		if changedSince2025c[strings.ToLower(zone)] {
			continue
		}
		days := []int64{}
		for d := fmt.Sprintf("%d-01-01", year); d < fmt.Sprintf("%d-01-01", year+1); d = AddDays(d, 1) {
			days = append(days, StartOf(d, zone, 0))
		}
		sum := sha256.Sum256([]byte(js.Stringify(days)))
		if hex.EncodeToString(sum[:]) != js.Str(js.Dig(c, 2)) {
			failures = append(failures, fmt.Sprintf("day starts %s %d", zone, year))
		}
	}
	if len(failures) > 0 {
		t.Errorf("%d differ (tzdata here may be newer than the fixture's 2025c), the first: %s", len(failures), strings.Join(failures[:min(40, len(failures))], "\n"))
	}
}

// The old names the time zone database made links in 2024b are read as those
// links, as ICU reads them, even where the system builds them as zones of
// their own (Debian's WET kept to UTC in 1970, while Lisbon was an hour ahead).
func TestLinkedLegacyZones(t *testing.T) {
	for _, c := range []struct {
		zone string
		ts   int64
		want string
	}{
		{"WET", 0, "1970-01-01 3 1"},
		{"wet", 15638400000, "1970-07-01 2 1"},
		{"CET", 0, "1970-01-01 3 1"},
		{"EST", 0, "1969-12-31 2 19"},
		{"MST", 15638400000, "1970-06-30 1 17"},
	} {
		if !IsTimezone(c.zone) {
			t.Errorf("%s is not taken", c.zone)
			continue
		}
		if got := localOf(c.ts, c.zone); got != c.want {
			t.Errorf("%s at %d: %s not %s", c.zone, c.ts, got, c.want)
		}
	}
}

func TestDatesAndRanges(t *testing.T) {
	f := fixture.PHP(t, "time.json")
	same(t, "periods", Periods, js.Dig(f, "periods"))
	for _, c := range js.Arr(js.Dig(f, "dates")) {
		date := js.Str(js.Dig(c, "date"))
		if IsDate(date) != js.Truthy(js.Dig(c, "isDate")) {
			t.Errorf("isDate %s", date)
		}
		if js.Dig(c, "plus") != nil {
			plus, months := []string{}, []string{}
			for _, n := range []int64{-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000} {
				plus = append(plus, AddDays(date, n))
			}
			for _, n := range []int64{-25, -12, -11, -1, 0, 1, 11, 12, 13} {
				months = append(months, AddMonths(date, n))
			}
			same(t, "plus "+date, plus, js.Dig(c, "plus"))
			same(t, "months "+date, months, js.Dig(c, "months"))
		}
	}
	failures := 0
	for _, c := range js.Arr(js.Dig(f, "ranges")) {
		in := js.Dig(c, "input")
		input := RangeInput{Period: optStr(js.Dig(in, "period")), From: optStr(js.Dig(in, "from")), To: optStr(js.Dig(in, "to")), Interval: optStr(js.Dig(in, "interval"))}
		zone := js.Str(js.Dig(c, "zone"))
		r := ResolveRange(input, zone, int64(js.Num(js.Dig(c, "now"))), js.Str(js.Dig(c, "firstDate")))
		got := js.NewObject("range", r)
		want := js.NewObject("range", js.Dig(c, "range"))
		if r != nil {
			buckets := Buckets(*r, zone)
			var first any
			if len(buckets) > 0 {
				first = buckets[0]
			}
			sum := sha256.Sum256([]byte(js.Stringify(buckets)))
			got.Set("buckets", js.NewObject("count", len(buckets), "first", first, "sha256", hex.EncodeToString(sum[:])))
			want.Set("buckets", js.Dig(c, "buckets"))
			if js.Dig(c, "compare") != nil {
				compare := &js.Object{}
				for _, mode := range []string{"previous", "year", "off", "custom", "nope"} {
					compare.Set(mode, CompareRange(*r, mode, zone, "2025-02-28", "2025-03-31"))
				}
				got.Set("compare", compare)
				want.Set("compare", js.Dig(c, "compare"))
			}
		}
		if !same(t, fmt.Sprintf("range %s %v %s", zone, js.Dig(c, "now"), js.Stringify(in)), got, want) {
			if failures++; failures > 10 {
				t.FailNow()
			}
		}
	}
	for _, c := range js.Arr(js.Dig(f, "compares")) {
		rv := js.Dig(c, "range")
		r := Range{int64(js.Num(js.Dig(rv, "from"))), int64(js.Num(js.Dig(rv, "to"))), js.Str(js.Dig(rv, "fromDate")), js.Str(js.Dig(rv, "toDate")), js.Str(js.Dig(rv, "interval"))}
		same(t, "compare", CompareRange(r, js.Str(js.Dig(c, "mode")), js.Str(js.Dig(c, "zone")), js.Str(js.Dig(c, "custom", "from")), js.Str(js.Dig(c, "custom", "to"))), js.Dig(c, "compare"))
	}
}

type mapHeaders map[string]string

func (h mapHeaders) Get(name string) string { return h[name] }

func headersOf(v any) mapHeaders {
	out := mapHeaders{}
	js.Obj(v).Each(func(k string, v any) { out[strings.ToLower(k)] = js.Str(v) })
	return out
}

func TestGeo(t *testing.T) {
	f := fixture.PHP(t, "geo.json")
	for _, c := range js.Arr(js.Dig(f, "headers")) {
		var got any
		if l := LocationFromHeaders(headersOf(js.Dig(c, "headers"))); l != nil {
			got = l
		}
		same(t, js.Stringify(js.Dig(c, "headers")), got, js.Dig(c, "location"))
	}
	for _, c := range js.Arr(js.Dig(f, "located")) {
		var lookup GeoLookup
		if !js.Truthy(js.Dig(c, "noLookup")) {
			lookup = func(string) (*Location, error) {
				if js.Truthy(js.Dig(c, "throws")) {
					return nil, fmt.Errorf("broken")
				}
				found := js.Dig(c, "found")
				if found == nil {
					return nil, nil
				}
				return &Location{js.Str(js.Dig(found, "country")), js.Str(js.Dig(found, "region")), js.Str(js.Dig(found, "city"))}, nil
			}
		}
		same(t, js.Stringify(c), Locate(headersOf(js.Dig(c, "headers")), js.Str(js.Dig(c, "ip")), lookup), js.Dig(c, "location"))
	}
	for _, db := range js.Arr(js.Dig(f, "databases")) {
		b, _ := base64.StdEncoding.DecodeString(js.Str(js.Dig(db, "base64")))
		reader, err := mmdb.FromBytes(b)
		if err != nil {
			t.Fatal(err)
		}
		if js.Num(reader.Metadata.Value("ip_version")) != js.Num(js.Dig(db, "ipVersion")) || js.Num(reader.Metadata.Value("record_size")) != js.Num(js.Dig(db, "recordSize")) {
			t.Errorf("metadata %s", js.Stringify(reader.Metadata))
		}
		lookup := LookupFrom(reader)
		for _, c := range js.Arr(js.Dig(db, "records")) {
			ip := js.Str(js.Dig(c, "ip"))
			record, err := reader.Get(ip)
			if err != nil {
				t.Errorf("%s: %v", ip, err)
			}
			if got, want := js.Stringify(record), js.Stringify(js.Dig(c, "record")); got != want {
				t.Errorf("record %s:\n got %s\nwant %s", ip, got, want)
			}
			var loc any
			if l, _ := lookup(ip); l != nil {
				loc = l
			}
			same(t, "lookup "+ip, loc, js.Dig(c, "location"))
		}
	}
}

func TestNamesLikeObjectPropertiesAreJustNames(t *testing.T) {
	for _, source := range []string{"constructor", "toString", "__proto__", "hasOwnProperty"} {
		_, err := ImportStep(t.Context(), nil, "default", source, nil, nil, 0)
		if e, ok := err.(*ImportError); !ok || e.Code != "import_source" {
			t.Errorf("%s: %v", source, err)
		}
	}
	same(t, "browsers", []any{browserName("constructor"), browserName("__proto__"), browserName("toString")}, []any{"Constructor", "__proto__", "ToString"})
	same(t, "devices", []any{deviceName("constructor"), deviceName("valueOf")}, []any{"", ""})
}

func TestConnectAddressesAndAttempts(t *testing.T) {
	for _, url := range []string{"https://[", "https://[::1", "https://a b"} {
		if _, err := installURL(url); err == nil {
			t.Errorf("%s passed", url)
		}
	}
	if url, err := installURL("https://example.com/runlight/"); err != nil || url != "https://example.com/runlight" {
		t.Error(url, err)
	}
	// An attempt counts only as a JSON object with a numeric expiry at or after now.
	for _, value := range []string{"", "null", "5", "not json", "[]", `{"url":"x"}`, `{"expires":"9999999999999"}`, `{"expires":999}`} {
		if pendingFrom(value, 1000) != nil {
			t.Errorf("%s counted", value)
		}
	}
	if pendingFrom(`{"expires":1000}`, 1000) == nil {
		t.Error("an attempt at its expiry did not count")
	}
}
