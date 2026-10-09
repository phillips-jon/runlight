package dbtest

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	runlight "runlight.sh/go"
)

func TestNetHTTP(t *testing.T) {
	store := Store(t, Kinds()[0])
	rl, err := runlight.New(runlight.Options{Store: store, Site: &runlight.SiteOptions{Hostnames: []string{"example.com"}}, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatal(err)
	}
	token := "a-long-random-token-for-tests"
	routes, err := rl.Routes(runlight.RoutesOptions{Token: &token})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /go/{slug}", rl.LinksHTTP())
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "the app") }))
	server := httptest.NewServer(routes.Middleware(rl.Observer(mux)))
	defer server.Close()
	client := server.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	get := func(path string, headers ...string) (*http.Response, string) {
		t.Helper()
		req, _ := http.NewRequest("GET", server.URL+path, nil)
		for i := 0; i+1 < len(headers); i += 2 {
			req.Header.Set(headers[i], headers[i+1])
		}
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		return res, string(body)
	}

	if res, body := get("/runlight/s.js"); res.StatusCode != 200 || !strings.Contains(res.Header.Get("content-type"), "javascript") || len(body) == 0 {
		t.Errorf("tracker: %d %s", res.StatusCode, res.Header.Get("content-type"))
	}
	if res, body := get("/about"); res.StatusCode != 200 || body != "the app" {
		t.Errorf("the app's own page: %d %q", res.StatusCode, body)
	}
	if res, _ := get("/runlight/api/stats"); res.StatusCode != 401 {
		t.Errorf("stats without the token: %d", res.StatusCode)
	}
	if res, body := get("/runlight/api/sites", "authorization", "Bearer "+token); res.StatusCode != 200 || !strings.Contains(body, `"example.com"`) {
		t.Errorf("sites with the token: %d %s", res.StatusCode, body)
	}
	// Signing in with the token sets the cookie and sends the person on.
	if res, _ := get("/runlight/?token=" + token); res.StatusCode != 303 || len(res.Cookies()) == 0 {
		t.Errorf("sign in: %d %v", res.StatusCode, res.Header)
	}
	if res, body := get("/go/nothing"); res.StatusCode != 404 {
		t.Errorf("unknown link: %d %s", res.StatusCode, body)
	}

	// The collect endpoint takes 16 KB at most.
	res, err := client.Post(server.URL+"/runlight/e", "text/plain", strings.NewReader(strings.Repeat("x", 17*1024)))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 413 {
		t.Errorf("a large collect body: %d", res.StatusCode)
	}
	res, err = client.Post(server.URL+"/runlight/e", "text/plain", strings.NewReader(`{"t":"pageview","u":"https://example.com/","r":""}`))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 202 {
		t.Errorf("a pageview: %d", res.StatusCode)
	}
	rl.Idle()
}
