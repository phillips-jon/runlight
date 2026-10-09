package importers

import (
	"context"
	"errors"
	"math"
	"regexp"
	"slices"
	"sync"
	"testing"
	"time"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// fakeFetcher answers from a scenario's routes, each used up after its
// "times", and records every request as the fixture writes one.
type fakeFetcher struct {
	mu       sync.Mutex
	routes   []any
	left     []int
	patterns []*regexp.Regexp
	requests []string
}

func newFakeFetcher(t *testing.T, routes []any) *fakeFetcher {
	f := &fakeFetcher{routes: routes}
	for _, r := range routes {
		times := math.MaxInt
		if n, ok := js.Dig(r, "times").(float64); ok {
			times = int(n)
		}
		f.left = append(f.left, times)
		re, err := regexp.Compile(js.Str(js.Dig(r, "pattern")))
		if err != nil {
			t.Fatalf("route pattern: %v", err)
		}
		f.patterns = append(f.patterns, re)
	}
	return f
}

func (f *fakeFetcher) Fetch(_ context.Context, url string, init web.FetchInit) (*web.Response, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	headers := js.NewObject()
	init.Headers.Each(func(name, value string) { headers.Set(name, value) })
	f.requests = append(f.requests, js.Stringify(js.NewObject("method", init.Method, "url", url, "headers", headers, "body", string(init.Body))))
	for i, r := range f.routes {
		if f.left[i] <= 0 || !f.patterns[i].MatchString(url) {
			continue
		}
		f.left[i]--
		if js.Truthy(js.Dig(r, "unreachable")) {
			return nil, &web.FetchError{Message: "fetch failed"}
		}
		status := 200
		if n, ok := js.Dig(r, "status").(float64); ok {
			status = int(n)
		}
		pairs := []string{"content-type", "application/json"}
		js.Obj(js.Dig(r, "headers")).Each(func(k string, v any) { pairs = append(pairs, k, js.Str(v)) })
		body, _ := js.Obj(r).Get("body")
		return web.NewResponse(status, []byte(js.Stringify(body)), pairs...), nil
	}
	return web.NewResponse(404, []byte("{}")), nil
}

func errorValue(err error) any {
	var h *HTTPError
	var ie *ImportError
	switch {
	case errors.As(err, &h):
		return js.NewObject("message", h.Message, "code", h.Code, "params", h.Params, "status", h.Status, "name", "HttpError")
	case errors.As(err, &ie):
		return js.NewObject("message", ie.Message, "code", ie.Code, "params", ie.Params, "name", "ImportError")
	}
	return err.Error()
}

// The importer scenarios in packages/php/tests/fixtures/outbound.json, written
// from the TypeScript SDK: each importer, run step by step against the same
// answers, must send the exact requests, wait as long between retries, ask
// about the same known links, and hand back the same steps, cursors included.
func TestScenariosMatchTypeScript(t *testing.T) {
	outbound := fixture.PHP(t, "outbound.json")
	now := int64(js.Num(js.Dig(outbound, "now")))
	scenarios := js.Arr(js.Dig(outbound, "importers"))
	if len(scenarios) == 0 {
		t.Fatal("no scenarios")
	}
	for _, scenario := range scenarios {
		name := js.Str(js.Dig(scenario, "name"))
		t.Run(name, func(t *testing.T) {
			fetcher := newFakeFetcher(t, js.Arr(js.Dig(scenario, "routes")))
			var waitsMu sync.Mutex
			waits := []any{}
			client := &Client{Fetcher: fetcher, Sleep: func(_ context.Context, ms float64) error {
				waitsMu.Lock()
				defer waitsMu.Unlock()
				waits = append(waits, ms)
				return nil
			}}
			importer := Importers[js.Str(js.Dig(scenario, "source"))]
			if importer == nil {
				t.Fatalf("no importer for %v", js.Dig(scenario, "source"))
			}
			known := js.Arr(js.Dig(scenario, "known"))
			knownCalls := []any{}
			credentials := Credentials{}
			js.Obj(js.Dig(scenario, "credentials")).Each(func(k string, v any) { credentials[k] = js.Str(v) })
			isKnown := func(_ context.Context, sourceID, slug, url string) (bool, error) {
				knownCalls = append(knownCalls, []any{sourceID, slug, url})
				return slices.Contains(known, any(sourceID)) || slices.Contains(known, any(slug+" "+url)), nil
			}

			steps := js.Arr(js.Dig(scenario, "steps"))
			var cursor *string
			if c, ok := js.Dig(steps, 0, "cursor").(string); ok {
				cursor = &c
			}
			for i, want := range steps {
				wantCursor := js.Stringify(js.Dig(want, "cursor"))
				if got := js.Stringify(cursor); got != wantCursor {
					t.Fatalf("step %d starts from %s, want %s", i, got, wantCursor)
				}
				result, err := importer.Step(context.Background(), client, StepInput{Credentials: credentials, Cursor: cursor, Known: isKnown, Now: now})
				wantError, failing := js.Obj(want).Get("error")
				if err != nil {
					if !failing {
						t.Fatalf("step %d should not fail: %v", i, err)
					}
					if got, want := js.Stringify(errorValue(err)), js.Stringify(wantError); got != want {
						t.Fatalf("step %d error\n got %s\nwant %s", i, got, want)
					}
					continue
				}
				if failing {
					t.Fatalf("step %d should fail with %s", i, js.Stringify(wantError))
				}
				if got, want := js.Stringify(result), js.Stringify(js.Dig(want, "result")); got != want {
					t.Fatalf("step %d\n got %s\nwant %s", i, got, want)
				}
				cursor = result.Cursor
			}

			sent := slices.Clone(fetcher.requests)
			var requests []string
			for _, r := range js.Arr(js.Dig(scenario, "requests")) {
				requests = append(requests, js.Stringify(r))
			}
			if js.Dig(scenario, "ordered") != true {
				// Umami asks for a link's events and sessions at once, so they come in either order.
				slices.Sort(sent)
				slices.Sort(requests)
			}
			if got, want := js.Stringify(sent), js.Stringify(requests); got != want {
				t.Errorf("requests\n got %s\nwant %s", got, want)
			}
			if got, want := js.Stringify(waits), js.Stringify(js.Dig(scenario, "waits")); got != want {
				t.Errorf("waits %s, want %s", got, want)
			}
			if got, want := js.Stringify(knownCalls), js.Stringify(js.Dig(scenario, "knownCalls")); got != want {
				t.Errorf("known calls\n got %s\nwant %s", got, want)
			}
		})
	}
}

func TestDatesParseAsJavaScriptParsesThem(t *testing.T) {
	local := time.Local
	time.Local = time.UTC
	defer func() { time.Local = local }()
	cases := map[string]float64{
		"2026-01-01T00:00:00Z":          1767225600000,
		"2026-01-01T00:00:00+0000":      1767225600000,
		"2026-01-01":                    1767225600000,
		"2026-01-01T02:00:00.5+02:00":   1767225600500,
		"2026-01-01T00:00:00":           1767225600000,
		"2026-01-01 00:00:00":           1767225600000,
		"Thu, 01 Jan 2026 00:00:00 GMT": 1767225600000,
		"1970-01-01T00:00:00.000Z":      0,
		"2026-03-04":                    1772582400000,
		" 2026-01-01T00:00:00.123456Z ": 1767225600123,
		"2026-01-01T24:00:00Z":          1767312000000,
	}
	for text, want := range cases {
		if got := ParseDate(text); got != want {
			t.Errorf("ParseDate(%q) = %v, want %v", text, got, want)
		}
	}
	for _, v := range []any{"nope", "2026-02-30", "2026-13-01", "2026-01-01T24:00:01Z", "", nil, js.Undefined{}, 5.0} {
		if got := ParseDate(v); !math.IsNaN(got) {
			t.Errorf("ParseDate(%#v) = %v, want NaN", v, got)
		}
	}
	if got, _ := isoString(1772409600000); got != "2026-03-02T00:00:00.000Z" {
		t.Errorf("isoString = %s", got)
	}
	if got, _ := isoString(-1); got != "1969-12-31T23:59:59.999Z" {
		t.Errorf("isoString(-1) = %s", got)
	}
	for _, ms := range []float64{math.NaN(), math.Inf(1), 8.64e15 + 1} {
		if _, err := isoString(ms); err == nil || err.Error() != "Invalid time value" {
			t.Errorf("isoString(%v) = %v, want Invalid time value", ms, err)
		}
	}
}

func TestEncodeURIComponent(t *testing.T) {
	if got := encodeURIComponent("a b/c!'()*~é&"); got != "a%20b%2Fc!'()*~%C3%A9%26" {
		t.Errorf("encodeURIComponent = %s", got)
	}
}

func TestHTTPErrorIsAnImportError(t *testing.T) {
	var err error = &HTTPError{NewImportError("x answered 500", "import_status", "host", "x", "status", "500"), 500}
	var ie *ImportError
	if !errors.As(err, &ie) || ie.Code != "import_status" || js.Stringify(ie.Params) != `{"host":"x","status":"500"}` {
		t.Fatalf("errors.As = %v", ie)
	}
	if err.Error() != "x answered 500" {
		t.Errorf("Error() = %s", err.Error())
	}
	if js.Stringify(NewImportError("a", "b").Params) != "{}" {
		t.Error("params without values are an empty object")
	}
}

func TestPauseStopsWithTheContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	if err := (&Client{}).Pause(ctx, 60_000); !errors.Is(err, context.Canceled) {
		t.Fatalf("Pause = %v", err)
	}
	if time.Since(start) > time.Second {
		t.Error("Pause waited")
	}
}

func TestCanceledRequestsAreNotRetried(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	client := &Client{Fetcher: web.FetchFunc(func(context.Context, string, web.FetchInit) (*web.Response, error) {
		calls++
		cancel()
		return nil, &web.FetchError{Message: "fetch failed"}
	})}
	if _, err := client.GetJSON(ctx, "https://api.dub.co/links", RequestInit{}); !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("GetJSON = %v after %d calls", err, calls)
	}
}

func TestUnreachableNamesTheHostWithItsPort(t *testing.T) {
	client := &Client{Fetcher: web.FetchFunc(func(context.Context, string, web.FetchInit) (*web.Response, error) {
		return nil, &web.FetchError{Message: "fetch failed"}
	})}
	_, err := client.GetJSON(context.Background(), "https://stats.example.com:8443/api/links", RequestInit{})
	if got := js.Stringify(errorValue(err)); got != `{"message":"Could not reach stats.example.com:8443","code":"unreachable","params":{"host":"stats.example.com:8443"},"name":"ImportError"}` {
		t.Fatalf("error = %s", got)
	}
}

func TestEveryImporterIsRegistered(t *testing.T) {
	for _, name := range Sources {
		if Importers[name] == nil {
			t.Errorf("%s is not registered", name)
		}
	}
	if len(Importers) != len(Sources) {
		t.Errorf("%d importers, %d sources", len(Importers), len(Sources))
	}
}
