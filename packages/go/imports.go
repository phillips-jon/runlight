package runlight

import (
	"context"
	"errors"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"runlight.sh/go/internal/importers"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Imports: links and their clicks from other shorteners, and visit history
// from Umami or a CSV file. The importers package reads the other services;
// this file writes what they send.

// ImportError is why an import stopped, as a code the dashboard says in its own words.
type ImportError struct{ CodedError }

func importError(message, code string, params ...string) error {
	return &ImportError{coded(message, code, params...)}
}

// importErr turns the importers package's errors into this package's.
func importErr(err error) error {
	var e *importers.ImportError
	if errors.As(err, &e) {
		params := e.Params
		if params == nil {
			params = js.NewObject()
		}
		return &ImportError{CodedError{Message: e.Message, Code: e.Code, Params: params}}
	}
	return err
}

func isImportError(err error) bool {
	var e *ImportError
	return errors.As(err, &e)
}

func (r *Runlight) importClient() *importers.Client {
	return &importers.Client{Fetcher: r.fetcher}
}

// shortenerDomains are domains run by the shorteners themselves. Links there stay on Runlight's own path.
var shortenerDomains = map[string]bool{"bit.ly": true, "bitly.com": true, "j.mp": true, "dub.sh": true, "dub.co": true, "dub.link": true, "short.gy": true, "rebrand.ly": true, "rebrandly.com": true, "rb.gy": true}

func hexID(value string, length int) string { return sha256Hex(value)[:length] }

// importedLinkID is the Runlight id an imported link gets, from its source and its id there.
func importedLinkID(source, sourceID string) string { return hexID(source+":"+sourceID, 24) }

// sameURL: two destinations are the same link when they differ only by a trailing slash.
func sameURL(a, b string) bool { return strings.TrimSuffix(a, "/") == strings.TrimSuffix(b, "/") }

// Browser and system names as other tools write them, in Runlight's spelling.
var (
	importBrowsers = map[string]string{
		"chrome": "Chrome", "crios": "Chrome", "chromium-webview": "Android WebView", "chrome webview": "Android WebView", "safari": "Safari", "ios": "Safari", "ios-webview": "Safari",
		"mobile safari": "Safari", "firefox": "Firefox", "fxios": "Firefox", "edge": "Edge", "edge-chromium": "Edge", "edge-ios": "Edge", "microsoft edge": "Edge",
		"opera": "Opera", "opera-mini": "Opera", "samsung": "Samsung Internet", "samsung internet": "Samsung Internet", "yandexbrowser": "Yandex Browser",
		"facebook": "Facebook", "instagram": "Instagram", "brave": "Brave", "duckduckgo": "DuckDuckGo",
	}
	importSystems = map[string]string{
		"mac os": "macOS", "mac os x": "macOS", "macos": "macOS", "ios": "iOS", "android os": "Android", "android": "Android",
		"windows 10": "Windows", "windows 11": "Windows", "windows 7": "Windows", "windows": "Windows", "linux": "Linux", "chrome os": "Chrome OS", "chromium os": "Chrome OS",
	}
	importDevices = map[string]string{"desktop": "desktop", "laptop": "desktop", "mobile": "mobile", "smartphone": "mobile", "phone": "mobile", "tablet": "tablet"}
)

func importTitle(v string) string {
	if v == "" {
		return ""
	}
	return upper(slice16(v, 0, 1)) + slice16(v, 1, len16(v))
}

func browserName(v string) string {
	if b, ok := importBrowsers[lower(v)]; ok {
		return b
	}
	return importTitle(v)
}

func deviceName(v string) string { return importDevices[lower(v)] }

var (
	twoLetters   = regexp.MustCompile(`^[A-Z]{2}$`)
	runlightSlug = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$`)
	leadingQ     = regexp.MustCompile(`^\?`)
)

// regionOf is a region as ISO 3166-2, from a code with or without its country.
func regionOf(region, country string) string {
	if region == "" {
		return ""
	}
	if !strings.Contains(region, "-") {
		region = country + "-" + region
	}
	return head16(upper(region), 10)
}

func pageAt(host, path, query, fallback string) Page {
	target := "https://" + host + path
	if query != "" {
		target += "?" + leadingQ.ReplaceAllString(query, "")
	}
	if u, err := whatwg.Parse(target); err == nil {
		return ParsePage(u)
	}
	return ParsePage(whatwg.MustParse("https://" + host + fallback))
}

func isoDay(ts float64) string {
	return time.UnixMilli(int64(ts)).UTC().Format("2006-01-02")
}

// clickText is a click's field as a template literal writes it, and whether
// the click has it (not missing, null, or undefined).
func clickText(c importers.ForeignClick, name string) (string, bool) {
	v, ok := c.Get(name)
	if !ok || v == nil {
		return "", false
	}
	if _, u := v.(js.Undefined); u {
		return "", false
	}
	return js.String(v), true
}

// clickOr is c.name || "", as text.
func clickOr(c importers.ForeignClick, name string) string {
	v := c.Value(name)
	if !js.Truthy(v) {
		return ""
	}
	return js.String(v)
}

type writeResult struct {
	status string
	clicks int64
	reason string
	code   string
	params *js.Object
}

// writeLink writes one link and its history in a single transaction: the
// link (and its branded domain), then each click as a visit like a live one,
// or daily counts as clicks without visitors. Ids come from the source's own
// ids, so importing again skips what is already there.
func (r *Runlight) writeLink(ctx context.Context, site, source string, foreign importers.ForeignLink, item importers.ForeignItem) (writeResult, error) {
	id := importedLinkID(source, foreign.SourceID)
	if existing, err := r.Store.LinkByID(ctx, id); err != nil || existing != nil {
		return writeResult{status: "skipped"}, err
	}
	taken, err := r.Store.LinkBySlug(ctx, foreign.Slug)
	if err != nil {
		return writeResult{}, err
	}
	// The same slug to the same place is this link, brought in earlier some other way.
	if taken != nil && sameURL(taken.URL, foreign.URL) {
		return writeResult{status: "skipped"}, nil
	}
	if taken != nil {
		return writeResult{status: "failed", reason: "/" + foreign.Slug + ` is already used by "` + taken.Name + `"`, code: "import_slug_taken", params: js.NewObject("slug", foreign.Slug, "name", taken.Name)}, nil
	}
	if !runlightSlug.MatchString(foreign.Slug) {
		return writeResult{status: "failed", reason: "/" + foreign.Slug + " has characters Runlight slugs cannot use", code: "import_slug_bad", params: js.NewObject("slug", foreign.Slug)}, nil
	}
	domain := StripWww(foreign.Domain)
	if shortenerDomains[domain] {
		domain = ""
	}
	now := r.now()
	var clicks int64
	// Nothing in the transaction is one link's own problem (those are checked above),
	// so a failure in it is the database's, and it stops the import rather than marking the link.
	err = r.Store.Transaction(ctx, func(store *Store) error {
		db := store.DB()
		// A failed earlier try can have left some of this link's clicks behind on a database without
		// transactions. Clear them, then write the link row last, so a link only counts as imported once
		// all of its history is in.
		if err := db.Run(ctx, `DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')`, id); err != nil {
			return err
		}
		if err := db.Run(ctx, `DELETE FROM rl_events WHERE link = ?`, id); err != nil {
			return err
		}
		made := map[string]bool{}
		for _, c := range item.Clicks {
			ts := c.TS()
			if math.IsNaN(ts) || math.IsInf(ts, 0) {
				continue
			}
			visitKey, has := clickText(c, "visit")
			if !has {
				visitKey = js.FormatNumber(ts) + ":" + strconv.FormatInt(clicks, 10)
			}
			session := hexID(source+":"+foreign.SourceID+":"+visitKey, 24)
			// A visitor id lasts one day at most, as every other visitor id does.
			visitor := hexID(source+":"+visitKey+":"+isoDay(ts), 16)
			path := clickOr(c, "path")
			if path == "" {
				path = "/" + foreign.Slug
			}
			if !made[session] {
				made[session] = true
				if err := db.Run(ctx, `DELETE FROM rl_sessions WHERE id = ?`, session); err != nil {
					return err
				}
				host := domain
				if host == "" {
					host = "link.invalid"
				}
				page := pageAt(host, path, clickOr(c, "query"), "/"+foreign.Slug)
				country := head16(upper(clickOr(c, "country")), 2)
				region := regionOf(clickOr(c, "region"), country)
				if country == "" {
					region = ""
				}
				if !twoLetters.MatchString(country) {
					country = ""
				}
				referrer, _ := clickText(c, "referrer")
				a := Attribute(page, referrer, nil)
				os, hasOS := clickText(c, "os")
				if s, ok := importSystems[lower(clickOr(c, "os"))]; ok {
					os = s
				} else if !hasOS {
					os = ""
				}
				screen, _ := clickText(c, "screen")
				language, _ := clickText(c, "language")
				if err := store.InsertSession(ctx, SessionRow{
					ID: session, Site: site, Visitor: visitor, StartedAt: int64(ts), Hostname: page.Hostname,
					ReferrerHost: a.ReferrerHost, ReferrerPath: a.ReferrerPath, Source: a.Source, Channel: a.Channel,
					UtmSource: page.Utm.Source, UtmMedium: page.Utm.Medium, UtmCampaign: page.Utm.Campaign, UtmTerm: page.Utm.Term, UtmContent: page.Utm.Content,
					Country: country, Region: region, City: head16(clickOr(c, "city"), 100),
					Browser: browserName(clickOr(c, "browser")), OS: os, Device: deviceName(clickOr(c, "device")), Screen: screen, Language: language,
				}); err != nil {
					return err
				}
				if err := db.Run(ctx, "UPDATE rl_sessions SET imported = 1 WHERE id = ?", session); err != nil {
					return err
				}
			}
			if err := store.TouchSession(ctx, session, int64(ts), "click", path, true); err != nil {
				return err
			}
			if err := store.InsertEvent(ctx, EventRow{Site: site, Ts: int64(ts), Kind: "click", Visitor: visitor, Session: session, Path: head16(path, 1000),
				Hostname: domain, Name: foreign.Slug, Link: id}); err != nil {
				return err
			}
			clicks++
		}
		// Counts without detail: clicks spread through each day, with no visitor or visit.
		for _, d := range item.Daily {
			start := importers.ParseDate(d.Day + "T00:00:00Z")
			if math.IsNaN(start) || math.IsInf(start, 0) || d.Clicks <= 0 {
				continue
			}
			n := math.Min(d.Clicks, 1_000_000)
			for i := 0.0; i < n; i++ {
				if err := store.InsertEvent(ctx, EventRow{Site: site, Ts: int64(start + math.Floor(((i+0.5)/n)*86_400_000)), Kind: "click",
					Path: "/" + foreign.Slug, Hostname: domain, Name: foreign.Slug, Props: js.NewObject("imported", "daily"), Link: id}); err != nil {
					return err
				}
				clicks++
			}
		}
		if domain != "" {
			if err := store.AddLinkDomain(ctx, domain, site, now); err != nil {
				return err
			}
		}
		name := foreign.Name
		if name == "" {
			name = foreign.Slug
		}
		created := foreign.CreatedAt
		if created == 0 {
			created = now
		}
		return store.InsertLink(ctx, LinkRow{ID: id, Site: site, Domain: domain, Slug: foreign.Slug, Name: head16(name, 100), URL: foreign.URL, CreatedAt: created, UpdatedAt: created})
	})
	if err != nil {
		return writeResult{}, err
	}
	if domain != "" {
		r.ForgetLinkDomains()
	}
	return writeResult{status: "created", clicks: clicks}, nil
}

// ImportResult is what one step of a link import did. The page keeps calling until Cursor is nil.
type ImportResult struct {
	Cursor *string `json:"cursor"`
	// Done and Total are links handled so far and in all, for the progress
	// bar. Total is nil when the service does not say.
	Done    float64                `json:"done"`
	Total   *float64               `json:"total"`
	Links   int64                  `json:"links"`
	Clicks  int64                  `json:"clicks"`
	Skipped int64                  `json:"skipped"`
	Failed  []importers.FailedLink `json:"failed"`
}

// ImportStep is one step of an import: fetch the next few links from the
// source, write each with its history, and report progress. The cursor
// carries where to pick up, so the page calls this until it comes back nil.
func ImportStep(ctx context.Context, r *Runlight, site, source string, credentials map[string]string, cursor *string, done float64) (*ImportResult, error) {
	importer, ok := importers.Importers[source]
	if !ok {
		return nil, importError("Runlight cannot import from "+source, "import_source", "source", source)
	}
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	known := func(ctx context.Context, sourceID, slug, url string) (bool, error) {
		link, err := r.Store.LinkByID(ctx, importedLinkID(source, sourceID))
		if err != nil || link != nil {
			return link != nil, err
		}
		if slug == "" || url == "" {
			return false, nil
		}
		taken, err := r.Store.LinkBySlug(ctx, slug)
		return taken != nil && sameURL(taken.URL, url), err
	}
	result, err := importer.Step(ctx, r.importClient(), importers.StepInput{Credentials: credentials, Cursor: cursor, Known: known, Now: r.now()})
	if err != nil {
		return nil, importErr(err)
	}
	step := &ImportResult{Cursor: result.Cursor, Done: done, Total: result.Total, Failed: []importers.FailedLink{}}
	for _, item := range result.Links {
		if item.Known {
			step.Done++
			step.Skipped++
			continue
		}
		written, err := r.writeLink(ctx, site, source, item.Link, item)
		if err != nil {
			return nil, err
		}
		step.Done++
		switch written.status {
		case "created":
			step.Links++
			step.Clicks += written.clicks
		case "skipped":
			step.Skipped++
		default:
			failed := importers.FailedLink{Slug: item.Link.Slug, Reason: written.reason}
			if written.code != "" {
				failed.Code = &written.code
				failed.Params = written.params
			}
			step.Failed = append(step.Failed, failed)
		}
	}
	// Links the source skipped (deleted ones) still count toward progress.
	if result.Cursor == nil && result.Total != nil {
		step.Done = math.Max(step.Done, *result.Total)
	}
	return step, nil
}

// Visit history from Umami: pageviews and custom events with where each
// visit came from, its place, and its device, written as imported visits so
// the dashboard's history does not start the day Runlight was installed.
//
// The dashboard drives it a few days at a time, oldest first, so it fits any
// host's time limit and shows progress. It stops where Runlight's own visits
// begin, so nothing is counted twice, and it remembers how far it got, so
// running it again carries on from there.

const (
	importDay = 86_400_000
	// stepDays and stepEvents: each step reads at most this many days, or stops after this many events.
	stepDays   = 14
	stepEvents = 5_000
	// maxDayEvents: a single day with more than this is refused rather than read without end.
	maxDayEvents = 200_000
	// CsvBatch is the most rows one CSV request may send.
	CsvBatch = 2000
)

func progressKey(site, website string) string { return "import:umami-visits:" + site + ":" + website }

func jsField(v any, key string) any {
	if o, ok := v.(*js.Object); ok {
		if x, ok := o.Get(key); ok {
			return x
		}
	}
	return js.Undefined{}
}

// UmamiWebsites are the websites an Umami account can see, to pick which one becomes this site's history.
func UmamiWebsites(ctx context.Context, r *Runlight, credentials map[string]string) ([]*js.Object, error) {
	client := r.importClient()
	login, err := importers.UmamiSignIn(ctx, client, credentials, nil)
	if err != nil {
		return nil, importErr(err)
	}
	headers := web.NewHeaders("authorization", login.Authorization())
	out := []*js.Object{}
	for page := 1; page < 100; page++ {
		body, err := client.GetJSON(ctx, login.Base+"/api/websites?page="+strconv.Itoa(page)+"&pageSize=100", importers.RequestInit{Headers: headers})
		if err != nil {
			return nil, importErr(err)
		}
		data, ok := jsField(body, "data").([]any)
		if !ok {
			return nil, errors.New("body.data.map is not a function")
		}
		for _, w := range data {
			out = append(out, js.NewObject("id", jsField(w, "id"), "name", jsField(w, "name"), "domain", jsField(w, "domain")))
		}
		if float64(len(out)) >= js.ToNumber(jsField(body, "count")) || len(data) == 0 {
			break
		}
	}
	return out, nil
}

func groupThousands(n int) string {
	s := strconv.Itoa(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

// umamiList is every page of an Umami list for a time window.
func umamiList(ctx context.Context, client *importers.Client, base, path string, headers *web.Headers, limit int) ([]any, error) {
	out := []any{}
	for page := 1; ; page++ {
		body, err := client.GetJSON(ctx, base+"/api"+path+"&page="+strconv.Itoa(page)+"&pageSize=1000", importers.RequestInit{Headers: headers})
		if err != nil {
			return nil, err
		}
		data, ok := jsField(body, "data").([]any)
		if !ok {
			return nil, errors.New("body.data is not iterable")
		}
		out = append(out, data...)
		if float64(len(out)) >= js.ToNumber(jsField(body, "count")) || len(data) == 0 {
			return out, nil
		}
		if len(out) > limit {
			return nil, importError("One day has more than "+groupThousands(limit)+" events, more than an import step can read", "import_day_full", "limit", strconv.Itoa(limit))
		}
	}
}

// VisitImportStep is what one step of a visit import did.
type VisitImportStep struct {
	Cursor *string `json:"cursor"`
	// Done and Total are days read so far and in all, for the progress bar.
	Done      float64 `json:"done"`
	Total     float64 `json:"total"`
	Pageviews int64   `json:"pageviews"`
	Events    int64   `json:"events"`
	Visits    int64   `json:"visits"`
}

var umamiWebsiteID = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

// importedHit is one pageview or event from another tool, in the shape every
// visit import writes. key groups rows into visitors, as Umami's session id does.
type importedHit struct {
	ts                                                float64
	key, kind, hostname, path, query, referrer, title string
	name, country, region, city, browser, os, device  string
	screen, language                                  string
}

type nsHit struct {
	ns  string
	hit importedHit
}

// textOr is value ?? "" for a value used as text.
func textOr(v any) string {
	switch v.(type) {
	case nil, js.Undefined:
		return ""
	}
	return js.String(v)
}

func referrerOf(domain, path, query string) string {
	if domain == "" {
		return ""
	}
	if path == "" {
		path = "/"
	}
	out := "https://" + domain + path
	if query != "" {
		out += "?" + leadingQ.ReplaceAllString(query, "")
	}
	return out
}

func fromUmami(e any, ts float64, session any) importedHit {
	kind := "event"
	if n, ok := jsField(e, "eventType").(float64); ok && n == 1 {
		kind = "pageview"
	}
	region := ""
	if v := jsField(session, "subdivision1"); js.Truthy(v) {
		region = js.String(v)
	} else if v := jsField(session, "region"); js.Truthy(v) {
		region = js.String(v)
	}
	truthy := func(key string) string {
		if v := jsField(e, key); js.Truthy(v) {
			return js.String(v)
		}
		return ""
	}
	return importedHit{
		ts: ts, key: js.String(jsField(e, "sessionId")), kind: kind,
		hostname: textOr(jsField(e, "hostname")), path: textOr(jsField(e, "urlPath")), query: textOr(jsField(e, "urlQuery")),
		referrer: referrerOf(truthy("referrerDomain"), truthy("referrerPath"), truthy("referrerQuery")),
		title:    textOr(jsField(e, "pageTitle")), name: textOr(jsField(e, "eventName")), country: textOr(jsField(e, "country")),
		region: region, city: textOr(jsField(e, "city")), browser: textOr(jsField(e, "browser")), os: textOr(jsField(e, "os")),
		device: textOr(jsField(e, "device")), screen: textOr(jsField(session, "screen")), language: textOr(jsField(session, "language")),
	}
}

// ImportUmamiVisits is one step: read the next few days from Umami and write them as imported visits.
func ImportUmamiVisits(ctx context.Context, r *Runlight, siteID string, credentials map[string]string, website any, cursor *string) (*VisitImportStep, error) {
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	if _, ok := r.Site(siteID); !ok {
		return nil, importError("Unknown site", "unknown_site")
	}
	websiteID := js.String(website)
	if !umamiWebsiteID.MatchString(websiteID) {
		return nil, importError("Pick the Umami website to import", "import_website")
	}
	var saved any
	if cursor != nil && *cursor != "" {
		var err error
		if saved, err = js.Parse(*cursor); err != nil {
			return nil, err
		}
	}
	client := r.importClient()
	var token any
	if saved != nil {
		token = jsField(saved, "token")
	}
	login, err := importers.UmamiSignIn(ctx, client, credentials, token)
	if err != nil {
		return nil, importErr(err)
	}
	headers := web.NewHeaders("authorization", login.Authorization())
	var state *js.Object
	if s, ok := saved.(*js.Object); ok && js.Canonical(s.Value("website")) == js.Canonical(website) {
		state = s
	} else {
		info, err := client.GetJSON(ctx, login.Base+"/api/websites/"+websiteID, importers.RequestInit{Headers: headers})
		if err != nil {
			return nil, importErr(err)
		}
		created := importers.ParseDate(jsField(info, "createdAt"))
		if math.IsNaN(created) || created == 0 {
			created = float64(r.now())
		}
		// Carry on where an earlier run stopped, and end where Runlight's own visits begin.
		resumed := 0.0
		if v, has, err := r.Store.Setting(ctx, progressKey(siteID, websiteID)); err != nil {
			return nil, err
		} else if has {
			resumed = js.Number(v)
		}
		// Never older than the site keeps, or the next scheduled check would delete it again.
		cutoff := 0.0
		if c, err := r.RetentionCutoff(ctx, siteID); err != nil {
			return nil, err
		} else if c != nil {
			cutoff = float64(*c)
		}
		start := math.Max(math.Max(math.Floor(created/importDay)*importDay, resumed), math.Ceil(cutoff/importDay)*importDay)
		end := float64(r.now())
		if own, err := r.Store.FirstOwnVisit(ctx, siteID); err != nil {
			return nil, err
		} else if own != nil {
			end = float64(*own)
		}
		state = js.NewObject("website", website, "day", start, "start", start, "end", end)
	}
	usesKey := jsTrim(credentials["apiKey"]) != ""
	day, end, start := js.ToNumber(state.Value("day")), js.ToNumber(state.Value("end")), js.ToNumber(state.Value("start"))

	// Read whole days until the step has enough.
	events := []any{}
	from, to := day, day
	for to < end && to-from < stepDays*importDay && len(events) < stepEvents {
		next := math.Min(to+importDay, end)
		got, err := umamiList(ctx, client, login.Base, "/websites/"+websiteID+"/events?startAt="+js.FormatNumber(to)+"&endAt="+js.FormatNumber(next-1), headers, maxDayEvents)
		if err != nil {
			return nil, importErr(err)
		}
		events = append(events, got...)
		to = next
	}
	sessions := map[string]any{}
	if len(events) > 0 {
		list, err := umamiList(ctx, client, login.Base, "/websites/"+websiteID+"/sessions?startAt="+js.FormatNumber(from)+"&endAt="+js.FormatNumber(to-1), headers, maxDayEvents*stepDays)
		if err != nil {
			return nil, importErr(err)
		}
		for _, s := range list {
			sessions[js.Canonical(jsField(s, "id"))] = s
		}
	}
	ns := "umami-visits:" + websiteID
	type timed struct {
		e  any
		ts float64
	}
	kept := []timed{}
	for _, e := range events {
		kind, _ := jsField(e, "eventType").(float64)
		if !(kind == 1 || (kind == 2 && js.Truthy(jsField(e, "eventName")))) {
			continue
		}
		ts := importers.ParseDate(jsField(e, "createdAt"))
		if math.IsNaN(ts) || math.IsInf(ts, 0) || !(ts < end) {
			continue
		}
		kept = append(kept, timed{e, ts})
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].ts < kept[j].ts })
	hits := make([]nsHit, len(kept))
	for i, k := range kept {
		hits[i] = nsHit{ns, fromUmami(k.e, k.ts, sessions[js.Canonical(jsField(k.e, "sessionId"))])}
	}
	counts, err := r.writeStep(ctx, siteID, from, to, hits, func(store *Store) error {
		value := js.FormatNumber(to)
		return store.SetSetting(ctx, progressKey(siteID, websiteID), &value)
	})
	if err != nil {
		return nil, err
	}
	totalDays := math.Max(1, math.Ceil((end-start)/importDay))
	doneDays := math.Min(totalDays, math.Ceil((to-start)/importDay))
	out := &VisitImportStep{Done: doneDays, Total: totalDays, Pageviews: counts.pageviews, Events: counts.events, Visits: counts.visits}
	if to < end {
		next := state.Clone()
		next.Set("day", to)
		if !usesKey {
			next.Set("token", login.Token)
		}
		text := js.Stringify(next)
		out.Cursor = &text
	}
	return out, nil
}

type visitCounts struct{ pageviews, events, visits int64 }

// writeStep writes one step of imported visits, sorted oldest first, all
// within [from, to). Whatever an earlier import left in those times is
// cleared first, so a step can always run again, and a visit carried in from
// the step before is counted again from its rows. done runs in the same
// transaction, to remember how far it got.
func (r *Runlight) writeStep(ctx context.Context, siteID string, from, to float64, hits []nsHit, done func(*Store) error) (visitCounts, error) {
	var counts visitCounts
	site, ok := r.Site(siteID)
	if !ok {
		return counts, importError("Unknown site", "unknown_site")
	}
	f, t := int64(from), int64(to)
	err := r.Store.Transaction(ctx, func(store *Store) error {
		db := store.DB()
		// Days this step writes into are added up again later, with the imported visits in them.
		if err := store.ClearRollups(ctx, siteID, RollupRange{From: &f, To: &t}); err != nil {
			return err
		}
		// A failed earlier try at these days (on a database without transactions) can
		// have left part of them behind. Clear it, so every step can safely run again.
		imported := `SELECT id FROM rl_sessions WHERE site = ? AND imported = 1`
		if err := db.Run(ctx, `DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN (`+imported+`)`, siteID, f, t, siteID); err != nil {
			return err
		}
		// Visits of these days that kept no rows go too. Their rows would come within EventTailMs of the step,
		// so the time bounds let the (site, ts) index find them, with no scan of every event.
		if err := db.Run(ctx, `DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)`, siteID, f, t, siteID, f, t+EventTailMs); err != nil {
			return err
		}
		for _, h := range hits {
			made, err := writeImportedEvent(ctx, store, site, h.ns, h.hit)
			if err != nil {
				return err
			}
			if made {
				counts.visits++
			}
			if h.hit.kind == "pageview" {
				counts.pageviews++
			} else {
				counts.events++
			}
		}
		// A visit that began in an earlier step and went on into this one is counted
		// again from its rows, so a repeated step cannot leave it with doubled totals.
		// The day it began may already be built, so that day is built again too.
		carried, err := db.All(ctx, `SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)`, siteID, f, f-EventTailMs, siteID, f, t)
		if err != nil {
			return err
		}
		if len(carried) > 0 {
			earliest := int64(math.MaxInt64)
			for _, c := range carried {
				earliest = min(earliest, numInt(c["started_at"]))
			}
			if err := store.ClearRollups(ctx, siteID, RollupRange{From: &earliest, To: &f}); err != nil {
				return err
			}
			// Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
			// Ninety ids a statement, within Cloudflare D1's 100 values.
			rows := []Row{}
			for i := 0; i < len(carried); i += 90 {
				chunk := carried[i:min(i+90, len(carried))]
				params := []any{siteID, earliest, t}
				marks := make([]string, len(chunk))
				for j, c := range chunk {
					params = append(params, str(c["id"]))
					marks[j] = "?"
				}
				got, err := db.All(ctx, `SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN (`+strings.Join(marks, ", ")+`)
             ORDER BY e.ts, e.id`, params...)
				if err != nil {
					return err
				}
				rows = append(rows, got...)
			}
			type total struct {
				pageviews, events, last int64
				exit                    *string
			}
			totals := map[string]*total{}
			order := []string{}
			for _, row := range rows {
				id := str(row["session"])
				tt := totals[id]
				if tt == nil {
					tt = &total{}
					totals[id] = tt
					order = append(order, id)
				}
				if str(row["kind"]) == "pageview" {
					tt.pageviews++
					p := str(row["path"])
					tt.exit = &p
				} else {
					tt.events++
				}
				tt.last = max(tt.last, numInt(row["ts"]))
			}
			for _, id := range order {
				tt := totals[id]
				var exit any
				if tt.exit != nil {
					exit = *tt.exit
				}
				if err := db.Run(ctx, `UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?`, tt.pageviews, tt.events, tt.last, exit, id); err != nil {
					return err
				}
			}
		}
		if done != nil {
			return done(store)
		}
		return nil
	})
	return counts, err
}

// writeImportedEvent writes one imported pageview or event as part of a
// Runlight visit. Visitors are hashed per day from the hit's key, as live
// visitors are hashed per day, and a hit within thirty minutes of the
// visitor's last one joins that visit. Ids come from ns and the key, so
// importing the same rows again makes the same ids. Returns whether it
// started a new visit.
func writeImportedEvent(ctx context.Context, store *Store, site SiteRow, ns string, e importedHit) (bool, error) {
	ts := int64(e.ts)
	// The site's own day, as live visitors are counted, so days add up the same way in rollups.
	day := LocalDate(ts, site.Timezone)
	visitor := hexID(ns+":"+e.key+":"+day, 16)
	// A visit that runs past midnight keeps the id it started with, as a live one does.
	yesterday := hexID(ns+":"+e.key+":"+AddDays(day, -1), 16)
	host := e.hostname
	if host == "" && len(site.Hostnames) > 0 {
		host = site.Hostnames[0]
	}
	if host == "" {
		host = "imported.invalid"
	}
	host = lower(host)
	path := e.path
	if path == "" {
		path = "/"
	}
	page := pageAt(host, path, e.query, "/")
	open, err := store.OpenSession(ctx, site.ID, []string{visitor, yesterday}, ts-SessionIdleMs)
	if err != nil {
		return false, err
	}
	var id string
	if open != nil {
		id = open.ID
	}
	if id == "" {
		id = hexID(ns+":"+e.key+":"+js.FormatNumber(e.ts), 24)
		if err := store.DB().Run(ctx, `DELETE FROM rl_sessions WHERE id = ?`, id); err != nil {
			return false, err
		}
		country := head16(upper(e.country), 2)
		region := regionOf(e.region, country)
		if !twoLetters.MatchString(country) {
			country, region = "", ""
		}
		a := Attribute(page, e.referrer, site.Hostnames)
		os := e.os
		if s, ok := importSystems[lower(e.os)]; ok {
			os = s
		}
		if err := store.InsertSession(ctx, SessionRow{
			ID: id, Site: site.ID, Visitor: visitor, StartedAt: ts, Hostname: page.Hostname,
			ReferrerHost: a.ReferrerHost, ReferrerPath: a.ReferrerPath, Source: a.Source, Channel: a.Channel,
			UtmSource: page.Utm.Source, UtmMedium: page.Utm.Medium, UtmCampaign: page.Utm.Campaign, UtmTerm: page.Utm.Term, UtmContent: page.Utm.Content,
			Country: country, Region: region, City: head16(e.city, 100), Browser: browserName(e.browser), OS: os, Device: deviceName(e.device),
			Screen: head16(e.screen, 20), Language: head16(e.language, 35),
		}); err != nil {
			return false, err
		}
		// No engaged time is known, so duration falls back to first-to-last pageview.
		if err := store.DB().Run(ctx, "UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", id); err != nil {
			return false, err
		}
	}
	if err := store.TouchSession(ctx, id, ts, e.kind, page.Path, true); err != nil {
		return false, err
	}
	// The visit's own visitor, which for one running past midnight is the id of the day it started.
	eventVisitor := visitor
	if open != nil {
		eventVisitor = open.Visitor
	}
	row := EventRow{Site: site.ID, Ts: ts, Kind: e.kind, Visitor: eventVisitor, Session: id, Path: page.Path, Hostname: page.Hostname}
	if e.kind == "pageview" {
		row.Title = head16(e.title, 300)
	} else {
		row.Name = head16(e.name, 120)
	}
	if err := store.InsertEvent(ctx, row); err != nil {
		return false, err
	}
	return open == nil, nil
}

// Visit history from a CSV file, in one of two shapes: Umami's data export
// (one row per pageview or event, as in its website_event table) or
// Runlight's own, documented on the dashboard docs page.

// csvFormat is which shape a file is, from its header row (lower case, as the dashboard reads it).
func csvFormat(row map[string]string) string {
	has := func(c string) bool { _, ok := row[c]; return ok }
	if has("created_at") && has("url_path") {
		return "umami"
	}
	if has("time") && (has("path") || has("url")) {
		return "runlight"
	}
	return ""
}

var (
	unixTime  = regexp.MustCompile(`^\d+(\.\d+)?$`)
	hasZone   = regexp.MustCompile(`[zZ]|[+-]\d\d:?\d\d$`)
	hasTime   = regexp.MustCompile(`T\d`)
	hasScheme = regexp.MustCompile(`(?i)^[a-z][a-z0-9+.-]*://`)
)

// rowTime is a row's time in milliseconds, or NaN. ISO 8601 with or without
// a zone, "2024-05-01 12:34:56" (both read as UTC when no zone is given, as
// Umami writes them), or a Unix time in seconds or milliseconds.
func rowTime(row map[string]string, format string) float64 {
	text := row["time"]
	if format == "umami" {
		text = row["created_at"]
	}
	text = jsTrim(text)
	if text == "" {
		return math.NaN()
	}
	if unixTime.MatchString(text) {
		n := js.Number(text)
		if n < 1e12 {
			return math.Round(n * 1000)
		}
		return math.Round(n)
	}
	iso := strings.Replace(text, " ", "T", 1)
	if !hasZone.MatchString(iso) && hasTime.MatchString(iso) {
		iso += "Z"
	}
	return importers.ParseDate(iso)
}

func cell(row map[string]string, names ...string) string {
	for _, n := range names {
		if v := jsTrim(row[n]); v != "" {
			return v
		}
	}
	return ""
}

// ownKey: a row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids.
func ownKey(row map[string]string, keys []string) string {
	sorted := append([]string(nil), keys...)
	sort.SliceStable(sorted, func(i, j int) bool { return compare16(sorted[i], sorted[j]) < 0 })
	pairs := make([]any, len(sorted))
	for i, k := range sorted {
		pairs[i] = []any{k, row[k]}
	}
	return "row:" + js.Stringify(pairs)
}

// csvHit is one row as a hit and the namespace its ids are made in, or nil
// for a row that is not a pageview or a named event, or has no time. Umami
// rows use the namespace the Umami API import does, so the same visits
// brought in both ways get the same ids.
func csvHit(row map[string]string, keys []string, format string) *nsHit {
	ts := rowTime(row, format)
	if math.IsNaN(ts) || math.IsInf(ts, 0) {
		return nil
	}
	if format == "umami" {
		kind := cell(row, "event_type")
		if kind == "" {
			kind = "1"
		}
		name := cell(row, "event_name")
		if kind != "1" && !(kind == "2" && name != "") {
			return nil
		}
		ns := "umami-csv"
		if website := cell(row, "website_id"); website != "" {
			ns = "umami-visits:" + website
		}
		key := cell(row, "session_id", "visit_id")
		if key == "" {
			key = ownKey(row, keys)
		}
		hit := importedHit{ts: ts, key: key, kind: "event", hostname: cell(row, "hostname"), path: cell(row, "url_path"), query: cell(row, "url_query"),
			referrer: referrerOf(cell(row, "referrer_domain"), cell(row, "referrer_path"), cell(row, "referrer_query")),
			title:    cell(row, "page_title"), country: cell(row, "country"), region: cell(row, "subdivision1", "region"), city: cell(row, "city"),
			browser: cell(row, "browser"), os: cell(row, "os"), device: cell(row, "device"), screen: cell(row, "screen"), language: cell(row, "language")}
		if hit.path == "" {
			hit.path = "/"
		}
		if kind == "1" {
			hit.kind = "pageview"
		}
		if kind == "2" {
			hit.name = name
		}
		return &nsHit{ns, hit}
	}
	// Runlight's own shape: a full url, or a path (with its query) and a hostname.
	hostname, path, query := cell(row, "hostname"), cell(row, "path"), ""
	if url := cell(row, "url"); url != "" {
		if !hasScheme.MatchString(url) {
			url = "https://" + url
		}
		u, err := whatwg.Parse(url)
		if err != nil {
			return nil
		}
		if hostname == "" {
			hostname = u.Hostname
		}
		path = u.Pathname
		query = slice16(u.Search, 1, len16(u.Search))
	} else if at := strings.Index(path, "?"); at >= 0 {
		path, query = path[:at], path[at+1:]
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	referrer := cell(row, "referrer")
	if referrer != "" && !hasScheme.MatchString(referrer) {
		referrer = "https://" + referrer
	}
	name := cell(row, "event")
	kind := "pageview"
	if name != "" {
		kind = "event"
	}
	// Without a visitor column every row is its own visit.
	key := cell(row, "visitor")
	if key == "" {
		key = ownKey(row, keys)
	}
	return &nsHit{"csv", importedHit{ts: ts, key: key, kind: kind, hostname: hostname, path: path, query: query, referrer: referrer,
		title: cell(row, "title"), name: name, country: cell(row, "country"), region: cell(row, "region"), city: cell(row, "city"),
		browser: cell(row, "browser"), os: cell(row, "os"), device: cell(row, "device"), screen: cell(row, "screen"), language: cell(row, "language")}}
}

// CsvVisits is what one CSV batch did.
type CsvVisits struct {
	Pageviews int64 `json:"pageviews"`
	Events    int64 `json:"events"`
	Visits    int64 `json:"visits"`
	Skipped   int64 `json:"skipped"`
}

// ImportCsvVisits imports one batch of a CSV file, sorted oldest first by the
// dashboard. As with Umami, only rows from before Runlight's own first visit,
// and within what the site keeps, are written. A batch can run again: its
// time span is cleared first, so batches must not share a moment, which the
// dashboard sees to.
func ImportCsvVisits(ctx context.Context, r *Runlight, siteID string, rows any) (*CsvVisits, error) {
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	if _, ok := r.Site(siteID); !ok {
		return nil, importError("Unknown site", "unknown_site")
	}
	list, ok := rows.([]any)
	if !ok || len(list) > CsvBatch {
		return nil, importError("Send at most "+strconv.Itoa(CsvBatch)+" rows at a time", "import_csv_batch", "max", strconv.Itoa(CsvBatch))
	}
	type cleanRow struct {
		values map[string]string
		keys   []string
	}
	clean := make([]cleanRow, len(list))
	for i, item := range list {
		c := cleanRow{values: map[string]string{}}
		add := func(k string, v any) {
			k = lower(jsTrim(k))
			if _, seen := c.values[k]; !seen {
				c.keys = append(c.keys, k)
			}
			c.values[k] = textOr(v)
		}
		switch t := item.(type) {
		case *js.Object:
			t.Each(add)
		case []any:
			for j, v := range t {
				add(strconv.Itoa(j), v)
			}
		}
		clean[i] = c
	}
	format := ""
	if len(clean) > 0 {
		format = csvFormat(clean[0].values)
	}
	if format == "" {
		return nil, importError("This CSV is not an Umami export or Runlight's visit format", "import_csv_format")
	}
	cutoff := 0.0
	if c, err := r.RetentionCutoff(ctx, siteID); err != nil {
		return nil, err
	} else if c != nil {
		cutoff = float64(*c)
	}
	end := float64(r.now())
	if own, err := r.Store.FirstOwnVisit(ctx, siteID); err != nil {
		return nil, err
	} else if own != nil {
		end = math.Min(float64(*own), end)
	}
	hits := []nsHit{}
	for _, row := range clean {
		if h := csvHit(row.values, row.keys, format); h != nil && h.hit.ts >= cutoff && h.hit.ts < end {
			hits = append(hits, *h)
		}
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].hit.ts < hits[j].hit.ts })
	skipped := int64(len(clean) - len(hits))
	if len(hits) == 0 {
		return &CsvVisits{Skipped: skipped}, nil
	}
	counts, err := r.writeStep(ctx, siteID, hits[0].hit.ts, hits[len(hits)-1].hit.ts+1, hits, nil)
	if err != nil {
		return nil, err
	}
	return &CsvVisits{Pageviews: counts.pageviews, Events: counts.events, Visits: counts.visits, Skipped: skipped}, nil
}
