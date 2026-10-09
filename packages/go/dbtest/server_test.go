package dbtest

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"testing"
	"time"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/server"
)

// offline answers no outbound request, as a test server with no network would.
var offline = web.FetchFunc(func(context.Context, string, web.FetchInit) (*web.Response, error) {
	return nil, errors.New("offline")
})

type standalone struct {
	t      *testing.T
	server *server.Server
}

func makeServer(t *testing.T, token, address string) *standalone {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC).UnixMilli()
	s, err := server.New(server.Options{Store: Store(t, Kinds()[0]), Secret: strings.Repeat("s", 64), Token: token, URL: address, Now: func() int64 { return now }, Fetcher: offline})
	if err != nil {
		t.Fatal(err)
	}
	return &standalone{t, s}
}

// do sends a request to the server at host (stats.example.com when empty), with header pairs.
func (s *standalone) do(method, path, host, body string, headers ...string) *runlight.Response {
	s.t.Helper()
	if host == "" {
		host = "stats.example.com"
	}
	h := web.NewHeaders(headers...)
	h.Set("host", host)
	var b []byte
	if body != "" {
		b = []byte(body)
	}
	return s.server.Handle(context.Background(), web.NewRequest(method, "https://"+host+path, h, b))
}

func cookieOf(r *runlight.Response) string {
	return strings.Split(r.Header.Get("set-cookie"), ";")[0]
}

func form(fields ...string) string {
	v := url.Values{}
	for i := 0; i+1 < len(fields); i += 2 {
		v.Set(fields[i], fields[i+1])
	}
	return v.Encode()
}

const formType = "application/x-www-form-urlencoded"

func TestServerSetupLocksUntilTheCodeMakesTheFirstAccount(t *testing.T) {
	s := makeServer(t, "", "")
	if r := s.do("GET", "/", "", ""); r.Status != 403 || !strings.Contains(r.Text(), "setup link printed in the server") {
		t.Fatalf("the dashboard waits for setup: %d %s", r.Status, r.Text())
	}
	if r := s.do("GET", "/setup?code=wrong", "", ""); r.Status != 403 {
		t.Fatal(r.Status)
	}
	code := s.server.SetupCode
	if r := s.do("GET", "/setup?code="+code, "", ""); r.Status != 200 {
		t.Fatal(r.Status)
	}
	made := s.do("POST", "/setup", "", form("code", code, "email", "Jon@Example.com", "password", "a long password", "again", "a long password"), "content-type", formType)
	if made.Status != 303 || made.Header.Get("location") != "/" || !strings.Contains(made.Header.Get("set-cookie"), "HttpOnly; SameSite=Lax; Max-Age=2592000; Secure") {
		t.Fatalf("%d %v", made.Status, made.Header)
	}
	if r := s.do("GET", "/", "", "", "cookie", cookieOf(made)); r.Status != 200 {
		t.Fatalf("signed straight in: %d", r.Status)
	}
	if r := s.do("GET", "/setup?code="+code, "", ""); r.Header.Get("location") != "/login" {
		t.Fatal("setup stays open once an account exists")
	}
}

func TestServerSitesTrackingAndShortLinksOnTheirOwnDomains(t *testing.T) {
	s := makeServer(t, "script-token", "")
	ctx := context.Background()
	if _, err := s.server.Accounts.SetPassword(ctx, "jon@example.com", "a long password", time.Now().UnixMilli(), ""); err != nil {
		t.Fatal(err)
	}
	auth := []string{"authorization", "Bearer script-token", "content-type", "application/json"}
	if r := s.do("POST", "/api/sites", "", `{"name":"Blog","hostnames":"blog.example.com"}`, auth...); r.Status != 201 {
		t.Fatal(r.Status, r.Text())
	}
	if r := s.do("GET", "/s.js", "", ""); r.Status != 200 {
		t.Fatal(r.Status)
	}
	hit := s.do("POST", "/e", "", `{"k":"pageview","u":"https://blog.example.com/post","s":"blog.example.com"}`, "user-agent", "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for", "203.0.113.9")
	if hit.Status != 202 {
		t.Fatal(hit.Status)
	}
	stats, _ := s.do("GET", "/api/stats?site=blog.example.com&period=today", "", "", auth...).JSON()
	if js.Num(js.Dig(stats, "stats", "pageviews")) != 1 {
		t.Fatal(js.Stringify(stats))
	}
	if r := s.do("POST", "/api/link-domains?site=blog.example.com", "", `{"domain":"go.example.com"}`, auth...); r.Status != 201 {
		t.Fatal(r.Status, r.Text())
	}
	if r := s.do("POST", "/api/links?site=blog.example.com", "", `{"url":"https://blog.example.com/launch","slug":"launch","domain":"go.example.com"}`, auth...); r.Status != 201 {
		t.Fatal(r.Status, r.Text())
	}
	if r := s.do("GET", "/launch", "go.example.com", ""); r.Status != 302 || r.Header.Get("location") != "https://blog.example.com/launch" {
		t.Fatal(r.Status, r.Header)
	}
	if r := s.do("GET", "/go/launch", "", ""); r.Status != 302 {
		t.Fatal("every link also answers at /go/:slug on the server itself", r.Status)
	}
	if r := s.do("GET", "/healthz", "", ""); r.Status != 200 || r.Text() != "ok" {
		t.Fatal(r.Status)
	}
	if r := s.do("GET", "/api/sites", "", "", "authorization", "Bearer wrong"); r.Status != 401 {
		t.Fatal(r.Status)
	}
}

func TestServerALinkDomainNeverTakesOverTheDashboard(t *testing.T) {
	s := makeServer(t, "script-token", "")
	ctx := context.Background()
	if _, err := s.server.Accounts.SetPassword(ctx, "jon@example.com", "a long password", time.Now().UnixMilli(), ""); err != nil {
		t.Fatal(err)
	}
	auth := []string{"authorization", "Bearer script-token", "content-type", "application/json"}
	s.do("POST", "/api/sites", "", `{"name":"Blog","hostnames":"blog.example.com"}`, auth...)
	// Someone signs in at stats.example.com, so a caller naming another Host cannot add it afterwards.
	cookie := cookieOf(s.do("POST", "/login", "", form("email", "jon@example.com", "password", "a long password"), "content-type", formType))
	if r := s.do("GET", "/api/sites", "", "", "cookie", cookie); r.Status != 200 {
		t.Fatal(r.Status)
	}
	for _, host := range []string{"decoy.example.org", "203.0.113.5", "stats.example.com."} {
		if r := s.do("POST", "/api/link-domains?site=blog.example.com", host, `{"domain":"stats.example.com"}`, auth...); r.Status != 400 {
			t.Fatal(host, r.Status, r.Text())
		}
	}
	// Added anyway: its short links answer, and the server's own pages stay the server's.
	if err := s.server.Runlight.Store.AddLinkDomain(ctx, "stats.example.com", "blog.example.com", time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	s.server.Runlight.ForgetLinkDomains()
	s.do("POST", "/api/links?site=blog.example.com", "", `{"url":"https://blog.example.com/a","slug":"login","domain":"stats.example.com"}`, auth...)
	s.do("POST", "/api/links?site=blog.example.com", "", `{"url":"https://blog.example.com/b","slug":"sale","domain":"stats.example.com"}`, auth...)
	for _, c := range []struct {
		path, cookie string
		status       int
	}{{"/sale", "", 302}, {"/login", "", 200}, {"/", cookie, 200}, {"/", "", 404}} {
		if r := s.do("GET", c.path, "", "", "cookie", c.cookie); r.Status != c.status {
			t.Errorf("%s %q: %d", c.path, c.cookie, r.Status)
		}
	}
	if r := s.do("DELETE", "/api/link-domains/stats.example.com?site=blog.example.com", "", "", "cookie", cookie); r.Status != 200 {
		t.Fatal(r.Status, r.Text())
	}
	if r := s.do("GET", "/sale", "", ""); r.Status != 404 {
		t.Fatal(r.Status)
	}

	// With the public address set, short links never answer there, and nobody can add it under any Host.
	named := makeServer(t, "script-token", "https://stats.example.com")
	named.do("POST", "/api/sites", "", `{"name":"Blog","hostnames":"blog.example.com"}`, auth...)
	if r := named.do("POST", "/api/link-domains?site=blog.example.com", "decoy.example.org", `{"domain":"stats.example.com"}`, auth...); r.Status != 400 {
		t.Fatal(r.Status)
	}
	if err := named.server.Runlight.Store.AddLinkDomain(ctx, "stats.example.com", "blog.example.com", time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	named.server.Runlight.ForgetLinkDomains()
	named.do("POST", "/api/links?site=blog.example.com", "", `{"url":"https://blog.example.com/b","slug":"sale","domain":"stats.example.com"}`, auth...)
	if r := named.do("GET", "/sale", "", ""); r.Status != 404 {
		t.Fatal(r.Status)
	}
	if r := named.do("GET", "/", "", ""); r.Status != 403 {
		t.Fatal("the dashboard, waiting for setup", r.Status)
	}
}

func TestServerLearnsNamesOnlyFromOwners(t *testing.T) {
	s := makeServer(t, "", "")
	ctx := context.Background()
	owner, _ := s.server.Accounts.SetPassword(ctx, "jon@example.com", "a long password", time.Now().UnixMilli(), "")
	viewer, _ := s.server.Accounts.SetPassword(ctx, "viewer@example.com", "another long one", time.Now().UnixMilli(), "viewer")
	as := func(u runlight.User) string {
		session, err := s.server.Accounts.SessionFor(u, time.Now().UnixMilli())
		if err != nil {
			t.Fatal(err)
		}
		return "runlight_session=" + url.QueryEscape(session)
	}
	names := func() string {
		v, _, _ := s.server.Runlight.Store.Setting(ctx, "server-hosts")
		return v
	}
	for i := 0; i < 25; i++ {
		s.do("GET", "/api/sites", "", "", "cookie", as(viewer), "x-forwarded-host", "junk"+js.FormatNumber(float64(i))+".example.org")
	}
	if n := names(); n != "" && n != "[]" {
		t.Fatal(n)
	}
	s.do("GET", "/api/sites", "", "", "cookie", as(owner), "x-forwarded-host", "203.0.113.7:8080")
	s.do("GET", "/api/sites", "", "", "cookie", as(owner))
	if n := names(); n != `["stats.example.com"]` {
		t.Fatal(n)
	}
}
