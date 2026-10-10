// Package runlightchi serves Runlight from a chi router: the link domains
// added in Settings, the dashboard and API under the routes' base path, the
// OAuth documents MCP clients look for at the site's root, and short links
// on the app's own domain.
//
//	rl, err := runlight.New(runlight.Options{Store: store, Site: &runlight.SiteOptions{Hostnames: []string{"example.com"}}})
//	routes, err := rl.Routes(runlight.RoutesOptions{})
//	r := chi.NewRouter()
//	r.Use(rl.Observer)
//	runlightchi.Mount(r, rl, routes)
package runlightchi

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	runlight "runlight.sh/go"
)

// Mount adds Runlight to r: middleware that answers the link domains added
// in Settings before the app's own routes, the routes at their base path and
// everything below it, the OAuth discovery documents, and GET
// {LinkPath}/{slug} for short links. Mount it on the top router, since the
// routes read the full path, and before the app's own routes, since chi
// takes middleware only until the first route.
func Mount(r chi.Router, rl *runlight.Runlight, routes *runlight.Routes) {
	linkDomains(r, rl)
	base := routes.Base()
	r.Handle(base+"/*", routes)
	if base != "" {
		r.Handle(base, routes)
		for _, document := range runlight.OAuthDocuments {
			r.Handle(document, routes)
			r.Handle(document+"/*", routes)
		}
	}
	r.Method("GET", rl.LinkPath+"/{slug}", rl.LinksHTTP())
}

// linkDomains puts rl.LinkDomains in front of r's routes. On a router that
// already has routes, which chi refuses middleware, link domains are answered
// only where no route matches the path.
func linkDomains(r chi.Router, rl *runlight.Runlight) {
	defer func() {
		refused := recover()
		if refused == nil {
			return
		}
		if !strings.Contains(fmt.Sprint(refused), "middlewares must be defined before routes") {
			panic(refused)
		}
		notFound := http.NotFoundHandler()
		if mux, ok := r.(interface{ NotFoundHandler() http.HandlerFunc }); ok {
			notFound = mux.NotFoundHandler()
		}
		r.NotFound(rl.LinkDomains(notFound).ServeHTTP)
	}()
	r.Use(rl.LinkDomains)
}
