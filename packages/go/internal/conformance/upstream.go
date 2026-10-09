package conformance

import (
	"context"
	"strings"
	"sync"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// fetched is one request the implementation made, as the file records it.
type fetched struct {
	seen *js.Object
	text string
}

// upstream plays the servers a scenario stands in for, as the fake fetch in
// http-conformance.ts plays them: a request goes to the first upstream whose
// url its URL starts with (and whose method matches, when one is given); a
// request none matches fails as a network error does. Every request is
// recorded, matched or not.
type upstream struct {
	mu      sync.Mutex
	servers []any
	fetched []fetched
}

func newUpstream(servers []any) *upstream { return &upstream{servers: servers} }

// Fetch answers a request as the scenario's servers do.
func (u *upstream) Fetch(_ context.Context, url string, init web.FetchInit) (*web.Response, error) {
	method := strings.ToUpper(init.Method)
	if method == "" {
		method = "GET"
	}
	seen := js.NewObject("method", method, "url", url)
	given := &js.Object{}
	init.Headers.Each(func(name, value string) { given.Set(name, value) })
	if given.Len() > 0 {
		seen.Set("headers", given)
	}
	text := string(init.Body)
	if text != "" {
		seen.Set("body", sentBody(text, init.Headers.Get("content-type")))
	}
	u.mu.Lock()
	u.fetched = append(u.fetched, fetched{seen: seen, text: text})
	u.mu.Unlock()
	var match *js.Object
	for _, s := range u.servers {
		server := js.Obj(s)
		m, _ := server.Value("method").(string)
		if strings.HasPrefix(url, js.Str(server.Value("url"))) && (m == "" || m == method) {
			match = server
			break
		}
	}
	if match == nil {
		return nil, &web.FetchError{Message: "fetch failed"}
	}
	headers := web.NewHeaders()
	var body []byte
	if match.Has("body") {
		switch v := match.Value("body").(type) {
		case string:
			body = []byte(v)
		case float64, bool:
			body = []byte(js.Stringify(v))
		default:
			// typeof null is "object" too, so a null body is sent as JSON.
			body = []byte(js.Stringify(v))
			headers.Set("content-type", "application/json")
		}
	}
	js.Obj(match.Value("headers")).Each(func(name string, value any) { headers.Set(name, js.String(value)) })
	// The cap a real Fetcher keeps, so code that reads only the start of a page sees what it would.
	if init.MaxBytes > 0 && int64(len(body)) > init.MaxBytes {
		if !init.Truncate {
			return nil, web.BodyTooLong(init.MaxBytes)
		}
		body = body[:init.MaxBytes]
	}
	status := 200
	if v, ok := match.Value("status").(float64); ok {
		status = int(v)
	}
	return &web.Response{Status: status, Header: headers, Body: body, URL: url}, nil
}

// take is the requests made since the last take, and forgets them.
func (u *upstream) take() []fetched {
	u.mu.Lock()
	defer u.mu.Unlock()
	out := u.fetched
	u.fetched = nil
	return out
}

// sentBody is a body another server was sent, as JSON or form fields when it is one of those, else its text.
func sentBody(text, contentType string) any {
	if strings.HasPrefix(contentType, "application/x-www-form-urlencoded") {
		fields := &js.Object{}
		for _, pair := range whatwg.ParseQuery(text).Pairs() {
			fields.Set(pair[0], pair[1])
		}
		return fields
	}
	if v, err := js.Parse(text); err == nil {
		return v
	}
	return text
}
