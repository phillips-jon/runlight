package runlight

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"
	"sync"
	"time"

	"runlight.sh/go/internal/assets"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Access is what a request may do: everything, everything but the
// install-wide controls (a member), read only, or nothing.
type Access string

const (
	// AccessNone refuses the request.
	AccessNone Access = ""
	// AccessFull is full access, as the owner.
	AccessFull Access = "full"
	// AccessMember changes everything but the install-wide controls (the
	// mail service, the assistant's settings, and deleting a site).
	AccessMember Access = "member"
	// AccessRead reads every site's stats and changes nothing, as an API token can.
	AccessRead Access = "read"
)

// RoutesOptions configure the dashboard and API.
type RoutesOptions struct {
	// BasePath is where the routes are mounted. nil is "/runlight".
	BasePath *string
	// Token is required to read stats. Send it as Authorization: Bearer
	// <token>, or open the dashboard once with ?token=<token> and a cookie is
	// set. nil reads RUNLIGHT_TOKEN. Without one, the dashboard and API are
	// open only when NODE_ENV is development, and answer 503 everywhere else.
	Token *string
	// Open leaves the dashboard and API open everywhere, for example behind
	// your own auth middleware. Token is then ignored.
	Open bool
	// Authorize is your own check instead of a token.
	Authorize func(ctx context.Context, request *Request) Access
	// CronSecret is also accepted as a bearer token on POST /api/check, so a
	// platform cron can run scheduled work. nil reads CRON_SECRET.
	CronSecret *string
	// ObserveKey lets another site report AI agent fetches to POST
	// /api/observe without the dashboard token. nil reads RUNLIGHT_OBSERVE_KEY.
	ObserveKey *string
	// SignOut is a link to sign out, shown in the dashboard's footer.
	SignOut string
	// SignIn is where to sign in: an app connecting over OAuth sends the
	// owner here first, and the dashboard links here when a session ends.
	SignIn string
	// Accounts turns on sign-in accounts for the dashboard.
	Accounts bool
	// AccountsWeb is the accounts the standalone server passes in.
	AccountsWeb *AccountsWeb
	// GeoCredit credits DB-IP in the dashboard's footer, as its free location data asks.
	GeoCredit bool
	// Origin is the address people open the app at, such as
	// https://example.com. A link domain can never be its host, and links in
	// email reports point there, whatever Host header a request carries.
	Origin string
	// OwnHosts are more names the dashboard is reached at, which can never be link domains either.
	OwnHosts func(ctx context.Context) []string
	// AccountOf is the account a request comes from, so the tokens someone
	// makes and the apps they connect are noted against them.
	AccountOf func(ctx context.Context, request *Request) string
	// TokenMade notes who made a token. False when they can no longer make one, which takes it back.
	TokenMade func(ctx context.Context, token TokenRow, by string) bool
}

// Routes are the dashboard and its API, the tracker's endpoint, and the
// pages that go with them.
type Routes struct {
	r          *Runlight
	options    RoutesOptions
	base       string
	token      string
	tokenSet   bool
	open       bool
	cronSecret string
	observeKey string
	origin     string
	web        *AccountsWeb
	signIn     string
	signOut    string
	accountOf  func(ctx context.Context, request *Request) string
	tokenMade  func(ctx context.Context, token TokenRow, by string) bool
	oauth      *oauthHost

	mu         sync.Mutex
	warned     bool
	sampleSent map[string]int64
	asked      map[string]*askCount
	trackers   map[string]trackerScript
}

type askCount struct {
	at   []int64
	open int
}

type trackerScript struct {
	body string
	etag string
	at   int64
}

// call is one request's own state: whether a manage token or a member made it.
type call struct {
	ctx     context.Context
	req     *Request
	managed *TokenRow
	member  bool
}

// Routes are the dashboard and API on this install.
func (r *Runlight) Routes(options RoutesOptions) (*Routes, error) {
	base := "/runlight"
	if options.BasePath != nil {
		base = *options.BasePath
	}
	rt := &Routes{r: r, options: options, base: normaliseBase(base), sampleSent: map[string]int64{}, asked: map[string]*askCount{}, trackers: map[string]trackerScript{}}
	switch {
	case options.Open:
		rt.open = true
	case options.Token != nil:
		rt.token, rt.tokenSet = *options.Token, *options.Token != ""
	default:
		rt.token, rt.tokenSet = envValue("RUNLIGHT_TOKEN")
	}
	if options.CronSecret != nil {
		rt.cronSecret = *options.CronSecret
	} else {
		rt.cronSecret, _ = envValue("CRON_SECRET")
	}
	if options.ObserveKey != nil {
		rt.observeKey = *options.ObserveKey
	} else {
		rt.observeKey, _ = envValue("RUNLIGHT_OBSERVE_KEY")
	}
	if options.Origin != "" {
		u, err := whatwg.Parse(options.Origin)
		if err != nil {
			return nil, fmt.Errorf("Runlight: origin %q is not a URL", options.Origin)
		}
		rt.origin = u.Origin()
	}
	// A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
	r.mu.Lock()
	r.routeBases[firstNonEmpty(rt.base, "/")] = true
	r.mu.Unlock()

	// Accounts: the standalone server passes its own, and an app turns them on with true. Sessions need a
	// secret that outlives the process; in development without one, a made-up one does, so a restart signs
	// everyone out. An app left open on purpose is treated like development here.
	openSetup := rt.open || (!rt.tokenSet && isDevelopment())
	secret, hasSecret := r.Secret, r.HasSecret
	if !hasSecret && openSetup {
		secret, hasSecret = randomID(32), true
	}
	switch {
	case options.AccountsWeb != nil:
		rt.web = options.AccountsWeb
	case options.Accounts && hasSecret:
		first := FirstAccount{Mode: "locked"}
		if rt.tokenSet {
			first = FirstAccount{Mode: "token", Token: rt.token}
		} else if openSetup {
			first = FirstAccount{Mode: "open"}
		}
		web := AccountsWebOptions{Runlight: r, Secret: secret, Base: rt.base, Now: r.now, FirstAccount: first, Forgot: "https://runlight.sh/docs/configuration/#accounts"}
		if rt.origin != "" {
			origin := rt.origin
			web.Home = func(context.Context) string { return origin }
		}
		rt.web = NewAccountsWeb(web)
	}
	rt.signIn = options.SignIn
	if rt.signIn == "" && rt.web != nil {
		rt.signIn = rt.base + "/login"
	}
	rt.signOut = options.SignOut
	if rt.signOut == "" && rt.web != nil {
		rt.signOut = rt.base + "/logout"
	}
	rt.accountOf = options.AccountOf
	if rt.accountOf == nil && rt.web != nil {
		rt.accountOf = rt.web.AccountOf
	}
	rt.tokenMade = options.TokenMade
	if rt.tokenMade == nil && rt.web != nil {
		rt.tokenMade = rt.web.TokenMade
	}
	rt.oauth = &oauthHost{
		r:    r,
		base: rt.base,
		isOwner: func(ctx context.Context, request *Request) bool {
			return rt.canRead(&call{ctx: ctx, req: request}) == canFull
		},
		isReader: func(ctx context.Context, request *Request) bool {
			if options.Authorize != nil {
				return options.Authorize(ctx, request) == AccessRead
			}
			if rt.web != nil {
				return rt.web.Access(ctx, request) == AccessRead
			}
			return false
		},
		signIn:    rt.signIn,
		accountOf: rt.accountOf,
		tokenMade: rt.tokenMade,
	}
	return rt, nil
}

// Base is where the routes are mounted, "" for the root.
func (rt *Routes) Base() string { return rt.base }

// canResult is what canRead found.
type canResult int

const (
	canNo canResult = iota
	canFull
	canUnconfigured
	canReadOnly
)

// canRead says whether this request acts as the owner. canReadOnly is
// someone signed in who may only read, such as a viewer.
func (rt *Routes) canRead(c *call) canResult {
	if c.managed != nil {
		return canFull
	}
	if rt.options.Authorize != nil || rt.web != nil {
		// A script's bearer token still has full access beside the sign-ins.
		given := bearer(c.req)
		if rt.options.Authorize == nil && rt.tokenSet && given != "" && constantTimeEqual(given, rt.token) {
			return canFull
		}
		var answer Access
		if rt.options.Authorize != nil {
			answer = rt.options.Authorize(c.ctx, c.req)
		} else {
			answer = rt.web.Access(c.ctx, c.req)
		}
		// A member changes things like an owner, apart from the few controls adminOnly names.
		if answer == AccessMember {
			c.member = true
		}
		switch answer {
		case AccessRead:
			return canReadOnly
		case AccessFull, AccessMember:
			return canFull
		}
		return canNo
	}
	if rt.open {
		return canFull
	}
	if !rt.tokenSet {
		// Fails closed: only a process that says it is in development runs open.
		if !isDevelopment() {
			return canUnconfigured
		}
		rt.mu.Lock()
		if !rt.warned {
			rt.warned = true
			rt.r.logf("Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.")
		}
		rt.mu.Unlock()
		return canFull
	}
	given := bearer(c.req)
	if given != "" && constantTimeEqual(given, rt.token) {
		return canFull
	}
	cookie := readCookie(c.req, tokenCookie)
	if cookie != "" && constantTimeEqual(cookie, cookieValue(rt.token)) {
		return canFull
	}
	return canNo
}

// apiToken is an API token from the bearer header: read-only, and maybe limited to one site.
func (rt *Routes) apiToken(c *call) (*TokenRow, error) {
	given := bearer(c.req)
	if !strings.HasPrefix(given, tokenPrefix) {
		return nil, nil
	}
	if err := rt.r.Init(c.ctx); err != nil {
		return nil, err
	}
	row, err := rt.r.Store.TokenByHash(c.ctx, sha256Hex(given))
	if err != nil || row == nil {
		return nil, err
	}
	now := rt.r.now()
	// At most once a minute, so a busy assistant does not write on every call.
	if row.LastUsedAt == nil || now-*row.LastUsedAt > 60_000 {
		if err := rt.r.Store.TouchToken(c.ctx, row.ID, now); err != nil {
			return nil, err
		}
	}
	return row, nil
}

// readerResult is who may read stats: the owner (full), an API token or a
// read-only sign-in (token), or nobody (no, or unconfigured).
type readerResult struct {
	full         bool
	token        *TokenRow
	unconfigured bool
}

func (a readerResult) refused() bool { return !a.full && a.token == nil }

func (rt *Routes) reader(c *call) (readerResult, error) {
	token, err := rt.apiToken(c)
	if err != nil {
		return readerResult{}, err
	}
	if token != nil {
		return readerResult{token: token}, nil
	}
	access := rt.canRead(c)
	if rt.options.Authorize != nil || rt.web != nil {
		// A read-only sign-in reads like an API token for every site.
		if access == canReadOnly {
			return readerResult{token: &TokenRow{Scope: "read"}}, nil
		}
		return readerResult{full: access == canFull}, nil
	}
	return readerResult{full: access == canFull, unconfigured: access == canUnconfigured}, nil
}

// originNeeded is the refusal for a hub that asks for something only safe once this app knows its own address.
func originNeeded() *Response {
	return Coded("Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.", "origin_needed", 400, nil)
}

func denied(result canResult) *Response {
	switch result {
	case canReadOnly:
		return Coded("Only an owner can change this", "owner_only", 403, nil)
	case canUnconfigured:
		return Coded("Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.", "token_unset", 503, nil)
	}
	return Coded("Unauthorized", "unauthorized", 401, nil)
}

func deniedReader(a readerResult) *Response {
	if a.unconfigured {
		return denied(canUnconfigured)
	}
	return denied(canNo)
}

func (rt *Routes) querySite(u *whatwg.URL) (SiteRow, *Response) {
	id, _ := queryValue(u, "site")
	site, ok := rt.r.Site(id)
	if !ok {
		return SiteRow{}, Coded("Unknown site", "unknown_site", 404, nil)
	}
	return site, nil
}

type readQuery struct {
	query    Query
	rng      Range
	compared *Range
}

func optionalQuery(u *whatwg.URL, name string) *string {
	if v, ok := queryValue(u, name); ok {
		return &v
	}
	return nil
}

func (rt *Routes) readQuery(ctx context.Context, u *whatwg.URL, site SiteRow) (*readQuery, *Response, error) {
	q := u.SearchParams()
	filters := []Filter{}
	raws := q.GetAll("filter")
	if len(raws) > MaxFilters {
		return nil, Coded(fmt.Sprintf("Use at most %d filters at once.", MaxFilters), "filters_max", 400, params("max", fmt.Sprint(MaxFilters))), nil
	}
	for _, raw := range raws {
		filter := ParseFilter(raw)
		if filter == nil {
			return nil, Coded(`Bad filter "`+raw+`". Use dimension:is|not|contains:value.`, "filter_bad", 400, params("filter", raw)), nil
		}
		filters = append(filters, *filter)
	}
	now := rt.r.now()
	firstDate := ""
	if period, _ := q.Get("period"); period == "all" {
		first, err := rt.r.Store.FirstSeen(ctx, site.ID)
		if err != nil {
			return nil, nil, err
		}
		if first != nil {
			firstDate = LocalDate(*first, site.Timezone)
		}
	}
	rng := ResolveRange(RangeInput{Period: optionalQuery(u, "period"), From: optionalQuery(u, "from"), To: optionalQuery(u, "to"), Interval: optionalQuery(u, "interval")}, site.Timezone, now, firstDate)
	if rng == nil {
		return nil, Coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400, nil), nil
	}
	query := Query{Site: site.ID, From: rng.From, To: rng.To, Filters: filters}
	// compare=false is the older spelling of off.
	raw, ok := q.Get("compare")
	if !ok {
		raw = "previous"
	}
	mode := raw
	if raw == "false" {
		mode = "off"
	}
	if mode != "previous" && mode != "year" && mode != "custom" && mode != "off" {
		return nil, Coded(`Bad compare "`+raw+`". Use previous, year, custom, or off.`, "compare_bad", 400, params("compare", raw)), nil
	}
	compared := CompareRange(*rng, mode, site.Timezone, q.Value("compare_from"), q.Value("compare_to"))
	if mode == "custom" && compared == nil {
		return nil, Coded("Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.", "compare_range_bad", 400, nil), nil
	}
	return &readQuery{query: query, rng: *rng, compared: compared}, nil, nil
}

// readJSON is the request's JSON object, or the refusal.
func readJSON(request *Request) (*js.Object, *Response) {
	// A form posted from another site cannot carry this content type without CORS.
	if !isJSON(request) {
		return nil, Coded("Send JSON", "send_json", 415, nil)
	}
	body, err := request.JSON()
	if o, ok := body.(*js.Object); err == nil && ok {
		return o, nil
	}
	return nil, Coded("Send a JSON object", "send_object", 400, nil)
}

var (
	domainScheme = regexp.MustCompile(`^https?://`)
	domainPath   = regexp.MustCompile(`/.*$`)
	domainDots   = regexp.MustCompile(`\.+$`)
	checkPath    = regexp.MustCompile(`^/api/link-domains/([^/]+)/check$`)
	domainOne    = regexp.MustCompile(`^/api/link-domains/([^/]+)$`)
	importPath   = regexp.MustCompile(`^/api/links/import/([a-z]+)$`)
	linkPathRe   = regexp.MustCompile(`^/api/links/([a-f0-9]+)$`)
)

func (rt *Routes) linksAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request := c.ctx, c.req
	if err := rt.r.Init(ctx); err != nil {
		return nil, err
	}
	site, refused := rt.querySite(u)
	if refused != nil {
		return refused, nil
	}
	answer, err := rt.linksRoutes(c, path, u, site)
	if err != nil {
		var le *LinkError
		if errors.As(err, &le) {
			return Coded(le.Message, le.Code, 400, le.Params), nil
		}
		if isRangeError(err) {
			return Coded(err.Error(), "unknown_link", 404, nil), nil
		}
		return nil, err
	}
	if answer != nil {
		return answer, nil
	}
	_ = request
	return Coded("Not found", "not_found", 404, nil), nil
}

func (rt *Routes) siteDomains(ctx context.Context, site string) ([]string, error) {
	list, err := rt.r.Store.LinkDomains(ctx)
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, d := range list {
		if d.Site == site {
			out = append(out, d.Domain)
		}
	}
	return out, nil
}

func (rt *Routes) linksRoutes(c *call, path string, u *whatwg.URL, site SiteRow) (*Response, error) {
	ctx, request := c.ctx, c.req
	if path == "/api/link-domains" {
		if request.Method == "GET" {
			domains, err := rt.siteDomains(ctx, site.ID)
			if err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("domains", domains), 200), nil
		}
		if request.Method == "POST" {
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			domain := lower(jsTrim(field(body, "domain")))
			domain = domainScheme.ReplaceAllString(domain, "")
			domain = domainPath.ReplaceAllString(domain, "")
			domain = domainDots.ReplaceAllString(domain, "")
			domain = strings.TrimPrefix(domain, "www.")
			if !isDomainName(domain) {
				return Coded("That is not a domain name", "domain_invalid", 400, nil), nil
			}
			if privateName(domain) || web.ResolvesPrivately(ctx, domain) {
				return Coded(domain+" is not a public domain name. Use one that browsers anywhere can reach.", "domain_not_public", 400, params("domain", domain)), nil
			}
			// A link domain answers every path on it, so it must never be where the dashboard or a counted site
			// lives. The request's own Host is the caller's to choose, so the configured address and the names
			// people signed in from count too. A hub cannot know every name this app answers on, so it adds none
			// until the app knows its own address.
			if c.managed != nil && rt.origin == "" {
				return originNeeded(), nil
			}
			own := []string{}
			if rt.origin != "" {
				own = append(own, whatwg.MustParse(rt.origin).Host())
			}
			for _, name := range []string{"host", "x-forwarded-host"} {
				if v := request.Header.Get(name); v != "" {
					own = append(own, v)
				}
			}
			if h := u.Host(); h != "" {
				own = append(own, h)
			}
			if rt.options.OwnHosts != nil {
				own = append(own, rt.options.OwnHosts(ctx)...)
			}
			taken := map[string]bool{}
			for _, h := range own {
				taken[HostName(h)] = true
			}
			for _, s := range rt.r.Sites() {
				for _, h := range s.Hostnames {
					taken[h] = true
				}
				if remote, ok := rt.r.Remote(s.ID); ok {
					for _, h := range remote.Hostnames {
						taken[h] = true
					}
				}
			}
			if taken[domain] {
				return Coded(domain+" is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go."+domain+".", "domain_in_use", 400, params("domain", domain)), nil
			}
			list, err := rt.r.Store.LinkDomains(ctx)
			if err != nil {
				return nil, err
			}
			for _, d := range list {
				if d.Domain == domain && d.Site != site.ID {
					return Coded(domain+" already belongs to another site", "domain_taken", 409, params("domain", domain)), nil
				}
			}
			if err := rt.r.Store.AddLinkDomain(ctx, domain, site.ID, rt.r.now()); err != nil {
				return nil, err
			}
			rt.r.ForgetLinkDomains()
			return jsonAnswer(js.NewObject("domain", domain), 201), nil
		}
	}
	if m := checkPath.FindStringSubmatch(path); m != nil && request.Method == "GET" {
		domain, ok := decodeURIComponent(m[1])
		if !ok {
			return nil, errors.New("URIError: URI malformed")
		}
		domains, err := rt.siteDomains(ctx, site.ID)
		if err != nil {
			return nil, err
		}
		if !contains(domains, domain) {
			return Coded("Unknown domain", "unknown_domain", 404, nil), nil
		}
		// Where the domain should point, for the setup steps: this server's name, and its public addresses
		// for a bare domain, which takes an A record. A server reached by its address has no name to give.
		own := u.Hostname
		if rt.origin != "" {
			own = whatwg.MustParse(rt.origin).Hostname
		}
		target := js.NewObject("host", own, "addresses", web.PublicAddresses(ctx, own))
		result := func(code, reason string, p *js.Object) *Response {
			out := js.NewObject("domain", domain, "working", code == "", "reason", reason, "target", target)
			if code != "" {
				out.Set("code", code)
				if p != nil {
					out.Set("params", p)
				}
			}
			return jsonAnswer(out, 200)
		}
		if !isDomainName(domain) || privateName(domain) {
			return result("check_not_public", "is not a public domain name", nil), nil
		}
		// Only a public address is fetched, whatever the name resolves to now, so the check cannot be pointed
		// into a private network.
		answer, err := web.PublicFetch(ctx, rt.r.fetcher, "https://"+domain+LinkDomainCheck, &Headers{}, 5*time.Second, 0, 1<<20, false)
		if err != nil {
			// A refused private address answers as a closed port does, so the check tells nothing about a private network.
			if web.IsTimeout(err) {
				return result("check_timeout", "timed out", nil), nil
			}
			return result("check_https", "could not connect over HTTPS", nil), nil
		}
		body, _ := answer.JSON()
		if answer.OK() && js.Dig(body, "runlight") == true && js.Dig(body, "domain") == domain {
			return result("", "", nil), nil
		}
		if answer.OK() {
			return result("check_not_runlight", "answered, but not from Runlight", nil), nil
		}
		return result("check_status", fmt.Sprintf("answered %d", answer.Status), params("status", fmt.Sprint(answer.Status))), nil
	}
	if m := domainOne.FindStringSubmatch(path); m != nil && request.Method == "DELETE" {
		domain, ok := decodeURIComponent(m[1])
		if !ok {
			return nil, errors.New("URIError: URI malformed")
		}
		domains, err := rt.siteDomains(ctx, site.ID)
		if err != nil {
			return nil, err
		}
		if !contains(domains, domain) {
			return Coded("Unknown domain", "unknown_domain", 404, nil), nil
		}
		if err := rt.r.Store.RemoveLinkDomain(ctx, domain); err != nil {
			return nil, err
		}
		rt.r.ForgetLinkDomains()
		return jsonAnswer(js.NewObject("ok", true), 200), nil
	}
	if path == "/api/links" {
		if request.Method == "GET" {
			read, refused, err := rt.readQuery(ctx, u, site)
			if err != nil || refused != nil {
				return refused, err
			}
			links, err := rt.r.Store.Links(ctx, site.ID, read.rng.From, read.rng.To)
			if err != nil {
				return nil, err
			}
			// Links on a removed domain are served from the app's own path until it is added back.
			domains, err := rt.siteDomains(ctx, site.ID)
			if err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("prefix", u.Origin()+rt.r.LinkPath, "domains", domains, "links", links), 200), nil
		}
		if request.Method == "POST" {
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			pick := func(key string) *string {
				v, ok := body.Get(key)
				if !ok {
					return nil
				}
				return ptr(js.String(v))
			}
			link, err := rt.r.Links.Create(ctx, site.ID, LinkInput{URL: field(body, "url"), Name: pick("name"), Slug: pick("slug"), Domain: pick("domain")})
			if err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("link", link), 201), nil
		}
	}
	// One step of an import from another shortener; the page calls again with the cursor.
	if m := importPath.FindStringSubmatch(path); m != nil && request.Method == "POST" {
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		credentials := map[string]string{}
		order := []string{}
		if cred, ok := body.Value("credentials").(*js.Object); ok {
			cred.Each(func(k string, v any) {
				credentials[k] = js.String(v)
				order = append(order, k)
			})
		}
		var cursor *string
		if s, ok := body.Value("cursor").(string); ok {
			cursor = &s
		}
		done := js.ToNumber(undefinedIfMissing(body, "done", body.Value("done")))
		if math.IsNaN(done) {
			done = 0
		}
		step, err := ImportStep(ctx, rt.r, site.ID, m[1], credentials, cursor, done)
		if err != nil {
			if isImportError(err) {
				return refusedAnswer(err, "import_failed", 400), nil
			}
			return nil, err
		}
		return jsonAnswer(step, 200), nil
	}
	if path == "/api/links/import" && request.Method == "POST" {
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		list, ok := body.Value("rows").([]any)
		if !ok {
			return Coded("Send rows as a list", "rows_needed", 400, nil), nil
		}
		// Rows that are not objects (null, a number) are dropped rather than failing the import.
		rows := []*js.Object{}
		for _, row := range list {
			if o, ok := row.(*js.Object); ok {
				rows = append(rows, o)
			}
		}
		if len(rows) > 5000 {
			rows = rows[:5000]
		}
		result, err := rt.r.Links.Import(ctx, site.ID, rows)
		if err != nil {
			return nil, err
		}
		return jsonAnswer(result, 200), nil
	}
	if m := linkPathRe.FindStringSubmatch(path); m != nil {
		id := m[1]
		if request.Method == "GET" {
			link, err := rt.r.Store.LinkByID(ctx, id)
			if err != nil {
				return nil, err
			}
			if link == nil || link.Site != site.ID {
				return Coded("Unknown link", "unknown_link", 404, nil), nil
			}
			read, refused, err := rt.readQuery(ctx, u, site)
			if err != nil || refused != nil {
				return refused, err
			}
			rng := read.rng
			series, err := rt.r.Store.LinkSeries(ctx, site.ID, id, Buckets(rng, site.Timezone))
			if err != nil {
				return nil, err
			}
			by := func(dimension string) ([]BreakdownRow, error) {
				return rt.r.Store.LinkBreakdown(ctx, site.ID, id, rng.From, rng.To, dimension, 10)
			}
			out := js.NewObject("link", link, "range", rangeOut(rng, site.Timezone))
			clicks := int64(0)
			for _, p := range series {
				clicks += p.Clicks
			}
			out.Set("clicks", clicks)
			out.Set("series", series)
			for _, pair := range [][2]string{{"sources", "source"}, {"referrers", "referrer"}, {"countries", "country"}, {"devices", "device"}, {"browsers", "browser"}} {
				rows, err := by(pair[1])
				if err != nil {
					return nil, err
				}
				out.Set(pair[0], rows)
			}
			return jsonAnswer(out, 200), nil
		}
		owned, err := rt.r.Store.LinkByID(ctx, id)
		if err != nil {
			return nil, err
		}
		if owned == nil || owned.Site != site.ID {
			return Coded("Unknown link", "unknown_link", 404, nil), nil
		}
		if request.Method == "PATCH" {
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			pick := func(key string) *string {
				v, ok := body.Get(key)
				if !ok {
					return nil
				}
				return ptr(js.String(v))
			}
			link, err := rt.r.Links.Update(ctx, id, pick("url"), pick("name"), pick("slug"), pick("domain"))
			if err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("link", link), 200), nil
		}
		if request.Method == "DELETE" {
			if err := rt.r.Links.Remove(ctx, id); err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("ok", true), 200), nil
		}
	}
	return nil, nil
}

func rangeOut(rng Range, timezone string) *js.Object {
	return js.NewObject("from", rng.FromDate, "to", rng.ToDate, "interval", rng.Interval, "timezone", timezone)
}

// pickKey is the key picker tickets are signed with, made on first use and kept in the database for every process.
func (rt *Routes) pickKey(ctx context.Context) (string, error) {
	if err := rt.r.Init(ctx); err != nil {
		return "", err
	}
	saved, ok, err := rt.r.Store.Setting(ctx, "pick-key")
	if err != nil || (ok && saved != "") {
		return saved, err
	}
	made := randomID(32)
	return made, rt.r.Store.SetSetting(ctx, "pick-key", &made)
}

// pickTicket lets the picker, on site's pages, send its choice to origin, the dashboard that asked, for half an hour.
func (rt *Routes) pickTicket(ctx context.Context, origin, site string) (string, error) {
	key, err := rt.pickKey(ctx)
	if err != nil {
		return "", err
	}
	payload := fmt.Sprintf("%d.%s.%s", rt.r.now()+pickTicketMs, hexText(site), hexText(origin))
	return payload + "." + hmacHex(key, payload), nil
}

var ticketPattern = regexp.MustCompile(`^(\d+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})$`)

// pickTarget is the dashboard origin and site a picker ticket names, or false
// when it is not one this install signed or has run out.
func (rt *Routes) pickTarget(ctx context.Context, ticket string) (string, string, bool, error) {
	parts := ticketPattern.FindStringSubmatch(ticket)
	if parts == nil || js.Number(parts[1]) < float64(rt.r.now()) {
		return "", "", false, nil
	}
	key, err := rt.pickKey(ctx)
	if err != nil {
		return "", "", false, err
	}
	if !constantTimeEqual(parts[4], hmacHex(key, parts[1]+"."+parts[2]+"."+parts[3])) {
		return "", "", false, nil
	}
	origin := unhexText(parts[3])
	if !originPattern.MatchString(origin) {
		return "", "", false, nil
	}
	return origin, unhexText(parts[2]), true, nil
}

// trackerScript is the tracker with click rules inside, rebuilt when goals change. With ?site= it carries
// only that site's rules, so one site's visitors never see another site's domains or goals.
func (rt *Routes) trackerScript(ctx context.Context, siteID *string) (trackerScript, error) {
	key := ""
	if siteID != nil {
		key = *siteID
	}
	rt.mu.Lock()
	cached, ok := rt.trackers[key]
	rt.mu.Unlock()
	if ok && rt.r.now()-cached.at < 60_000 {
		return cached, nil
	}
	if err := rt.r.Init(ctx); err != nil {
		return trackerScript{}, err
	}
	sites := []SiteRow{}
	switch {
	case siteID != nil:
		for _, s := range rt.r.Sites() {
			if s.ID == *siteID {
				sites = append(sites, s)
			}
		}
	case rt.r.ManagedSites:
	default:
		sites = rt.r.Sites()
	}
	goals, err := rt.r.Store.Goals(ctx, "")
	if err != nil {
		return trackerScript{}, err
	}
	rules := js.Stringify(ClickRules(sites, goals))
	body := strings.Replace(assets.Tracker, rulesPlaceholder, rules, 1)
	script := trackerScript{body: body, etag: `"` + assets.Build.TrackerHash + "-" + sha256Hex(rules)[:8] + `"`, at: rt.r.now()}
	// One entry per site at most; a query naming no real site gets the empty script without filling the map.
	if siteID == nil || len(sites) > 0 {
		rt.mu.Lock()
		rt.trackers[key] = script
		rt.mu.Unlock()
	}
	return script, nil
}

func (rt *Routes) clearTrackers() {
	rt.mu.Lock()
	rt.trackers = map[string]trackerScript{}
	rt.mu.Unlock()
}

func (rt *Routes) goalWrites(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request := c.ctx, c.req
	if err := rt.r.Init(ctx); err != nil {
		return nil, err
	}
	site, refused := rt.querySite(u)
	if refused != nil {
		return refused, nil
	}
	existing, err := rt.r.Store.Goals(ctx, site.ID)
	if err != nil {
		return nil, err
	}
	id := ""
	var before *GoalRow
	if path != "/api/goals" {
		decoded, ok := decodeURIComponent(path[len("/api/goals/"):])
		if !ok {
			return nil, errors.New("URIError: URI malformed")
		}
		id = decoded
		for i := range existing {
			if existing[i].ID == id {
				before = &existing[i]
			}
		}
		if before == nil {
			return Coded("Unknown goal", "unknown_goal", 404, nil), nil
		}
	}
	rt.clearTrackers()
	if request.Method == "DELETE" {
		if err := rt.r.Store.DeleteGoal(ctx, id); err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("ok", true), 200), nil
	}
	body, refusedBody := readJSON(request)
	if refusedBody != nil {
		return refusedBody, nil
	}
	goal, err := GoalFrom(body, site.ID, existing, rt.r.now(), id)
	if err != nil {
		var ge *GoalError
		if errors.As(err, &ge) {
			return refusedAnswer(err, "goal_invalid", 400), nil
		}
		return nil, err
	}
	if err := rt.r.Store.SaveGoal(ctx, goal, before); err != nil {
		return nil, err
	}
	status := 201
	if id != "" {
		status = 200
	}
	return jsonAnswer(js.NewObject("goal", goal), status), nil
}

func reportView(r ReportRow) *js.Object {
	return js.NewObject("id", r.ID, "site", r.Site, "email", r.Email, "frequency", r.Frequency, "lang", r.Lang, "lastSentAt", r.LastSentAt, "createdAt", r.CreatedAt)
}

var (
	reportPath = regexp.MustCompile(`^/api/reports/([a-f0-9]{24})(/send)?$`)
	homeURL    = regexp.MustCompile(`^https?://[^\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]+$`)
)

func (rt *Routes) mailAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	if err := rt.r.Init(c.ctx); err != nil {
		return nil, err
	}
	answer, err := rt.mailRoutes(c, path, u)
	if err != nil {
		if me := mailErrorOf(err); me != nil {
			return Coded(me.Message, me.Code, 400, me.Params), nil
		}
		return nil, err
	}
	return answer, nil
}

func (rt *Routes) mailRoutes(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request := c.ctx, c.req
	if path == "/api/mail" {
		switch request.Method {
		case "GET":
			return rt.mailView(c)
		case "PUT":
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			if err := rt.r.SaveMailSettings(ctx, body); err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("ok", true), 200), nil
		case "DELETE":
			if err := rt.r.SaveMailSettings(ctx, nil); err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("ok", true), 200), nil
		}
		return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
	}
	if path == "/api/mail/test" && request.Method == "POST" {
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		to := jsTrim(field(body, "to"))
		if !emailPattern.MatchString(to) {
			return Coded("Enter an email address to send the test to", "test_email", 400, nil), nil
		}
		settings, err := rt.r.MailSettings(ctx)
		if err != nil {
			return nil, err
		}
		if settings == nil {
			return Coded("Set up a mail service first", "mail_unset", 400, nil), nil
		}
		lang := "en"
		if v, ok := body.Get("lang"); ok && v != nil {
			lang = js.String(v)
		}
		tr := NewTranslator(lang)
		name := mailServiceName(js.String(settings.Value("service")))
		text := tr.T("email.test.body", Vars{"service": name})
		if err := rt.r.SendMail(ctx, MailMessage{To: to, Subject: tr.T("email.test.subject", nil), Text: text, HTML: `<p style="font-family:sans-serif;font-size:15px">` + escapeHTML(text) + `</p>`}); err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("ok", true), 200), nil
	}

	site, refused := rt.querySite(u)
	if refused != nil {
		return refused, nil
	}
	if path == "/api/reports" {
		if request.Method == "GET" {
			reports, err := rt.r.Store.Reports(ctx, site.ID)
			if err != nil {
				return nil, err
			}
			views := []any{}
			for _, r := range reports {
				views = append(views, reportView(r))
			}
			return jsonAnswer(js.NewObject("reports", views, "languages", Languages()), 200), nil
		}
		if request.Method == "POST" {
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			email := lower(jsTrim(field(body, "email")))
			if !emailPattern.MatchString(email) {
				return Coded("Enter an email address", "email_invalid", 400, nil), nil
			}
			frequency := "weekly"
			if body.Value("frequency") == "monthly" {
				frequency = "monthly"
			}
			existing, err := rt.r.Store.Reports(ctx, site.ID)
			if err != nil {
				return nil, err
			}
			for _, r := range existing {
				if r.Email == email && r.Frequency == frequency {
					return Coded(email+" already gets the "+frequency+" report", "report_exists", 400, params("email", email)), nil
				}
			}
			if len(existing) >= 50 {
				return Coded("A site can send to at most 50 addresses", "report_limit", 400, nil), nil
			}
			// Links in the email point back to the configured address, or else to this dashboard as the browser
			// sees it. A report made from a hub needs the configured address, where its unsubscribe link
			// answers, since the Host its request names is the hub's to choose.
			if c.managed != nil && rt.origin == "" {
				return originNeeded(), nil
			}
			given := ""
			if rt.origin == "" {
				given = field(body, "origin")
			}
			home := firstNonEmpty(rt.origin, u.Origin()) + rt.base
			if homeURL.MatchString(given) {
				home = strings.TrimRight(given, "/")
			}
			// A period already due counts as sent, so a report added mid-week first goes out on the next Monday, as the form says.
			now := rt.r.now()
			due := LastPeriod(frequency, now, site.Timezone)
			lang := "en"
			if l := js.String(undefinedIfMissing(body, "lang", body.Value("lang"))); contains(Languages(), l) {
				lang = l
			}
			last := ""
			if now >= due.DueAt {
				last = due.Key
			}
			report := ReportRow{ID: randomID(12), Site: site.ID, Email: email, Frequency: frequency, Lang: lang, Token: randomID(16), Origin: home, LastPeriod: last, CreatedAt: now}
			if err := rt.r.Store.InsertReport(ctx, report); err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("report", reportView(report)), 201), nil
		}
		return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
	}
	m := reportPath.FindStringSubmatch(path)
	var report *ReportRow
	if m != nil {
		var err error
		if report, err = rt.r.Store.ReportBy(ctx, "id", m[1]); err != nil {
			return nil, err
		}
	}
	if report == nil || report.Site != site.ID {
		return Coded("Unknown report", "unknown_report", 404, nil), nil
	}
	if m[2] != "" && request.Method == "POST" {
		// A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A hub
		// sends one every ten minutes for the whole site, so adding reports again does not start a new count.
		key, wait := report.ID, int64(60_000)
		if c.managed != nil {
			key, wait = "site:"+site.ID, 600_000
		}
		rt.mu.Lock()
		last, sent := rt.sampleSent[key]
		if sent && rt.r.now()-last < wait {
			rt.mu.Unlock()
			if c.managed != nil {
				return Coded("A connected hub can send one sample every ten minutes. Wait a few minutes and try again.", "sample_soon_hub", 429, nil), nil
			}
			return Coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429, nil), nil
		}
		rt.sampleSent[key] = rt.r.now()
		rt.mu.Unlock()
		if err := rt.r.DeliverReport(ctx, *report, site, nil); err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("ok", true), 200), nil
	}
	if m[2] == "" && request.Method == "DELETE" {
		if err := rt.r.Store.DeleteReport(ctx, report.ID); err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("ok", true), 200), nil
	}
	return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
}

var reportToken = regexp.MustCompile(`^[a-f0-9]{32}$`)

// unsubscribePage is a plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing.
func (rt *Routes) unsubscribePage(ctx context.Context, request *Request, token string) (*Response, error) {
	if err := rt.r.Init(ctx); err != nil {
		return nil, err
	}
	var report *ReportRow
	if reportToken.MatchString(token) {
		var err error
		if report, err = rt.r.Store.ReportBy(ctx, "token", token); err != nil {
			return nil, err
		}
	}
	var site SiteRow
	found := false
	if report != nil {
		site, found = rt.r.Site(report.Site)
	}
	lang := "en"
	if report != nil {
		lang = report.Lang
	}
	tr := NewTranslator(lang)
	page := func(body string, status int) *Response { return smallPage(tr.Lang, body, status) }
	if !found {
		return page("<h1>"+escapeHTML(tr.T("email.unsub.goneTitle", nil))+"</h1><p>"+escapeHTML(tr.T("email.unsub.gone", nil))+"</p>", 404), nil
	}
	if request.Method == "POST" {
		if err := rt.r.Store.DeleteReport(ctx, report.ID); err != nil {
			return nil, err
		}
		return page("<h1>"+escapeHTML(tr.T("email.unsub.doneTitle", nil))+"</h1><p>"+escapeHTML(tr.T("email.unsub.done", Vars{"site": site.Name, "email": report.Email}))+"</p>", 200), nil
	}
	return page("<h1>"+escapeHTML(tr.T("email.unsub.title", Vars{"site": site.Name}))+"</h1><p>"+escapeHTML(tr.T("email.unsub.body", Vars{"email": report.Email}))+`</p><form method="post"><button type="submit">`+escapeHTML(tr.T("email.unsubscribe", nil))+"</button></form>", 200), nil
}

func (rt *Routes) sharesAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request := c.ctx, c.req
	if err := rt.r.Init(ctx); err != nil {
		return nil, err
	}
	site, refused := rt.querySite(u)
	if refused != nil {
		return refused, nil
	}
	view := func(share ShareRow) *js.Object {
		o := js.ToValue(share).(*js.Object)
		o.Set("path", rt.base+"/share/"+share.ID)
		return o
	}
	if path == "/api/shares" {
		if request.Method == "GET" {
			shares, err := rt.r.Store.Shares(ctx, site.ID)
			if err != nil {
				return nil, err
			}
			views := []any{}
			for _, s := range shares {
				views = append(views, view(s))
			}
			return jsonAnswer(js.NewObject("shares", views), 200), nil
		}
		if request.Method == "POST" {
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			share := ShareRow{ID: randomID(16), Site: site.ID, Name: head16(jsTrim(field(body, "name")), 100), CreatedAt: rt.r.now()}
			if err := rt.r.Store.InsertShare(ctx, share); err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("share", view(share)), 201), nil
		}
		return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
	}
	id, ok := decodeURIComponent(path[len("/api/shares/"):])
	if !ok {
		return nil, errors.New("URIError: URI malformed")
	}
	var share *ShareRow
	if shareID.MatchString(id) {
		var err error
		if share, err = rt.r.Store.ShareByID(ctx, id); err != nil {
			return nil, err
		}
	}
	if share == nil || share.Site != site.ID {
		return Coded("Unknown share", "unknown_share", 404, nil), nil
	}
	if request.Method == "PATCH" {
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		name := head16(jsTrim(field(body, "name")), 100)
		if err := rt.r.Store.RenameShare(ctx, share.ID, name); err != nil {
			return nil, err
		}
		renamed := *share
		renamed.Name = name
		return jsonAnswer(js.NewObject("share", view(renamed)), 200), nil
	}
	if request.Method == "DELETE" {
		if err := rt.r.Store.DeleteShare(ctx, share.ID); err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("ok", true), 200), nil
	}
	return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
}

// viewerDaily is how many questions each viewer may ask the assistant a day, as an owner set it.
func (rt *Routes) viewerDaily(ctx context.Context) (float64, error) {
	saved, ok, err := rt.r.Store.Setting(ctx, "assistant-viewer-daily")
	if err != nil || !ok {
		return viewerDailyDefault, err
	}
	return js.Number(saved), nil
}

// askTurn counts a question to the assistant, which spends the owner's AI
// credit, or refuses it: past thirty an hour or two at once for anyone, and
// past the owner's daily number for a viewer. Returns how to finish.
func (rt *Routes) askTurn(ctx context.Context, who string, owner bool) (*Response, func(), error) {
	now := rt.r.now()
	rt.mu.Lock()
	mine, ok := rt.asked[who]
	if !ok {
		mine = &askCount{}
	}
	kept := []int64{}
	for _, at := range mine.at {
		if now-at < 3_600_000 {
			kept = append(kept, at)
		}
	}
	mine.at = kept
	busy := len(mine.at) >= askPerHour || mine.open >= askAtOnce
	rt.mu.Unlock()
	if busy {
		return Coded("You have asked a lot in a short time. Wait a little and ask again.", "assistant_soon", 429, nil), nil, nil
	}
	if !owner {
		limit, err := rt.viewerDaily(ctx)
		if err != nil {
			return nil, nil, err
		}
		day := "assistant-asked:" + js.ISOString(now)[:10]
		stored, has, err := rt.r.Store.Setting(ctx, day)
		if err != nil {
			return nil, nil, err
		}
		if !has {
			stored = "{}"
		}
		parsed, err := js.Parse(stored)
		if err != nil {
			return nil, nil, err
		}
		counts, _ := parsed.(*js.Object)
		if counts == nil {
			counts = &js.Object{}
		}
		if js.ToNumber(counts.Value(who)) >= limit {
			l := js.FormatNumber(limit)
			return Coded("Viewers can ask "+l+" questions a day. Ask again tomorrow.", "assistant_daily", 429, params("limit", l)), nil, nil
		}
		counts.Set(who, js.ToNumber(counts.Value(who))+1)
		if err := rt.r.Store.SetSetting(ctx, day, ptr(js.Stringify(counts))); err != nil {
			return nil, nil, err
		}
		old, err := rt.r.Store.SettingsStartingWith(ctx, "assistant-asked:")
		if err != nil {
			return nil, nil, err
		}
		for _, s := range old {
			if s.Key != day {
				if err := rt.r.Store.SetSetting(ctx, s.Key, nil); err != nil {
					return nil, nil, err
				}
			}
		}
	}
	rt.mu.Lock()
	mine.at = append(mine.at, now)
	mine.open++
	rt.asked[who] = mine
	// People who stopped asking are dropped, so the map holds only the last hour's.
	if len(rt.asked) > 1000 {
		for key, value := range rt.asked {
			recent := false
			for _, at := range value.at {
				if now-at < 3_600_000 {
					recent = true
				}
			}
			if value.open == 0 && !recent {
				delete(rt.asked, key)
			}
		}
	}
	rt.mu.Unlock()
	return nil, func() {
		rt.mu.Lock()
		mine.open--
		rt.mu.Unlock()
	}, nil
}

var tokenPath = regexp.MustCompile(`^/api/tokens/([a-f0-9]{24})$`)

func tokenView(t TokenRow) *js.Object {
	return js.NewObject("id", t.ID, "name", t.Name, "site", t.Site, "scope", t.Scope, "hint", t.Hint, "createdAt", t.CreatedAt, "lastUsedAt", t.LastUsedAt)
}

func (rt *Routes) tokensAPI(c *call, path string) (*Response, error) {
	ctx, request := c.ctx, c.req
	if err := rt.r.Init(ctx); err != nil {
		return nil, err
	}
	if path == "/api/tokens" && request.Method == "GET" {
		tokens, err := rt.r.Store.Tokens(ctx)
		if err != nil {
			return nil, err
		}
		views := []any{}
		for _, t := range tokens {
			views = append(views, tokenView(t))
		}
		return jsonAnswer(js.NewObject("tokens", views), 200), nil
	}
	if path == "/api/tokens" && request.Method == "POST" {
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		name := head16(jsTrim(field(body, "name")), 100)
		if name == "" {
			return Coded("Name the token", "token_name", 400, nil), nil
		}
		site := field(body, "site")
		if _, ok := rt.r.Site(site); site != "" && !ok {
			return Coded("Unknown site", "unknown_site", 404, nil), nil
		}
		scope := "read"
		if body.Value("scope") == "manage" {
			scope = "manage"
		}
		if scope == "manage" && site == "" {
			return Coded("A token that changes settings is for one site. Pick the site.", "token_site", 400, nil), nil
		}
		secret := tokenPrefix + randomID(20)
		row := TokenRow{ID: randomID(12), Name: name, Site: site, Scope: scope, Hash: sha256Hex(secret), Hint: secret[len(secret)-4:], CreatedAt: rt.r.now()}
		if err := rt.r.Store.InsertToken(ctx, row); err != nil {
			return nil, err
		}
		by := ""
		if rt.accountOf != nil {
			by = rt.accountOf(ctx, request)
		}
		if by != "" && rt.tokenMade != nil && !rt.tokenMade(ctx, row, by) {
			if _, err := rt.r.Store.DeleteToken(ctx, row.ID); err != nil {
				return nil, err
			}
			return denied(canReadOnly), nil
		}
		// The only time the token is ever shown.
		return jsonAnswer(js.NewObject("token", tokenView(row), "secret", secret), 201), nil
	}
	if m := tokenPath.FindStringSubmatch(path); m != nil && request.Method == "DELETE" {
		ok, err := rt.r.Store.DeleteToken(ctx, m[1])
		if err != nil {
			return nil, err
		}
		if ok {
			return jsonAnswer(js.NewObject("ok", true), 200), nil
		}
		return Coded("Unknown token", "unknown_token", 404, nil), nil
	}
	return Coded("Not found", "not_found", 404, nil), nil
}

// adminOnly are the controls a member cannot change: the mail service and
// its keys, the assistant's settings, and deleting a site.
func adminOnly(path, method string) bool {
	return (path == "/api/mail" && (method == "PUT" || method == "DELETE")) ||
		(path == "/api/assistant" && (method == "PUT" || method == "DELETE")) ||
		(path == "/api/assistant/limits" && method == "PUT") ||
		(path == "/api/assistant/models" && method == "POST") ||
		(manageSite.MatchString(path) && method == "DELETE")
}
