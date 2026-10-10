package importers

import (
	"context"
	"math"
	"regexp"
	"strconv"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

const umamiPage = 5

var (
	trailingSlashes = regexp.MustCompile(`/+$`)
	umamiAddress    = regexp.MustCompile(`^https://[^/]+`)
)

// UmamiLogin is where an Umami is and the token that signs in to it.
type UmamiLogin struct {
	Base string
	// Token is the API key, the token from an earlier step, or the one the
	// sign-in gave: any JSON value, js.Undefined when the sign-in gave none,
	// as TS's login.token is then.
	Token any
}

// Authorization is the header value that signs in: "Bearer " and the token
// as a template literal writes it.
func (l *UmamiLogin) Authorization() string {
	return "Bearer " + js.String(l.Token)
}

// UmamiSignIn signs in to an Umami: an API key, or a username and password
// (stock self-hosted Umami has no API keys). A token from an earlier step is
// reused when it is truthy; pass nil for none.
func UmamiSignIn(ctx context.Context, client *Client, credentials Credentials, token any) (*UmamiLogin, error) {
	base := trailingSlashes.ReplaceAllString(js.Trim(credentials["url"]), "")
	if !umamiAddress.MatchString(base) {
		return nil, NewImportError("Enter your Umami address, like https://stats.example.com", "import_umami_address")
	}
	key := trimmed(credentials, "apiKey")
	if key != "" {
		return &UmamiLogin{base, key}, nil
	}
	if js.Truthy(token) {
		return &UmamiLogin{base, token}, nil
	}
	if credentials["username"] == "" || credentials["password"] == "" {
		return nil, NewImportError("Enter an API key, or a username and password", "import_umami_login")
	}
	login, err := client.GetJSON(ctx, base+"/api/auth/login", RequestInit{
		Method:  "POST",
		Headers: web.NewHeaders("content-type", "application/json"),
		Body:    []byte(js.Stringify(js.NewObject("username", credentials["username"], "password", credentials["password"]))),
	})
	if err != nil {
		return nil, err
	}
	// A sign-in that answers without a token was refused, whatever its status.
	token, isText := field(login, "token").(string)
	if !isText || token == "" {
		return nil, NewImportError("The key or sign-in was refused", "import_refused")
	}
	return &UmamiLogin{base, token}, nil
}

// UmamiAll is every page of an Umami list: GET {base}/api{path}&page=N&pageSize=1000
// until it has count items or a page comes back empty.
func UmamiAll(ctx context.Context, client *Client, base, path string, headers *web.Headers) ([]any, error) {
	out := []any{}
	for page := 1; ; page++ {
		body, err := client.GetJSON(ctx, base+"/api"+path+"&page="+strconv.Itoa(page)+"&pageSize=1000", RequestInit{Headers: headers})
		if err != nil {
			return nil, err
		}
		data, err := list(field(body, "data"), "body.data")
		if err != nil {
			return nil, err
		}
		out = append(out, data...)
		if float64(len(out)) >= js.ToNumber(field(body, "count")) || len(data) == 0 {
			return out, nil
		}
	}
}

type umami struct{}

// Umami is Umami v3 (and forks with custom link domains). Signs in with an
// API key, or with a username and password (stock self-hosted Umami has no
// API keys). In Umami a link's clicks are events stored under the link's id,
// with the visitor's session holding place and device.
var Umami Importer = umami{}

func (umami) Step(ctx context.Context, client *Client, in StepInput) (*StepResult, error) {
	// A key comes with every step; only a sign-in token, which expires, rides in the cursor.
	saved, ok, err := cursorState(in.Cursor)
	if err != nil {
		return nil, err
	}
	if !ok {
		saved = js.NewObject("page", 1.0)
	}
	key := trimmed(in.Credentials, "apiKey")
	login, err := UmamiSignIn(ctx, client, in.Credentials, field(saved, "token"))
	if err != nil {
		return nil, err
	}
	page := field(saved, "page")
	headers := web.NewHeaders("authorization", login.Authorization())
	body, err := client.GetJSON(ctx, login.Base+"/api/links?page="+js.String(page)+"&pageSize=5", RequestInit{Headers: headers})
	if err != nil {
		return nil, err
	}
	data, err := list(field(body, "data"), "list.data")
	if err != nil {
		return nil, err
	}

	links := []ForeignItem{}
	for _, l := range data {
		if js.Truthy(field(l, "deletedAt")) {
			continue
		}
		id, slug, url, name := field(l, "id"), text(field(l, "slug")), text(field(l, "url")), text(field(l, "name"))
		seen, err := in.Known(ctx, text(id), slug, url)
		if err != nil {
			return nil, err
		}
		if seen {
			links = append(links, ForeignItem{Link: ForeignLink{SourceID: text(id), Slug: slug, Name: name, URL: url}, Known: true})
			continue
		}
		created := createdAt(field(l, "createdAt"), in.Now)
		rng := "startAt=" + js.FormatNumber(float64(created-86_400_000)) + "&endAt=" + js.FormatNumber(float64(in.Now+60_000))
		events, sessions, err := umamiHistory(ctx, client, login.Base, js.String(id), rng, headers)
		if err != nil {
			return nil, err
		}
		info := map[any]any{}
		for _, s := range sessions {
			if k, ok := mapKey(field(s, "id")); ok {
				info[k] = s
			}
		}
		clicks := make([]ForeignClick, len(events))
		for i, e := range events {
			var s any = js.Undefined{}
			if k, ok := mapKey(field(e, "sessionId")); ok {
				if found, ok := info[k]; ok {
					s = found
				}
			}
			referrer := ""
			if domain := field(e, "referrerDomain"); js.Truthy(domain) {
				referrer = "https://" + js.String(domain) + js.String(or(field(e, "referrerPath"), "/"))
			}
			clicks[i] = clickOf(
				"ts", ParseDate(field(e, "createdAt")),
				"visit", field(e, "sessionId"),
				"referrer", referrer,
				"path", field(e, "urlPath"),
				"query", field(e, "urlQuery"),
				"country", field(e, "country"),
				"region", field(s, "region"),
				"city", field(e, "city"),
				"browser", field(e, "browser"),
				"os", field(e, "os"),
				"device", field(e, "device"),
				"screen", field(s, "screen"),
				"language", field(s, "language"),
			)
		}
		links = append(links, ForeignItem{
			Link:   ForeignLink{SourceID: text(id), Slug: slug, Domain: text(coalesce(field(field(l, "customDomain"), "domain"), "")), Name: name, URL: url, CreatedAt: created},
			Clicks: clicks,
		})
	}
	count := field(body, "count")
	result := &StepResult{Links: links}
	// Without a count there is no total, and a full page may have more after it.
	n, isNumber := count.(float64)
	isNumber = isNumber && !math.IsNaN(n) && !math.IsInf(n, 0)
	more := len(data) == umamiPage
	if isNumber {
		result.Total = &n
		more = js.ToNumber(page)*umamiPage < n && len(data) > 0
	}
	if more {
		next := js.NewObject("page", js.ToNumber(page)+1)
		if key == "" {
			next.Set("token", login.Token)
		}
		result.Cursor = strPtr(js.Stringify(next))
	}
	return result, nil
}

// umamiHistory is a link's events and sessions, asked for at once as TS's
// Promise.all asks. When either fails, the step fails with the first error
// to come back.
func umamiHistory(ctx context.Context, client *Client, base, id, rng string, headers *web.Headers) (events, sessions []any, err error) {
	type answer struct {
		events bool
		items  []any
		err    error
	}
	answers := make(chan answer, 2)
	go func() {
		items, err := UmamiAll(ctx, client, base, "/websites/"+id+"/events?"+rng, headers)
		answers <- answer{true, items, err}
	}()
	go func() {
		items, err := UmamiAll(ctx, client, base, "/websites/"+id+"/sessions?"+rng, headers)
		answers <- answer{false, items, err}
	}()
	for range 2 {
		a := <-answers
		if a.err != nil && err == nil {
			err = a.err
		}
		if a.events {
			events = a.items
		} else {
			sessions = a.items
		}
	}
	return events, sessions, err
}

// mapKey is a value as a Map key compares it: text, numbers, booleans, and
// null by value, and nothing else, since two parsed objects are never the same one.
func mapKey(v any) (any, bool) {
	switch v.(type) {
	case string, float64, bool, nil, js.Undefined:
		return v, true
	}
	return nil, false
}
