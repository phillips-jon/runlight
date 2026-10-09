// Package runlightchi serves Runlight from a chi router: the dashboard and
// API under the routes' base path, the OAuth documents MCP clients look for
// at the site's root, and short links on the app's own domain.
//
//	rl, err := runlight.New(runlight.Options{Store: store, Site: &runlight.SiteOptions{Hostnames: []string{"example.com"}}})
//	routes, err := rl.Routes(runlight.RoutesOptions{})
//	r := chi.NewRouter()
//	r.Use(rl.Observer)
//	runlightchi.Mount(r, rl, routes)
package runlightchi

import (
	"github.com/go-chi/chi/v5"

	runlight "runlight.sh/go"
)

// Mount adds Runlight to r: the routes at their base path and everything
// below it, the OAuth discovery documents, and GET {LinkPath}/{slug} for
// short links. Mount it on the top router, since the routes read the full
// path.
func Mount(r chi.Router, rl *runlight.Runlight, routes *runlight.Routes) {
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
