// Package runlightecho serves Runlight from an Echo app: the link domains
// added in Settings, the dashboard and API under the routes' base path, the
// OAuth documents MCP clients look for at the site's root, and short links
// on the app's own domain.
//
//	rl, err := runlight.New(runlight.Options{Store: store, Site: &runlight.SiteOptions{Hostnames: []string{"example.com"}}})
//	routes, err := rl.Routes(runlight.RoutesOptions{})
//	e := echo.New()
//	e.Use(runlightecho.Observer(rl))
//	runlightecho.Register(e, rl, routes)
package runlightecho

import (
	"github.com/labstack/echo/v5"

	runlight "runlight.sh/go"
)

// Register adds Runlight to e: middleware that answers the link domains added
// in Settings before Echo routes the request, the routes at their base path
// and everything below it, the OAuth discovery documents, and GET
// {LinkPath}/:slug for short links.
func Register(e *echo.Echo, rl *runlight.Runlight, routes *runlight.Routes) {
	e.Pre(echo.WrapMiddleware(rl.LinkDomains))
	handler := echo.WrapHandler(routes)
	base := routes.Base()
	e.Any(base+"/*", handler)
	if base != "" {
		e.Any(base, handler)
		for _, document := range runlight.OAuthDocuments {
			e.Any(document, handler)
			e.Any(document+"/*", handler)
		}
	}
	e.GET(rl.LinkPath+"/:slug", echo.WrapHandler(rl.LinksHTTP()))
}

// Observer is middleware that records AI agent fetches of the app's pages
// and always passes the request on.
func Observer(rl *runlight.Runlight) echo.MiddlewareFunc {
	return echo.WrapMiddleware(rl.Observer)
}
