package importers

import (
	"context"
	"errors"
	"strconv"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// https://dub.co/docs/api-reference
const (
	dubBase = "https://api.dub.co"
	dubPage = 10
)

type dub struct{}

// Dub is Dub. Links come from GET /links (cursor pages of up to 100,
// archived included). Click history is per click from /events where the
// plan allows, else daily counts from /analytics, else none; the first link
// decides. What the account's plan lets us read rides in the cursor as
// "history": "events" (Business), "daily" (Pro), "none" (Free), or null
// before the first link.
var Dub Importer = dub{}

func (dub) Step(ctx context.Context, client *Client, in StepInput) (*StepResult, error) {
	key := trimmed(in.Credentials, "apiKey")
	if key == "" {
		return nil, NewImportError("Enter a Dub API key", "import_key", "service", "Dub")
	}
	headers := web.NewHeaders("authorization", "Bearer "+key)
	state, ok, err := cursorState(in.Cursor)
	if err != nil {
		return nil, err
	}
	if !ok {
		state = js.NewObject("after", nil, "history", nil)
	}
	history := field(state, "history")
	after := ""
	if a := field(state, "after"); js.Truthy(a) {
		after = "&startingAfter=" + encodeURIComponent(js.String(a))
	}
	body, err := client.GetJSON(ctx, dubBase+"/links?pageSize=10&showArchived=true"+after, RequestInit{Headers: headers})
	if err != nil {
		return nil, err
	}
	all, err := list(body, "list")
	if err != nil {
		return nil, err
	}

	links := []ForeignItem{}
	for _, l := range all {
		id, slug, url := field(l, "id"), field(l, "key"), field(l, "url")
		seen, err := in.Known(ctx, text(id), text(slug), text(url))
		if err != nil {
			return nil, err
		}
		if seen {
			links = append(links, ForeignItem{Link: ForeignLink{SourceID: text(id), Slug: text(slug), URL: text(url)}, Known: true})
			continue
		}
		var clicks []ForeignClick
		var daily []DailyClicks
		if history == nil || history == "events" {
			clicks, err = dubEvents(ctx, client, headers, id)
			if err != nil {
				if !planRefused(err) {
					return nil, err
				}
				clicks = nil
				history = "daily"
			} else {
				history = "events"
			}
		}
		if history == "daily" {
			series, err := client.GetJSON(ctx, dubBase+"/analytics?event=clicks&groupBy=timeseries&interval=all&linkId="+encodeURIComponent(js.String(id)), RequestInit{Headers: headers})
			if err == nil {
				daily, err = dailyCounts(series, "clicks", "start", "series")
				if err != nil {
					return nil, err
				}
			} else if !planRefused(err) {
				return nil, err
			} else {
				history = "none"
			}
		}
		links = append(links, ForeignItem{
			Link:   ForeignLink{SourceID: text(id), Slug: text(slug), Domain: text(field(l, "domain")), Name: text(or(field(l, "title"), "")), URL: text(url), CreatedAt: createdAt(field(l, "createdAt"), in.Now)},
			Clicks: clicks,
			Daily:  daily,
		})
	}
	result := &StepResult{Links: links}
	if len(all) == dubPage && js.Truthy(all[len(all)-1]) {
		result.Cursor = strPtr(js.Stringify(js.NewObject("after", field(all[len(all)-1], "id"), "history", history)))
	}
	return result, nil
}

// dubEvents is every click Dub has for a link, page by page.
func dubEvents(ctx context.Context, client *Client, headers *web.Headers, id any) ([]ForeignClick, error) {
	clicks := []ForeignClick{}
	for page := 1; ; page++ {
		body, err := client.GetJSON(ctx, dubBase+"/events?event=clicks&linkId="+encodeURIComponent(js.String(id))+"&interval=all&sortOrder=asc&limit=1000&page="+strconv.Itoa(page), RequestInit{Headers: headers})
		if err != nil {
			return nil, err
		}
		events, err := list(body, "events")
		if err != nil {
			return nil, err
		}
		for _, e := range events {
			click := field(e, "click")
			referer := field(click, "referer")
			referrer := field(click, "refererUrl")
			if !js.Truthy(referrer) {
				referrer = ""
				if js.Truthy(referer) && referer != "(direct)" {
					referrer = "https://" + js.String(referer) + "/"
				}
			}
			var device any = js.Undefined{}
			switch d := field(click, "device").(type) {
			case string:
				device = js.ToLower(d)
			case nil, js.Undefined:
			default:
				return nil, errors.New("e.click?.device?.toLowerCase is not a function")
			}
			clicks = append(clicks, clickOf(
				"ts", ParseDate(field(e, "timestamp")),
				"visit", field(click, "id"),
				"referrer", referrer,
				"country", field(click, "country"),
				"region", field(click, "region"),
				"city", field(click, "city"),
				"device", device,
				"browser", field(click, "browser"),
				"os", field(click, "os"),
			))
		}
		if len(events) < 1000 {
			return clicks, nil
		}
	}
}

// planRefused is whether Dub said the plan does not include what was asked
// (403, or 402). Any other failure (a server error that outlasts the
// retries, say) fails the step and leaves the history mode as it was.
func planRefused(err error) bool {
	var h *HTTPError
	return errors.As(err, &h) && (h.Status == 403 || h.Status == 402)
}
