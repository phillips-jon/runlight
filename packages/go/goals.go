package runlight

import (
	"math"
	"regexp"
	"strings"

	"runlight.sh/go/internal/js"
)

// PagePattern is a page to match, written the way paths are recorded: the
// path of a pasted URL, with a leading slash, percent-encoded as browsers
// send it, so /café matches the recorded /caf%C3%A9, and with a hash route
// kept, so /#/thanks counts only that route. * stays a wildcard. False when
// it is not a path or a URL.
func PagePattern(input string) (string, bool) {
	starred := strings.ReplaceAll(input, "*", "__STAR__")
	// A pattern written to start with * keeps that start, rather than gaining a slash.
	if strings.HasPrefix(starred, "__STAR__") {
		starred = "/" + starred
	}
	path, ok := RecordedPath(starred)
	if !ok {
		return "", false
	}
	pattern := strings.ReplaceAll(path, "__STAR__", "*")
	if strings.HasPrefix(input, "*") {
		pattern = strings.TrimPrefix(pattern, "/")
	}
	return pattern, true
}

var (
	goalKinds  = map[string]bool{"event": true, "page": true, "click": true}
	goalModes  = map[string]bool{"none": true, "fixed": true, "prop": true}
	propName   = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,40}$`)
	currencyRe = regexp.MustCompile(`^[A-Z]{3}$`)
)

// field is String(input[key] ?? ""): a value read from a JSON body as text.
func field(input *js.Object, key string) string {
	v, ok := input.Get(key)
	if !ok || v == nil {
		return ""
	}
	if _, undefined := v.(js.Undefined); undefined {
		return ""
	}
	return js.String(v)
}

// text is String(input[key] ?? "").trim().slice(0, max).
func text(input *js.Object, key string, max int) string {
	return head16(jsTrim(field(input, key)), max)
}

// GoalFrom checks and tidies a goal from the dashboard. existing is the
// site's other goals, so two goals cannot share a name. id is "" for a new goal.
func GoalFrom(input *js.Object, site string, existing []GoalRow, now int64, id string) (GoalRow, error) {
	name := text(input, "name", 80)
	if name == "" {
		return GoalRow{}, goalError("Give the goal a name", "goal_name")
	}
	for _, g := range existing {
		if g.ID != id && lower(g.Name) == lower(name) {
			return GoalRow{}, goalError(`There is already a goal called "`+name+`"`, "goal_exists", "name", name)
		}
	}
	kind := field(input, "kind")
	if !goalKinds[kind] {
		return GoalRow{}, goalError("Pick what the goal counts: an event, a page visit, or a click", "goal_kind")
	}
	match := text(input, "match", 500)
	clickBy := ""
	if kind == "event" && match == "" {
		return GoalRow{}, goalError("Enter the event's name", "goal_event")
	}
	if kind == "page" {
		if match == "" {
			return GoalRow{}, goalError("Enter a page path, like /thanks or /blog/*", "goal_page")
		}
		// A full URL is fine to paste; the path is what counts.
		path, ok := PagePattern(match)
		if !ok {
			return GoalRow{}, goalError("That page is not a path or a URL", "goal_page_bad")
		}
		match = path
	}
	if kind == "click" {
		clickBy = "selector"
		if v, _ := input.Get("clickBy"); v == "link" {
			clickBy = "link"
		}
		if match == "" {
			if clickBy == "link" {
				return GoalRow{}, goalError("Enter the link's address, like https://buy.stripe.com/*", "goal_link")
			}
			return GoalRow{}, goalError("Enter a CSS selector, like #signup or .buy-button", "goal_selector")
		}
	}

	// A click goal sends an event named after itself, so its name and an event goal's match must not meet.
	for _, g := range existing {
		if g.ID == id {
			continue
		}
		if kind == "click" && g.Kind == "event" && lower(g.Match) == lower(name) {
			return GoalRow{}, goalError(`An event goal already counts events called "`+name+`", so give this click goal another name`, "goal_event_taken", "name", name)
		}
	}
	for _, g := range existing {
		if g.ID == id {
			continue
		}
		if kind == "event" && g.Kind == "click" && lower(g.Name) == lower(match) {
			return GoalRow{}, goalError(`The click goal "`+match+`" already sends events with that name`, "goal_click_taken", "match", match)
		}
	}

	valueMode := "none"
	if raw, _ := input.Get("valueMode"); goalModes[js.String(undefinedIfMissing(input, "valueMode", raw))] {
		valueMode = js.String(raw)
	}
	// Page visits and click rules carry no properties, so only an event can send its own amount.
	if valueMode == "prop" && kind != "event" {
		return GoalRow{}, goalError("Only an event goal can take its amount from the event; use a fixed amount instead", "goal_prop_kind")
	}
	value := 0.0
	if valueMode == "fixed" {
		v, _ := input.Get("value")
		value = js.ToNumber(undefinedIfMissing(input, "value", v))
		if !(!math.IsNaN(value) && !math.IsInf(value, 0) && value >= 0 && value < 1e9) {
			return GoalRow{}, goalError("Enter an amount, like 49 or 9.99", "goal_amount")
		}
	}
	valueProp := ""
	if valueMode == "prop" {
		valueProp = text(input, "valueProp", 40)
		if valueProp == "" {
			valueProp = "revenue"
		}
		if !propName.MatchString(valueProp) {
			return GoalRow{}, goalError("A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name")
		}
	}
	currency := upper(text(input, "currency", 20))
	if currency == "" {
		currency = "USD"
	}
	if !currencyRe.MatchString(currency) {
		return GoalRow{}, goalError("Use a three-letter currency code, like USD or EUR", "goal_currency")
	}

	createdAt := now
	for _, g := range existing {
		if g.ID == id {
			createdAt = g.CreatedAt
			break
		}
	}
	if id == "" {
		id = randomID(12)
	}
	return GoalRow{ID: id, Site: site, Name: name, Kind: kind, Match: match, ClickBy: clickBy, ValueMode: valueMode,
		Value: js.Round(value*100) / 100, ValueProp: valueProp, Currency: currency, CreatedAt: createdAt}, nil
}

// undefinedIfMissing is a body's value, or undefined when the key is not there.
func undefinedIfMissing(input *js.Object, key string, v any) any {
	if !input.Has(key) {
		return js.Undefined{}
	}
	return v
}

// ClickRule is one click rule for the tracker: s for selector or h for a
// link, what to match, the event to send.
type ClickRule [3]string

// ClickRules are the click rules for the tracker, keyed by site id and by
// each of the site's hostnames (or "*" for a site with none), so the script
// finds its own.
func ClickRules(sites []SiteRow, goals []GoalRow) *js.Object {
	out := &js.Object{}
	for _, site := range sites {
		rules := []any{}
		for _, g := range goals {
			if g.Site == site.ID && g.Kind == "click" {
				by := "s"
				if g.ClickBy == "link" {
					by = "h"
				}
				rules = append(rules, []any{by, g.Match, g.Name})
			}
		}
		if len(rules) == 0 {
			continue
		}
		out.Set(site.ID, rules)
		hosts := site.Hostnames
		if len(hosts) == 0 {
			hosts = []string{"*"}
		}
		for _, host := range hosts {
			out.Set(strings.TrimPrefix(host, "www."), rules)
		}
	}
	return out
}

// FunnelFrom checks and tidies a funnel from the dashboard: a name, and two
// to eight steps, each a page (with * as a wildcard) or an event name.
func FunnelFrom(input *js.Object, site string, existing []FunnelRow, now int64, id string) (FunnelRow, error) {
	name := text(input, "name", 80)
	if name == "" {
		return FunnelRow{}, funnelError("Give the funnel a name", "funnel_name")
	}
	for _, f := range existing {
		if f.ID != id && lower(f.Name) == lower(name) {
			return FunnelRow{}, funnelError(`There is already a funnel called "`+name+`"`, "funnel_exists", "name", name)
		}
	}
	steps := []FunnelStep{}
	for _, item := range js.Arr(input.Value("steps")) {
		step, _ := item.(*js.Object)
		if step == nil {
			step = &js.Object{}
		}
		kind := "page"
		if v, _ := step.Get("kind"); v == "event" {
			kind = "event"
		}
		match := text(step, "match", 500)
		if match == "" {
			continue
		}
		if kind == "page" {
			// A full URL is fine to paste; the path is what counts.
			path, ok := PagePattern(match)
			if !ok {
				return FunnelRow{}, funnelError(`"`+match+`" is not a path or a URL`, "funnel_page_bad", "match", match)
			}
			match = path
		}
		steps = append(steps, FunnelStep{Kind: kind, Match: match})
	}
	if len(steps) < 2 {
		return FunnelRow{}, funnelError("A funnel needs at least two steps", "funnel_short")
	}
	if len(steps) > 8 {
		return FunnelRow{}, funnelError("A funnel has at most eight steps", "funnel_long")
	}
	createdAt := now
	for _, f := range existing {
		if f.ID == id {
			createdAt = f.CreatedAt
			break
		}
	}
	if id == "" {
		id = randomID(12)
	}
	return FunnelRow{ID: id, Site: site, Name: name, Steps: steps, CreatedAt: createdAt}, nil
}
