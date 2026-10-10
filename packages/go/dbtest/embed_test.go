package dbtest

import (
	"context"
	"regexp"
	"strings"
	"testing"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

func TestTheDashboardInsideACmsOpensOneFramedPageOnceWhoseSessionReadsOneSite(t *testing.T) {
	ctx := context.Background()
	rl, err := runlight.New(runlight.Options{Store: Store(t, Kinds()[0]), Logf: func(string, ...any) {}, Sites: []runlight.SiteOptions{
		{ID: "a", Name: "Site A", Hostnames: []string{"a.com"}, Timezone: "UTC"},
		{ID: "b", Name: "Site B", Hostnames: []string{"b.com"}, Timezone: "UTC"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	secret := "secret"
	routes, err := rl.Routes(runlight.RoutesOptions{Token: &secret})
	if err != nil {
		t.Fatal(err)
	}
	do := func(method, path, body string, headers ...string) *runlight.Response {
		t.Helper()
		var b []byte
		if body != "" {
			b = []byte(body)
			headers = append(headers, "content-type", "application/json")
		}
		return routes.Handle(ctx, web.NewRequest(method, "https://stats.example.com"+path, web.NewHeaders(headers...), b))
	}
	bodyOf := func(r *runlight.Response) *js.Object {
		t.Helper()
		v, err := js.Parse(string(r.Body))
		if err != nil {
			t.Fatalf("%d %s", r.Status, r.Body)
		}
		return v.(*js.Object)
	}
	owner := []string{"authorization", "Bearer secret"}

	made := do("POST", "/runlight/api/tokens", `{"name":"CMS","site":"a","scope":"embed"}`, owner...)
	if made.Status != 201 {
		t.Fatalf("an embed token: %d %s", made.Status, made.Body)
	}
	key := js.Str(bodyOf(made).Value("secret"))
	tokenID := js.Str(js.Dig(bodyOf(made), "token", "id"))
	if r := do("POST", "/runlight/api/tokens", `{"name":"CMS","scope":"embed"}`, owner...); r.Status != 400 || js.Str(bodyOf(r).Value("code")) != "embed_site" {
		t.Errorf("an embed token for no site: %d %s", r.Status, r.Body)
	}
	mint := func(origin string) *runlight.Response {
		return do("POST", "/runlight/api/embed", `{"origin":`+js.Stringify(origin)+`}`, "authorization", "Bearer "+key)
	}
	if r := mint("https://b.com"); r.Status != 400 {
		t.Errorf("only an origin on the site's own domains: %d %s", r.Status, r.Body)
	}
	if r := do("GET", "/runlight/api/stats?site=a", "", "authorization", "Bearer "+key); r.Status != 403 {
		t.Errorf("an embed token reads nothing itself: %d %s", r.Status, r.Body)
	}
	minted := mint("https://www.a.com")
	if minted.Status != 201 {
		t.Fatalf("a ticket: %d %s", minted.Status, minted.Body)
	}
	answer := bodyOf(minted)
	ticket, path := js.Str(answer.Value("ticket")), js.Str(answer.Value("path"))
	if js.Str(answer.Value("site")) != "a" || path != "/runlight/embed?ticket="+ticket {
		t.Errorf("the ticket's answer: %s", minted.Body)
	}
	if strings.Contains(ticket, tokenID) {
		t.Error("a ticket never names its token")
	}

	page := do("GET", path, "")
	if page.Status != 200 {
		t.Fatalf("the embedded page: %d %s", page.Status, page.Body)
	}
	if csp := page.Header.Get("content-security-policy"); !strings.HasSuffix(csp, "frame-ancestors https://www.a.com") {
		t.Errorf("framing: %s", csp)
	}
	if page.Header.Get("x-frame-options") != "" || page.Header.Get("referrer-policy") != "no-referrer" {
		t.Errorf("headers: %v", page.Header)
	}
	found := regexp.MustCompile(`data-embed="([^"]+)"`).FindStringSubmatch(string(page.Body))
	if found == nil || !regexp.MustCompile(`^\d+\.[a-f0-9]{24}\.[a-f0-9]{64}$`).MatchString(found[1]) {
		t.Fatalf("the session: %v", found)
	}
	session := found[1]
	again := do("GET", path, "")
	if again.Status != 410 {
		t.Errorf("a ticket works once: %d", again.Status)
	}
	if csp := again.Header.Get("content-security-policy"); !strings.HasSuffix(csp, "frame-ancestors https://www.a.com") {
		t.Errorf("a used ticket still says so inside its frame: %s", csp)
	}

	stats := do("GET", "/runlight/api/stats?site=b", "", "x-runlight-embed", session)
	if stats.Status != 200 || js.Str(bodyOf(stats).Value("site")) != "a" {
		t.Errorf("pinned to its token's site whatever is asked: %d %s", stats.Status, stats.Body)
	}
	if r := do("GET", "/runlight/api/links?site=a", "", "x-runlight-embed", session, "authorization", "Bearer secret"); r.Status != 403 {
		t.Errorf("nothing a share cannot read, even beside the owner's token: %d", r.Status)
	}
	if r := do("GET", "/runlight/", ""); r.Header.Get("x-frame-options") != "DENY" {
		t.Error("every other page still refuses to be framed")
	}

	if r := do("DELETE", "/runlight/api/tokens/"+tokenID, "", owner...); r.Status != 200 {
		t.Fatalf("deleting the token: %d %s", r.Status, r.Body)
	}
	if r := do("GET", "/runlight/api/stats", "", "x-runlight-embed", session); r.Status != 401 {
		t.Errorf("deleting the token ends its sessions at once: %d", r.Status)
	}
}

func TestASettingCanBeTakenOnce(t *testing.T) {
	ctx := context.Background()
	for _, kind := range Kinds() {
		t.Run(kind.Name, func(t *testing.T) {
			store := Store(t, kind)
			one := "1"
			if err := store.SetSetting(ctx, "x", &one); err != nil {
				t.Fatal(err)
			}
			if v, has, err := store.TakeSetting(ctx, "x"); err != nil || !has || v != "1" {
				t.Fatalf("first take: %q %v %v", v, has, err)
			}
			if _, has, err := store.TakeSetting(ctx, "x"); err != nil || has {
				t.Fatalf("second take: %v %v", has, err)
			}
			if _, has, _ := store.Setting(ctx, "x"); has {
				t.Error("the setting is gone")
			}
		})
	}
}
