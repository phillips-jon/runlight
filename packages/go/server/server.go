// Package server is the standalone server: Runlight's routes at the root of
// their own domain, behind a sign-in, with sites managed in the dashboard and
// short links answered on any domain pointed at it. The runlight command
// (runlight.sh/go/cmd/runlight) runs it; this package is for embedding it.
package server

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"regexp"
	"strings"
	"sync"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Options configure the server.
type Options struct {
	Store *runlight.Store
	// Secret signs sessions and encrypts saved keys, such as the mail
	// service's and two-factor secrets. Keep it stable across restarts.
	Secret string
	// Token is also accepted as a bearer token on the API, for scripts.
	Token string
	// URL is the dashboard's public address, such as https://stats.example.com.
	// It can never become a link domain, short links never answer on it, and
	// emails link to it whatever Host header a request carries.
	URL string
	// IgnoreProxy reads only the connection's address, for a server nothing
	// sits in front of. By default forwarded headers are trusted.
	IgnoreProxy bool
	// ProxyHeader names the one forwarding header to read, such as cf-connecting-ip.
	ProxyHeader string
	Geo         runlight.GeoLookup
	// GeoCredit credits DB-IP in the dashboard, when its free data supplies locations.
	GeoCredit bool
	Now       func() int64
	Fetcher   runlight.Fetcher
	Logf      func(format string, args ...any)
}

// Server is a running standalone server's parts.
type Server struct {
	Runlight *runlight.Runlight
	Accounts *runlight.AccountStore
	// SetupCode is the one-time code that unlocks /setup while no account exists.
	SetupCode string

	options    Options
	publicHost string
	web        *runlight.AccountsWeb
	routes     *runlight.Routes
	links      func(ctx context.Context, request *runlight.Request) *runlight.Response
	logf       func(format string, args ...any)

	mu        sync.Mutex
	ownHosts  []string
	ownLoaded bool
}

// serverPaths are the server's own pages, which answer as the server on every name it is reached at, a link domain too.
var serverPaths = map[string]bool{"/login": true, "/logout": true, "/setup": true, "/invite": true, "/healthz": true, "/auth.css": true, "/auth.js": true, "/api": true, "/mcp": true, "/s.js": true, "/pick.js": true, "/e": true}

// maxOwnHosts is the most names remembered as the server's own. The first
// ones stay and later ones are not learned, so a server reached at more names
// than this needs a URL to keep the rest from becoming link domains.
const maxOwnHosts = 20

var (
	oneSegment = regexp.MustCompile(`^/[^/]*$`)
	goLink     = regexp.MustCompile(`^/go/[^/]+/?$`)
)

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// New makes the server.
func New(options Options) (*Server, error) {
	logf := options.Logf
	if logf == nil {
		logf = func(format string, args ...any) {}
	}
	s := &Server{options: options, SetupCode: runlight.SetupCode(), logf: logf}
	var origin string
	if options.URL != "" {
		u, err := whatwg.Parse(options.URL)
		if err != nil {
			return nil, err
		}
		origin = u.Origin()
		s.publicHost = runlight.HostName(u.Host())
	}
	rl, err := runlight.New(runlight.Options{
		Store: options.Store, ManagedSites: true, Secret: &options.Secret, IgnoreProxy: options.IgnoreProxy, ProxyHeader: options.ProxyHeader,
		Geo: options.Geo, Now: options.Now, Fetcher: options.Fetcher, Logf: options.Logf,
	})
	if err != nil {
		return nil, err
	}
	s.Runlight = rl
	now := options.Now
	if now == nil {
		now = rl.Now
	}
	// Accounts, shared with apps that turn them on. The first one is made with the code the server prints at start,
	// and emails link to its public address, or else the first name the owner or an admin signed in from.
	s.web = runlight.NewAccountsWeb(runlight.AccountsWebOptions{
		Runlight: rl, Secret: options.Secret, Base: "", Now: now,
		FirstAccount: runlight.FirstAccount{Mode: "code", Code: s.SetupCode},
		Home: func(ctx context.Context) string {
			if origin != "" {
				return origin
			}
			if hosts := s.knownHosts(ctx); len(hosts) > 0 {
				return "https://" + hosts[0]
			}
			return ""
		},
		Forgot: "https://runlight.sh/docs/server/#forgotten-passwords",
	})
	s.Accounts = s.web.Accounts
	base := ""
	// The cron route is never needed: the server runs the check itself.
	cronSecret := randomHex(32)
	s.routes, err = rl.Routes(runlight.RoutesOptions{
		BasePath: &base, CronSecret: &cronSecret, SignOut: "/logout", SignIn: "/login", GeoCredit: options.GeoCredit, AccountsWeb: s.web,
		Authorize: func(ctx context.Context, request *runlight.Request) runlight.Access {
			auth := request.Header.Get("authorization")
			if options.Token != "" && strings.HasPrefix(strings.ToLower(auth), "bearer ") && subtle.ConstantTimeCompare([]byte(strings.TrimSpace(auth[7:])), []byte(options.Token)) == 1 {
				return runlight.AccessFull
			}
			access := s.web.Access(ctx, request)
			if access == runlight.AccessFull {
				s.learnHost(ctx, request)
			}
			return access
		},
		Origin:   origin,
		OwnHosts: s.knownHosts,
	})
	if err != nil {
		return nil, err
	}
	s.links = rl.LinkHandler()
	return s, nil
}

// hostOf is the name a request came in on, read as link domains read it.
func (s *Server) hostOf(request *runlight.Request) string {
	if !s.options.IgnoreProxy {
		if host, ok := request.Header.Lookup("x-forwarded-host"); ok {
			return runlight.HostName(host)
		}
	}
	if host, ok := request.Header.Lookup("host"); ok {
		return runlight.HostName(host)
	}
	return runlight.HostName(request.Parsed().Host())
}

func (s *Server) savedHosts(ctx context.Context) []string {
	if err := s.Runlight.Init(ctx); err != nil {
		return nil
	}
	stored, has, err := s.options.Store.Setting(ctx, "server-hosts")
	if err != nil || !has {
		return nil
	}
	parsed, err := js.Parse(stored)
	if err != nil {
		return nil
	}
	out := []string{}
	for _, v := range js.Arr(parsed) {
		out = append(out, js.String(v))
	}
	return out
}

// knownHosts are the names the owner and admins signed in from, kept in the
// database, so a link domain can never be one of them even when whoever adds
// it picks another Host header.
func (s *Server) knownHosts(ctx context.Context) []string {
	s.mu.Lock()
	loaded := s.ownLoaded
	s.mu.Unlock()
	if !loaded {
		saved := s.savedHosts(ctx)
		s.mu.Lock()
		if !s.ownLoaded {
			s.ownHosts, s.ownLoaded = dedupe(saved), true
		}
		s.mu.Unlock()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.ownHosts...)
}

func dedupe(list []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, v := range list {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// learnHost remembers a name the owner or an admin signed in from. Only they
// teach them, since anyone else could fill the list with made-up names, and
// only real domain names. Names that are already link domains are left out.
func (s *Server) learnHost(ctx context.Context, request *runlight.Request) {
	host := s.hostOf(request)
	known := s.knownHosts(ctx)
	if !runlight.IsDomainName(host) || contains(known, host) || len(known) >= maxOwnHosts {
		return
	}
	domains, err := s.options.Store.LinkDomains(ctx)
	if err != nil {
		return
	}
	for _, d := range domains {
		if d.Domain == host {
			return
		}
	}
	// Another copy of the server may have saved names since this one read them.
	all := dedupe(append(append(known, s.savedHosts(ctx)...), host))
	if len(all) > maxOwnHosts {
		all = all[:maxOwnHosts]
	}
	s.mu.Lock()
	s.ownHosts = all
	s.mu.Unlock()
	value := js.Stringify(all)
	if err := s.options.Store.SetSetting(ctx, "server-hosts", &value); err != nil {
		s.logf("Runlight: %v", err)
	}
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// Handle answers one request.
func (s *Server) Handle(ctx context.Context, request *runlight.Request) *runlight.Response {
	path := request.Parsed().Pathname
	// A domain pointed at this server for short links answers at its root, with links one segment deep. The
	// server's own pages and its public address never answer as links, and "/" stays the dashboard for someone
	// signed in, so a link domain added on the dashboard's own name can always be removed again.
	linkable := path == runlight.LinkDomainCheck
	if !linkable && oneSegment.MatchString(path) && !serverPaths[path] {
		linkable = true
		if path == "/" {
			if user, err := s.web.SignedIn(ctx, request); err == nil && user != nil {
				linkable = false
			}
		}
	}
	if linkable && !(s.publicHost != "" && s.hostOf(request) == s.publicHost) {
		linked, err := s.Runlight.LinkDomainResponse(ctx, request)
		if err != nil {
			s.logf("Runlight: %v", err)
			return runlight.Coded("Internal error", "internal", 500, nil)
		}
		if linked != nil {
			return linked
		}
	}
	if path == "/healthz" {
		return web.NewResponse(200, []byte("ok"), "content-type", "text/plain", "cache-control", "no-store")
	}
	if goLink.MatchString(path) && request.Method == "GET" {
		return s.links(ctx, request)
	}
	// Everything else, the sign-in pages and People included, is the routes'.
	return s.routes.Handle(ctx, request)
}

// ServeHTTP makes the server an http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	runlight.HTTPHandler(s.Handle).ServeHTTP(w, req)
}

// Check runs the scheduled work: salts, email reports that are due, retention, and rollups.
func (s *Server) Check(ctx context.Context) error {
	_, err := s.Runlight.Check(ctx)
	return err
}
