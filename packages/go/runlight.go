package runlight

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Request is an incoming request, shaped like the Fetch API's: an absolute
// URL, a method, headers, a body, and the address it came from.
type Request = web.Request

// Response is an answer, shaped like the Fetch API's.
type Response = web.Response

// Headers are request or response headers, matched without regard to case.
type Headers = web.Headers

// Fetcher makes outgoing requests, the stand-in for fetch(). Every
// request Runlight makes to another server goes through the one in Options.
type Fetcher = web.Fetcher

// FetchInit is what a Fetcher is asked to do.
type FetchInit = web.FetchInit

// SiteOptions describe one site set in code.
type SiteOptions struct {
	// ID is stable and stored with every row. "" is "default" for the first site.
	ID string `json:"id,omitempty"`
	// Name defaults to the first hostname, else "My site".
	Name string `json:"name,omitempty"`
	// Hostnames belong to this site, without www. With one site, none means
	// any hostname. With several, each site needs at least one.
	Hostnames []string `json:"hostnames,omitempty"`
	// Timezone is an IANA timezone for reports, such as "Europe/London". "" is UTC.
	Timezone string `json:"timezone,omitempty"`
}

// Options configure a Runlight.
type Options struct {
	Store *Store
	// Site is the site this install counts. Ignored when Sites is given.
	Site *SiteOptions
	// Sites are several sites in one install, told apart by hostname.
	Sites []SiteOptions
	// ManagedSites keeps sites in the database, added, changed, and deleted
	// in the dashboard, as the standalone server does. Site and Sites are ignored.
	ManagedSites bool
	// Geo looks up a location for an IP when the platform sends no location headers.
	Geo GeoLookup
	// IgnoreProxy reads only the connection's address, for an app nothing
	// sits in front of. By default the client IP comes from forwarding
	// headers: the last X-Forwarded-For entry, which the nearest proxy
	// wrote, then X-Real-IP, then CF-Connecting-IP.
	IgnoreProxy bool
	// ProxyHeader names the one forwarding header to read, such as
	// "cf-connecting-ip" behind Cloudflare and another proxy.
	ProxyHeader string
	// TrustProxy reads the default forwarding headers on purpose. It changes
	// nothing but the warning given when, left unset, a request arrives
	// straight from a public address with none of them.
	TrustProxy bool
	// LinkPath is where short links on the app's own domain live, as
	// {LinkPath}/{slug}. "" is "/go".
	LinkPath string
	// Mail is the mail service for email reports, in code. When set, the
	// dashboard shows it and cannot change it.
	Mail *js.Object
	// Secret encrypts the keys kept in the database. nil reads the
	// RUNLIGHT_SECRET environment variable, then RUNLIGHT_TOKEN.
	Secret *string
	// RateLimit is tracker requests allowed per visitor address per minute,
	// counted in memory by each process. nil is 120; 0 or less turns the limit off.
	RateLimit *int
	// Now is the clock, in epoch milliseconds, for tests.
	Now func() int64
	// Fetcher makes every outgoing request. nil is a net/http one.
	Fetcher Fetcher
	// LocalInstalls lets a connected install be at http://localhost or
	// http://127.0.0.1, for trying a hub and an app on one machine. Default
	// false: otherwise anyone who can add a site could have this server ask
	// services on its own machine, so other installs must be public https
	// addresses.
	LocalInstalls bool
	// Logf reports what goes wrong where nothing can answer for it. nil logs to standard error.
	Logf func(format string, args ...any)
}

// Remote is another Runlight install a site is read from: its address, its
// token there, and its own id for the site.
type Remote struct {
	URL       string   `json:"url"`
	Token     string   `json:"token"`
	Site      string   `json:"site"`
	Hostnames []string `json:"hostnames"`
	// Scope is manage when the token may change the site's settings there; older connections read only.
	Scope string `json:"scope,omitempty"`
}

// RemoteInfo is what a connected install last said about its site, and
// whether it answered this server at all.
type RemoteInfo struct {
	LastSeen *int64
	// RetentionMonths is unknown (Known false) while the install cannot be reached.
	RetentionMonths      *int64
	RetentionMonthsKnown bool
	// Connection is ok, refused, or unreachable.
	Connection string
	at         int64
}

// LinkDomainCheck is a path on every link domain that answers when the
// domain reaches this Runlight.
const LinkDomainCheck = "/.well-known/runlight-link-domain"

// rollupVersion is raised whenever what a rolled-up day holds changes.
const rollupVersion = 3

// rollupBatch is days of rollups built per site in one scheduled check.
const rollupBatch = 10

// remoteMaxBytes is the most a connected install's list of sites may weigh.
const remoteMaxBytes = 2 * 1024 * 1024

// meteredRollupBatch is fewer days a check on a database that caps statements per request.
const meteredRollupBatch = 4

const rollupDelayMs = 2 * 3_600_000

// RetentionMonths are the choices for how long a site keeps its visits.
var RetentionMonths = []int64{6, 12, 24, 36, 60}

// SessionIdleMs is thirty minutes without a request, which ends a session.
const SessionIdleMs = 30 * 60 * 1000

func utcDay(ts int64) string { return js.ISOString(ts)[:10] }

var siteID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func siteRow(options SiteOptions, index int) (SiteRow, error) {
	timezone := options.Timezone
	if timezone == "" {
		timezone = "UTC"
	}
	if !IsTimezone(timezone) {
		return SiteRow{}, fmt.Errorf("Runlight: unknown timezone %q", timezone)
	}
	id := options.ID
	if id == "" && index == 0 {
		id = "default"
	}
	if id == "" || !siteID.MatchString(id) {
		return SiteRow{}, fmt.Errorf("Runlight: site id %q must be letters, digits, dots, dashes, or underscores", id)
	}
	name := options.Name
	if name == "" {
		name = "My site"
		if len(options.Hostnames) > 0 {
			name = options.Hostnames[0]
		}
	}
	hostnames := []string{}
	for _, h := range options.Hostnames {
		hostnames = append(hostnames, StripWww(h))
	}
	return SiteRow{ID: id, Name: name, Hostnames: hostnames, Timezone: timezone}, nil
}

// envValue is an environment variable, trimmed, and false when it is empty.
func envValue(name string) (string, bool) {
	v := strings.TrimSpace(os.Getenv(name))
	return v, v != ""
}

// SettingsError is a setting refused, such as a site's domain or the
// assistant's service, as a code the dashboard says in its own words.
type SettingsError struct{ CodedError }

func (*SettingsError) isRangeError() {}

func settingsError(message, code string, params ...string) error {
	return &SettingsError{coded(message, code, params...)}
}

// emailPattern is what passes for an email address: something@somewhere.tld,
// with no spaces, quotes, or angle brackets.
var emailPattern = regexp.MustCompile(`^[^\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}@<>"]+@[^\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}@<>"]+\.[^\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}@<>"]+$`)

type salts struct {
	day       string
	today     string
	yesterday string
	hasYest   bool
}

// Runlight is one install: its store, its sites, and everything that
// records and reads visits.
type Runlight struct {
	// Store keeps the tables.
	Store *Store
	// ManagedSites says sites are managed in the dashboard.
	ManagedSites bool
	// Links creates, changes, deletes, and imports short links.
	Links *Links
	// LinkPath is where links on the app's own domain are served, such as "/go".
	LinkPath string
	// Secret encrypts the keys kept in the database; "" (HasSecret false)
	// leaves them readable, and the dashboard says so.
	Secret    string
	HasSecret bool
	// LocalInstalls says a connected install may be on this machine, at http://localhost or http://127.0.0.1.
	LocalInstalls bool

	now       func() int64
	fetcher   Fetcher
	logf      func(format string, args ...any)
	geo       GeoLookup
	trust     string // "" none, "*" the defaults, or one header's name
	limit     *rateLimit
	mailCode  *js.Object
	readyMu   sync.Mutex
	ready     bool
	checkMu   sync.Mutex
	checking  *checkRun
	pruneMu   sync.Mutex
	pruneWG   sync.WaitGroup
	turnsMu   sync.Mutex
	turns     map[string]*turn
	optimized int64
	// warnDirect is true until the default trust, never chosen, has been seen
	// answering a public address directly, and warned about once.
	warnDirect atomic.Bool

	mu          sync.Mutex
	configured  []SiteRow
	overrides   map[string]*js.Object
	remotes     map[string]Remote
	remoteOrder []string
	remoteSeen  map[string]RemoteInfo
	routeBases  map[string]bool
	linkDomains *linkDomainCache
	salts       map[string]salts
}

type linkDomainCache struct {
	at      int64
	domains map[string]bool
}

type checkRun struct {
	done   chan struct{}
	result CheckResult
	err    error
}

type turn struct {
	mu    sync.Mutex
	users int
}

// New makes a Runlight.
func New(options Options) (*Runlight, error) {
	if options.Store == nil {
		return nil, errors.New(`Runlight: pass a store, such as runlight.NewStore(runlight.SQLite(db))`)
	}
	r := &Runlight{
		Store:         options.Store,
		ManagedSites:  options.ManagedSites,
		LocalInstalls: options.LocalInstalls,
		now:           options.Now,
		fetcher:       options.Fetcher,
		logf:          options.Logf,
		geo:           options.Geo,
		mailCode:      options.Mail,
		turns:         map[string]*turn{},
		overrides:     map[string]*js.Object{},
		remotes:       map[string]Remote{},
		remoteSeen:    map[string]RemoteInfo{},
		routeBases:    map[string]bool{},
		salts:         map[string]salts{},
	}
	if r.now == nil {
		r.now = func() int64 { return time.Now().UnixMilli() }
	}
	if r.fetcher == nil {
		r.fetcher = web.HTTPFetcher{}
	}
	if r.logf == nil {
		logger := log.New(os.Stderr, "", 0)
		r.logf = logger.Printf
	}
	var configured []SiteOptions
	if !r.ManagedSites {
		switch {
		case len(options.Sites) > 0:
			configured = options.Sites
		case options.Site != nil:
			configured = []SiteOptions{*options.Site}
		default:
			configured = []SiteOptions{{}}
		}
	}
	r.configured = []SiteRow{}
	seen := map[string]bool{}
	for i, s := range configured {
		row, err := siteRow(s, i)
		if err != nil {
			return nil, err
		}
		r.configured = append(r.configured, row)
		seen[row.ID] = true
	}
	if len(r.configured) > 1 {
		for _, site := range r.configured {
			if len(site.Hostnames) == 0 {
				return nil, errors.New("Runlight: with several sites, give each one its hostnames")
			}
		}
	}
	if len(seen) != len(r.configured) {
		return nil, errors.New("Runlight: two sites share an id")
	}
	switch {
	case options.IgnoreProxy:
		r.trust = ""
	case options.ProxyHeader != "":
		r.trust = strings.ToLower(options.ProxyHeader)
	default:
		r.trust = "*"
		r.warnDirect.Store(!options.TrustProxy)
	}
	perMinute := 120
	if options.RateLimit != nil {
		perMinute = *options.RateLimit
	}
	// 0, or anything that is not a positive number, means no limit, never a limit of nothing.
	if perMinute > 0 {
		r.limit = newRateLimit(perMinute, r.now)
	}
	r.Links = &Links{r: r}
	r.LinkPath = "/" + strings.Trim(firstNonEmpty(options.LinkPath, "/go"), "/")
	if options.Secret != nil {
		r.Secret, r.HasSecret = *options.Secret, true
	} else if v, ok := envValue("RUNLIGHT_SECRET"); ok {
		r.Secret, r.HasSecret = v, true
	} else if v, ok := envValue("RUNLIGHT_TOKEN"); ok {
		r.Secret, r.HasSecret = v, true
	}
	return r, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// Now is the clock, in epoch milliseconds.
func (r *Runlight) Now() int64 { return r.now() }

// Fetcher is what every outgoing request goes through.
func (r *Runlight) Fetcher() Fetcher { return r.fetcher }

// Init creates tables and records the configured sites. Runs once.
func (r *Runlight) Init(ctx context.Context) error {
	r.readyMu.Lock()
	defer r.readyMu.Unlock()
	if r.ready {
		return nil
	}
	if err := r.init(ctx); err != nil {
		return err
	}
	r.ready = true
	return nil
}

func (r *Runlight) init(ctx context.Context) error {
	if err := r.Store.Migrate(ctx); err != nil {
		return err
	}
	// A database that never had its statistics gathered gets them now, before any report is read, rather
	// than at the first scheduled check, which an app may never run.
	r.Store.Optimize(ctx, true)
	if r.ManagedSites {
		sites, err := r.Store.Sites(ctx)
		if err != nil {
			return err
		}
		r.mu.Lock()
		r.configured = sites
		r.mu.Unlock()
		if err := r.loadRemotes(ctx); err != nil {
			return err
		}
	}
	for _, site := range r.configuredSites() {
		if err := r.Store.UpsertSite(ctx, site, r.now()); err != nil {
			return err
		}
	}
	overrides, _, err := r.Store.SiteOverrides(ctx)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.overrides = overrides
	r.mu.Unlock()
	// A process starting with a timezone set in code is the newest word on it: if the code changed it,
	// the days built in the old one are cleared here, once, and never by a process still running.
	for _, site := range r.Sites() {
		if _, remote := r.Remote(site.ID); remote {
			continue
		}
		stored, ok, err := r.Store.Setting(ctx, "rollup-zone:"+site.ID)
		if err != nil {
			return err
		}
		zone := ""
		if ok {
			if parsed, err := js.Parse(stored); err == nil {
				zone = js.String(js.Dig(parsed, "zone"))
			} else {
				return err
			}
		}
		if !ok {
			if err := r.Store.SetSetting(ctx, "rollup-zone:"+site.ID, ptr(js.Stringify(js.NewObject("zone", site.Timezone, "since", 0)))); err != nil {
				return err
			}
		} else if zone != site.Timezone {
			if _, err := r.zoneChanged(ctx, site.ID, site.Timezone); err != nil {
				return err
			}
		}
	}
	return nil
}

func ptr[T any](v T) *T { return &v }

func (r *Runlight) configuredSites() []SiteRow {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]SiteRow(nil), r.configured...)
}

// Sites are the sites, with any settings changed in the dashboard applied.
func (r *Runlight) Sites() []SiteRow {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]SiteRow, len(r.configured))
	for i, site := range r.configured {
		if o := r.overrides[site.ID]; o != nil {
			if v, ok := o.Get("name"); ok {
				site.Name = js.String(v)
			}
			if v, ok := o.Get("timezone"); ok {
				site.Timezone = js.String(v)
			}
		}
		out[i] = site
	}
	return out
}

var (
	hostScheme   = regexp.MustCompile(`^https?://`)
	hostTail     = regexp.MustCompile(`[/:].*$`)
	hostSplit    = regexp.MustCompile(`[\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff},]+`)
	domainLabel  = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)
	httpsInstall = regexp.MustCompile(`^https://[^/]+`)
	localInstall = regexp.MustCompile(`^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)`)
	hostIDLetter = regexp.MustCompile(`[^A-Za-z0-9._-]`)
)

// isDomainName is DOMAIN_NAME.test(value): a domain name of 1 to 253 characters.
func isDomainName(value string) bool {
	return len16(value) >= 1 && len16(value) <= 253 && domainLabel.MatchString(value)
}

// IsDomainName reports whether a value is a domain name of 1 to 253 characters, such as example.com.
func IsDomainName(value string) bool { return isDomainName(value) }

// hostnamesFor checks a list of hostnames for a managed site: at least one,
// each a domain, none taken.
func (r *Runlight) hostnamesFor(input any, except string) ([]string, error) {
	var raw []string
	if list, ok := input.([]any); ok {
		for _, h := range list {
			raw = append(raw, js.String(h))
		}
	} else {
		text := ""
		if input != nil {
			if _, u := input.(js.Undefined); !u {
				text = js.String(input)
			}
		}
		raw = hostSplit.Split(text, -1)
	}
	hostnames := []string{}
	seen := map[string]bool{}
	for _, h := range raw {
		host := StripWww(hostTail.ReplaceAllString(hostScheme.ReplaceAllString(jsTrim(h), ""), ""))
		if host != "" && !seen[host] {
			seen[host] = true
			hostnames = append(hostnames, host)
		}
	}
	if len(hostnames) == 0 {
		return nil, settingsError("Add the site's domain, like example.com", "site_domain_needed")
	}
	for _, host := range hostnames {
		if !isDomainName(host) && host != "localhost" {
			return nil, settingsError(`"`+host+`" is not a domain name`, "site_domain_invalid", "host", host)
		}
		for _, site := range r.configuredSites() {
			if site.ID == except {
				continue
			}
			for _, h := range site.Hostnames {
				if h == host {
					return nil, settingsError(host+" already belongs to "+site.Name, "site_domain_taken", "host", host, "site", site.Name)
				}
			}
		}
	}
	return hostnames, nil
}

func (r *Runlight) loadRemotes(ctx context.Context) error {
	settings, err := r.Store.SettingsStartingWith(ctx, "remote:")
	if err != nil {
		return err
	}
	remotes := map[string]Remote{}
	order := []string{}
	for _, s := range settings {
		opened, ok := r.unseal(s.Value)
		if !ok {
			continue
		}
		parsed, err := js.Parse(opened)
		if err != nil {
			return err
		}
		remote := Remote{URL: js.String(js.Dig(parsed, "url")), Token: js.String(js.Dig(parsed, "token")), Site: js.String(js.Dig(parsed, "site")), Hostnames: []string{}}
		for _, h := range js.Arr(js.Dig(parsed, "hostnames")) {
			remote.Hostnames = append(remote.Hostnames, js.String(h))
		}
		if v, ok := js.Dig(parsed, "scope").(string); ok {
			remote.Scope = v
		}
		id := strings.TrimPrefix(s.Key, "remote:")
		remotes[id] = remote
		order = append(order, id)
	}
	r.mu.Lock()
	r.remotes = remotes
	r.remoteOrder = order
	r.mu.Unlock()
	return nil
}

// Remote is the install a site is read from, when it is counted elsewhere.
func (r *Runlight) Remote(id string) (Remote, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	remote, ok := r.remotes[id]
	return remote, ok
}

func (r *Runlight) hasRemotes() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.remotes) > 0
}

// RemoteLastSeen is when a connected install's site last had a visit, asked at most once a minute.
func (r *Runlight) RemoteLastSeen(ctx context.Context, id string) *int64 {
	info := r.RemoteInfo(ctx, id)
	if info == nil {
		return nil
	}
	return info.LastSeen
}

// RemoteInfo is what a connected install says about its site: its last
// visit and how long it keeps visits, asked at most once a minute. nil for
// a site that is not connected.
func (r *Runlight) RemoteInfo(ctx context.Context, id string) *RemoteInfo {
	remote, ok := r.Remote(id)
	if !ok {
		return nil
	}
	r.mu.Lock()
	cached, have := r.remoteSeen[id]
	r.mu.Unlock()
	if have && r.now()-cached.at < 60_000 {
		return &cached
	}
	info := RemoteInfo{Connection: "unreachable"}
	if have {
		info.LastSeen = cached.LastSeen
	}
	answer, err := r.installFetch(ctx, remote.URL+"/api/sites", FetchInit{Headers: web.NewHeaders("authorization", "Bearer "+remote.Token), Timeout: 8 * time.Second, MaxBytes: remoteMaxBytes})
	if err == nil {
		if answer.Status == 401 || answer.Status == 403 {
			info.Connection = "refused"
		}
		if body, err := answer.JSON(); err == nil {
			for _, s := range js.Arr(js.Dig(body, "sites")) {
				if js.Dig(s, "id") == remote.Site {
					info = RemoteInfo{Connection: "ok", RetentionMonthsKnown: true}
					if v, ok := js.Dig(s, "lastSeen").(float64); ok {
						info.LastSeen = i64(int64(v))
					}
					if v, ok := js.Dig(s, "retentionMonths").(float64); ok {
						info.RetentionMonths = i64(int64(v))
					}
					break
				}
			}
		}
	}
	info.at = r.now()
	r.mu.Lock()
	r.remoteSeen[id] = info
	r.mu.Unlock()
	return &info
}

// ForgetRemoteInfo forgets what a connected install said, after a change made through it.
func (r *Runlight) ForgetRemoteInfo(id string) {
	r.mu.Lock()
	delete(r.remoteSeen, id)
	r.mu.Unlock()
}

// revokeRemoteToken asks a connected install to delete the token this
// server holds for it. A failure leaves it listed there.
func (r *Runlight) revokeRemoteToken(ctx context.Context, remote Remote) {
	_, _ = r.installFetch(ctx, remote.URL+"/api/token", FetchInit{Method: "DELETE", Headers: web.NewHeaders("authorization", "Bearer "+remote.Token), Timeout: 5 * time.Second})
}

// installAddress is whether an address can be another Runlight install's:
// https, or, with local, an install on this machine, which only code can allow.
func installAddress(url string, local bool) bool {
	return httpsInstall.MatchString(url) || (local && localInstall.MatchString(url))
}

// installFetch fetches from another Runlight install, which someone signed
// in named: a public address as web.PublicFetch fetches it, with no redirect
// followed, so a token sent there goes nowhere else. With LocalInstalls, an
// install on this machine is fetched as it is, still without following a
// redirect.
func (r *Runlight) installFetch(ctx context.Context, url string, init FetchInit) (*Response, error) {
	if r.LocalInstalls && localInstall.MatchString(url) {
		init.Redirect = "manual"
		return r.fetcher.Fetch(ctx, url, init)
	}
	return web.PublicFetch(ctx, r.fetcher, url, init, 0)
}

// sortSites keeps sites by name, as localeCompare orders them.
func sortSites(sites []SiteRow) {
	sort.SliceStable(sites, func(i, j int) bool { return localeCompare(sites[i].Name, sites[j].Name) < 0 })
}

// addRemoteSite connects a site counted by another Runlight (an app's own
// install) so this server shows it too. Takes the install's address, as its
// dashboard is (https://example.com/runlight), and an API token made there.
func (r *Runlight) addRemoteSite(ctx context.Context, input *js.Object, name any) (SiteRow, error) {
	url := strings.TrimRight(jsTrim(field(input, "url")), "/")
	if !installAddress(url, r.LocalInstalls) {
		return SiteRow{}, settingsError("Enter the install's address, like https://example.com/runlight", "connect_url")
	}
	token := jsTrim(field(input, "token"))
	if token == "" {
		return SiteRow{}, settingsError("Enter an API token from that install", "install_token")
	}
	auth := web.NewHeaders("authorization", "Bearer "+token)
	answer, err := r.installFetch(ctx, url+"/api/sites", FetchInit{Headers: auth, Timeout: 10 * time.Second, MaxBytes: remoteMaxBytes})
	if err != nil {
		if errors.Is(err, web.ErrBodyTooLong) {
			answer = &Response{Status: 200, Header: &Headers{}}
		} else {
			return SiteRow{}, settingsError("Could not reach "+url, "unreachable", "host", whatwg.MustParse(url).Host())
		}
	}
	if answer.Status == 401 || answer.Status == 403 {
		return SiteRow{}, settingsError("That install refused the token", "install_refused")
	}
	body, _ := answer.JSON()
	sites := js.Arr(js.Dig(body, "sites"))
	if !answer.OK() || len(sites) == 0 {
		return SiteRow{}, settingsError(url+" did not answer like a Runlight install", "connect_not_runlight", "url", url)
	}
	// What the token may do there; an install from before manage tokens has no /api/token and reads only.
	scope := "read"
	tokenSite := ""
	if about, err := r.installFetch(ctx, url+"/api/token", FetchInit{Headers: auth, Timeout: 10 * time.Second, MaxBytes: remoteMaxBytes}); err == nil && about.OK() {
		if info, err := about.JSON(); err == nil {
			if js.Dig(info, "scope") == "manage" {
				scope = "manage"
			}
			if v := js.Dig(info, "site"); v != nil {
				tokenSite = js.String(v)
			}
		}
	}
	want := tokenSite
	if want == "" {
		want = js.String(undefinedIfMissing(input, "site", input.Value("site")))
	}
	there := sites[0]
	for _, s := range sites {
		if js.Dig(s, "id") == want {
			there = s
			break
		}
	}
	thereID := js.String(js.Dig(there, "id"))
	// An install's answer is read as given: a site without a list of hostnames has none.
	hostnames := []string{}
	for _, h := range js.Arr(js.Dig(there, "hostnames")) {
		if s, ok := h.(string); ok {
			hostnames = append(hostnames, s)
		}
	}
	// Connecting the same site again (to allow changes, or with a new token) updates it in place.
	r.mu.Lock()
	order := append([]string(nil), r.remoteOrder...)
	r.mu.Unlock()
	for _, existing := range order {
		known, _ := r.Remote(existing)
		if known.URL == url && known.Site == thereID {
			updated := known
			updated.Token, updated.Scope, updated.Hostnames = token, scope, hostnames
			if known.Token != token {
				r.revokeRemoteToken(ctx, known)
			}
			sealed, err := r.seal(js.Stringify(updated))
			if err != nil {
				return SiteRow{}, err
			}
			if err := r.Store.SetSetting(ctx, "remote:"+existing, &sealed); err != nil {
				return SiteRow{}, err
			}
			r.mu.Lock()
			r.remotes[existing] = updated
			delete(r.remoteSeen, existing)
			r.mu.Unlock()
			site, _ := r.Site(existing)
			return site, nil
		}
	}
	first := whatwg.MustParse(url).Host()
	if len(hostnames) > 0 {
		first = hostnames[0]
	}
	host := lower(hostIDLetter.ReplaceAllString(first, "-"))
	id := head16(host, 56)
	for n := 2; r.hasSite(id); n++ {
		id = fmt.Sprintf("%s-%d", head16(host, 56), n)
	}
	siteName := head16(jsTrim(stringOf(name)), 80)
	if siteName == "" {
		siteName = js.String(js.Dig(there, "name"))
	}
	timezone := js.String(js.Dig(there, "timezone"))
	if !IsTimezone(timezone) {
		timezone = "UTC"
	}
	// No hostnames: tracker hits never land on a site that is counted elsewhere.
	site := SiteRow{ID: id, Name: siteName, Hostnames: []string{}, Timezone: timezone}
	remote := Remote{URL: url, Token: token, Site: thereID, Hostnames: hostnames, Scope: scope}
	if err := r.Store.UpsertSite(ctx, site, r.now()); err != nil {
		return SiteRow{}, err
	}
	sealed, err := r.seal(js.Stringify(remote))
	if err != nil {
		return SiteRow{}, err
	}
	if err := r.Store.SetSetting(ctx, "remote:"+id, &sealed); err != nil {
		return SiteRow{}, err
	}
	r.mu.Lock()
	r.remotes[id] = remote
	r.remoteOrder = append(r.remoteOrder, id)
	r.configured = append(r.configured, site)
	sortSites(r.configured)
	r.mu.Unlock()
	return site, nil
}

// stringOf is String(value ?? "").
func stringOf(v any) string {
	if v == nil {
		return ""
	}
	if _, u := v.(js.Undefined); u {
		return ""
	}
	return js.String(v)
}

func (r *Runlight) hasSite(id string) bool {
	for _, site := range r.configuredSites() {
		if site.ID == id {
			return true
		}
	}
	return false
}

var nonIDChar = regexp.MustCompile(`[^a-z0-9._-]`)

// AddSite adds a site, when sites are managed in the dashboard: one counted
// here, or one connected from another install.
func (r *Runlight) AddSite(ctx context.Context, input *js.Object) (SiteRow, error) {
	if err := r.Init(ctx); err != nil {
		return SiteRow{}, err
	}
	if !r.ManagedSites {
		return SiteRow{}, settingsError("Sites are set in code", "sites_in_code")
	}
	if remote, ok := input.Value("remote").(*js.Object); ok {
		return r.addRemoteSite(ctx, remote, undefinedIfMissing(input, "name", input.Value("name")))
	}
	hostnames, err := r.hostnamesFor(undefinedIfMissing(input, "hostnames", input.Value("hostnames")), "")
	if err != nil {
		return SiteRow{}, err
	}
	name := jsTrim(field(input, "name"))
	if name == "" {
		name = hostnames[0]
	}
	if len16(name) > 80 {
		return SiteRow{}, settingsError("A site name is 1 to 80 characters", "site_name")
	}
	timezone := "UTC"
	if v, ok := input.Get("timezone"); ok && v != nil {
		timezone = js.String(v)
	}
	if !IsTimezone(timezone) {
		return SiteRow{}, settingsError(`Unknown timezone "`+timezone+`"`, "unknown_timezone", "timezone", timezone)
	}
	stem := head16(nonIDChar.ReplaceAllString(hostnames[0], "-"), 56)
	id := stem
	for n := 2; r.hasSite(id); n++ {
		id = fmt.Sprintf("%s-%d", stem, n)
	}
	site := SiteRow{ID: id, Name: name, Hostnames: hostnames, Timezone: timezone}
	if err := r.Store.UpsertSite(ctx, site, r.now()); err != nil {
		return SiteRow{}, err
	}
	r.mu.Lock()
	r.configured = append(r.configured, site)
	sortSites(r.configured)
	r.mu.Unlock()
	return site, nil
}

// DeleteSite deletes a site and everything recorded for it, when sites are
// managed in the dashboard.
func (r *Runlight) DeleteSite(ctx context.Context, id string) error {
	if err := r.Init(ctx); err != nil {
		return err
	}
	if !r.ManagedSites {
		return settingsError("Sites are set in code", "sites_in_code")
	}
	if !r.hasSite(id) {
		return settingsError("Unknown site", "unknown_site")
	}
	if err := r.Store.DeleteSite(ctx, id); err != nil {
		return err
	}
	for _, key := range []string{"retention:", "observe-key:", "rollup-zone:", "orphans-swept:"} {
		if err := r.Store.SetSetting(ctx, key+id, nil); err != nil {
			return err
		}
	}
	// A site made again with the same id starts its Umami import from the beginning.
	imports, err := r.Store.SettingsStartingWith(ctx, "import:umami-visits:"+id+":")
	if err != nil {
		return err
	}
	for _, s := range imports {
		if err := r.Store.SetSetting(ctx, s.Key, nil); err != nil {
			return err
		}
	}
	// A connected install keeps its own data; only the connection goes, and its token there with it.
	if remote, ok := r.Remote(id); ok {
		r.revokeRemoteToken(ctx, remote)
		r.mu.Lock()
		delete(r.remotes, id)
		for i, k := range r.remoteOrder {
			if k == id {
				r.remoteOrder = append(r.remoteOrder[:i], r.remoteOrder[i+1:]...)
				break
			}
		}
		r.mu.Unlock()
		if err := r.Store.SetSetting(ctx, "remote:"+id, nil); err != nil {
			return err
		}
	}
	r.mu.Lock()
	kept := []SiteRow{}
	for _, site := range r.configured {
		if site.ID != id {
			kept = append(kept, site)
		}
	}
	r.configured = kept
	delete(r.overrides, id)
	r.mu.Unlock()
	return nil
}

// SitePatch is a change to a site: a nil field is left as it is.
type SitePatch struct {
	Name      any
	Timezone  any
	Hostnames any
}

// UpdateSite changes a site's name or timezone from the dashboard. Stored
// apart from the settings in code, which keep being written on every start.
// A managed site has no settings in code, so its changes, hostnames too, go
// to its row.
func (r *Runlight) UpdateSite(ctx context.Context, id string, patch SitePatch) (SiteRow, error) {
	if err := r.Init(ctx); err != nil {
		return SiteRow{}, err
	}
	var current *SiteRow
	for _, site := range r.configuredSites() {
		if site.ID == id {
			s := site
			current = &s
			break
		}
	}
	if current == nil {
		return SiteRow{}, settingsError("Unknown site", "unknown_site")
	}
	checkName := func() (string, error) {
		name := jsTrim(js.String(patch.Name))
		if name == "" || len16(name) > 80 {
			return "", settingsError("A site name is 1 to 80 characters", "site_name")
		}
		return name, nil
	}
	checkZone := func() (string, error) {
		timezone := js.String(patch.Timezone)
		if !IsTimezone(timezone) {
			return "", settingsError(`Unknown timezone "`+timezone+`"`, "unknown_timezone", "timezone", timezone)
		}
		return timezone, nil
	}
	if r.ManagedSites {
		next := *current
		if patch.Name != nil {
			name, err := checkName()
			if err != nil {
				return SiteRow{}, err
			}
			next.Name = name
		}
		if patch.Timezone != nil {
			timezone, err := checkZone()
			if err != nil {
				return SiteRow{}, err
			}
			next.Timezone = timezone
			if site, ok := r.Site(id); !ok || next.Timezone != site.Timezone {
				if _, err := r.zoneChanged(ctx, id, next.Timezone); err != nil {
					return SiteRow{}, err
				}
			}
		}
		if _, remote := r.Remote(id); patch.Hostnames != nil && !remote {
			hostnames, err := r.hostnamesFor(patch.Hostnames, id)
			if err != nil {
				return SiteRow{}, err
			}
			next.Hostnames = hostnames
		}
		if err := r.Store.UpsertSite(ctx, next, r.now()); err != nil {
			return SiteRow{}, err
		}
		r.mu.Lock()
		for i, site := range r.configured {
			if site.ID == id {
				r.configured[i] = next
			}
		}
		r.mu.Unlock()
		site, _ := r.Site(id)
		return site, nil
	}
	r.mu.Lock()
	next := r.overrides[id].Clone()
	r.mu.Unlock()
	if next == nil {
		next = &js.Object{}
	}
	if patch.Name != nil {
		name, err := checkName()
		if err != nil {
			return SiteRow{}, err
		}
		next.Set("name", name)
	}
	if patch.Timezone != nil {
		timezone, err := checkZone()
		if err != nil {
			return SiteRow{}, err
		}
		next.Set("timezone", timezone)
		if site, ok := r.Site(id); !ok || timezone != site.Timezone {
			if _, err := r.zoneChanged(ctx, id, timezone); err != nil {
				return SiteRow{}, err
			}
		}
	}
	if err := r.Store.SetSiteOverrides(ctx, id, next); err != nil {
		return SiteRow{}, err
	}
	r.mu.Lock()
	r.overrides[id] = next
	r.mu.Unlock()
	site, _ := r.Site(id)
	return site, nil
}

// Retention is how many months of visits a site keeps, or nil to keep everything (the default).
func (r *Runlight) Retention(ctx context.Context, site string) (*int64, error) {
	value, ok, err := r.Store.Setting(ctx, "retention:"+site)
	if err != nil {
		return nil, err
	}
	n := js.ToNumber(nil)
	if ok {
		n = js.Number(value)
	}
	for _, m := range RetentionMonths {
		if float64(m) == n {
			return i64(m), nil
		}
	}
	return nil, nil
}

// SetRetention sets how many months of visits a site keeps; nil keeps everything.
func (r *Runlight) SetRetention(ctx context.Context, site string, months *float64) error {
	_, known := r.Site(site)
	if _, remote := r.Remote(site); !known || remote {
		return settingsError("Unknown site", "unknown_site")
	}
	allowed := months == nil
	if months != nil {
		for _, m := range RetentionMonths {
			if float64(m) == *months {
				allowed = true
			}
		}
	}
	if !allowed {
		list := retentionList()
		return settingsError("Keep visits for "+list+" months, or forever", "retention_bad", "months", list)
	}
	var value *string
	if months != nil {
		value = ptr(js.FormatNumber(*months))
	}
	if err := r.Store.SetSetting(ctx, "retention:"+site, value); err != nil {
		return err
	}
	// Deleting a long history takes a while, so it runs in pieces after the answer, with tracking going on between them.
	r.prune(func(ctx context.Context) error { return r.applyRetention(ctx, site) })
	return nil
}

func retentionList() string {
	parts := make([]string, len(RetentionMonths))
	for i, m := range RetentionMonths {
		parts[i] = fmt.Sprint(m)
	}
	return strings.Join(parts, ", ")
}

// prune runs retention work after the answer, one piece of it at a time.
func (r *Runlight) prune(fn func(ctx context.Context) error) {
	r.pruneWG.Add(1)
	go func() {
		defer r.pruneWG.Done()
		r.pruneMu.Lock()
		defer r.pruneMu.Unlock()
		if err := fn(context.Background()); err != nil {
			r.logf("Runlight: could not apply retention %v", err)
		}
	}()
}

// later runs work after the answer, such as an email a right password
// should not wait for; Idle waits for it.
func (r *Runlight) later(fn func(ctx context.Context)) {
	r.pruneWG.Add(1)
	go func() {
		defer r.pruneWG.Done()
		fn(context.Background())
	}()
}

// errURIMalformed is what decodeURIComponent throws for a broken escape.
var errURIMalformed = errors.New("URIError: URI malformed")

// Idle waits for retention work still running; the scheduled check and tests wait for it.
func (r *Runlight) Idle() { r.pruneWG.Wait() }

// zoneChanged clears a site's built days for a new timezone. Visitor ids
// recorded before the change were made per day of the old timezone, and
// could count one person twice in a new day, so only days that start after
// the change are built; earlier ones are always counted visit by visit.
func (r *Runlight) zoneChanged(ctx context.Context, id, timezone string) (int64, error) {
	since := r.now()
	if err := r.Store.ClearRollups(ctx, id, RollupRange{}); err != nil {
		return 0, err
	}
	return since, r.Store.SetSetting(ctx, "rollup-zone:"+id, ptr(js.Stringify(js.NewObject("zone", timezone, "since", since))))
}

// rollupSince is since when a site's days may be built: 0 for always, or
// when its timezone last changed. False when this process holds a different
// timezone than the one on record, such as an older copy still running
// during a deploy.
func (r *Runlight) rollupSince(ctx context.Context, site SiteRow) (int64, bool, error) {
	stored, ok, err := r.Store.Setting(ctx, "rollup-zone:"+site.ID)
	if err != nil {
		return 0, false, err
	}
	if !ok {
		return 0, true, r.Store.SetSetting(ctx, "rollup-zone:"+site.ID, ptr(js.Stringify(js.NewObject("zone", site.Timezone, "since", 0))))
	}
	zone, err := js.Parse(stored)
	if err != nil {
		return 0, false, err
	}
	if js.String(js.Dig(zone, "zone")) != site.Timezone {
		return 0, false, nil
	}
	return int64(js.Num(js.Dig(zone, "since"))), true, nil
}

// BuildRollups adds up each site's finished days, so long ranges read a row
// a day instead of every visit. A day is built two hours after it ends in
// the site's timezone, once late engagement has landed, and at most ten
// days a run, so a long history fills in over a few runs.
func (r *Runlight) BuildRollups(ctx context.Context) (int, error) {
	// Days rolled up by an earlier way of counting are cleared once, and built again below.
	version, _, err := r.Store.Setting(ctx, "rollup-version")
	if err != nil {
		return 0, err
	}
	if version != fmt.Sprint(rollupVersion) {
		for _, site := range r.Sites() {
			if err := r.Store.ClearRollups(ctx, site.ID, RollupRange{}); err != nil {
				return 0, err
			}
		}
		if err := r.Store.SetSetting(ctx, "rollup-version", ptr(fmt.Sprint(rollupVersion))); err != nil {
			return 0, err
		}
	}
	built := 0
	now := r.now()
	batch := rollupBatch
	if r.Store.metered() {
		batch = meteredRollupBatch
	}
	for _, site := range r.Sites() {
		if _, remote := r.Remote(site.ID); remote {
			continue
		}
		first, err := r.Store.FirstSeen(ctx, site.ID)
		if err != nil {
			return built, err
		}
		if first == nil {
			continue
		}
		cutoffP, err := r.RetentionCutoff(ctx, site.ID)
		if err != nil {
			return built, err
		}
		cutoff := int64(0)
		if cutoffP != nil {
			cutoff = *cutoffP
		}
		since, ok, err := r.rollupSince(ctx, site)
		if err != nil {
			return built, err
		}
		if !ok {
			continue
		}
		done, err := r.Store.RollupDays(ctx, site.ID)
		if err != nil {
			return built, err
		}
		today := LocalDate(now, site.Timezone)
		made := 0
		// Newest first, so recent ranges speed up before a long history is done.
		for day := AddDays(today, -1); day >= LocalDate(max(*first, cutoff), site.Timezone) && made < batch; day = AddDays(day, -1) {
			if done[day] {
				continue
			}
			start := StartOf(day, site.Timezone, 0)
			end := StartOf(AddDays(day, 1), site.Timezone, 0)
			if start < since {
				break
			}
			if now < end+rollupDelayMs || start < cutoff {
				continue
			}
			if err := r.Store.BuildRollupDay(ctx, site.ID, day, start, end); err != nil {
				// Another process building the same day at once loses nothing: the day is there either way.
				if days, _ := r.Store.RollupDays(ctx, site.ID); !days[day] {
					r.logf("Runlight: could not add up %s for %s %v", day, site.ID, err)
				}
			} else {
				made++
			}
		}
		built += made
	}
	return built, nil
}

// RetentionCutoff is the oldest moment a site keeps visits from, or nil when it keeps everything.
func (r *Runlight) RetentionCutoff(ctx context.Context, site string) (*int64, error) {
	months, err := r.Retention(ctx, site)
	if err != nil || months == nil {
		return nil, err
	}
	// setUTCMonth(getUTCMonth() - months), which may roll the day over into the next month.
	now := r.now()
	days := js.FloorDiv(now, 86_400_000)
	rest := now - days*86_400_000
	y, m, d := js.CivilFromDays(days)
	return i64(js.DateUTC(y, m-1-*months, d, 0, 0, 0, 0) + rest), nil
}

// applyRetention deletes visits older than each site's retention allows. Cheap when there is nothing to delete.
func (r *Runlight) applyRetention(ctx context.Context, only string) error {
	for _, site := range r.Sites() {
		if _, remote := r.Remote(site.ID); (only != "" && site.ID != only) || remote {
			continue
		}
		cutoff, err := r.RetentionCutoff(ctx, site.ID)
		if err != nil {
			return err
		}
		if cutoff == nil {
			continue
		}
		if err := r.Store.DropBefore(ctx, site.ID, *cutoff); err != nil {
			return err
		}
		// Earlier versions let an event join its visit days late, so retention could leave such an event behind
		// once its visit was gone. They are swept once; events can no longer join a visit that late.
		if _, swept, err := r.Store.Setting(ctx, "orphans-swept:"+site.ID); err != nil {
			return err
		} else if !swept {
			if err := r.Store.DropOrphans(ctx, site.ID, *cutoff, r.now()); err != nil {
				return err
			}
			if err := r.Store.SetSetting(ctx, "orphans-swept:"+site.ID, ptr("1")); err != nil {
				return err
			}
		}
	}
	return nil
}

// Site is the site with an id, or with "" the first.
func (r *Runlight) Site(id string) (SiteRow, bool) {
	sites := r.Sites()
	if id == "" {
		if len(sites) == 0 {
			return SiteRow{}, false
		}
		return sites[0], true
	}
	for _, site := range sites {
		if site.ID == id {
			return site, true
		}
	}
	return SiteRow{}, false
}

// SiteFor is the site a page belongs to, by its hostname and the id the tracker gave ("" for none).
func (r *Runlight) SiteFor(hostname, id string) (SiteRow, bool) {
	host := StripWww(hostname)
	// A site counted by another install never takes hits here.
	if r.hasRemotes() {
		local := []SiteRow{}
		for _, site := range r.Sites() {
			if _, remote := r.Remote(site.ID); !remote {
				local = append(local, site)
			}
		}
		if id != "" {
			if _, remote := r.Remote(id); remote {
				return SiteRow{}, false
			}
		}
		return siteForAmong(local, host, id)
	}
	return siteForAmong(r.Sites(), host, id)
}

func contains(list []string, value string) bool {
	for _, v := range list {
		if v == value {
			return true
		}
	}
	return false
}

func siteForAmong(sites []SiteRow, host, id string) (SiteRow, bool) {
	if id != "" {
		for _, site := range sites {
			if site.ID == id {
				return site, len(site.Hostnames) == 0 || contains(site.Hostnames, host)
			}
		}
		return SiteRow{}, false
	}
	if len(sites) == 1 {
		only := sites[0]
		return only, len(only.Hostnames) == 0 || contains(only.Hostnames, host)
	}
	for _, site := range sites {
		if contains(site.Hostnames, host) {
			return site, true
		}
	}
	return SiteRow{}, false
}

var localName = regexp.MustCompile(`\.(localhost|local|test)$`)

// setupSite is a test from a developer's own machine while a site is being
// set up. A site with no visits yet accepts hits from localhost and .local
// or .test names, so the install screen confirms it works; after its first
// visit they are ignored again.
func (r *Runlight) setupSite(ctx context.Context, hostname, id string) (SiteRow, bool, error) {
	host := strings.TrimSuffix(strings.TrimPrefix(lower(hostname), "["), "]")
	if !(host == "localhost" || host == "127.0.0.1" || host == "::1" || localName.MatchString(host)) {
		return SiteRow{}, false, nil
	}
	var site SiteRow
	var ok bool
	if id != "" {
		site, ok = r.Site(id)
	} else if sites := r.Sites(); len(sites) == 1 {
		site, ok = sites[0], true
	}
	if _, remote := r.Remote(site.ID); !ok || remote {
		return SiteRow{}, false, nil
	}
	last, err := r.Store.LastSeen(ctx, site.ID)
	if err != nil {
		return SiteRow{}, false, err
	}
	return site, last == nil, nil
}

func lastEntry(value string) (string, bool) {
	parts := strings.Split(value, ",")
	for i := len(parts) - 1; i >= 0; i-- {
		if p := strings.TrimSpace(parts[i]); p != "" {
			return p, true
		}
	}
	return "", false
}

// ClientIP is the visitor's address, for the daily visitor hash and the
// rate limit. Behind a proxy it comes from a header: by default the last
// X-Forwarded-For entry, which the nearest proxy wrote and a client cannot
// choose, then X-Real-IP and CF-Connecting-IP.
func (r *Runlight) ClientIP(request *Request) string {
	if r.trust != "" {
		h := request.Header
		var forwarded string
		var ok bool
		switch r.trust {
		case "*":
			if v, has := h.Lookup("x-forwarded-for"); has {
				forwarded, ok = lastEntry(v)
			}
			if !ok {
				forwarded, ok = h.Lookup("x-real-ip")
			}
			if !ok {
				forwarded, ok = h.Lookup("cf-connecting-ip")
			}
		case "x-forwarded-for":
			if v, has := h.Lookup("x-forwarded-for"); has {
				forwarded, ok = lastEntry(v)
			}
		default:
			forwarded, ok = h.Lookup(r.trust)
		}
		if ok && strings.TrimSpace(forwarded) != "" {
			return strings.TrimSpace(forwarded)
		}
		// A public address with no forwarding header means nothing sits in front, and then any client
		// could name its own address in one. Said once, only when the trust was left at its default.
		if r.warnDirect.Load() && web.PublicAddress(request.RemoteAddress) && r.warnDirect.CompareAndSwap(true, false) {
			r.logf("Runlight: a request came straight from a public address with no proxy in front, but trustProxy is on by default, so a client could send X-Forwarded-For and choose its own address, getting round the rate limits. Set IgnoreProxy: true when nothing sits in front of this server, or put a proxy in front that sets the header.")
		}
	}
	return request.RemoteAddress
}

// currentSalts are today's salt in a site's timezone and, if it still
// exists, yesterday's. Salts follow the site's own days, as its reports do,
// so a visitor is one visitor for the whole of that site's day.
func (r *Runlight) currentSalts(ctx context.Context, now int64, timezone string) (salts, error) {
	day := LocalDate(now, timezone)
	r.mu.Lock()
	cached, ok := r.salts[timezone]
	r.mu.Unlock()
	if ok && cached.day == day {
		return cached, nil
	}
	today, err := r.Store.Salt(ctx, day, randomSalt())
	if err != nil {
		return salts{}, err
	}
	yesterday, has, err := r.Store.SaltIfExists(ctx, AddDays(day, -1))
	if err != nil {
		return salts{}, err
	}
	if err := r.dropOldSalts(ctx, now); err != nil {
		return salts{}, err
	}
	s := salts{day: day, today: today, yesterday: yesterday, hasYest: has}
	r.mu.Lock()
	r.salts[timezone] = s
	r.mu.Unlock()
	return s, nil
}

// dropOldSalts deletes salts whose day has ended everywhere. The earliest
// timezone is a day behind UTC and still needs its yesterday, so a salt goes
// two UTC days after its date.
func (r *Runlight) dropOldSalts(ctx context.Context, now int64) error {
	return r.Store.DropSaltsBefore(ctx, utcDay(now-2*86_400_000))
}

// forwardedHost is the host a proxy says the request was for, read only
// when proxy headers are trusted, as the client's address is.
func (r *Runlight) forwardedHost(request *Request) (string, bool) {
	if r.trust == "" {
		return "", false
	}
	return request.Header.Lookup("x-forwarded-host")
}

var busyError = regexp.MustCompile(`(?i)timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked`)

// Collect handles one tracker request. Bad input is dropped quietly.
func (r *Runlight) Collect(ctx context.Context, request *Request) error {
	if length := js.Number(request.Header.Get("content-length")); length > MaxBody {
		return nil
	}
	// Read no more than a tracker hit can be, whatever the length header says (or when there is none).
	if len(request.Body) > MaxBody {
		return nil
	}
	payload := ParsePayload(request.Text())
	if payload == nil {
		return nil
	}
	ua := request.Header.Get("user-agent")
	if AiAgentOf(ua) != nil || IsBot(ua) {
		return nil
	}
	if r.limit != nil && !r.limit.allow(r.ClientIP(request)) {
		return nil
	}
	// A database too busy to take the hit right now (every pooled connection held by long reports, or
	// another process writing the SQLite file) gets it a little later, at the time it arrived.
	now := r.now()
	for attempt := 1; ; attempt++ {
		err := r.record(ctx, payload, request, now)
		if err == nil || attempt >= 3 || !busyError.MatchString(err.Error()) {
			return err
		}
		select {
		case <-ctx.Done():
			return err
		case <-time.After(time.Duration(500*attempt) * time.Millisecond):
		}
	}
}

func (r *Runlight) record(ctx context.Context, payload *Payload, request *Request, now int64) error {
	// Managed sites load from the database in init(), so it must come first.
	if err := r.Init(ctx); err != nil {
		return err
	}
	site, ok := r.SiteFor(payload.URL.Hostname, payload.Site)
	if !ok {
		var err error
		site, ok, err = r.setupSite(ctx, payload.URL.Hostname, payload.Site)
		if err != nil || !ok {
			return err
		}
	}
	if payload.Kind == "engagement" {
		return r.engagement(ctx, site, payload, now)
	}
	page := ParsePage(payload.URL)
	var session *OpenSession
	reopen := true
	if payload.Kind == "event" && payload.PageviewID != "" {
		pageview, err := r.Store.Pageview(ctx, site.ID, payload.PageviewID)
		if err != nil {
			return err
		}
		// An event joins its page's visit unless that visit began longer ago than reports look for its rows
		// (a tab left open for days); it then starts a visit of its own, as any later activity would.
		if pageview != nil && now-pageview.StartedAt < EventTailMs {
			session = &OpenSession{ID: pageview.Session, Visitor: pageview.Visitor}
			// A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
			reopen = now-pageview.LastAt <= SessionIdleMs
			if now-pageview.StartedAt > 3_600_000 {
				if err := r.Store.TouchedOldVisit(ctx, site.ID, pageview.StartedAt, now-rollupDelayMs+3_600_000); err != nil {
					return err
				}
			}
		}
	}
	if session == nil {
		screen := ""
		if payload.ScreenWidth != nil && payload.ScreenHeight != nil && *payload.ScreenWidth != 0 && *payload.ScreenHeight != 0 {
			screen = fmt.Sprintf("%dx%d", *payload.ScreenWidth, *payload.ScreenHeight)
		}
		var err error
		session, err = r.sessionFor(ctx, site, request, page, payload.Referrer, now, payload.ScreenWidth, screen, payload.Language)
		if err != nil {
			return err
		}
	}
	if err := r.Store.TouchSession(ctx, session.ID, now, payload.Kind, page.Path, reopen); err != nil {
		return err
	}
	title, name := "", ""
	if payload.Kind == "pageview" {
		title = payload.Title
	}
	if payload.Kind == "event" {
		name = payload.Name
	}
	return r.Store.InsertEvent(ctx, EventRow{Site: site.ID, Ts: now, Kind: payload.Kind, Visitor: session.Visitor, Session: session.ID, Pageview: payload.PageviewID,
		Path: page.Path, Hostname: page.Hostname, Title: title, Name: name, Props: payload.Props})
}

// sessionFor is the visitor's open session on a site, or a new one
// attributed to this request. Shared by tracker hits and short link clicks.
func (r *Runlight) sessionFor(ctx context.Context, site SiteRow, request *Request, page Page, referrer string, now int64, screenWidth *int, screen, language string) (*OpenSession, error) {
	ua := request.Header.Get("user-agent")
	ip := r.ClientIP(request)
	s, err := r.currentSalts(ctx, now, site.Timezone)
	if err != nil {
		return nil, err
	}
	today := visitorHash(s.today, site.ID, ip, ua)
	candidates := []string{today}
	if s.hasYest && s.yesterday != "" {
		candidates = append(candidates, visitorHash(s.yesterday, site.ID, ip, ua))
	}
	// One visitor's requests often arrive together (a pageview and the event right after it). Taking turns
	// per visitor means only the first opens a session and the rest find it, instead of each opening its own.
	unlock := r.oneAtATime(site.ID + ":" + today)
	defer unlock()
	open, err := r.Store.OpenSession(ctx, site.ID, candidates, now-SessionIdleMs)
	if err != nil || open != nil {
		return open, err
	}
	session := &OpenSession{ID: randomID(12), Visitor: today}
	attribution := Attribute(page, referrer, site.Hostnames)
	hints := ClientHints{}
	if v, ok := request.Header.Lookup("sec-ch-ua"); ok {
		hints.Brands = &v
	}
	if v, ok := request.Header.Lookup("sec-ch-ua-mobile"); ok {
		hints.Mobile = &v
	}
	if v, ok := request.Header.Lookup("sec-ch-ua-platform"); ok {
		hints.Platform = &v
	}
	parsed := ParseClient(ua, hints, screenWidth)
	location := Locate(request.Header, ip, r.geo)
	err = r.Store.InsertSession(ctx, SessionRow{
		ID: session.ID, Site: site.ID, Visitor: session.Visitor, StartedAt: now, Hostname: page.Hostname,
		ReferrerHost: attribution.ReferrerHost, ReferrerPath: attribution.ReferrerPath, Source: attribution.Source, Channel: attribution.Channel,
		UtmSource: page.Utm.Source, UtmMedium: page.Utm.Medium, UtmCampaign: page.Utm.Campaign, UtmTerm: page.Utm.Term, UtmContent: page.Utm.Content,
		Country: location.Country, Region: location.Region, City: location.City,
		Browser: parsed.Browser, BrowserVersion: parsed.BrowserVersion, OS: parsed.OS, OSVersion: parsed.OSVersion, Device: parsed.Device,
		Screen: screen, Language: language,
	})
	return session, err
}

// linkDomainSet is the link domains, read at most every 30 seconds.
func (r *Runlight) linkDomainSet(ctx context.Context) (map[string]bool, error) {
	now := r.now()
	r.mu.Lock()
	cache := r.linkDomains
	r.mu.Unlock()
	if cache != nil && now-cache.at < 30_000 {
		return cache.domains, nil
	}
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	list, err := r.Store.LinkDomains(ctx)
	if err != nil {
		return nil, err
	}
	domains := map[string]bool{}
	for _, d := range list {
		domains[d.Domain] = true
	}
	r.mu.Lock()
	r.linkDomains = &linkDomainCache{at: now, domains: domains}
	r.mu.Unlock()
	return domains, nil
}

// ForgetLinkDomains clears the cached link domains after one is added or removed.
func (r *Runlight) ForgetLinkDomains() {
	r.mu.Lock()
	r.linkDomains = nil
	r.mu.Unlock()
}

// oneAtATime takes the turn for a key, and gives back its release: work
// with the same key runs one after another.
func (r *Runlight) oneAtATime(key string) func() {
	r.turnsMu.Lock()
	t, ok := r.turns[key]
	if !ok {
		t = &turn{}
		r.turns[key] = t
	}
	t.users++
	r.turnsMu.Unlock()
	t.mu.Lock()
	return func() {
		t.mu.Unlock()
		r.turnsMu.Lock()
		t.users--
		if t.users == 0 {
			delete(r.turns, key)
		}
		r.turnsMu.Unlock()
	}
}

func notFoundText() *Response {
	return web.NewResponse(404, []byte("Not found"), "content-type", "text/plain; charset=utf-8")
}

// LinkHandler handles {LinkPath}/{slug} on the app's own domain.
func (r *Runlight) LinkHandler() func(ctx context.Context, request *Request) *Response {
	return func(ctx context.Context, request *Request) *Response {
		path := request.Parsed().Pathname
		slug := ""
		if strings.HasPrefix(path, r.LinkPath+"/") {
			decoded, ok := decodeURIComponent(path[len(r.LinkPath)+1:])
			if !ok {
				return internalError(r, errors.New("URIError: URI malformed"))
			}
			slug = decoded
		}
		if slug != "" && !strings.Contains(slug, "/") {
			found, err := r.Redirect(ctx, request, slug, "")
			if err != nil {
				return internalError(r, err)
			}
			if found != nil {
				return found
			}
		}
		return notFoundText()
	}
}

// internalError is what an unexpected failure answers: the error goes to
// the log, and the caller gets a plain 500.
func internalError(r *Runlight, err error) *Response {
	r.logf("Runlight: %v", err)
	return web.NewResponse(500, []byte("Internal Server Error"), "content-type", "text/plain; charset=utf-8")
}

// LinkDomainResponse is, for middleware, the answer for a request on a link
// domain added in Settings (such as t.example.com): /{slug} there is the
// redirect, and anything else a 404. nil for every other host, so the app
// carries on as normal, and for the dashboard's own paths, so its owner can
// always reach it to remove the domain.
func (r *Runlight) LinkDomainResponse(ctx context.Context, request *Request) (*Response, error) {
	u := request.Parsed()
	// A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
	given, ok := r.forwardedHost(request)
	if !ok {
		given, ok = request.Header.Lookup("host")
	}
	if !ok {
		given = u.Host()
	}
	host := StripWww(strings.Split(strings.TrimSpace(strings.Split(given, ",")[0]), ":")[0])
	domains, err := r.linkDomainSet(ctx)
	if err != nil {
		return nil, err
	}
	if !domains[host] {
		return nil, nil
	}
	// Lets the dashboard confirm that requests to this domain reach Runlight.
	if u.Pathname == LinkDomainCheck {
		return web.NewResponse(200, []byte(js.Stringify(js.NewObject("runlight", true, "domain", host))), "content-type", "application/json", "cache-control", "no-store"), nil
	}
	r.mu.Lock()
	bases := []string{}
	for b := range r.routeBases {
		bases = append(bases, b)
	}
	r.mu.Unlock()
	if len(bases) == 0 {
		bases = []string{"/runlight"}
	}
	for _, base := range bases {
		if base != "/" && (u.Pathname == base || strings.HasPrefix(u.Pathname, base+"/")) {
			return nil, nil
		}
	}
	slug, ok := decodeURIComponent(u.Pathname[1:])
	if !ok {
		return nil, errors.New("URIError: URI malformed")
	}
	if slug != "" && !strings.Contains(slug, "/") {
		found, err := r.Redirect(ctx, request, slug, host)
		if err != nil {
			return nil, err
		}
		if found != nil {
			return found, nil
		}
	}
	return notFoundText(), nil
}

// Redirect answers a request for a short link: a redirect to its
// destination, with the click recorded like a visit (source, place, device,
// and any campaign tags on the short URL) but kept out of visitor and
// pageview counts. Bots are redirected and not counted. domain is the link
// domain the request came in on, or "" for the app's own link path, which
// answers for every link. nil when no link fits.
func (r *Runlight) Redirect(ctx context.Context, request *Request, slug, domain string) (*Response, error) {
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	u := request.Parsed()
	given, ok := r.forwardedHost(request)
	if !ok {
		given, ok = request.Header.Lookup("host")
	}
	if !ok {
		given = u.Host()
	}
	host := StripWww(strings.Split(given, ":")[0])
	link, err := r.Store.LinkBySlug(ctx, slug)
	if err != nil {
		return nil, err
	}
	// The app's own link path answers for every link, so a link whose domain was removed keeps working; a
	// link domain answers only for its own links.
	if link == nil || (domain != "" && link.Domain != domain) {
		return nil, nil
	}
	site, ok := r.Site(link.Site)
	if !ok {
		site, ok = r.Site("")
	}
	ua := request.Header.Get("user-agent")
	if ok && AiAgentOf(ua) == nil && !IsBot(ua) && request.Method == "GET" {
		if err := r.recordClick(ctx, request, u, site, link, host); err != nil {
			// A failed count must never break the redirect.
			r.logf("Runlight: could not record a link click %v", err)
		}
	}
	return web.NewResponse(302, nil, "location", link.URL, "cache-control", "no-store", "referrer-policy", "no-referrer-when-downgrade"), nil
}

func (r *Runlight) recordClick(ctx context.Context, request *Request, u *whatwg.URL, site SiteRow, link *LinkRow, host string) error {
	now := r.now()
	language := strings.Split(request.Header.Get("accept-language"), ",")[0]
	language = head16(jsTrim(strings.Split(language, ";")[0]), 35)
	referer := request.Header.Get("referer")
	session, err := r.sessionFor(ctx, site, request, ParsePage(u), referer, now, nil, "", language)
	if err != nil {
		return err
	}
	if err := r.Store.TouchSession(ctx, session.ID, now, "click", u.Pathname, true); err != nil {
		return err
	}
	return r.Store.InsertEvent(ctx, EventRow{Site: site.ID, Ts: now, Kind: "click", Visitor: session.Visitor, Session: session.ID,
		Path: head16(u.Pathname, 1000), Hostname: host, Name: link.Slug, Link: link.ID})
}

func (r *Runlight) engagement(ctx context.Context, site SiteRow, payload *Payload, now int64) error {
	if payload.EngagedMs <= 0 {
		return nil
	}
	pageview, err := r.Store.Pageview(ctx, site.ID, payload.PageviewID)
	if err != nil {
		return err
	}
	// Reports look for a visit's rows only so long after it began, so later time on it is let go.
	if pageview == nil || now-pageview.StartedAt >= EventTailMs {
		return nil
	}
	if err := r.Store.AddEngagement(ctx, pageview.Session, payload.EngagedMs); err != nil {
		return err
	}
	// Only a visit that began more than an hour ago can belong to a day that is already added up.
	if now-pageview.StartedAt > 3_600_000 {
		if err := r.Store.TouchedOldVisit(ctx, site.ID, pageview.StartedAt, now-rollupDelayMs+3_600_000); err != nil {
			return err
		}
	}
	return r.Store.InsertEvent(ctx, EventRow{Site: site.ID, Ts: now, Kind: "engagement", Visitor: pageview.Visitor, Session: pageview.Session,
		Pageview: payload.PageviewID, Path: pageview.Path, Hostname: pageview.Hostname, EngagedMs: payload.EngagedMs, Scroll: payload.Scroll})
}

var pageExtension = regexp.MustCompile(`\.([A-Za-z0-9]+)$`)

// Observe records a request from a known AI agent. Call it from middleware
// for every page request; it ignores everything else and never fails. at is
// when a log says the page was served, or nil for now. Agents do not run
// JavaScript, so the tracker cannot see them.
func (r *Runlight) Observe(ctx context.Context, request *Request, at *float64) bool {
	ok, err := r.observe(ctx, request, at)
	if err != nil {
		// Analytics must never break the page it watches, but a failure should still be seen.
		r.logf("Runlight: could not record an AI agent fetch %v", err)
		return false
	}
	return ok
}

func (r *Runlight) observe(ctx context.Context, request *Request, at *float64) (bool, error) {
	if request.Method != "GET" {
		return false, nil
	}
	agent := AiAgentOf(request.Header.Get("user-agent"))
	if agent == nil {
		return false, nil
	}
	u := request.Parsed()
	// Pages, not their assets.
	if m := pageExtension.FindStringSubmatch(u.Pathname); m != nil {
		switch lower(m[1]) {
		case "html", "htm", "md", "txt", "php":
		default:
			return false, nil
		}
	}
	host, ok := r.forwardedHost(request)
	if !ok {
		host, ok = request.Header.Lookup("host")
	}
	if !ok {
		host = u.Hostname
	}
	if err := r.Init(ctx); err != nil {
		return false, err
	}
	site, ok := r.SiteFor(strings.Split(host, ":")[0], "")
	if !ok {
		return false, nil
	}
	// A log reader sends when the page was served. Older than a week is dropped, so a first run over an old
	// log does not land as one spike on today; a time ahead of now counts as now.
	now := r.now()
	finite := at != nil && !math.IsNaN(*at) && !math.IsInf(*at, 0)
	if finite && *at < float64(now-7*86_400_000) {
		return false, nil
	}
	ts := now
	if finite && *at <= float64(now) {
		ts = int64(math.Floor(*at))
	}
	return true, r.Store.InsertEvent(ctx, EventRow{Site: site.ID, Ts: ts, Kind: "fetch", Path: head16(u.Pathname, 1000), Hostname: StripWww(u.Hostname),
		Name: agent.Name, Props: js.NewObject("company", agent.Company, "kind", agent.Kind)})
}

// CheckResult is what a scheduled check did.
type CheckResult struct {
	OK      bool         `json:"ok"`
	Reports ReportsCount `json:"reports"`
}

// ReportsCount is how many email reports went out, and how many failed.
type ReportsCount struct {
	Sent   int `json:"sent"`
	Failed int `json:"failed"`
}

// Check is the scheduled upkeep, safe to run every minute. It rotates salts,
// sends the email reports that are due, deletes visits past each site's
// retention, and builds daily rollups. It also rereads sites, their
// dashboard settings, and connected installs, so a change made by another
// process sharing the database shows up here too.
func (r *Runlight) Check(ctx context.Context) (CheckResult, error) {
	// A check still running when the next is due (a long retention, say) is shared, never run twice at once.
	r.checkMu.Lock()
	run := r.checking
	if run == nil {
		run = &checkRun{done: make(chan struct{})}
		r.checking = run
		go func() {
			run.result, run.err = r.runCheck(context.WithoutCancel(ctx))
			r.checkMu.Lock()
			r.checking = nil
			r.checkMu.Unlock()
			close(run.done)
		}()
	}
	r.checkMu.Unlock()
	select {
	case <-run.done:
		return run.result, run.err
	case <-ctx.Done():
		return CheckResult{}, ctx.Err()
	}
}

func (r *Runlight) runCheck(ctx context.Context) (CheckResult, error) {
	if err := r.Init(ctx); err != nil {
		return CheckResult{}, err
	}
	if r.ManagedSites {
		sites, err := r.Store.Sites(ctx)
		if err != nil {
			return CheckResult{}, err
		}
		r.mu.Lock()
		r.configured = sites
		r.mu.Unlock()
		if err := r.loadRemotes(ctx); err != nil {
			return CheckResult{}, err
		}
	}
	// A name or timezone changed in the dashboard by another process reaches this one too.
	overrides, _, err := r.Store.SiteOverrides(ctx)
	if err != nil {
		return CheckResult{}, err
	}
	r.mu.Lock()
	r.overrides = overrides
	r.salts = map[string]salts{}
	r.mu.Unlock()
	seen := map[string]bool{}
	for _, site := range r.Sites() {
		if seen[site.Timezone] {
			continue
		}
		seen[site.Timezone] = true
		if _, err := r.currentSalts(ctx, r.now(), site.Timezone); err != nil {
			return CheckResult{}, err
		}
	}
	if err := r.dropOldSalts(ctx, r.now()); err != nil {
		return CheckResult{}, err
	}
	r.prune(func(ctx context.Context) error { return r.applyRetention(ctx, "") })
	r.Idle()
	if r.now()-r.optimized >= 86_400_000 {
		r.optimized = r.now()
		r.Store.Optimize(ctx, false)
	}
	if _, err := r.BuildRollups(ctx); err != nil {
		return CheckResult{}, err
	}
	reports, err := r.SendReports(ctx)
	if err != nil {
		return CheckResult{}, err
	}
	return CheckResult{OK: true, Reports: reports}, nil
}
