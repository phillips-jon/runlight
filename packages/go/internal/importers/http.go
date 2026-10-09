package importers

import (
	"context"
	"errors"
	"math"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// HTTPError is a service answering with a status that is not success.
type HTTPError struct {
	*ImportError
	Status int
}

// Unwrap is the ImportError, so errors.As finds one in an HTTPError.
func (e *HTTPError) Unwrap() error { return e.ImportError }

// Client is JSON over HTTPS with a timeout and a few retries on rate limits
// and server errors. Every importer request goes through one, so tests can
// pass a fake Fetcher and a Sleep that does not wait.
type Client struct {
	// Fetcher makes the requests; nil is web.HTTPFetcher{}.
	Fetcher web.Fetcher
	// Sleep waits this many milliseconds; nil waits for real, or until ctx ends.
	Sleep func(ctx context.Context, ms float64) error
}

// RequestInit is what a request sends beyond its URL: Method is GET when
// empty, Body is nil for none.
type RequestInit struct {
	Method  string
	Headers *web.Headers
	Body    []byte
}

// Pause waits ms milliseconds.
func (c *Client) Pause(ctx context.Context, ms float64) error {
	if c != nil && c.Sleep != nil {
		return c.Sleep(ctx, ms)
	}
	if ms <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(time.Duration(ms * float64(time.Millisecond)))
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *Client) fetcher() web.Fetcher {
	if c != nil && c.Fetcher != nil {
		return c.Fetcher
	}
	return web.HTTPFetcher{}
}

// GetJSON fetches url and parses its JSON answer as JSON.parse does. A
// request that gets no answer is tried three times, then fails as
// "unreachable"; a 429 or 5xx is tried four times, waiting as Retry-After
// says (800 ms more each time when it says nothing usable, 10 seconds at
// most). A 401 fails as "import_refused" and any other failure as
// "import_status", both HTTPErrors.
func (c *Client) GetJSON(ctx context.Context, url string, init RequestInit) (any, error) {
	for attempt := 1; ; attempt++ {
		headers := web.NewHeaders("accept", "application/json")
		init.Headers.Each(func(name, value string) { headers.Set(name, value) })
		method := init.Method
		if method == "" {
			method = "GET"
		}
		response, err := c.fetcher().Fetch(ctx, url, web.FetchInit{Method: method, Headers: headers, Body: init.Body, Timeout: 20 * time.Second})
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			if attempt < 3 {
				continue
			}
			host, err := hostOf(url)
			if err != nil {
				return nil, err
			}
			return nil, NewImportError("Could not reach "+host, "unreachable", "host", host)
		}
		if response.OK() {
			return response.JSON()
		}
		if response.Status == 401 {
			return nil, &HTTPError{NewImportError("The key or sign-in was refused", "import_refused"), 401}
		}
		if (response.Status == 429 || response.Status >= 500) && attempt < 4 {
			wait := 0.0
			if text, ok := response.Header.Lookup("retry-after"); ok {
				wait = js.Number(text) * 1000
			}
			if wait == 0 || math.IsNaN(wait) {
				wait = float64(800 * attempt)
			}
			if err := c.Pause(ctx, math.Min(wait, 10_000)); err != nil {
				return nil, err
			}
			continue
		}
		host, err := hostOf(url)
		if err != nil {
			return nil, err
		}
		status := js.FormatNumber(float64(response.Status))
		return nil, &HTTPError{NewImportError(host+" answered "+status, "import_status", "host", host, "status", status), response.Status}
	}
}

// hostOf is new URL(url).host, failing with new URL's TypeError.
func hostOf(url string) (string, error) {
	u, err := whatwg.Parse(url)
	if err != nil {
		return "", errors.New("Invalid URL")
	}
	return u.Host(), nil
}

// field is object?.[key]: js.Undefined when v is not an object or has no such key.
func field(v any, key string) any {
	if o, ok := v.(*js.Object); ok {
		if x, ok := o.Get(key); ok {
			return x
		}
	}
	return js.Undefined{}
}

// at is array?.[i] for an index given as any JSON value, as JavaScript reads one.
func at(v any, i any) any {
	a, ok := v.([]any)
	if !ok {
		return js.Undefined{}
	}
	n, ok := js.ArrayIndex(js.String(i))
	if !ok || int(n) >= len(a) {
		return js.Undefined{}
	}
	return a[n]
}

// nullish is whether v is null or undefined.
func nullish(v any) bool {
	if v == nil {
		return true
	}
	_, u := v.(js.Undefined)
	return u
}

// coalesce is v ?? fallback.
func coalesce(v, fallback any) any {
	if nullish(v) {
		return fallback
	}
	return v
}

// or is v || fallback.
func or(v, fallback any) any {
	if js.Truthy(v) {
		return v
	}
	return fallback
}

// text is a value as a ForeignLink keeps it: text as it is, null or
// undefined as "", anything else as String() writes it.
func text(v any) string {
	if nullish(v) {
		return ""
	}
	return js.String(v)
}

// list is a value that must be an array, as a for...of or .map over it needs.
func list(v any, what string) ([]any, error) {
	if a, ok := v.([]any); ok {
		return a, nil
	}
	return nil, errors.New(what + " is not iterable")
}

// positive is value > 0 as JavaScript compares it.
func positive(v any) bool {
	return js.ToNumber(v) > 0
}

// trimmed is credentials[key]?.trim().
func trimmed(credentials Credentials, key string) string {
	return js.Trim(credentials[key])
}

// encodeURIComponent is encodeURIComponent(text).
func encodeURIComponent(text string) string {
	text = js.WellFormed(text)
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.IndexByte("-_.!~*'()", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte("0123456789ABCDEF"[c>>4])
		b.WriteByte("0123456789ABCDEF"[c&15])
	}
	return b.String()
}

// createdAt is Date.parse(value) || now.
func createdAt(value any, now int64) int64 {
	ms := ParseDate(value)
	if ms == 0 || math.IsNaN(ms) {
		return now
	}
	return int64(ms)
}
