package importers

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// https://dev.bitly.com/api-reference
const (
	bitlyBase = "https://api-ssl.bitly.com/v4"
	bitlyPage = 20
)

var scheme = regexp.MustCompile(`^https?://`)

// split is a short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale".
func split(value string) (domain, slug string) {
	bare := scheme.ReplaceAllString(value, "")
	at := strings.IndexByte(bare, '/')
	if at < 0 {
		return bare, ""
	}
	return bare[:at], strings.TrimSuffix(bare[at+1:], "/")
}

type bitly struct{}

// Bitly is Bitly. Links are listed per group (every group in the account),
// with archived ones. Bitly only keeps daily click counts, and only as far
// back as the account's plan allows. A custom back-half or branded domain
// wins over the random bit.ly one.
var Bitly Importer = bitly{}

func (bitly) Step(ctx context.Context, client *Client, in StepInput) (*StepResult, error) {
	token := trimmed(in.Credentials, "token")
	if token == "" {
		token = trimmed(in.Credentials, "apiKey")
	}
	if token == "" {
		return nil, NewImportError("Enter a Bitly access token", "import_key", "service", "Bitly")
	}
	headers := web.NewHeaders("authorization", "Bearer "+token)
	state, ok, err := cursorState(in.Cursor)
	if err != nil {
		return nil, err
	}
	if !ok {
		body, err := client.GetJSON(ctx, bitlyBase+"/groups", RequestInit{Headers: headers})
		if err != nil {
			return nil, err
		}
		groups, err := list(field(body, "groups"), "groups")
		if err != nil {
			return nil, err
		}
		guids := make([]any, len(groups))
		for i, g := range groups {
			guids[i] = field(g, "guid")
		}
		state = js.NewObject("groups", guids, "g", 0.0, "after", nil)
	}
	group := at(field(state, "groups"), field(state, "g"))
	if !js.Truthy(group) {
		return &StepResult{}, nil
	}

	after := ""
	if a := field(state, "after"); js.Truthy(a) {
		after = "&search_after=" + encodeURIComponent(js.String(a))
	}
	page, err := client.GetJSON(ctx, bitlyBase+"/groups/"+js.String(group)+"/bitlinks?size=20&archived=both"+after, RequestInit{Headers: headers})
	if err != nil {
		return nil, err
	}
	bitlinks, err := list(field(page, "links"), "page.links")
	if err != nil {
		return nil, err
	}

	links := []ForeignItem{}
	for _, b := range bitlinks {
		if js.Truthy(field(b, "is_deleted")) {
			continue
		}
		id, longURL := field(b, "id"), field(b, "long_url")
		domain, slug := split(js.String(coalesce(at(field(b, "custom_bitlinks"), 0.0), id)))
		seen, err := in.Known(ctx, text(id), slug, text(longURL))
		if err != nil {
			return nil, err
		}
		if seen {
			links = append(links, ForeignItem{Link: ForeignLink{SourceID: text(id), URL: text(longURL)}, Known: true})
			continue
		}
		var daily []DailyClicks
		body, err := client.GetJSON(ctx, bitlyBase+"/bitlinks/"+encodeURIComponent(js.String(id))+"/clicks?unit=day&units=-1", RequestInit{Headers: headers})
		if err == nil {
			daily, err = dailyCounts(field(body, "link_clicks"), "clicks", "date", "clicks.link_clicks")
			if err != nil {
				return nil, err
			}
		} else if refused(err) {
			// Plans without analytics refuse this; the link still comes across.
			return nil, err
		}
		links = append(links, ForeignItem{
			Link:  ForeignLink{SourceID: text(id), Slug: slug, Domain: domain, Name: text(or(field(b, "title"), "")), URL: text(longURL), CreatedAt: createdAt(field(b, "created_at"), in.Now)},
			Daily: daily,
		})
	}

	var next any
	if searchAfter := field(field(page, "pagination"), "search_after"); js.Truthy(searchAfter) && len(bitlinks) == bitlyPage {
		next = searchAfter
	}
	var more *js.Object
	g := js.ToNumber(field(state, "g"))
	if next != nil {
		more = js.Obj(state).Clone()
		more.Set("after", next)
	} else if g+1 < float64(len(js.Arr(field(state, "groups")))) {
		more = js.Obj(state).Clone()
		more.Set("g", g+1)
		more.Set("after", nil)
	}
	result := &StepResult{Links: links}
	if more != nil {
		result.Cursor = strPtr(js.Stringify(more))
	}
	return result, nil
}

// refused is whether a failed history request stops the import: anything but
// an HTTPError, or a 401.
func refused(err error) bool {
	var h *HTTPError
	return !errors.As(err, &h) || h.Status == 401
}

// dailyCounts is points.filter((p) => p[count] > 0).map((p) => ({ day: p[date].slice(0, 10), clicks: p[count] })).
func dailyCounts(points any, count, date, what string) ([]DailyClicks, error) {
	all, err := list(points, what)
	if err != nil {
		return nil, err
	}
	out := []DailyClicks{}
	for _, p := range all {
		if !positive(field(p, count)) {
			continue
		}
		day, ok := field(p, date).(string)
		if !ok {
			return nil, errors.New(date + ".slice is not a function")
		}
		out = append(out, DailyClicks{Day: js.Slice16(day, 0, 10), Clicks: js.ToNumber(field(p, count))})
	}
	return out, nil
}
