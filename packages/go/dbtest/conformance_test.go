package dbtest

import (
	"context"
	"os"
	"strings"
	"testing"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/conformance"
	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// core is the Go core as a scenario's target.
type core struct {
	r      *runlight.Runlight
	routes *runlight.Routes
	links  func(ctx context.Context, request *web.Request) *web.Response
}

func (c *core) Handle(ctx context.Context, request *web.Request) *web.Response {
	return c.routes.Handle(ctx, request)
}

func (c *core) Links(ctx context.Context, request *web.Request) *web.Response {
	return c.links(ctx, request)
}

func (c *core) LinkDomain(ctx context.Context, request *web.Request) *web.Response {
	answer, err := c.r.LinkDomainResponse(ctx, request)
	if err != nil {
		return web.NewResponse(500, []byte(err.Error()))
	}
	return answer
}

func (c *core) Idle() { c.r.Idle() }

func siteOptions(v any) runlight.SiteOptions {
	o := runlight.SiteOptions{ID: js.Str(js.Dig(v, "id")), Name: js.Str(js.Dig(v, "name")), Timezone: js.Str(js.Dig(v, "timezone"))}
	for _, h := range js.Arr(js.Dig(v, "hostnames")) {
		o.Hostnames = append(o.Hostnames, js.Str(h))
	}
	return o
}

// makeCore makes the Go core from a scenario's options, on a store.
func makeCore(store *runlight.Store) func(conformance.Setup) (conformance.Target, error) {
	return func(setup conformance.Setup) (conformance.Target, error) {
		ro := setup.Runlight
		options := runlight.Options{Store: store, Now: setup.Now, Fetcher: setup.Fetcher, Logf: func(string, ...any) {}}
		if js.Truthy(ro.Value("managedSites")) {
			options.ManagedSites = true
		} else if sites := js.Arr(ro.Value("sites")); sites != nil {
			for _, s := range sites {
				options.Sites = append(options.Sites, siteOptions(s))
			}
		} else if site := ro.Value("site"); site != nil {
			s := siteOptions(site)
			options.Site = &s
		}
		if s, ok := ro.Value("secret").(string); ok {
			options.Secret = &s
		}
		if v, ok := ro.Get("rateLimit"); ok {
			n := 0
			if f, isNum := v.(float64); isNum {
				n = int(f)
			}
			options.RateLimit = &n
		}
		r, err := runlight.New(options)
		if err != nil {
			return nil, err
		}
		o := setup.Routes
		ropts := runlight.RoutesOptions{ObserveKey: ptr(js.Str(o.Value("observeKey"))), CronSecret: ptr(js.Str(o.Value("cronSecret"))), Accounts: js.Truthy(o.Value("accounts"))}
		switch t := o.Value("token").(type) {
		case nil:
			ropts.Open = true
		case string:
			ropts.Token = &t
		}
		if origin, ok := o.Value("origin").(string); ok {
			ropts.Origin = origin
		}
		routes, err := r.Routes(ropts)
		if err != nil {
			return nil, err
		}
		return &core{r: r, routes: routes, links: r.LinkHandler()}, nil
	}
}

func ptr[T any](v T) *T { return &v }

// Replays conformance/http.json on every database: each step's answer must equal the one the file holds.
func TestConformance(t *testing.T) {
	file := fixture.JSON(t, "conformance", "http.json")
	only := os.Getenv("RUNLIGHT_SCENARIO")
	for _, kind := range Kinds() {
		t.Run(kind.Name, func(t *testing.T) {
			for _, scenario := range js.Arr(js.Dig(file, "scenarios")) {
				name := js.Str(js.Dig(scenario, "name"))
				if only != "" && !strings.Contains(name, only) {
					continue
				}
				t.Run(name, func(t *testing.T) {
					store := runlight.NewStore(Open(t, kind))
					answers, err := conformance.Play(scenario, makeCore(store))
					if err != nil {
						t.Fatal(err)
					}
					steps := js.Arr(js.Dig(scenario, "steps"))
					differ := 0
					for i, step := range steps {
						want := conformance.Canonical(js.Dig(step, "expect"))
						var got string
						if i < len(answers) {
							got = conformance.Canonical(answers[i])
						}
						if got != want {
							differ++
							if differ <= 3 {
								t.Errorf("step %d, %s %s:\n got %s\nwant %s", i+1, js.Str(js.Dig(step, "method")), js.Str(js.Dig(step, "path")), got, want)
							}
						}
					}
					if differ > 3 {
						t.Errorf("%d of %d steps differ", differ, len(steps))
					}
				})
			}
		})
	}
}
