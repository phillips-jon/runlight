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

// empty is a database with nothing in it that takes every write, which is
// all these requests need.
type empty struct{}

func (empty) Dialect() string { return "sqlite" }
func (empty) All(context.Context, string, ...any) ([]runlight.Row, error) {
	return nil, nil
}
func (empty) Run(context.Context, string, ...any) error { return nil }

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
	r.GET("/about", func(c *echo.Context) error { return c.String(200, "the app") })
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
		res, err := http.Get(server.URL + c.path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != c.status || !strings.Contains(string(body), c.has) {
			t.Errorf("%s: %d %s", c.path, res.StatusCode, body)
		}
	}
}
