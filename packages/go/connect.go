package runlight

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Connecting another Runlight to this one (a hub) without copying a token:
// this server registers itself with the install's OAuth server, sends the
// owner to that install's consent page, and on the way back swaps the code
// for a manage token, limited there to the one site the owner picked.

const pendingMs = 15 * 60_000

// connectMaxBytes is the most an install's answer while connecting may weigh; a real one is under a kilobyte.
const connectMaxBytes = 64 * 1024

// ConnectError is why connecting failed, as a code the dashboard says in its
// own words: expired, denied, refused, or token on the way back from the
// consent page, and url, unreachable, not_runlight, endpoints, old, or
// register when starting.
type ConnectError struct{ CodedError }

func (*ConnectError) isRangeError() {}

func connectError(message, code string, params ...string) error {
	return &ConnectError{coded(message, code, params...)}
}

// installURL is the install's address as its dashboard is, without a trailing slash.
func installURL(value any, local bool) (string, error) {
	url := strings.TrimRight(jsTrim(stringOf(value)), "/")
	// The pattern says which addresses are allowed; the parser, that it is an address at all ("https://[" is not).
	if !installAddress(url, local) || !whatwg.CanParse(url) {
		return "", connectError("Enter the install's address, like https://example.com/runlight", "url")
	}
	return url, nil
}

// pendingFrom is a saved attempt, or nil when it cannot be read or has no
// time it runs out, which counts as expired.
func pendingFrom(value string, now int64) *js.Object {
	parsed, err := js.Parse(value)
	if err != nil {
		return nil
	}
	pending, ok := parsed.(*js.Object)
	if !ok {
		return nil
	}
	expires, ok := pending.Value("expires").(float64)
	if !ok || expires < float64(now) {
		return nil
	}
	return pending
}

// clearExpired removes attempts nobody came back from, so they do not pile up in settings.
func clearExpired(ctx context.Context, r *Runlight) error {
	settings, err := r.Store.SettingsStartingWith(ctx, "connect:")
	if err != nil {
		return err
	}
	for _, s := range settings {
		if pendingFrom(s.Value, r.now()) == nil {
			if err := r.Store.SetSetting(ctx, s.Key, nil); err != nil {
				return err
			}
		}
	}
	return nil
}

// StartConnect starts connecting another install: the address of its consent page.
func StartConnect(ctx context.Context, r *Runlight, input any, back, site string) (string, error) {
	url, err := installURL(input, r.LocalInstalls)
	if err != nil {
		return "", err
	}
	host := whatwg.MustParse(url).Host()
	answer, err := r.installFetch(ctx, url+"/.well-known/oauth-authorization-server", FetchInit{Timeout: 10 * time.Second, MaxBytes: connectMaxBytes})
	if err != nil {
		return "", connectError("Could not reach "+url, "unreachable", "host", host)
	}
	var meta any
	if answer.OK() {
		meta, _ = answer.JSON()
	}
	authorization, token, registration := js.Dig(meta, "authorization_endpoint"), js.Dig(meta, "token_endpoint"), js.Dig(meta, "registration_endpoint")
	if !js.Truthy(authorization) || !js.Truthy(token) || !js.Truthy(registration) {
		return "", connectError(url+" did not answer like a Runlight install", "not_runlight", "url", url)
	}
	// Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
	origin := whatwg.MustParse(url).Origin()
	for _, endpoint := range []any{authorization, token, registration} {
		u, err := whatwg.Parse(js.String(endpoint))
		if err != nil || u.Origin() != origin {
			return "", connectError(url+" named endpoints on another address", "endpoints", "url", url)
		}
	}
	scopes, isList := js.Dig(meta, "scopes_supported").([]any)
	manage := false
	for _, s := range scopes {
		if s == "manage" {
			manage = true
		}
	}
	if !isList || !manage {
		return "", connectError(url+" runs an older Runlight. Update it, or connect it with an API token from its Settings.", "old", "url", url)
	}

	body := js.Stringify(js.NewObject("client_name", "Runlight at "+whatwg.MustParse(back).Host(), "redirect_uris", []string{back}))
	registered, err := r.installFetch(ctx, js.String(registration), FetchInit{Method: "POST", Headers: web.NewHeaders("content-type", "application/json"), Body: []byte(body), Timeout: 10 * time.Second, MaxBytes: connectMaxBytes})
	if err != nil {
		return "", connectError("Could not reach "+url, "unreachable", "host", host)
	}
	client, _ := registered.JSON()
	clientID := js.Dig(client, "client_id")
	if !registered.OK() || !js.Truthy(clientID) {
		// Say why, in the install's own words when it gives them.
		var reason string
		switch {
		case js.Truthy(js.Dig(client, "error_description")):
			reason = head16(js.String(js.Dig(client, "error_description")), 200) + "."
		case registered.Status == 400:
			reason = "This server's address must use https."
		default:
			reason = fmt.Sprintf("It answered %d.", registered.Status)
		}
		return "", connectError(url+" would not let this server connect. "+reason, "register", "url", url, "reason", reason)
	}
	if err := clearExpired(ctx, r); err != nil {
		return "", err
	}
	state := randomID(16)
	verifier := randomID(32) + randomID(32)
	pending := js.NewObject("url", url, "client", js.String(clientID), "verifier", verifier, "redirect", back, "token", js.String(token), "expires", r.now()+pendingMs)
	if err := r.Store.SetSetting(ctx, "connect:"+state, ptr(js.Stringify(pending))); err != nil {
		return "", err
	}
	to := whatwg.MustParse(js.String(authorization))
	q := whatwg.NewSearchParams("response_type", "code", "client_id", js.String(clientID), "redirect_uri", back, "code_challenge", S256(verifier),
		"code_challenge_method", "S256", "scope", "manage", "state", state)
	// Which of its sites to offer first, when connecting again for a site already here.
	if site != "" {
		q.Append("site", site)
	}
	to.SetSearch(q.String())
	return to.Href(), nil
}

var connectState = regexp.MustCompile(`^[a-f0-9]{32}$`)

// FinishConnect finishes connecting when the owner comes back from the consent page. Returns the site's id here.
func FinishConnect(ctx context.Context, r *Runlight, params *whatwg.SearchParams) (string, error) {
	state := params.Value("state")
	key := "connect:" + state
	var stored string
	var has bool
	if connectState.MatchString(state) {
		var err error
		if stored, has, err = r.Store.Setting(ctx, key); err != nil {
			return "", err
		}
	}
	// Each attempt works once.
	if has && stored != "" {
		if err := r.Store.SetSetting(ctx, key, nil); err != nil {
			return "", err
		}
	}
	var pending *js.Object
	if has && stored != "" {
		pending = pendingFrom(stored, r.now())
	}
	if pending == nil {
		return "", connectError("That connection took too long or was already used. Start again.", "expired")
	}
	if e, _ := params.Get("error"); e == "access_denied" {
		return "", connectError("The connection was not allowed.", "denied")
	}
	if e, has := params.Get("error"); has && e != "" {
		message, ok := params.Get("error_description")
		if !ok {
			message = e
		}
		return "", connectError(message, "refused")
	}
	body := whatwg.NewSearchParams("grant_type", "authorization_code", "code", params.Value("code"), "client_id", js.String(js.Dig(pending, "client")),
		"redirect_uri", js.String(js.Dig(pending, "redirect")), "code_verifier", js.String(js.Dig(pending, "verifier"))).String()
	answer, err := r.installFetch(ctx, js.String(js.Dig(pending, "token")), FetchInit{Method: "POST", Headers: web.NewHeaders("content-type", "application/x-www-form-urlencoded"), Body: []byte(body), Timeout: 10 * time.Second, MaxBytes: connectMaxBytes})
	var granted any
	if err == nil && answer.OK() {
		granted, _ = answer.JSON()
	}
	if !js.Truthy(js.Dig(granted, "access_token")) {
		return "", connectError(whatwg.MustParse(js.String(js.Dig(pending, "url"))).Host()+" did not give this server a token. Start again.", "token")
	}
	remote := js.NewObject("url", js.Dig(pending, "url"), "token", js.Dig(granted, "access_token"))
	if s, ok := js.Obj(granted).Get("site"); ok {
		remote.Set("site", s)
	}
	site, err := r.AddSite(ctx, js.NewObject("remote", remote))
	if err != nil {
		return "", err
	}
	return site.ID, nil
}
