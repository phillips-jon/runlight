package runlight

// net/http: Runlight's routes, short links, and AI agent fetches served from
// Go's own server and the routers built on it (chi, echo, gorilla/mux, and
// http.ServeMux).
//
//	routes, err := rl.Routes(runlight.RoutesOptions{})
//	mux.Handle("/runlight/", routes)
//	mux.Handle("/runlight", routes)
//	mux.Handle("GET /go/{slug}", rl.LinksHTTP())
//	http.ListenAndServe(":8080", rl.LinkDomains(rl.Observer(mux)))
//
// routes.Middleware(next) and rl.LinkDomains(next) answer link domains
// before the app's own routing; a handler mounted at a path never sees them.

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"

	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

const (
	// maxCollectBody is the collect endpoint's limit; its payloads are under 8 KB.
	maxCollectBody = 16 * 1024
	// maxBody is everything else, such as a link import of 5,000 rows.
	maxBody = 10 * 1024 * 1024
)

// ErrBodyTooLarge is a request body past its limit, answered with 413
// rather than passed on cut short.
var ErrBodyTooLarge = errors.New("runlight: request body too large")

// FromHTTP is an http.Request as Runlight's request: an absolute URL from
// the Host header and X-Forwarded-Proto (or the connection's TLS), the
// headers, the body (16 KB at most for the collect endpoint, 10 MB for
// anything else), and the address the connection came from.
func FromHTTP(req *http.Request) (*Request, error) {
	out := headOf(req)
	if req.Method != "GET" && req.Method != "HEAD" && req.Body != nil {
		limit := int64(maxBody)
		if strings.HasSuffix(req.URL.Path, "/e") {
			limit = maxCollectBody
		}
		body, err := io.ReadAll(io.LimitReader(req.Body, limit+1))
		if err != nil {
			return nil, err
		}
		if int64(len(body)) > limit {
			return nil, ErrBodyTooLarge
		}
		out.Body = body
	}
	return out, nil
}

// headOf is an http.Request as Runlight's request without its body, which is left unread.
func headOf(req *http.Request) *Request {
	proto := "http"
	if req.TLS != nil {
		proto = "https"
	}
	if forwarded := strings.ToLower(strings.TrimSpace(strings.Split(req.Header.Get("x-forwarded-proto"), ",")[0])); forwarded != "" {
		proto = forwarded
	}
	if proto != "https" {
		proto = "http"
	}
	host := req.Host
	if host == "" {
		host = "localhost"
	}
	target := req.RequestURI
	if target == "" || !strings.HasPrefix(target, "/") {
		target = req.URL.RequestURI()
	}
	href := "http://localhost/"
	if u, err := whatwg.Parse(target, proto+"://"+host); err == nil {
		href = u.Href()
	}
	headers := &web.Headers{}
	for name, values := range req.Header {
		for _, v := range values {
			headers.Append(name, v)
		}
	}
	if !headers.Has("host") && req.Host != "" {
		headers.Set("host", req.Host)
	}
	out := web.NewRequest(req.Method, href, headers, nil)
	out.RemoteAddress = remoteAddress(req.RemoteAddr)
	return out
}

// remoteAddress is the connection's address without its port.
func remoteAddress(addr string) string {
	if host, _, err := net.SplitHostPort(addr); err == nil {
		return host
	}
	return addr
}

// WriteHTTP sends Runlight's answer through w.
func WriteHTTP(w http.ResponseWriter, answer *Response) {
	header := w.Header()
	for _, name := range answer.Header.Names() {
		if name == "set-cookie" {
			for _, cookie := range answer.Header.SetCookies() {
				header.Add("Set-Cookie", cookie)
			}
			continue
		}
		header.Set(name, answer.Header.Get(name))
	}
	w.WriteHeader(answer.Status)
	if len(answer.Body) > 0 {
		_, _ = w.Write(answer.Body)
	}
}

// HTTPHandler is a Runlight handler, such as LinkHandler's, as an http.Handler.
func HTTPHandler(handle func(ctx context.Context, request *Request) *Response) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		request, err := FromHTTP(req)
		if err != nil {
			tooLarge(w, err)
			return
		}
		WriteHTTP(w, handle(req.Context(), request))
	})
}

func tooLarge(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrBodyTooLarge) {
		// An upload cut off part way leaves the connection unfit for another request.
		w.Header().Set("connection", "close")
		w.Header().Set("content-type", "application/json; charset=utf-8")
		w.WriteHeader(413)
		_, _ = w.Write([]byte(`{"error":"That request is too large"}`))
		return
	}
	w.WriteHeader(400)
}

// ServeHTTP answers the routes: mount them at their base path and below it,
// such as "/runlight" and "/runlight/". The request's context ending stops
// the work, such as a report or a pass-through to a connected install.
func (rt *Routes) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	HTTPHandler(rt.Handle).ServeHTTP(w, req)
}

// Owns reports whether a path is the routes' own: the base path and
// everything below it, and the OAuth documents at the site's root.
func (rt *Routes) Owns(path string) bool {
	return rt.base == "" || path == rt.base || strings.HasPrefix(path, rt.base+"/") || isOauthDocument(path)
}

// Middleware answers the link domains added in Settings and the routes' own
// paths, and passes every other request to next unread, for an app that
// sends every request through one handler.
func (rt *Routes) Middleware(next http.Handler) http.Handler {
	return rt.r.LinkDomains(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if !rt.Owns(req.URL.Path) {
			next.ServeHTTP(w, req)
			return
		}
		rt.ServeHTTP(w, req)
	}))
}

// LinkDomains is middleware that answers requests on the link domains added
// in Settings (such as go.example.com): /{slug} there is the redirect, and
// anything else a 404. Every other request goes on to next untouched, its
// body unread, so the app's own pages are as they were. The routes' own
// paths go on too, so an owner can always reach the dashboard to remove a
// domain.
func (r *Runlight) LinkDomains(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		answer, err := r.LinkDomainResponse(req.Context(), headOf(req))
		if err != nil {
			WriteHTTP(w, internalError(r, err))
			return
		}
		if answer != nil {
			WriteHTTP(w, answer)
			return
		}
		next.ServeHTTP(w, req)
	})
}

// OAuthDocuments are the discovery documents OAuth clients read at the
// site's root, which the routes answer when an app sends them there. Each is
// also answered with a path after it.
var OAuthDocuments = []string{"/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"}

// LinksHTTP answers short links on the app's own domain, at {LinkPath}/{slug}.
func (r *Runlight) LinksHTTP() http.Handler { return HTTPHandler(r.LinkHandler()) }

// Observer is middleware that records AI agent fetches of the app's pages
// and always passes the request on. It reads only the URL and headers, never
// the body, and the recording runs beside the request, so the page is not
// held up.
func (r *Runlight) Observer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		// Most requests are people, which need no more than this look at the user agent.
		if req.Method == "GET" && AiAgentOf(req.Header.Get("user-agent")) != nil {
			if request, err := FromHTTP(req); err == nil {
				r.later(func(ctx context.Context) { r.Observe(ctx, request, nil) })
			}
		}
		next.ServeHTTP(w, req)
	})
}
