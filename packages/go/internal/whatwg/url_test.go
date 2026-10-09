package whatwg

import (
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
)

func parts(u *URL) any {
	return js.NewObject(
		"href", u.Href(), "protocol", u.Protocol, "username", u.Username, "password", u.Password,
		"hostname", u.Hostname, "port", u.Port, "host", u.Host(), "origin", u.Origin(),
		"pathname", u.Pathname, "search", u.Search, "hash", u.Hash,
	)
}

// Replays conformance/url.json: URLs, query strings, and numbers read and written as JavaScript does.
func TestURLConformance(t *testing.T) {
	file := fixture.JSON(t, "conformance", "url.json")
	check := func(input string, base []string, expect any) {
		t.Helper()
		u, err := Parse(input, base...)
		if expect == nil {
			if err == nil {
				t.Errorf("%q %v should not parse, got %s", input, base, u.Href())
			}
			return
		}
		if err != nil {
			t.Errorf("%q %v should parse: %v", input, base, err)
			return
		}
		if got, want := js.Stringify(parts(u)), js.Stringify(expect); got != want {
			t.Errorf("%q %v:\n got %s\nwant %s", input, base, got, want)
		}
	}
	for _, c := range js.Arr(js.Dig(file, "urls")) {
		check(js.Str(js.Dig(c, "input")), nil, js.Dig(c, "expect"))
	}
	for _, c := range js.Arr(js.Dig(file, "relative")) {
		check(js.Str(js.Dig(c, "input")), []string{js.Str(js.Dig(c, "base"))}, js.Dig(c, "expect"))
	}
	for _, c := range js.Arr(js.Dig(file, "queries")) {
		p := ParseQuery(js.Str(js.Dig(c, "input")))
		pairs := []any{}
		for _, pair := range p.Pairs() {
			pairs = append(pairs, []any{pair[0], pair[1]})
		}
		if got, want := js.Stringify(pairs), js.Stringify(js.Dig(c, "pairs")); got != want {
			t.Errorf("query %q: got %s want %s", js.Dig(c, "input"), got, want)
		}
		if got, want := p.String(), js.Str(js.Dig(c, "string")); got != want {
			t.Errorf("query %q string: got %s want %s", js.Dig(c, "input"), got, want)
		}
	}
	for _, c := range js.Arr(js.Dig(file, "written")) {
		p := NewSearchParams()
		for _, pair := range js.Arr(js.Dig(c, "pairs")) {
			p.Append(js.Str(js.Dig(pair, 0)), js.Str(js.Dig(pair, 1)))
		}
		if got, want := p.String(), js.Str(js.Dig(c, "string")); got != want {
			t.Errorf("written: got %s want %s", got, want)
		}
	}
	for _, c := range js.Arr(js.Dig(file, "numbers")) {
		n := js.Dig(c, "n")
		f, ok := n.(float64)
		if !ok {
			f = js.Number(js.Str(n))
		}
		if got, want := js.FormatNumber(f), js.Str(js.Dig(c, "text")); got != want {
			t.Errorf("number %v: got %s want %s", n, got, want)
		}
	}
}
