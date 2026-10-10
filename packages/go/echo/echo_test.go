package runlightecho_test

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"

	runlight "runlight.sh/go"
	runlightecho "runlight.sh/go/echo"
)

// empty is a database with nothing in it that takes every write, except for
// one link domain, go.example.com, with one link on it, /hello. That is all
// these requests need.
type empty struct{}

func (empty) Dialect() string { return "sqlite" }
func (empty) All(_ context.Context, sql string, params ...any) ([]runlight.Row, error) {
	if strings.Contains(sql, "FROM rl_link_domains") {
		return []runlight.Row{{"domain": "go.example.com", "site": "default"}}, nil
	}
	if strings.Contains(sql, "FROM rl_links WHERE slug") && len(params) > 0 && params[0] == "hello" {
		return []runlight.Row{{"id": "a1", "site": "default", "domain": "go.example.com", "slug": "hello", "url": "https://example.org/landing", "created_at": 0, "updated_at": 0}}, nil
	}
	return nil, nil
}
func (empty) Run(context.Context, string, ...any) error { return nil }

// get asks server for path on host ("" for the server's own), without following redirects.
func get(t *testing.T, server *httptest.Server, host, path string) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest("GET", server.URL+path, nil)
	if host != "" {
		req.Host = host
	}
	res, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res, string(body)
}

func TestRegister(t *testing.T) {
	rl, err := runlight.New(runlight.Options{Store: runlight.NewStore(empty{}), Site: &runlight.SiteOptions{Hostnames: []string{"example.com"}}, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatal(err)
	}
	token := "a-long-random-token-for-tests"
	routes, err := rl.Routes(runlight.RoutesOptions{Token: &token})
	if err != nil {
		t.Fatal(err)
	}
	r := echo.New()
	r.Use(runlightecho.Observer(rl))
	runlightecho.Register(r, rl, routes)
	r.GET("/:page", func(c *echo.Context) error { return c.String(200, "the app") })
	server := httptest.NewServer(r)
	defer server.Close()

	for _, c := range []struct {
		path, has string
		status    int
	}{
		{"/runlight/s.js", "", 200},
		{"/runlight", `data-base="/runlight"`, 200},
		{"/runlight/api/stats", "unauthorized", 401},
		{"/.well-known/oauth-protected-resource/runlight/mcp", `"resource":"` + server.URL + `/runlight/mcp"`, 200},
		{"/go/nothing", "", 404},
		{"/about", "the app", 200},
	} {
		res, body := get(t, server, "", c.path)
		if res.StatusCode != c.status || !strings.Contains(body, c.has) {
			t.Errorf("%s: %d %s", c.path, res.StatusCode, body)
		}
	}

	if res, _ := get(t, server, "go.example.com", "/hello"); res.StatusCode != 302 || res.Header.Get("location") != "https://example.org/landing" {
		t.Errorf("a link on its link domain: %d %s", res.StatusCode, res.Header.Get("location"))
	}
	if res, body := get(t, server, "go.example.com", "/about"); res.StatusCode != 404 || body == "the app" {
		t.Errorf("a link domain is not the app: %d %s", res.StatusCode, body)
	}
	if res, body := get(t, server, "example.com", "/hello"); res.StatusCode != 200 || body != "the app" {
		t.Errorf("the app's own host reaches the app: %d %s", res.StatusCode, body)
	}
}
