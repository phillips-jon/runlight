package runlight

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"regexp"
	"strings"
	"sync"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// OAuth for the MCP server, so apps that connect only through OAuth (the
// Claude and ChatGPT web connectors) can reach it. Runlight is both the
// resource and the authorization server. The token is an ordinary API token,
// so it appears in Settings, API and AI, beside the others, and deleting it
// there disconnects the app. It reads stats, or with the "manage" scope
// (asked for by a Runlight hub) it also changes one site's settings.

const (
	codeMs = 5 * 60_000
	// unusedClientMs: an app stored before client ids were signed, which never finished connecting within a day, is removed.
	unusedClientMs = 86_400_000
	// registrationsPerMinute is the registrations one address may make a minute.
	registrationsPerMinute = 10
	// maxClientID is the longest client id, which carries the app's name and redirect addresses.
	maxClientID = 2048
)

type oauthHost struct {
	r         *Runlight
	base      string
	isOwner   func(ctx context.Context, request *Request) bool
	isReader  func(ctx context.Context, request *Request) bool
	signIn    string
	accountOf func(ctx context.Context, request *Request) string
	tokenMade func(ctx context.Context, token TokenRow, by string) bool

	limitOnce sync.Once
	limit     *rateLimit
}

type oauthClient struct {
	name      string
	redirects []string
	createdAt float64
	usedAt    *float64
	raw       *js.Object
}

func base64urlText(text string) string { return base64.RawURLEncoding.EncodeToString([]byte(text)) }

func fromBase64urlText(text string) string {
	decoded, err := atob(strings.NewReplacer("-", "+", "_", "/").Replace(text))
	if err != nil {
		return ""
	}
	b := make([]byte, 0, len(decoded))
	for _, r := range decoded {
		b = append(b, byte(r))
	}
	return web.DecodeUTF8(b)
}

// clientKey is the key client ids are signed with, made on first use and kept in the database for every process.
func (o *oauthHost) clientKey(ctx context.Context) (string, error) {
	saved, ok, err := o.r.Store.Setting(ctx, "oauth-key")
	if err != nil || (ok && saved != "") {
		return saved, err
	}
	made := randomID(32)
	return made, o.r.Store.SetSetting(ctx, "oauth-key", &made)
}

var (
	storedClientID = regexp.MustCompile(`^[a-f0-9]{32}$`)
	signedClientID = regexp.MustCompile(`^([A-Za-z0-9_-]+)\.([a-f0-9]{64})$`)
)

// clientFor is the app a client id names, and where to note that it
// connected. A new id carries the app's name and addresses, signed, so
// registering stores nothing. Ids from before that were stored.
func (o *oauthHost) clientFor(ctx context.Context, id string) (*oauthClient, string, error) {
	if storedClientID.MatchString(id) {
		stored, ok, err := o.r.Store.Setting(ctx, "oauth-client:"+id)
		if err != nil || !ok || stored == "" {
			return nil, "", err
		}
		parsed, err := js.Parse(stored)
		if err != nil {
			return nil, "", err
		}
		return clientOf(js.Obj(parsed)), "oauth-client:" + id, nil
	}
	parts := signedClientID.FindStringSubmatch(id)
	if parts == nil || len(parts[1]) > 2000 || len(id) > maxClientID {
		return nil, "", nil
	}
	key, err := o.clientKey(ctx)
	if err != nil {
		return nil, "", err
	}
	if !constantTimeEqual(parts[2], hmacHex(key, parts[1])) {
		return nil, "", nil
	}
	meta, err := js.Parse(fromBase64urlText(parts[1]))
	if err != nil {
		return nil, "", err
	}
	usedKey := "oauth-used:" + sha256Hex(id)
	used, has, err := o.r.Store.Setting(ctx, usedKey)
	if err != nil {
		return nil, "", err
	}
	client := &oauthClient{name: js.String(js.Dig(meta, "n")), createdAt: js.Num(js.Dig(meta, "t"))}
	for _, r := range js.Arr(js.Dig(meta, "r")) {
		client.redirects = append(client.redirects, js.String(r))
	}
	if has && used != "" {
		client.usedAt = ptr(js.Number(used))
	}
	return client, usedKey, nil
}

func clientOf(o *js.Object) *oauthClient {
	c := &oauthClient{name: js.String(o.Value("name")), createdAt: js.Num(o.Value("createdAt")), raw: o}
	for _, r := range js.Arr(o.Value("redirects")) {
		c.redirects = append(c.redirects, js.String(r))
	}
	if v, ok := o.Value("usedAt").(float64); ok {
		c.usedAt = &v
	}
	return c
}

var oauthCORS = []string{"access-control-allow-origin", "*", "access-control-allow-headers", "authorization, content-type, mcp-protocol-version", "access-control-allow-methods", "GET, POST, OPTIONS"}

func oauthJSON(body any, status int) *Response {
	headers := append([]string{"content-type", "application/json; charset=utf-8", "cache-control", "no-store"}, oauthCORS...)
	return web.NewResponse(status, []byte(js.Stringify(body)), headers...)
}

func oauthError(code, description string, status int) *Response {
	return oauthJSON(js.NewObject("error", code, "error_description", description), status)
}

// S256 is base64url of SHA-256, as PKCE's S256 method compares.
func S256(verifier string) string {
	sum := sha256.Sum256([]byte(js.WellFormed(verifier)))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

var (
	httpsRedirect    = regexp.MustCompile(`^https://[^/]+`)
	loopbackRedirect = regexp.MustCompile(`^http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?/`)
	challengePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43,128}$`)
	scopeSplit       = regexp.MustCompile(`[\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]+`)
)

// allowedRedirect: redirect addresses a client may register are https, or a local app's own loopback address.
func allowedRedirect(value string) bool {
	return httpsRedirect.MatchString(value) || loopbackRedirect.MatchString(value)
}

// ResourceMetadataURL is the URL that a 401 from the MCP endpoint points clients at, to start OAuth.
func ResourceMetadataURL(origin, base string) string {
	return origin + base + "/.well-known/oauth-protected-resource"
}

// respond answers the OAuth paths, or nil for anything else. path is
// relative to the routes' base; the two well-known documents are also
// answered at the site's root for clients that look there.
func (o *oauthHost) respond(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request, r := c.ctx, c.req, o.r
	issuer := u.Origin() + o.base
	if request.Method == "OPTIONS" && (strings.HasPrefix(path, "/.well-known/oauth-") || strings.HasPrefix(path, "/.well-known/openid-configuration") || strings.HasPrefix(path, "/oauth/")) {
		return web.NewResponse(204, nil, oauthCORS...), nil
	}
	if strings.HasPrefix(path, "/.well-known/oauth-protected-resource") {
		return oauthJSON(js.NewObject("resource", issuer+"/mcp", "authorization_servers", []string{issuer}, "scopes_supported", []string{"read", "manage"}, "bearer_methods_supported", []string{"header"}), 200), nil
	}
	if strings.HasPrefix(path, "/.well-known/oauth-authorization-server") || strings.HasPrefix(path, "/.well-known/openid-configuration") {
		return oauthJSON(js.NewObject(
			"issuer", issuer,
			"authorization_endpoint", issuer+"/oauth/authorize",
			"token_endpoint", issuer+"/oauth/token",
			"registration_endpoint", issuer+"/oauth/register",
			"response_types_supported", []string{"code"},
			"grant_types_supported", []string{"authorization_code"},
			"code_challenge_methods_supported", []string{"S256"},
			"token_endpoint_auth_methods_supported", []string{"none"},
			"scopes_supported", []string{"read", "manage"},
		), 200), nil
	}
	if path == "/oauth/register" && request.Method == "POST" {
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		o.limitOnce.Do(func() { o.limit = newRateLimit(registrationsPerMinute, r.now) })
		if !o.limit.allow(r.ClientIP(request)) {
			return oauthError("invalid_client_metadata", "Too many registrations from this address. Wait a minute and try again.", 429), nil
		}
		body, _ := request.JSON()
		redirects := []string{}
		for _, v := range js.Arr(js.Dig(body, "redirect_uris")) {
			if s := js.String(v); allowedRedirect(s) && len(redirects) < 10 {
				redirects = append(redirects, s)
			}
		}
		if len(redirects) == 0 {
			return oauthError("invalid_redirect_uri", "Register at least one https redirect address", 400), nil
		}
		name := "An app"
		if v := js.Dig(body, "client_name"); v != nil {
			name = js.String(v)
		}
		return o.register(ctx, name, redirects)
	}
	if path == "/oauth/authorize" && (request.Method == "GET" || request.Method == "POST") {
		return o.authorize(c, u)
	}
	if path == "/oauth/token" && request.Method == "POST" {
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		var form *whatwg.SearchParams
		if strings.TrimSpace(strings.Split(request.Header.Get("content-type"), ";")[0]) == "application/json" {
			form = whatwg.NewSearchParams()
			if parsed, err := request.JSON(); err == nil {
				js.Obj(parsed).Each(func(k string, v any) { form.Append(k, js.String(v)) })
			}
		} else {
			form = whatwg.ParseQuery(request.Text())
		}
		if form.Value("grant_type") != "authorization_code" {
			return oauthError("unsupported_grant_type", "Only authorization_code is supported", 400), nil
		}
		key := "oauth-code:" + sha256Hex(form.Value("code"))
		stored, has, err := r.Store.Setting(ctx, key)
		if err != nil {
			return nil, err
		}
		// A code works once: it is gone before anything else is checked.
		if has && stored != "" {
			if err := r.Store.SetSetting(ctx, key, nil); err != nil {
				return nil, err
			}
		}
		var grant *js.Object
		if has && stored != "" {
			parsed, err := js.Parse(stored)
			if err != nil {
				return nil, err
			}
			grant = js.Obj(parsed)
		}
		if grant == nil || js.Num(grant.Value("expires")) < float64(r.now()) {
			return oauthError("invalid_grant", "The code has expired or was already used", 400), nil
		}
		clientID, _ := form.Get("client_id")
		redirectURI, _ := form.Get("redirect_uri")
		if grant.Value("client") != clientID || grant.Value("redirect") != redirectURI {
			return oauthError("invalid_grant", "The code was issued to another app", 400), nil
		}
		if S256(form.Value("code_verifier")) != js.String(grant.Value("challenge")) {
			return oauthError("invalid_grant", "The code verifier does not match", 400), nil
		}
		// The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
		client, usedKey, err := o.clientFor(ctx, js.String(grant.Value("client")))
		if err != nil {
			return nil, err
		}
		name := "An app"
		if client != nil {
			name = client.name
			if client.usedAt == nil {
				var value string
				if strings.HasPrefix(usedKey, "oauth-client:") {
					raw := client.raw.Clone()
					raw.Set("usedAt", r.now())
					value = js.Stringify(raw)
				} else {
					value = js.FormatNumber(float64(r.now()))
				}
				if err := r.Store.SetSetting(ctx, usedKey, &value); err != nil {
					return nil, err
				}
			}
		}
		secret := tokenPrefix + randomID(20)
		scope := "read"
		if grant.Value("scope") == "manage" {
			scope = "manage"
		}
		site := js.String(grant.Value("site"))
		row := TokenRow{ID: randomID(12), Name: head16(name+" (OAuth)", 100), Site: site, Scope: scope, Hash: sha256Hex(secret), Hint: secret[len(secret)-4:], CreatedAt: r.now()}
		if err := r.Store.InsertToken(ctx, row); err != nil {
			return nil, err
		}
		// Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
		if by, ok := grant.Value("by").(string); ok && by != "" && o.tokenMade != nil && !o.tokenMade(ctx, row, by) {
			if _, err := r.Store.DeleteToken(ctx, row.ID); err != nil {
				return nil, err
			}
			return oauthError("invalid_grant", "Whoever allowed this app can no longer connect it", 400), nil
		}
		// A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
		if scope == "manage" {
			origin := whatwg.MustParse(js.String(grant.Value("redirect"))).Origin()
			if err := r.Store.SetSetting(ctx, "token-origin:"+row.ID, &origin); err != nil {
				return nil, err
			}
		}
		// site is not part of OAuth, but a hub needs to know which site it was given.
		out := js.NewObject("access_token", secret, "token_type", "Bearer", "scope", scope)
		if site != "" {
			out.Set("site", site)
		}
		return oauthJSON(out, 200), nil
	}
	return nil, nil
}

func (o *oauthHost) authorize(c *call, u *whatwg.URL) (*Response, error) {
	ctx, request, r, base := c.ctx, c.req, o.r, o.base
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	form := u.SearchParams()
	if request.Method == "POST" {
		form = whatwg.ParseQuery(request.Text())
	}
	clientID := form.Value("client_id")
	client, _, err := o.clientFor(ctx, clientID)
	if err != nil {
		return nil, err
	}
	redirect := form.Value("redirect_uri")
	// Without a known client and one of its own addresses there is nowhere safe to send an answer.
	if client == nil || !contains(client.redirects, redirect) {
		return oauthPage("This app is not registered", "<p>Start connecting again from the app.</p>", 400), nil
	}
	back := func(pairs ...string) *Response {
		to := whatwg.MustParse(redirect)
		q := to.SearchParams()
		for i := 0; i+1 < len(pairs); i += 2 {
			q.Set(pairs[i], pairs[i+1])
		}
		if state := form.Value("state"); state != "" {
			q.Set("state", state)
		}
		to.SetSearchParams(q)
		return web.NewResponse(303, nil, "location", to.Href(), "cache-control", "no-store")
	}
	// Anyone can register an app with any address, so until an owner has allowed it once, a request it got
	// wrong ends on a page here rather than sending a visitor who is not signed in on to it.
	refuse := func(pairs ...string) *Response {
		if client.usedAt != nil {
			return back(pairs...)
		}
		what := pairs[1]
		if len(pairs) >= 4 {
			what = pairs[3]
		}
		return oauthPage("This app asked in a way Runlight does not support", "<p>"+escapeHTML(client.name)+" sent "+escapeHTML(what)+". Start connecting again from the app.</p>", 400)
	}
	if form.Value("response_type") != "code" {
		return refuse("error", "unsupported_response_type"), nil
	}
	challenge := form.Value("code_challenge")
	if form.Value("code_challenge_method") != "S256" || !challengePattern.MatchString(challenge) {
		return refuse("error", "invalid_request", "error_description", "PKCE with S256 is required"), nil
	}
	manage := contains(scopeSplit.Split(form.Value("scope"), -1), "manage")

	if !o.isOwner(ctx, request) {
		// Someone signed in who may only read would be sent to sign in again and again.
		if o.isReader != nil && o.isReader(ctx, request) {
			return oauthPage("Ask an owner to connect this", "<p>You are signed in as a viewer, and only an owner of this Runlight can connect "+escapeHTML(client.name)+".</p>", 403), nil
		}
		// The site stays, since on the way in it only says which one to offer first.
		kept := whatwg.NewSearchParams()
		for _, pair := range form.Pairs() {
			if pair[0] != "decision" {
				kept.Append(pair[0], pair[1])
			}
		}
		here := u.Pathname + "?" + kept.String()
		if o.signIn != "" {
			return web.NewResponse(303, nil, "location", o.signIn+"?next="+encodeURIComponent(here), "cache-control", "no-store"), nil
		}
		home := firstNonEmpty(base, "/")
		return oauthPage("Sign in first", `<p>Open your Runlight dashboard at <a href="`+escapeHTML(home)+`">`+escapeHTML(u.Host()+home)+`</a> and sign in, then connect `+escapeHTML(client.name)+` again.</p>`, 401), nil
	}

	if request.Method == "GET" {
		var hidden strings.Builder
		for _, k := range []string{"response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource"} {
			if v, ok := form.Get(k); ok {
				hidden.WriteString(`<input type="hidden" name="` + k + `" value="` + escapeHTML(v) + `">`)
			}
		}
		// The app names itself, so the page also shows where the answer goes, which it cannot fake.
		sendsTo := `<p class="note">Allowing sends you back to <strong>` + escapeHTML(whatwg.MustParse(redirect).Host()) + `</strong>. Only allow it if you started connecting there.</p>`
		name := escapeHTML(client.name)
		if manage {
			// Changing settings is for one site at a time, so there is no "every site" here.
			wanted := form.Value("site")
			var choices strings.Builder
			for _, s := range r.Sites() {
				if _, remote := r.Remote(s.ID); remote {
					continue
				}
				selected := ""
				if s.ID == wanted {
					selected = " selected"
				}
				choices.WriteString(`<option value="` + escapeHTML(s.ID) + `"` + selected + `>` + escapeHTML(s.Name) + `</option>`)
			}
			return oauthPage("Connect "+name, `<p><strong>`+name+`</strong> wants to show this site’s stats and change its settings, so you can manage it from there.</p>
<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>
`+sendsTo+`
<form method="post" action="`+escapeHTML(base)+`/oauth/authorize">`+hidden.String()+`
<label>Site<select name="site">`+choices.String()+`</select></label>
<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects `+name+`.</p>
<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>`, 200), nil
		}
		options := ""
		if sites := r.Sites(); len(sites) > 1 {
			for _, s := range sites {
				options += `<option value="` + escapeHTML(s.ID) + `">` + escapeHTML(s.Name) + ` only</option>`
			}
		}
		return oauthPage("Connect "+name, `<p><strong>`+name+`</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>
`+sendsTo+`
<form method="post" action="`+escapeHTML(base)+`/oauth/authorize">`+hidden.String()+`
<label>Which sites it can read<select name="site"><option value="">Every site</option>`+options+`</select></label>
<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>
<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>`, 200), nil
	}
	// The consent form posts here from this page only; a form from another site is refused.
	if origin, has := request.Header.Lookup("origin"); has && origin != "" && origin != u.Origin() {
		return oauthPage("This request came from another site", "<p>Start connecting again from the app.</p>", 403), nil
	}
	if form.Value("decision") != "allow" {
		return back("error", "access_denied"), nil
	}
	site := form.Value("site")
	if _, known := r.Site(site); site != "" && !known {
		return back("error", "invalid_request", "error_description", "Unknown site"), nil
	}
	if _, remote := r.Remote(site); manage && (site == "" || remote) {
		return back("error", "invalid_request", "error_description", "Pick the site to manage"), nil
	}
	code := randomID(32)
	scope := "read"
	if manage {
		scope = "manage"
	}
	grant := js.NewObject("client", clientID, "redirect", redirect, "challenge", challenge, "site", site, "scope", scope, "expires", r.now()+codeMs)
	if o.accountOf != nil {
		if by := o.accountOf(ctx, request); by != "" {
			grant.Set("by", by)
		}
	}
	if err := r.Store.SetSetting(ctx, "oauth-code:"+sha256Hex(code), ptr(js.Stringify(grant))); err != nil {
		return nil, err
	}
	return back("code", code), nil
}

// register registers a client by signing its name and addresses into its
// id, so nothing is stored until an owner allows it and the app swaps its code.
func (o *oauthHost) register(ctx context.Context, name string, redirects []string) (*Response, error) {
	r := o.r
	now := r.now()
	// Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
	clients, err := r.Store.SettingsStartingWith(ctx, "oauth-client:")
	if err != nil {
		return nil, err
	}
	for _, s := range clients {
		parsed, err := js.Parse(s.Value)
		if err != nil {
			return nil, err
		}
		if js.Dig(parsed, "usedAt") == nil && float64(now)-js.Num(js.Dig(parsed, "createdAt")) >= unusedClientMs {
			if err := r.Store.SetSetting(ctx, s.Key, nil); err != nil {
				return nil, err
			}
		}
	}
	codes, err := r.Store.SettingsStartingWith(ctx, "oauth-code:")
	if err != nil {
		return nil, err
	}
	for _, s := range codes {
		parsed, err := js.Parse(s.Value)
		if err != nil {
			return nil, err
		}
		if js.Num(js.Dig(parsed, "expires")) < float64(now) {
			if err := r.Store.SetSetting(ctx, s.Key, nil); err != nil {
				return nil, err
			}
		}
	}
	clientName := head16(jsTrim(name), 80)
	if clientName == "" {
		clientName = "An app"
	}
	payload := base64urlText(js.Stringify(js.NewObject("n", clientName, "r", redirects, "t", now)))
	key, err := o.clientKey(ctx)
	if err != nil {
		return nil, err
	}
	id := payload + "." + hmacHex(key, payload)
	if len(id) > maxClientID {
		return oauthError("invalid_client_metadata", "Register fewer or shorter redirect addresses", 400), nil
	}
	return oauthJSON(js.NewObject("client_id", id, "client_name", clientName, "redirect_uris", redirects, "token_endpoint_auth_method", "none",
		"grant_types", []string{"authorization_code"}, "response_types", []string{"code"}), 201), nil
}

const oauthStyle = `<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 6l4 4 4-4' fill='none' stroke='%238a8a93' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style>`

func oauthPage(title, body string, status int) *Response {
	return web.NewResponse(status, []byte(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>`+title+` | Runlight</title>
`+oauthStyle+`</head><body><main><h1>`+title+`</h1>`+body+`</main></body></html>`),
		"content-type", "text/html; charset=utf-8",
		"cache-control", "no-store",
		// No form-action rule: browsers apply it to the redirect back to the app after Allow.
		"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
		"x-frame-options", "DENY",
		// same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check refuses.
		"referrer-policy", "same-origin")
}
