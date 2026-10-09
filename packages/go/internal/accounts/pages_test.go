package accounts

import (
	"strings"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
)

// The account pages against tests/fixtures/pages.json, the TypeScript's HTML for the same inputs.

func TestStylesAndScriptMatch(t *testing.T) {
	f := fixture.PHP(t, "pages.json")
	if AuthCSS != js.Str(js.Dig(f, "css")) {
		t.Error("AuthCSS differs from the TypeScript's")
	}
	if AuthJS != js.Str(js.Dig(f, "js")) {
		t.Error("AuthJS differs from the TypeScript's")
	}
}

func TestPagesMatch(t *testing.T) {
	f := fixture.PHP(t, "pages.json")
	pages := js.Arr(js.Dig(f, "pages"))
	if len(pages) == 0 {
		t.Fatal("no pages")
	}
	for _, c := range pages {
		base, fn := js.Str(js.Dig(c, "base")), js.Str(js.Dig(c, "fn"))
		opts := js.Obj(js.Dig(c, "opts"))
		get := func(key string) string { return js.Str(opts.Value(key)) }
		var html string
		switch fn {
		case "loginPage":
			o := LoginOptions{Error: get("error"), Email: get("email"), Forgot: get("forgot")}
			if opts.Has("next") {
				next := get("next")
				o.Next = &next
			}
			html = LoginPage(base, o)
		case "codePage":
			html = CodePage(base, CodeOptions{Pending: get("pending"), Next: get("next"), Error: get("error")})
		case "invitePage":
			html = InvitePage(base, InviteOptions{Code: get("code"), Email: get("email"), Role: get("role"), Host: get("host"), Error: get("error")})
		case "inviteGonePage":
			html = InviteGonePage(base)
		case "setupPage":
			html = SetupPage(base, SetupOptions{Code: get("code"), Error: get("error"), Email: get("email"), AskCode: js.Truthy(opts.Value("askCode"))})
		case "setupLockedPage":
			html = SetupLockedPage(base)
		case "setupNeedsTokenPage":
			html = SetupNeedsTokenPage(base)
		default:
			t.Fatalf("unknown page %s", fn)
		}
		if want := js.Str(js.Dig(c, "html")); html != want {
			t.Errorf("%s at %q differs:\n%s\nwant:\n%s", fn, base, html, want)
		}
	}
	for _, c := range js.Arr(js.Dig(f, "roles")) {
		if got := RoleText(js.Str(js.Dig(c, "role"))); got != js.Str(js.Dig(c, "text")) {
			t.Errorf("role %q: %s", js.Str(js.Dig(c, "role")), got)
		}
	}
}

func TestSetupAsksForTheTokenWhenTold(t *testing.T) {
	page := SetupPage("/runlight", SetupOptions{AskCode: true})
	for _, want := range []string{"RUNLIGHT_TOKEN", `action="/runlight/setup"`, `href="/runlight/auth.css"`} {
		if !strings.Contains(page, want) {
			t.Errorf("setup page lacks %s", want)
		}
	}
	if !strings.Contains(InvitePage("", InviteOptions{Code: "c", Email: "a@b.c", Role: "member", Host: "x"}), "as a member") {
		t.Error("invite page lacks the role")
	}
}
