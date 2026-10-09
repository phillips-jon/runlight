package runlight

import (
	"errors"
	"regexp"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
)

var freshID = regexp.MustCompile(`^[0-9a-f]{24}$`)

// outcome is an answer as the fixture writes it: the row with a new id as "<random>", or the error.
func outcome(value any, err error, fresh bool) string {
	if err != nil {
		var c interface{ coded() *CodedError }
		if errors.As(err, &c) {
			e := c.coded()
			return js.Stringify(js.NewObject("error", js.NewObject("message", e.Message, "code", e.Code, "params", e.Params)))
		}
		return "error " + err.Error()
	}
	v := js.ToValue(value).(*js.Object)
	if fresh && freshID.MatchString(js.Str(v.Value("id"))) {
		v.Set("id", "<random>")
	}
	return js.Stringify(js.NewObject("value", v))
}

func goalsOf(v any) []GoalRow {
	out := []GoalRow{}
	for _, g := range js.Arr(v) {
		out = append(out, GoalRow{ID: js.Str(js.Dig(g, "id")), Site: js.Str(js.Dig(g, "site")), Name: js.Str(js.Dig(g, "name")), Kind: js.Str(js.Dig(g, "kind")),
			Match: js.Str(js.Dig(g, "match")), ClickBy: js.Str(js.Dig(g, "clickBy")), ValueMode: js.Str(js.Dig(g, "valueMode")), Value: js.Num(js.Dig(g, "value")),
			ValueProp: js.Str(js.Dig(g, "valueProp")), Currency: js.Str(js.Dig(g, "currency")), CreatedAt: int64(js.Num(js.Dig(g, "createdAt")))})
	}
	return out
}

func TestGoalsAndFunnels(t *testing.T) {
	f := fixture.PHP(t, "goals.json")
	existing := goalsOf(js.Dig(f, "existing"))
	cases := js.Arr(js.Dig(f, "goals"))
	if len(cases) < 50 {
		t.Fatal("few goal cases")
	}
	for i, c := range cases {
		id := js.Str(js.Dig(c, "id"))
		goal, err := GoalFrom(js.Obj(js.Dig(c, "input")), "s", existing, 1000, id)
		if got, want := outcome(goal, err, id == ""), js.Stringify(js.Dig(c, "result")); got != want {
			t.Errorf("goal #%d %s:\n got %s\nwant %s", i, js.Stringify(js.Dig(c, "input")), got, want)
		}
	}
	funnels := []FunnelRow{}
	for _, fr := range js.Arr(js.Dig(f, "existingFunnels")) {
		funnels = append(funnels, FunnelRow{ID: js.Str(js.Dig(fr, "id")), Site: js.Str(js.Dig(fr, "site")), Name: js.Str(js.Dig(fr, "name")), Steps: []FunnelStep{}, CreatedAt: int64(js.Num(js.Dig(fr, "createdAt")))})
	}
	for i, c := range js.Arr(js.Dig(f, "funnels")) {
		id := js.Str(js.Dig(c, "id"))
		funnel, err := FunnelFrom(js.Obj(js.Dig(c, "input")), "s", funnels, 1000, id)
		if got, want := outcome(funnel, err, id == ""), js.Stringify(js.Dig(c, "result")); got != want {
			t.Errorf("funnel #%d %s:\n got %s\nwant %s", i, js.Stringify(js.Dig(c, "input")), got, want)
		}
	}
	for _, c := range js.Arr(js.Dig(f, "patterns")) {
		var got any
		if p, ok := PagePattern(js.Str(js.Dig(c, "input"))); ok {
			got = p
		}
		same(t, "pattern "+js.Str(js.Dig(c, "input")), got, js.Dig(c, "result"))
	}
	goal := func(id string, g GoalRow) GoalRow {
		g.ID = id
		if g.Site == "" {
			g.Site = "s"
		}
		if g.Name == "" {
			g.Name = id
		}
		if g.Kind == "" {
			g.Kind = "event"
		}
		if g.Match == "" {
			g.Match = id
		}
		g.ValueMode, g.Currency, g.CreatedAt = "none", "USD", 5
		return g
	}
	rules := ClickRules(
		[]SiteRow{{"s", "S", []string{"www.example.com", "shop.example.com"}, "UTC"}, {"t", "T", []string{}, "UTC"}, {"u", "U", []string{"u.example"}, "UTC"}},
		[]GoalRow{
			goal("cccccccccccccccccccccccc", GoalRow{Name: "Buy", Kind: "click", Match: ".buy", ClickBy: "selector"}),
			goal("dddddddddddddddddddddddd", GoalRow{Name: "Out", Kind: "click", Match: "https://x.example/*", ClickBy: "link", Site: "t"}),
			goal("eeeeeeeeeeeeeeeeeeeeeeee", GoalRow{Name: "E", Site: "u"}),
		})
	if got, want := js.Stringify(rules), js.Stringify(js.Dig(f, "rules")); got != want {
		t.Errorf("rules: %s not %s", got, want)
	}
}

func TestJourneys(t *testing.T) {
	f := fixture.PHP(t, "journeys.json")
	datasets := js.Arr(js.Dig(f, "datasets"))
	for i, run := range js.Arr(js.Dig(f, "runs")) {
		rows := []JourneyRow{}
		for _, r := range js.Arr(datasets[int(js.Num(js.Dig(run, "dataset")))]) {
			rows = append(rows, JourneyRow{Session: js.Str(js.Dig(r, "session")), Path: js.Str(js.Dig(r, "path"))})
		}
		o := js.Dig(run, "options")
		options := JourneyOptions{Steps: js.ToNumber(undefinedIfMissing(js.Obj(o), "steps", js.Dig(o, "steps"))), Start: js.Str(js.Dig(o, "start")), End: js.Str(js.Dig(o, "end"))}
		if th := js.Dig(o, "through"); th != nil {
			options.Through = &JourneyThrough{Step: js.ToNumber(js.Dig(th, "step")), Value: js.Str(js.Dig(th, "value"))}
		}
		if got, want := js.Stringify(Journeys(rows, options)), js.Stringify(js.Dig(run, "result")); got != want {
			t.Errorf("run %d %s:\n got %s\nwant %s", i, js.Stringify(o), got, want)
		}
	}
}
