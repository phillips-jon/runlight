package importers

import (
	"context"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// https://developers.short.io/reference
const (
	shortioAPI   = "https://api.short.io"
	shortioStats = "https://statistics.short.io/statistics"
	shortioPage  = 8
	// The statistics API allows 60 requests a minute.
	statsGapMs = 1050
)

type shortio struct{}

// Shortio is Short.io. Links are listed per domain. Daily click counts come
// from the statistics API, paced to its limit of 60 requests a minute, so a
// step holds only a few links.
var Shortio Importer = shortio{}

func (shortio) Step(ctx context.Context, client *Client, in StepInput) (*StepResult, error) {
	key := trimmed(in.Credentials, "apiKey")
	if key == "" {
		return nil, NewImportError("Enter a Short.io secret API key", "import_key", "service", "Short.io")
	}
	headers := web.NewHeaders("authorization", key)
	state, ok, err := cursorState(in.Cursor)
	if err != nil {
		return nil, err
	}
	if !ok {
		body, err := client.GetJSON(ctx, shortioAPI+"/api/domains?limit=300", RequestInit{Headers: headers})
		if err != nil {
			return nil, err
		}
		found, err := list(body, "domains")
		if err != nil {
			return nil, err
		}
		domains := make([]any, len(found))
		for i, d := range found {
			o := js.NewObject()
			for _, k := range []string{"id", "hostname"} {
				if v := field(d, k); !isUndefined(v) {
					o.Set(k, v)
				}
			}
			domains[i] = o
		}
		state = js.NewObject("domains", domains, "d", 0.0, "token", nil, "total", nil)
	}
	domain := at(field(state, "domains"), field(state, "d"))
	if !js.Truthy(domain) {
		return &StepResult{}, nil
	}

	token := ""
	if t := field(state, "token"); js.Truthy(t) {
		token = "&pageToken=" + encodeURIComponent(js.String(t))
	}
	page, err := client.GetJSON(ctx, shortioAPI+"/api/links?domain_id="+js.String(field(domain, "id"))+"&limit=8"+token, RequestInit{Headers: headers})
	if err != nil {
		return nil, err
	}
	found, err := list(field(page, "links"), "page.links")
	if err != nil {
		return nil, err
	}

	links := []ForeignItem{}
	for _, l := range found {
		id := js.String(coalesce(field(l, "idString"), field(l, "id")))
		path, url := text(field(l, "path")), text(field(l, "originalURL"))
		seen, err := in.Known(ctx, id, path, url)
		if err != nil {
			return nil, err
		}
		if seen {
			links = append(links, ForeignItem{Link: ForeignLink{SourceID: id, Slug: path, URL: url}, Known: true})
			continue
		}
		daily, err := shortioDaily(ctx, client, headers, id)
		if err != nil && refused(err) {
			return nil, err
		}
		links = append(links, ForeignItem{
			Link:  ForeignLink{SourceID: id, Slug: path, Domain: text(field(domain, "hostname")), Name: text(or(field(l, "title"), "")), URL: url, CreatedAt: createdAt(field(l, "createdAt"), in.Now)},
			Daily: daily,
		})
	}

	var more *js.Object
	d := js.ToNumber(field(state, "d"))
	if next := field(page, "nextPageToken"); js.Truthy(next) {
		more = js.Obj(state).Clone()
		more.Set("token", next)
	} else if d+1 < float64(len(js.Arr(field(state, "domains")))) {
		more = js.Obj(state).Clone()
		more.Set("d", d+1)
		more.Set("token", nil)
	}
	result := &StepResult{Links: links}
	if more != nil {
		result.Cursor = strPtr(js.Stringify(more))
	}
	return result, nil
}

// shortioDaily is a link's clicks per day from the statistics API, after the
// pause its rate limit needs.
func shortioDaily(ctx context.Context, client *Client, headers *web.Headers, id string) ([]DailyClicks, error) {
	if err := client.Pause(ctx, statsGapMs); err != nil {
		return nil, err
	}
	post := headers.Clone()
	post.Set("content-type", "application/json")
	body, err := client.GetJSON(ctx, shortioStats+"/link/"+encodeURIComponent(id)+"/by_interval", RequestInit{
		Method:  "POST",
		Headers: post,
		Body:    []byte(js.Stringify(js.NewObject("period", "total", "clicksChartInterval", "day", "tz", "UTC"))),
	})
	if err != nil {
		return nil, err
	}
	raw := field(body, "clickStatistics")
	var points any
	if _, ok := raw.([]any); ok {
		points = raw
	} else {
		points = coalesce(field(at(field(raw, "datasets"), 0.0), "data"), []any{})
	}
	all, err := list(points, "points")
	if err != nil {
		return nil, err
	}
	daily := []DailyClicks{}
	for _, p := range all {
		y := field(p, "y")
		if !positive(y) {
			continue
		}
		x := field(p, "x")
		ms, ok := x.(float64)
		if !ok {
			ms = ParseDate(x)
		}
		// A point whose date cannot be read is left out, not the link.
		iso, err := isoString(ms)
		if err != nil {
			continue
		}
		daily = append(daily, DailyClicks{Day: iso[:10], Clicks: js.ToNumber(y)})
	}
	return daily, nil
}

func isUndefined(v any) bool {
	_, u := v.(js.Undefined)
	return u
}
