package dbtest

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
)

func queryOf(v any) runlight.Query {
	q := runlight.Query{Site: js.Str(js.Dig(v, "site")), From: int64(js.Num(js.Dig(v, "from"))), To: int64(js.Num(js.Dig(v, "to"))), Filters: []runlight.Filter{}}
	for _, f := range js.Arr(js.Dig(v, "filters")) {
		q.Filters = append(q.Filters, runlight.Filter{Dimension: js.Str(js.Dig(f, "dimension")), Op: js.Str(js.Dig(f, "op")), Value: js.Str(js.Dig(f, "value"))})
	}
	return q
}

func goalOf(v any) runlight.GoalRow {
	return runlight.GoalRow{ID: js.Str(js.Dig(v, "id")), Site: js.Str(js.Dig(v, "site")), Name: js.Str(js.Dig(v, "name")), Kind: js.Str(js.Dig(v, "kind")),
		Match: js.Str(js.Dig(v, "match")), ClickBy: js.Str(js.Dig(v, "clickBy")), ValueMode: js.Str(js.Dig(v, "valueMode")), Value: js.Num(js.Dig(v, "value")),
		ValueProp: js.Str(js.Dig(v, "valueProp")), Currency: js.Str(js.Dig(v, "currency")), CreatedAt: int64(js.Num(js.Dig(v, "createdAt")))}
}

func bucketsOf(v any) []runlight.Bucket {
	out := []runlight.Bucket{}
	for _, b := range js.Arr(v) {
		out = append(out, runlight.Bucket{Start: int64(js.Num(js.Dig(b, "start"))), End: int64(js.Num(js.Dig(b, "end")))})
	}
	return out
}

func filtersOf(v any) []runlight.Filter {
	return queryOf(js.NewObject("filters", js.Dig(v, "filters"))).Filters
}

func ptrValue(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

// call runs one store call the fixture recorded, as the TypeScript store answers it.
func call(ctx context.Context, s *runlight.Store, method string, args []any) (any, error) {
	a := func(i int) any { return js.Dig(args, i) }
	n := func(i int) int { return int(js.Num(a(i))) }
	switch method {
	case "sites":
		return s.Sites(ctx)
	case "siteOverrides":
		m, order, err := s.SiteOverrides(ctx)
		o := &js.Object{}
		for _, id := range order {
			o.Set(id, m[id])
		}
		return o, err
	case "lastSeen":
		v, err := s.LastSeen(ctx, js.Str(a(0)))
		return ptrValue(v), err
	case "firstSeen":
		v, err := s.FirstSeen(ctx, js.Str(a(0)))
		return ptrValue(v), err
	case "firstOwnVisit":
		v, err := s.FirstOwnVisit(ctx, js.Str(a(0)))
		return ptrValue(v), err
	case "rollupDays":
		days, err := s.RollupDays(ctx, js.Str(a(0)))
		out := []string{}
		for d := range days {
			out = append(out, d)
		}
		sortStrings(out)
		return out, err
	case "stats":
		return s.Stats(ctx, queryOf(a(0)))
	case "visitors":
		return s.Visitors(ctx, queryOf(a(0)))
	case "hourly":
		return s.Hourly(ctx, queryOf(a(0)))
	case "breakdown":
		return s.Breakdown(ctx, queryOf(a(0)), js.Str(a(1)), n(2), n(3))
	case "goalTotalsAll":
		goals := []runlight.GoalRow{}
		for _, g := range js.Arr(a(1)) {
			goals = append(goals, goalOf(g))
		}
		m, err := s.GoalTotalsAll(ctx, queryOf(a(0)), goals)
		o := &js.Object{}
		for _, g := range goals {
			o.Set(g.ID, m[g.ID])
		}
		return o, err
	case "funnelCounts":
		f := runlight.FunnelRow{ID: js.Str(js.Dig(a(1), "id")), Site: js.Str(js.Dig(a(1), "site")), Name: js.Str(js.Dig(a(1), "name"))}
		for _, st := range js.Arr(js.Dig(a(1), "steps")) {
			f.Steps = append(f.Steps, runlight.FunnelStep{Kind: js.Str(js.Dig(st, "kind")), Match: js.Str(js.Dig(st, "match"))})
		}
		return s.FunnelCounts(ctx, queryOf(a(0)), f)
	case "journeyPages":
		rows, sampled, err := s.JourneyPages(ctx, queryOf(a(0)), n(1))
		return js.NewObject("rows", rows, "sampled", sampled), err
	case "eventPropKeys":
		return s.EventPropKeys(ctx, queryOf(a(0)), js.Str(a(1)))
	case "eventPropValues":
		return s.EventPropValues(ctx, queryOf(a(0)), js.Str(a(1)), js.Str(a(2)), n(3))
	case "goalTotals":
		return s.GoalTotals(ctx, queryOf(a(0)), goalOf(a(1)))
	case "goalBreakdown":
		limit := 10
		if len(args) > 3 {
			limit = n(3)
		}
		return s.GoalBreakdown(ctx, queryOf(a(0)), goalOf(a(1)), js.Str(a(2)), limit)
	case "links":
		return s.Links(ctx, js.Str(a(0)), int64(js.Num(a(1))), int64(js.Num(a(2))))
	case "linkBreakdown":
		return s.LinkBreakdown(ctx, js.Str(a(0)), js.Str(a(1)), int64(js.Num(a(2))), int64(js.Num(a(3))), js.Str(a(4)), n(5))
	case "series":
		return s.Series(ctx, js.Str(js.Dig(a(0), "site")), filtersOf(a(0)), bucketsOf(a(1)))
	case "goalSeries":
		return s.GoalSeries(ctx, js.Str(js.Dig(a(0), "site")), filtersOf(a(0)), goalOf(a(1)), bucketsOf(a(2)))
	case "linkSeries":
		return s.LinkSeries(ctx, js.Str(a(0)), js.Str(a(1)), bucketsOf(a(2)))
	case "realtime":
		return s.Realtime(ctx, js.Str(a(0)), int64(js.Num(a(1))))
	case "goals":
		site := ""
		if len(args) > 0 {
			site = js.Str(a(0))
		}
		return s.Goals(ctx, site)
	case "goalById":
		return s.GoalByID(ctx, js.Str(a(0)))
	case "funnels":
		return s.Funnels(ctx, js.Str(a(0)))
	case "linkBySlug":
		return s.LinkBySlug(ctx, js.Str(a(0)))
	case "linkById":
		return s.LinkByID(ctx, js.Str(a(0)))
	case "linkDomains":
		return s.LinkDomains(ctx)
	case "shares":
		return s.Shares(ctx, js.Str(a(0)))
	case "shareById":
		return s.ShareByID(ctx, js.Str(a(0)))
	case "tokens":
		return s.Tokens(ctx)
	case "tokenByHash":
		return s.TokenByHash(ctx, js.Str(a(0)))
	case "reports":
		site := ""
		if len(args) > 0 {
			site = js.Str(a(0))
		}
		return s.Reports(ctx, site)
	case "reportBy":
		return s.ReportBy(ctx, js.Str(a(0)), js.Str(a(1)))
	case "setting":
		v, ok, err := s.Setting(ctx, js.Str(a(0)))
		if !ok {
			return nil, err
		}
		return v, err
	case "settingsStartingWith":
		return s.SettingsStartingWith(ctx, js.Str(a(0)))
	case "pageview":
		return s.Pageview(ctx, js.Str(a(0)), js.Str(a(1)))
	case "openSession":
		visitors := []string{}
		for _, v := range js.Arr(a(1)) {
			visitors = append(visitors, js.Str(v))
		}
		return s.OpenSession(ctx, js.Str(a(0)), visitors, int64(js.Num(a(2))))
	case "saltIfExists":
		v, ok, err := s.SaltIfExists(ctx, js.Str(a(0)))
		if !ok {
			return nil, err
		}
		return v, err
	}
	return nil, fmt.Errorf("no such call %s", method)
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// fixtureStore is store.db, the SQLite file the TypeScript SDK wrote, opened from a copy.
func fixtureStore(t *testing.T) *runlight.Store {
	src, err := os.ReadFile(fixture.Path("packages", "php", "tests", "fixtures", "store.db"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "store.db")
	if err := os.WriteFile(path, src, 0o600); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	store := runlight.NewStore(runlight.SQLite(db).Owned(0))
	t.Cleanup(func() { store.Close() })
	if err := store.Migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	return store
}

// copyRows copies every rl_ table's rows from one store to another.
func copyRows(t *testing.T, from, to *runlight.Store) {
	ctx := context.Background()
	for _, table := range []string{"rl_sites", "rl_salts", "rl_sessions", "rl_events", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_settings", "rl_reports", "rl_tokens", "rl_funnels", "rl_rollup_days", "rl_rollups"} {
		rows, err := from.DB().All(ctx, "SELECT * FROM "+table)
		if err != nil {
			t.Fatal(err)
		}
		for _, row := range rows {
			cols := []string{}
			marks := []string{}
			params := []any{}
			for k, v := range row {
				cols = append(cols, `"`+k+`"`)
				marks = append(marks, "?")
				params = append(params, v)
			}
			if err := to.DB().Run(ctx, "INSERT INTO "+table+" ("+join(cols)+") VALUES ("+join(marks)+")", params...); err != nil {
				t.Fatalf("%s: %v", table, err)
			}
		}
	}
}

func join(s []string) string {
	out := ""
	for i, x := range s {
		if i > 0 {
			out += ", "
		}
		out += x
	}
	return out
}

// Replays store.json: every read the TypeScript store answered over store.db, a SQLite file it wrote,
// on that file and on the same rows copied into each other database.
func TestStoreFixture(t *testing.T) {
	for _, kind := range Kinds() {
		t.Run(kind.Name, func(t *testing.T) {
			store := fixtureStore(t)
			if kind.Name != "sqlite" {
				other := Store(t, kind)
				copyRows(t, store, other)
				store = other
			}
			replayStore(t, store)
		})
	}
}

func replayStore(t *testing.T, store *runlight.Store) {
	file := fixture.PHP(t, "store.json")
	ctx := context.Background()
	failures := 0
	calls := js.Arr(js.Dig(file, "calls"))
	if len(calls) < 1000 {
		t.Fatalf("only %d calls", len(calls))
	}
	for i, c := range calls {
		method := js.Str(js.Dig(c, "method"))
		args := js.Arr(js.Dig(c, "args"))
		got, err := call(ctx, store, method, args)
		if err != nil {
			t.Errorf("%d %s %s: %v", i, method, js.Stringify(args), err)
			failures++
		} else if g, w := js.Canonical(got), js.Canonical(js.Dig(c, "result")); g != w {
			t.Errorf("%d %s %s:\n got %s\nwant %s", i, method, js.Stringify(args), g, w)
			failures++
		}
		if failures > 15 {
			t.FailNow()
		}
	}
}
