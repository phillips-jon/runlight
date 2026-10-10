package runlight

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"

	"runlight.sh/go/internal/assets"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

var (
	funnelPath  = regexp.MustCompile(`^/api/funnels/[a-f0-9]{24}$`)
	goalAnyPath = regexp.MustCompile(`^/api/goals/[^/]+$`)
	siteOnePath = regexp.MustCompile(`^/api/sites/([^/]+)$`)
	linkGetPath = regexp.MustCompile(`^/api/links/[a-f0-9]+$`)
	throughStep = regexp.MustCompile(`^(\d+):(.+)$`)
	propName64  = regexp.MustCompile(`^[^"\\]{1,64}$`)
	localePath  = regexp.MustCompile(`^/assets/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json$`)
	unsubPath   = regexp.MustCompile(`^/unsubscribe/([^/]+)/?$`)
	sharePage   = regexp.MustCompile(`^/share/([^/]+)/?$`)
)

func ok() *Response { return jsonAnswer(js.NewObject("ok", true), 200) }

func methodIn(method string, list ...string) bool {
	for _, m := range list {
		if m == method {
			return true
		}
	}
	return false
}

// embedAPI answers POST /api/embed: a ticket for one load of the dashboard inside a CMS's admin pages.
func (rt *Routes) embedAPI(c *call) (*Response, error) {
	ctx, request, r := c.ctx, c.req, rt.r
	token, err := rt.apiToken(c)
	if err != nil {
		return nil, err
	}
	if token == nil {
		return denied(canNo), nil
	}
	if token.Scope != "embed" {
		return Coded("Use a key for the dashboard in a CMS, made in Settings, Install", "embed_token", 403, nil), nil
	}
	site, known := r.Site(token.Site)
	if !known {
		return Coded("Unknown site", "unknown_site", 404, nil), nil
	}
	body, refused := readJSON(request)
	if refused != nil {
		return refused, nil
	}
	origin := field(body, "origin")
	var parsed *whatwg.URL
	if originPattern.MatchString(origin) && js.Length16(origin) <= 200 {
		parsed, _ = whatwg.Parse(origin)
	}
	if parsed == nil || parsed.Origin() != origin {
		return Coded("Send the admin page's origin, such as https://example.com", "embed_origin", 400, nil), nil
	}
	host := HostName(parsed.Host())
	hostnames := site.Hostnames
	if remote, isRemote := r.Remote(site.ID); isRemote {
		hostnames = remote.Hostnames
	}
	mine := false
	for _, h := range hostnames {
		if HostName(h) == host {
			mine = true
			break
		}
	}
	if !mine {
		return Coded(host+" is not one of this site's domains. Add it to the site's domains in Runlight's settings.", "embed_host", 400, js.NewObject("host", host)), nil
	}
	ticket, expiresAt, err := rt.embedTicket(ctx, origin, token.ID)
	if err != nil {
		return nil, err
	}
	return jsonAnswer(js.NewObject("ticket", ticket, "site", site.ID, "expiresAt", expiresAt, "path", rt.base+"/embed?ticket="+ticket), 201), nil
}

// api answers /api and everything under it.
func (rt *Routes) api(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request := c.ctx, c.req
	r := rt.r
	// An embedded dashboard reads what a share link shows and nothing else, whoever else the request comes from.
	if _, has := request.Header.Lookup(embedHeader); has && !(request.Method == "GET" && sharedPath(path)) {
		return Coded("Not available on a shared dashboard", "share_not_available", 403, nil), nil
	}
	// A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
	// That holds without a cookie too, since a browser also sends Basic credentials or comes from an
	// allowed address on its own. A bearer token is never sent by the browser on its own, so it needs no check.
	if !methodIn(request.Method, "GET", "HEAD", "OPTIONS", "DELETE") && bearer(request) == "" && !isJSON(request) {
		return Coded("Send JSON", "send_json", 415, nil), nil
	}
	if path == "/api" && request.Method == "GET" {
		body := js.NewObject("name", "runlight", "version", Version, "api", APIVersion)
		for _, pair := range implementation {
			body.Set(pair[0], pair[1])
		}
		return jsonAnswer(body, 200), nil
	}

	// A hub asks what its token may do before offering to change anything.
	if path == "/api/token" && (request.Method == "GET" || request.Method == "DELETE") {
		token, err := rt.apiToken(c)
		if err != nil {
			return nil, err
		}
		if token == nil {
			return denied(canNo), nil
		}
		if request.Method == "GET" {
			return jsonAnswer(js.NewObject("scope", token.Scope, "site", token.Site), 200), nil
		}
		// A token can delete itself, which a hub does when it disconnects a site or gets a new token.
		if _, err := r.Store.DeleteToken(ctx, token.ID); err != nil {
			return nil, err
		}
		return ok(), nil
	}

	// Connecting another Runlight through its consent page, so nobody copies a token.
	if path == "/api/sites/connect" && request.Method == "POST" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		if !r.ManagedSites {
			return Coded("Sites are set in code", "sites_in_code", 400, nil), nil
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		site, _ := body.Value("site").(string)
		authorize, err := StartConnect(ctx, r, body.Value("url"), u.Origin()+rt.base+"/api/sites/connect/done", site)
		if err != nil {
			var ce *ConnectError
			if errors.As(err, &ce) {
				code := "connect_" + ce.Code
				if ce.Code == "unreachable" {
					code = "unreachable"
				}
				return Coded(ce.Message, code, 400, ce.Params), nil
			}
			if isRangeError(err) {
				return refusedAnswer(err, "connect_failed", 400), nil
			}
			return nil, err
		}
		return jsonAnswer(js.NewObject("authorize", authorize), 200), nil
	}
	if path == "/api/sites/connect/done" && request.Method == "GET" {
		home := firstNonEmpty(rt.base, "/")
		if rt.canRead(c) != canFull {
			return web.NewResponse(303, nil, "location", home, "cache-control", "no-store"), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		var to string
		id, err := FinishConnect(ctx, r, u.SearchParams())
		if err != nil {
			if !isRangeError(err) {
				return nil, err
			}
			// A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
			code := "failed"
			var ce *ConnectError
			if errors.As(err, &ce) {
				code = ce.Code
			}
			to = home + "?connect_error=" + code
		} else {
			// The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
			to = home + "?site=" + encodeURIComponent(id) + "&settings=general&connected=1"
		}
		return web.NewResponse(303, nil, "location", to, "cache-control", "no-store"), nil
	}

	// A ticket for one load of the dashboard inside a CMS's admin pages. The plugin's server asks with its embed
	// token on each page view and names the admin's origin, which must be one of the site's domains and alone
	// may frame the page the ticket opens.
	if path == "/api/embed" && request.Method == "POST" {
		return rt.embedAPI(c)
	}

	var token *TokenRow
	if strings.HasPrefix(bearer(request), tokenPrefix) {
		var err error
		if token, err = rt.apiToken(c); err != nil {
			return nil, err
		}
	}
	// An embed token gets tickets and reads nothing itself.
	if token != nil && token.Scope == "embed" {
		return Coded("This key only opens the dashboard inside a CMS", "token_embed_only", 403, nil), nil
	}
	if token != nil && token.Scope == "manage" && ManagePath(request.Method, path) {
		asked, has := queryValue(u, "site")
		siteMatch := siteOnePath.FindStringSubmatch(path)
		if has && asked != "" && asked != token.Site {
			return Coded("Unknown site", "unknown_site", 404, nil), nil
		}
		if siteMatch != nil {
			if id, ok := decodeURIComponent(siteMatch[1]); !ok || id != token.Site {
				return Coded("Unknown site", "unknown_site", 404, nil), nil
			}
		}
		if siteMatch != nil && isJSON(request) {
			// Where a site lives stays with its owner: a hub may rename it, never move it.
			if body, err := request.JSON(); err == nil {
				if o, isObj := body.(*js.Object); isObj && o.Has("hostnames") {
					if _, undefined := o.Value("hostnames").(js.Undefined); !undefined {
						return Coded("A connected hub cannot change a site's domains", "hub_domains", 403, nil), nil
					}
				}
			}
		}
		u = u.Clone()
		q := u.SearchParams()
		q.Set("site", token.Site)
		u.SetSearchParams(q)
		c.managed = token
	}
	// A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
	if token != nil && c.managed == nil && !methodIn(request.Method, "GET", "HEAD", "OPTIONS") {
		if token.Scope == "manage" {
			return Coded("A manage token changes only its own site's settings", "token_manage_only", 403, nil), nil
		}
		return Coded("API tokens can only read", "token_read_only", 403, nil), nil
	}

	// A page another site served to an AI agent, reported by a CMS plugin.
	if path == "/api/observe" && request.Method == "POST" {
		return rt.observeAPI(c)
	}

	// GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
	if path == "/api/check" && (request.Method == "POST" || request.Method == "GET") {
		given := bearer(request)
		allowed := (rt.cronSecret != "" && given != "" && constantTimeEqual(given, rt.cronSecret)) || rt.canRead(c) == canFull
		if !allowed {
			return Coded("Unauthorized", "unauthorized", 401, nil), nil
		}
		result, err := r.Check(ctx)
		if err != nil {
			return nil, err
		}
		return jsonAnswer(result, 200), nil
	}

	// A site counted by another install is read there. Its settings change there too, through this server
	// when the install gave a manage token, and only by an owner here.
	asked, _ := queryValue(u, "site")
	var connected *Remote
	if asked != "" {
		if remote, ok := r.Remote(asked); ok {
			connected = &remote
		}
	}
	if connected != nil && connected.Scope == "manage" && ManagePath(request.Method, path) && !(request.Method == "GET" && sharedPath(path)) {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		if request.Method != "GET" {
			r.ForgetRemoteInfo(asked)
		}
		return passThrough(ctx, r.fetcher, *connected, path, u, request), nil
	}
	if connected != nil && !(request.Method == "GET" && (sharedPath(path) || path == "/api/links")) {
		return Coded("This site is counted by its own Runlight. Connect it again from its settings to change it from here.", "site_remote", 400, nil), nil
	}

	// Visit history from Umami: list the account's websites, then import one a step at a time.
	if (path == "/api/import/umami/websites" || path == "/api/import/umami/visits") && request.Method == "POST" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		credentials := map[string]string{}
		if cred, ok := body.Value("credentials").(*js.Object); ok {
			cred.Each(func(k string, v any) { credentials[k] = js.String(v) })
		}
		answer, err := func() (*Response, error) {
			if path == "/api/import/umami/websites" {
				websites, err := UmamiWebsites(ctx, r, credentials)
				if err != nil {
					return nil, err
				}
				return jsonAnswer(js.NewObject("websites", websites), 200), nil
			}
			if err := r.Init(ctx); err != nil {
				return nil, err
			}
			site, refused := rt.querySite(u)
			if refused != nil {
				return refused, nil
			}
			var cursor *string
			if s, ok := body.Value("cursor").(string); ok {
				cursor = &s
			}
			step, err := ImportUmamiVisits(ctx, r, site.ID, credentials, undefinedIfMissing(body, "website", body.Value("website")), cursor)
			if err != nil {
				return nil, err
			}
			return jsonAnswer(step, 200), nil
		}()
		if err != nil && isImportError(err) {
			return refusedAnswer(err, "import_failed", 400), nil
		}
		return answer, err
	}

	// Visit history from a CSV file, a batch at a time.
	if path == "/api/import/csv/visits" && request.Method == "POST" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		site, refusedSite := rt.querySite(u)
		if refusedSite != nil {
			return refusedSite, nil
		}
		result, err := ImportCsvVisits(ctx, r, site.ID, undefinedIfMissing(body, "rows", body.Value("rows")))
		if err != nil {
			if isImportError(err) {
				return refusedAnswer(err, "import_failed", 400), nil
			}
			return nil, err
		}
		return jsonAnswer(result, 200), nil
	}

	// Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
	if (path == "/api/observe-key" && request.Method == "GET") || (path == "/api/observe-key/new" && request.Method == "POST") {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		site, refused := rt.querySite(u)
		if refused != nil {
			return refused, nil
		}
		name := "observe-key:" + site.ID
		key := ""
		if !strings.HasSuffix(path, "/new") {
			var err error
			if key, _, err = r.Store.Setting(ctx, name); err != nil {
				return nil, err
			}
		}
		if key == "" {
			key = "rlo_" + randomID(20)
			if err := r.Store.SetSetting(ctx, name, &key); err != nil {
				return nil, err
			}
		}
		return jsonAnswer(js.NewObject("key", key), 200), nil
	}

	// Making, changing, and deleting funnels; reading them is with the other reports.
	if (path == "/api/funnels" && request.Method == "POST") || (funnelPath.MatchString(path) && (request.Method == "PATCH" || request.Method == "DELETE")) {
		return rt.funnelWrites(c, path, u)
	}

	if strings.HasPrefix(path, "/api/assistant") {
		if answer, err := rt.assistantAPI(c, path, u); answer != nil || err != nil {
			return answer, err
		}
	}

	// Only the owner manages tokens: an API token cannot make or revoke one.
	if path == "/api/tokens" || strings.HasPrefix(path, "/api/tokens/") {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		return rt.tokensAPI(c, path)
	}

	if connected != nil && path == "/api/links" {
		access, err := rt.reader(c)
		if err != nil {
			return nil, err
		}
		if access.refused() {
			return deniedReader(access), nil
		}
		// A token limited to one site reads only that site's links, here as everywhere else.
		if !access.full && access.token.Site != "" && access.token.Site != asked {
			return Coded("Unknown site", "unknown_site", 404, nil), nil
		}
		return passThrough(ctx, r.fetcher, *connected, path, u, nil), nil
	}

	// An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
	if request.Method == "GET" && (path == "/api/links" || linkGetPath.MatchString(path)) {
		access, err := rt.reader(c)
		if err != nil {
			return nil, err
		}
		if access.refused() {
			return deniedReader(access), nil
		}
		if !access.full {
			if err := r.Init(ctx); err != nil {
				return nil, err
			}
			id, has := queryValue(u, "site")
			if !has {
				id = access.token.Site
			}
			site, found := r.Site(id)
			if !found || (access.token.Site != "" && site.ID != access.token.Site) {
				return Coded("Unknown site", "unknown_site", 404, nil), nil
			}
			scoped := u.Clone()
			q := scoped.SearchParams()
			q.Set("site", site.ID)
			scoped.SetSearchParams(q)
			return rt.linksAPI(c, path, scoped)
		}
	}

	if path == "/api/links" || strings.HasPrefix(path, "/api/links/") || path == "/api/link-domains" || strings.HasPrefix(path, "/api/link-domains/") {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		return rt.linksAPI(c, path, u)
	}

	if path == "/api/mail" || path == "/api/mail/test" || path == "/api/reports" || strings.HasPrefix(path, "/api/reports/") {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		return rt.mailAPI(c, path, u)
	}

	// A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks the install
	// that serves the site's script, with its own origin, since that install signs what the script will trust.
	if path == "/api/pick" && request.Method == "POST" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		site, refused := rt.querySite(u)
		if refused != nil {
			return refused, nil
		}
		body, refusedBody := readJSON(request)
		if refusedBody != nil {
			return refusedBody, nil
		}
		origin := field(body, "origin")
		if !originPattern.MatchString(origin) {
			return Coded("Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400, nil), nil
		}
		// A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
		if c.managed != nil {
			saved, has, err := r.Store.Setting(ctx, "token-origin:"+c.managed.ID)
			if err != nil {
				return nil, err
			}
			if !has || saved != origin {
				return Coded("This hub's address is not the one it connected from. Connect the site again from here.", "pick_hub", 403, nil), nil
			}
		}
		ticket, err := rt.pickTicket(ctx, origin, site.ID)
		if err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("ticket", ticket), 200), nil
	}

	if (path == "/api/goals" && request.Method == "POST") || (goalAnyPath.MatchString(path) && (request.Method == "PATCH" || request.Method == "DELETE")) {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		return rt.goalWrites(c, path, u)
	}

	if path == "/api/shares" || strings.HasPrefix(path, "/api/shares/") {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		return rt.sharesAPI(c, path, u)
	}

	// Adding and deleting sites, when they are managed in the dashboard.
	if path == "/api/sites" && request.Method == "POST" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		site, err := r.AddSite(ctx, body)
		if err != nil {
			if isRangeError(err) {
				return refusedAnswer(err, "site_invalid", 400), nil
			}
			return nil, err
		}
		return jsonAnswer(js.NewObject("site", site), 201), nil
	}

	if m := siteOnePath.FindStringSubmatch(path); m != nil && (request.Method == "DELETE" || request.Method == "PATCH") {
		return rt.siteWrites(c, m[1], u)
	}

	if request.Method != "GET" {
		return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
	}
	return rt.reads(c, path, u)
}

func (rt *Routes) observeAPI(c *call) (*Response, error) {
	ctx, request, r := c.ctx, c.req, rt.r
	given := bearer(request)
	// The install-wide key and the owner's access can report for any site.
	anySite := (rt.observeKey != "" && given != "" && constantTimeEqual(given, rt.observeKey)) || rt.canRead(c) == canFull
	if !anySite && given == "" {
		return Coded("Unauthorized", "unauthorized", 401, nil), nil
	}
	body, refused := readJSON(request)
	if refused != nil {
		return refused, nil
	}
	// One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
	batch, isBatch := body.Value("fetches").([]any)
	list := batch
	if !isBatch {
		list = []any{body}
	}
	if len(list) > 500 {
		return Coded("Send at most 500 fetches at a time", "observe_many", 413, nil), nil
	}
	type observed struct {
		page      *whatwg.URL
		userAgent string
		at        *float64
	}
	pages := []observed{}
	for _, item := range list {
		if item == nil {
			// item?.url on null is undefined, and String(undefined ?? "") is no URL.
			return Coded("Send the page's url", "observe_url", 400, nil), nil
		}
		o, _ := item.(*js.Object)
		raw := field(o, "url")
		page, err := whatwg.Parse(raw)
		if err != nil || (page.Protocol != "https:" && page.Protocol != "http:") {
			return Coded("Send the page's url", "observe_url", 400, nil), nil
		}
		var at *float64
		switch v := o.Value("at").(type) {
		case float64:
			at = &v
		case string:
			if t, ok := dateParse(v); ok {
				at = &t
			}
		}
		if at != nil && (math.IsNaN(*at) || math.IsInf(*at, 0)) {
			at = nil
		}
		pages = append(pages, observed{page, head16(field(o, "userAgent"), 500), at})
	}
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	keep := pages
	if !anySite {
		// A site's own key reports only pages on that site's domains. Pages elsewhere in a batch (another
		// host in the same log, say) are skipped, not a reason to refuse the rest.
		keySite := ""
		for _, site := range r.Sites() {
			key, has, err := r.Store.Setting(ctx, "observe-key:"+site.ID)
			if err != nil {
				return nil, err
			}
			if has && key != "" && constantTimeEqual(given, key) {
				keySite = site.ID
			}
		}
		if keySite == "" {
			return Coded("Unauthorized", "unauthorized", 401, nil), nil
		}
		keep = []observed{}
		for _, p := range pages {
			if site, ok := r.SiteFor(p.page.Hostname, ""); ok && site.ID == keySite {
				keep = append(keep, p)
			}
		}
		// A single report for another site's page is a misconfigured plugin, which should hear about it.
		if !isBatch && len(keep) == 0 {
			return Coded("Unauthorized", "unauthorized", 401, nil), nil
		}
	}
	recorded := 0
	for _, p := range keep {
		req := web.NewRequest("GET", p.page.Href(), web.NewHeaders("user-agent", p.userAgent), nil)
		if r.Observe(ctx, req, p.at) {
			recorded++
		}
	}
	// A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
	if !isBatch {
		return web.NewResponse(204, nil), nil
	}
	return jsonAnswer(js.NewObject("recorded", recorded, "skipped", len(pages)-recorded), 200), nil
}

func (rt *Routes) funnelWrites(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request, r := c.ctx, c.req, rt.r
	if access := rt.canRead(c); access != canFull {
		return denied(access), nil
	}
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	site, refused := rt.querySite(u)
	if refused != nil {
		return refused, nil
	}
	existing, err := r.Store.Funnels(ctx, site.ID)
	if err != nil {
		return nil, err
	}
	id := ""
	if path != "/api/funnels" {
		id = path[len("/api/funnels/"):]
		found := false
		for _, f := range existing {
			if f.ID == id {
				found = true
			}
		}
		if !found {
			return Coded("Unknown funnel", "unknown_funnel", 404, nil), nil
		}
	}
	if request.Method == "DELETE" {
		if err := r.Store.DeleteFunnel(ctx, id); err != nil {
			return nil, err
		}
		return ok(), nil
	}
	body, refusedBody := readJSON(request)
	if refusedBody != nil {
		return refusedBody, nil
	}
	funnel, err := FunnelFrom(body, site.ID, existing, r.now(), id)
	if err != nil {
		var fe *FunnelError
		if errors.As(err, &fe) {
			return refusedAnswer(err, "funnel_invalid", 400), nil
		}
		return nil, err
	}
	if err := r.Store.SaveFunnel(ctx, funnel); err != nil {
		return nil, err
	}
	status := 201
	if id != "" {
		status = 200
	}
	return jsonAnswer(js.NewObject("funnel", funnel), status), nil
}

func (rt *Routes) siteWrites(c *call, raw string, u *whatwg.URL) (*Response, error) {
	ctx, request, r := c.ctx, c.req, rt.r
	if access := rt.canRead(c); access != canFull {
		return denied(access), nil
	}
	id, decoded := decodeURIComponent(raw)
	if !decoded {
		return nil, errors.New("URIError: URI malformed")
	}
	siteError := func(err error) (*Response, error) {
		if isRangeError(err) {
			if err.Error() == "Unknown site" {
				return Coded(err.Error(), "unknown_site", 404, nil), nil
			}
			return refusedAnswer(err, "site_invalid", 400), nil
		}
		return nil, err
	}
	if request.Method == "DELETE" {
		if err := r.DeleteSite(ctx, id); err != nil {
			return siteError(err)
		}
		return ok(), nil
	}
	// A form posted from another site cannot carry this content type without CORS.
	body, refused := readJSON(request)
	if refused != nil {
		return refused, nil
	}
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	// Every field is checked before any changes, since a shorter retention deletes visits at once.
	if v, has := body.Get("name"); has {
		if name := jsTrim(js.String(v)); name == "" || len16(name) > 80 {
			return Coded("A site name is 1 to 80 characters", "site_name", 400, nil), nil
		}
	}
	if v, has := body.Get("timezone"); has && !IsTimezone(js.String(v)) {
		return Coded(`Unknown timezone "`+js.String(v)+`"`, "unknown_timezone", 400, params("timezone", js.String(v))), nil
	}
	retention, hasRetention := body.Get("retentionMonths")
	if hasRetention && retention != nil {
		n := js.ToNumber(retention)
		allowed := false
		for _, m := range RetentionMonths {
			if float64(m) == n {
				allowed = true
			}
		}
		if !allowed {
			list := retentionList()
			return Coded("Keep visits for "+list+" months, or forever", "retention_bad", 400, params("months", list)), nil
		}
	}
	remote, isRemote := r.Remote(id)
	// How long a connected site keeps visits, and the timezone its days follow, are the install's settings:
	// this server passes them on, and changes its own row only once the install took them.
	forward := &js.Object{}
	if hasRetention {
		forward.Set("retentionMonths", retention)
	}
	if v, has := body.Get("timezone"); has {
		if current, found := r.Site(id); !found || js.String(v) != current.Timezone {
			forward.Set("timezone", js.String(v))
		}
	}
	if isRemote && forward.Len() > 0 {
		if remote.Scope != "manage" {
			return Coded("Connect this site again to change it from here", "connect_again", 400, nil), nil
		}
		patch := web.NewRequest("PATCH", request.URL, web.NewHeaders("content-type", "application/json"), []byte(js.Stringify(forward)))
		answer := passThrough(ctx, r.fetcher, remote, "/api/sites/"+encodeURIComponent(remote.Site), u.Clone(), patch)
		if !answer.OK() {
			return answer, nil
		}
		r.ForgetRemoteInfo(id)
	} else if !isRemote && hasRetention {
		var months *float64
		if retention != nil {
			months = ptr(js.ToNumber(retention))
		}
		if err := r.SetRetention(ctx, id, months); err != nil {
			return siteError(err)
		}
	}
	patch := SitePatch{}
	if v, has := body.Get("name"); has {
		patch.Name = js.String(v)
	}
	if v, has := body.Get("timezone"); has {
		patch.Timezone = js.String(v)
	}
	if v, has := body.Get("hostnames"); has && r.ManagedSites {
		if v == nil {
			v = js.Undefined{}
		}
		patch.Hostnames = v
		if _, undefined := v.(js.Undefined); undefined {
			patch.Hostnames = nil
		}
	}
	site, err := r.UpdateSite(ctx, id, patch)
	if err != nil {
		return siteError(err)
	}
	// A connected site answers as the list shows it, so the dashboard keeps its install and domains.
	if isRemote {
		view := js.ToValue(site).(*js.Object)
		view.Set("remote", remote.URL)
		view.Set("remoteSite", remote.Site)
		view.Set("manage", remote.Scope == "manage")
		view.Set("hostnames", remote.Hostnames)
		return jsonAnswer(js.NewObject("site", view), 200), nil
	}
	return jsonAnswer(js.NewObject("site", site), 200), nil
}

// reads answers the GET reports, for the owner, a token, a reader, or a share.
func (rt *Routes) reads(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request, r := c.ctx, c.req, rt.r
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	// A shared dashboard sees exactly what its visitors see, even for someone signed in.
	var shared *ShareRow
	// The one site a share or a site's API token may read; "" for every site.
	only := ""
	if shareIDValue, has := request.Header.Lookup(shareHeader); has {
		if shareID.MatchString(shareIDValue) {
			var err error
			if shared, err = r.Store.ShareByID(ctx, shareIDValue); err != nil {
				return nil, err
			}
		}
		if shared == nil {
			return Coded("This share link no longer works", "share_gone", 404, nil), nil
		}
		if !sharedPath(path) {
			return Coded("Not available on a shared dashboard", "share_not_available", 403, nil), nil
		}
		only = shared.Site
	} else if session, has := request.Header.Lookup(embedHeader); has {
		token, err := rt.embedReader(ctx, session)
		if err != nil {
			return nil, err
		}
		if token == nil {
			return Coded("This dashboard has expired. Reload the page to open it again.", "embed_expired", 401, nil), nil
		}
		// An embedded dashboard sees what a share link of its token's site shows.
		shared = &ShareRow{Site: token.Site}
		only = token.Site
	} else {
		access, err := rt.reader(c)
		if err != nil {
			return nil, err
		}
		if access.refused() {
			return deniedReader(access), nil
		}
		if !access.full {
			if !sharedPath(path) {
				return Coded("API tokens can only read", "token_read_only", 403, nil), nil
			}
			only = access.token.Site
		}
	}

	if path == "/api/sites" {
		sites := []any{}
		for _, site := range r.Sites() {
			if only != "" && site.ID != only {
				continue
			}
			view := js.ToValue(site).(*js.Object)
			remote, isRemote := r.Remote(site.ID)
			// A connected install's address, so the dashboard can say where the site is counted. Its domains
			// as the install reported them, for the goal picker; tracker hits never match them here.
			if isRemote && shared == nil {
				view.Set("remote", remote.URL)
				view.Set("remoteSite", remote.Site)
				view.Set("manage", remote.Scope == "manage")
				view.Set("hostnames", remote.Hostnames)
			}
			// Hostnames say where the site lives; a share shows only its name.
			if shared != nil {
				view.Set("hostnames", []string{})
			}
			if isRemote {
				view.Set("lastSeen", r.RemoteLastSeen(ctx, site.ID))
			} else {
				last, err := r.Store.LastSeen(ctx, site.ID)
				if err != nil {
					return nil, err
				}
				view.Set("lastSeen", last)
			}
			// Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
			if shared == nil {
				if isRemote {
					if info := r.RemoteInfo(ctx, site.ID); info != nil && info.RetentionMonthsKnown {
						view.Set("retentionMonths", info.RetentionMonths)
					}
				} else {
					months, err := r.Retention(ctx, site.ID)
					if err != nil {
						return nil, err
					}
					view.Set("retentionMonths", months)
				}
			}
			// Whether a connected install still takes this server's token, so the dashboard offers to connect
			// it again only when it no longer does.
			if isRemote && shared == nil {
				if info := r.RemoteInfo(ctx, site.ID); info != nil {
					view.Set("connection", info.Connection)
				}
			}
			sites = append(sites, view)
		}
		// A share never learns how the install is run.
		if shared != nil {
			return jsonAnswer(js.NewObject("sites", sites), 200), nil
		}
		return jsonAnswer(js.NewObject("sites", sites, "managed", r.ManagedSites), 200), nil
	}

	var site SiteRow
	var found bool
	switch {
	case shared != nil:
		site, found = r.Site(shared.Site)
	case only != "":
		id, has := queryValue(u, "site")
		if !has {
			id = only
		}
		site, found = r.Site(id)
	default:
		var refused *Response
		site, refused = rt.querySite(u)
		if refused != nil {
			return refused, nil
		}
		found = true
	}
	if !found || (only != "" && site.ID != only) {
		return Coded("Unknown site", "unknown_site", 404, nil), nil
	}
	if remote, isRemote := r.Remote(site.ID); isRemote {
		return passThrough(ctx, r.fetcher, remote, path, u, request), nil
	}

	if path == "/api/icon" {
		// Only a site's own domain, never the request's Host header, which a caller can write.
		var icon *SiteIcon
		if len(site.Hostnames) > 0 {
			icon = FetchIcon(ctx, r.fetcher, "https://"+site.Hostnames[0], r.now())
		}
		if icon == nil {
			return Coded("No icon", "icon_none", 404, nil, "cache-control", "private, max-age=3600"), nil
		}
		return web.NewResponse(200, icon.Body, "content-type", icon.Type, "cache-control", "private, max-age=86400",
			// An SVG served from this origin must never run script.
			"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox", "x-content-type-options", "nosniff"), nil
	}

	if path == "/api/realtime" {
		realtime, err := r.Store.Realtime(ctx, site.ID, r.now())
		if err != nil {
			return nil, err
		}
		return jsonAnswer(realtime, 200), nil
	}

	read, refused, err := rt.readQuery(ctx, u, site)
	if err != nil || refused != nil {
		return refused, err
	}
	query, rng, compared := read.query, read.rng, read.compared
	ranged := rangeOut(rng, site.Timezone)
	var compareOut any = js.Undefined{}
	previousQuery := query
	if compared != nil {
		compareOut = js.NewObject("from", compared.FromDate, "to", compared.ToDate)
		previousQuery.From, previousQuery.To = compared.From, compared.To
	}

	switch path {
	case "/api/stats":
		stats, err := r.Store.Stats(ctx, query)
		if err != nil {
			return nil, err
		}
		var previous any = js.Undefined{}
		if compared != nil {
			p, err := r.Store.Stats(ctx, previousQuery)
			if err != nil {
				return nil, err
			}
			previous = p
		}
		return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "compare", compareOut, "stats", stats, "previous", previous), 200), nil

	case "/api/goals":
		goals, err := r.Store.Goals(ctx, site.ID)
		if err != nil {
			return nil, err
		}
		visitors, err := r.Store.Visitors(ctx, query)
		if err != nil {
			return nil, err
		}
		previousVisitors := int64(0)
		var beforeAll map[string]GoalTotals
		if compared != nil {
			if previousVisitors, err = r.Store.Visitors(ctx, previousQuery); err != nil {
				return nil, err
			}
		}
		// Every goal in one pass for the range, and one more for the comparison.
		nowAll, err := r.Store.GoalTotalsAll(ctx, query, goals)
		if err != nil {
			return nil, err
		}
		if compared != nil {
			if beforeAll, err = r.Store.GoalTotalsAll(ctx, previousQuery, goals); err != nil {
				return nil, err
			}
		}
		rows := []any{}
		for _, goal := range goals {
			now := nowAll[goal.ID]
			row := js.ToValue(goal).(*js.Object)
			row.Set("conversions", now.Conversions)
			row.Set("visitors", now.Visitors)
			row.Set("revenue", now.Revenue)
			row.Set("rate", rate(now.Visitors, visitors))
			if before, has := beforeAll[goal.ID]; has {
				row.Set("previous", js.NewObject("conversions", before.Conversions, "visitors", before.Visitors, "revenue", before.Revenue, "rate", rate(before.Visitors, previousVisitors)))
			} else {
				row.Set("previous", js.Undefined{})
			}
			rows = append(rows, row)
		}
		return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "compare", compareOut, "visitors", visitors, "goals", rows), 200), nil

	case "/api/series":
		points, err := r.Store.Series(ctx, query.Site, query.Filters, Buckets(rng, site.Timezone))
		if err != nil {
			return nil, err
		}
		var previous any = js.Undefined{}
		if compared != nil {
			// Comparison points line up with the main ones by position.
			p, err := r.Store.Series(ctx, query.Site, query.Filters, Buckets(*compared, site.Timezone))
			if err != nil {
				return nil, err
			}
			if len(p) > len(points) {
				p = p[:len(points)]
			}
			previous = p
		}
		return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "compare", compareOut, "points", points, "previous", previous), 200), nil

	case "/api/rhythm":
		return rt.rhythm(ctx, site, query, ranged)

	case "/api/journeys":
		q := u.SearchParams()
		through := throughStep.FindStringSubmatch(q.Value("through"))
		// Journeys reads the newest visits up to a cap; say when it was reached.
		rows, sampled, err := r.Store.JourneyPages(ctx, query, PagesPerVisit)
		if err != nil {
			return nil, err
		}
		steps := 5.0
		if v, has := q.Get("steps"); has {
			steps = js.Number(v)
		}
		options := JourneyOptions{Steps: steps, Start: q.Value("start"), End: q.Value("end")}
		if through != nil {
			options.Through = &JourneyThrough{Step: js.Number(through[1]), Value: through[2]}
		}
		answer := js.ToValue(Journeys(rows, options)).(*js.Object)
		out := js.NewObject("site", site.ID, "range", ranged)
		answer.Each(func(k string, v any) { out.Set(k, v) })
		if sampled {
			out.Set("sampled", JourneyVisits)
		}
		return jsonAnswer(out, 200), nil

	case "/api/funnels":
		funnels, err := r.Store.Funnels(ctx, site.ID)
		if err != nil {
			return nil, err
		}
		// One funnel at a time, so a page of funnels never takes every database connection at once.
		rows := []any{}
		for _, funnel := range funnels {
			counts, err := r.Store.FunnelCounts(ctx, query, funnel)
			if err != nil {
				return nil, err
			}
			row := js.ToValue(funnel).(*js.Object)
			steps := []any{}
			for i, step := range funnel.Steps {
				steps = append(steps, js.NewObject("kind", step.Kind, "match", step.Match, "visits", counts[i]))
			}
			row.Set("steps", steps)
			rows = append(rows, row)
		}
		return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "funnels", rows), 200), nil

	case "/api/event-props":
		event, _ := queryValue(u, "event")
		if event == "" {
			return Coded("Name the event", "event_needed", 400, nil), nil
		}
		keys, err := r.Store.EventPropKeys(ctx, query, event)
		if err != nil {
			return nil, err
		}
		askedKey, hasKey := queryValue(u, "key")
		// A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
		if hasKey && !propName64.MatchString(askedKey) {
			return Coded("Bad property name", "property_bad", 400, nil), nil
		}
		var key any
		if hasKey {
			key = askedKey
		} else if len(keys) > 0 {
			key = keys[0].Key
		}
		limit := clampedNumber(u, "limit", 100)
		rows := []PropValue{}
		if k, isString := key.(string); isString && k != "" {
			if rows, err = r.Store.EventPropValues(ctx, query, event, k, limit); err != nil {
				return nil, err
			}
		}
		return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "event", event, "keys", keys, "key", key, "rows", rows), 200), nil

	case "/api/breakdown":
		dimension, _ := queryValue(u, "dimension")
		if !IsDimension(dimension) {
			return Coded(`Unknown dimension "`+dimension+`"`, "unknown_dimension", 400, params("dimension", dimension)), nil
		}
		limit := clampedNumber(u, "limit", 10)
		pageNumber := 1.0
		if v, has := queryValue(u, "page"); has {
			if n := js.Number(v); !math.IsNaN(n) && n != 0 {
				pageNumber = math.Max(1, n)
			}
		}
		rows, err := r.Store.Breakdown(ctx, query, dimension, limit, int((pageNumber-1)*float64(limit)))
		if err != nil {
			return nil, err
		}
		if format, _ := queryValue(u, "format"); format == "csv" {
			return download(site.ID+"-"+dimension+"-"+rng.FromDate+"-"+rng.ToDate+".csv", []byte(rowsCsv(rows, site.Timezone, "", dimension)), "text/csv; charset=utf-8"), nil
		}
		return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "dimension", dimension, "rows", rows), 200), nil

	case "/api/export":
		return rt.export(ctx, site, query, rng, compared, previousQuery)
	}

	if goalPath.MatchString(path) {
		goal, err := r.Store.GoalByID(ctx, path[len("/api/goals/"):])
		if err != nil {
			return nil, err
		}
		if goal == nil || goal.Site != site.ID {
			return Coded("Unknown goal", "unknown_goal", 404, nil), nil
		}
		visitors, err := r.Store.Visitors(ctx, query)
		if err != nil {
			return nil, err
		}
		totals, err := r.Store.GoalTotals(ctx, query, *goal)
		if err != nil {
			return nil, err
		}
		series, err := r.Store.GoalSeries(ctx, query.Site, query.Filters, *goal, Buckets(rng, site.Timezone))
		if err != nil {
			return nil, err
		}
		out := js.NewObject("site", site.ID, "range", ranged, "goal", goal,
			"totals", js.NewObject("conversions", totals.Conversions, "visitors", totals.Visitors, "revenue", totals.Revenue, "rate", rate(totals.Visitors, visitors)),
			"series", series)
		for _, pair := range [][2]string{{"sources", "source"}, {"channels", "channel"}, {"pages", "path"}} {
			rows, err := r.Store.GoalBreakdown(ctx, query, *goal, pair[1], 10)
			if err != nil {
				return nil, err
			}
			out.Set(pair[0], rows)
		}
		return jsonAnswer(out, 200), nil
	}
	return Coded("Not found", "not_found", 404, nil), nil
}

// clampedNumber is Math.min(1000, Math.max(1, Number(value) || fallback)), as a whole number.
func clampedNumber(u *whatwg.URL, name string, fallback float64) int {
	n := fallback
	if v, has := queryValue(u, name); has {
		if parsed := js.Number(v); !math.IsNaN(parsed) && parsed != 0 {
			n = parsed
		}
	}
	return int(math.Min(1000, math.Max(1, n)))
}

func rate(part, whole int64) float64 {
	if whole == 0 {
		return 0
	}
	return float64(part) / float64(whole)
}

func (rt *Routes) rhythm(ctx context.Context, site SiteRow, query Query, ranged *js.Object) (*Response, error) {
	// Visits per weekday and hour, plus each cell's details for its tooltip. Visitors are summed over the
	// hours folded into a cell, so someone who came on two Tuesdays at 2pm counts twice there.
	var grid [7][24]int64
	type cell struct{ visits, visitors, pageviews, bounced int64 }
	var cells [7][24]cell
	rows, err := rt.r.Store.Hourly(ctx, query)
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		weekday, h := LocalWeekdayHour(row.Quarter*900_000, site.Timezone)
		grid[weekday][h] += row.Visits
		c := &cells[weekday][h]
		c.visits += row.Visits
		c.visitors += row.Visitors
		c.pageviews += row.Pageviews
		c.bounced += row.Bounced
	}
	gridOut := []any{}
	details := []any{}
	for d := 0; d < 7; d++ {
		day := []any{}
		hours := []any{}
		for h := 0; h < 24; h++ {
			day = append(day, grid[d][h])
			c := cells[d][h]
			hours = append(hours, js.NewObject("visits", c.visits, "visitors", c.visitors, "pageviews", c.pageviews, "bounceRate", rate(c.bounced, c.visits)))
		}
		gridOut = append(gridOut, day)
		details = append(details, hours)
	}
	return jsonAnswer(js.NewObject("site", site.ID, "range", ranged, "grid", gridOut, "cells", details), 200), nil
}

// export is everything the dashboard shows for a view, as a ZIP of CSV files.
func (rt *Routes) export(ctx context.Context, site SiteRow, query Query, rng Range, compared *Range, previousQuery Query) (*Response, error) {
	r := rt.r
	files := []ZipFile{}
	stats, err := r.Store.Stats(ctx, query)
	if err != nil {
		return nil, err
	}
	now := sheetRow(js.ToValue(stats).(*js.Object), site.Timezone, "", "")
	var before *js.Object
	if compared != nil {
		previous, err := r.Store.Stats(ctx, previousQuery)
		if err != nil {
			return nil, err
		}
		before = sheetRow(js.ToValue(previous).(*js.Object), site.Timezone, "", "")
	}
	header := []string{"metric", "value"}
	if before != nil {
		header = append(header, "previous")
	}
	rows := [][]any{}
	for _, m := range now.Keys() {
		row := []any{m, now.Value(m)}
		if before != nil {
			row = append(row, undefinedIfMissing(before, m, before.Value(m)))
		}
		rows = append(rows, row)
	}
	files = append(files, ZipFile{"overview.csv", Csv(header, rows)})
	points, err := r.Store.Series(ctx, query.Site, query.Filters, Buckets(rng, site.Timezone))
	if err != nil {
		return nil, err
	}
	files = append(files, ZipFile{"over-time.csv", rowsCsv(points, site.Timezone, rng.Interval, "")})
	for _, dimension := range Dimensions {
		rows, err := r.Store.Breakdown(ctx, query, dimension, 1000, 0)
		if err != nil {
			return nil, err
		}
		if len(rows) > 0 {
			files = append(files, ZipFile{dimension + ".csv", rowsCsv(rows, site.Timezone, "", dimension)})
		}
	}
	goals, err := r.Store.Goals(ctx, site.ID)
	if err != nil {
		return nil, err
	}
	if len(goals) > 0 {
		totals, err := r.Store.GoalTotalsAll(ctx, query, goals)
		if err != nil {
			return nil, err
		}
		rows := [][]any{}
		for _, g := range goals {
			t := totals[g.ID]
			rows = append(rows, []any{g.Name, t.Conversions, t.Visitors, t.Revenue, g.Currency})
		}
		files = append(files, ZipFile{"goals.csv", Csv([]string{"goal", "conversions", "visitors", "revenue", "currency"}, rows)})
	}
	return download(site.ID+"-"+rng.FromDate+"-"+rng.ToDate+".zip", Zip(files, r.now()), "application/zip"), nil
}

// Handle answers one request to the routes.
func (rt *Routes) Handle(ctx context.Context, request *Request) *Response {
	answer, err := rt.handle(ctx, request)
	if err != nil {
		rt.r.logf("Runlight: %v", err)
		return Coded("Internal error", "internal", 500, nil)
	}
	return answer
}

func (rt *Routes) handle(ctx context.Context, request *Request) (answer *Response, err error) {
	defer func() {
		if p := recover(); p != nil {
			answer, err = nil, fmt.Errorf("panic: %v", p)
		}
	}()
	r := rt.r
	u := request.Parsed()
	c := &call{ctx: ctx, req: request}
	// OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
	if rt.base != "" && isOauthDocument(u.Pathname) {
		answer, err := rt.oauth.respond(c, u.Pathname, u)
		if err != nil || answer != nil {
			return answer, err
		}
		return Coded("Not found", "not_found", 404, nil), nil
	}
	if rt.base != "" && u.Pathname != rt.base && !strings.HasPrefix(u.Pathname, rt.base+"/") {
		return Coded("Not found", "not_found", 404, nil), nil
	}
	path := firstNonEmpty(u.Pathname[len(rt.base):], "/")

	// Checked before any route, so a connected site's pass-through to its install is held to it too.
	if adminOnly(path, request.Method) && rt.canRead(c) == canFull && c.member {
		return Coded("Only an owner or admin can change this", "admin_only", 403, nil), nil
	}
	// Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone signed out to sign in.
	if rt.web != nil {
		answered, err := rt.web.Handle(ctx, request, path)
		if err != nil || answered != nil {
			return answered, err
		}
	}
	if path == "/s.js" && request.Method == "GET" {
		script, err := rt.trackerScript(ctx, optionalQuery(u, "site"))
		if err != nil {
			return nil, err
		}
		// Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
		headers := []string{"content-type", "application/javascript; charset=utf-8", "cache-control", "public, max-age=300", "etag", script.etag}
		if v, has := request.Header.Lookup("if-none-match"); has && v == script.etag {
			return web.NewResponse(304, nil, headers...), nil
		}
		return web.NewResponse(200, []byte(script.body), headers...), nil
	}
	if path == "/pick.js" && request.Method == "GET" {
		// The picker sends what it picked only to the dashboard its ticket names; without a good ticket it does
		// nothing. It also runs only on the pages of the site the ticket names.
		ticket, _ := queryValue(u, "runlight_ticket")
		origin, siteID, found, err := rt.pickTarget(ctx, ticket)
		if err != nil {
			return nil, err
		}
		var hosts []string
		haveHosts := true
		if found {
			if err := r.Init(ctx); err != nil {
				return nil, err
			}
			site, known := r.Site(siteID)
			if known {
				hosts = site.Hostnames
			} else {
				haveHosts = false
			}
		} else {
			hosts = []string{}
		}
		target := ""
		if haveHosts {
			target = origin
		}
		if hosts == nil {
			hosts = []string{}
		}
		script := strings.Replace(assets.Picker, pickTargetPlaceholder, js.Stringify(target), 1)
		script = strings.Replace(script, pickHostsPlaceholder, js.Stringify(js.Stringify(hosts)), 1)
		return web.NewResponse(200, []byte(script), "content-type", "application/javascript; charset=utf-8", "cache-control", "no-store"), nil
	}
	if path == "/assets/world."+assets.Build.WorldHash+".json" && request.Method == "GET" {
		return web.NewResponse(200, []byte(assets.WorldJSON), "content-type", "application/json; charset=utf-8", "cache-control", "public, max-age=31536000, immutable"), nil
	}
	if m := localePath.FindStringSubmatch(path); m != nil && m[2] == assets.Build.LocalesHash && m[1] != "en" && request.Method == "GET" {
		if text, has := assets.Locales[m[1]]; has {
			return web.NewResponse(200, []byte(text), "content-type", "application/json; charset=utf-8", "cache-control", "public, max-age=31536000, immutable"), nil
		}
	}
	if strings.HasPrefix(path, "/assets/app.") && request.Method == "GET" {
		var asset string
		switch path {
		case "/assets/app." + assets.Build.DashboardHash + ".js":
			asset = assets.DashboardJS
		case "/assets/app." + assets.Build.DashboardHash + ".css":
			asset = assets.DashboardCSS
		default:
			return Coded("Not found", "not_found", 404, nil), nil
		}
		contentType := "text/css; charset=utf-8"
		if strings.HasSuffix(path, ".js") {
			contentType = "application/javascript; charset=utf-8"
		}
		return web.NewResponse(200, []byte(asset), "content-type", contentType, "cache-control", "public, max-age=31536000, immutable"), nil
	}
	if path == "/e" {
		if request.Method == "OPTIONS" {
			return web.NewResponse(204, nil, "access-control-allow-origin", "*", "access-control-allow-methods", "POST", "access-control-max-age", "86400"), nil
		}
		if request.Method != "POST" {
			return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
		}
		if err := r.Collect(ctx, request); err != nil {
			r.logf("Runlight: could not record an event %v", err)
		}
		// The same answer whatever happened, so the endpoint reveals nothing.
		return web.NewResponse(202, nil, "access-control-allow-origin", "*"), nil
	}
	if path == "/api" || strings.HasPrefix(path, "/api/") {
		return rt.api(c, path, u)
	}
	if strings.HasPrefix(path, "/oauth/") || isOauthDocument(path) {
		answer, err := rt.oauth.respond(c, path, u)
		if err != nil || answer != nil {
			return answer, err
		}
	}
	if path == "/mcp" {
		return rt.mcp(c, u)
	}
	if m := unsubPath.FindStringSubmatch(path); m != nil && (request.Method == "GET" || request.Method == "POST") {
		return rt.unsubscribePage(ctx, request, m[1])
	}
	// The dashboard inside a CMS's admin pages, opened with a ticket its plugin just got. Only the admin origin
	// the ticket names may frame it. A ticket used already or run out opens it with no session, so it says it
	// has expired and offers to reload the admin page; anything else is refused and never framed.
	if path == "/embed" && request.Method == "GET" {
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		ticket, _ := queryValue(u, "ticket")
		origin, token, found, err := rt.redeemEmbed(ctx, ticket)
		if err != nil {
			return nil, err
		}
		if !found {
			tr := NewTranslator(acceptedLanguage(request))
			return smallPage(tr.Lang, "<h1>"+escapeHTML(tr.T("embed.goneTitle", nil))+"</h1><p>"+escapeHTML(tr.T("embed.gone", nil))+"</p>", 404), nil
		}
		session := ""
		if token != nil {
			if session, err = rt.embedSession(ctx, token.ID); err != nil {
				return nil, err
			}
		}
		status := 410
		if session != "" {
			status = 200
		}
		return web.NewResponse(status, []byte(dashboardPage(rt.base, "", "", rt.options.GeoCredit, false, "", &embedded{session: session, origin: origin})),
			"content-type", "text/html; charset=utf-8", "cache-control", "no-store",
			"content-security-policy", strings.Replace(dashboardCSP, "frame-ancestors 'none'", "frame-ancestors "+origin, 1),
			"referrer-policy", "no-referrer", "x-robots-tag", "noindex"), nil
	}
	if m := sharePage.FindStringSubmatch(path); m != nil && request.Method == "GET" {
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		var share *ShareRow
		if shareID.MatchString(m[1]) {
			var err error
			if share, err = r.Store.ShareByID(ctx, m[1]); err != nil {
				return nil, err
			}
		}
		if share == nil {
			tr := NewTranslator(acceptedLanguage(request))
			return smallPage(tr.Lang, "<h1>"+escapeHTML(tr.T("share.goneTitle", nil))+"</h1><p>"+escapeHTML(tr.T("share.gone", nil))+"</p>", 404), nil
		}
		return web.NewResponse(200, []byte(dashboardPage(rt.base, share.ID, "", rt.options.GeoCredit, false, "", nil)),
			"content-type", "text/html; charset=utf-8", "cache-control", "no-store", "content-security-policy", dashboardCSP, "x-frame-options", "DENY",
			// The share id is the key; never send it on to another site.
			"referrer-policy", "no-referrer", "x-robots-tag", "noindex"), nil
	}
	if (path == "/" || path == "") && request.Method == "GET" {
		given, _ := queryValue(u, "token")
		if given != "" && rt.tokenSet && constantTimeEqual(given, rt.token) {
			q := u.SearchParams()
			q.Delete("token")
			u.SetSearchParams(q)
			secure := ""
			if u.Protocol == "https:" {
				secure = "; Secure"
			}
			return web.NewResponse(303, nil, "location", u.Pathname+u.Search,
				"set-cookie", tokenCookie+"="+cookieValue(rt.token)+"; Path="+firstNonEmpty(rt.base, "/")+"; HttpOnly; SameSite=Lax; Max-Age=2592000"+secure), nil
		}
		// The page itself holds no data; the API it calls checks access and the page explains how to sign in when it is refused.
		return web.NewResponse(200, []byte(dashboardPage(rt.base, "", rt.signOut, rt.options.GeoCredit, rt.web != nil, rt.signIn, nil)),
			"content-type", "text/html; charset=utf-8", "cache-control", "no-store", "content-security-policy", dashboardCSP, "x-frame-options", "DENY", "referrer-policy", "same-origin"), nil
	}
	return Coded("Not found", "not_found", 404, nil), nil
}

// dateParse is Date.parse for the forms log readers send: ISO 8601, with or without a zone.
func dateParse(text string) (float64, bool) {
	for _, layout := range dateLayouts {
		if t, err := parseTime(layout, text); err == nil {
			return float64(t), true
		}
	}
	return math.NaN(), false
}
