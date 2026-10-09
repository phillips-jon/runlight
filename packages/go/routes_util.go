package runlight

import (
	"context"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"runlight.sh/go/internal/assets"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

const tokenCookie = "runlight_token"

// implementation names this port in GET /api.
var implementation = [][2]string{{"library", "runlight.sh/go"}, {"language", "go"}}

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;")

func escapeHTML(value string) string { return htmlEscaper.Replace(value) }

var attrEscaper = strings.NewReplacer("&", "&#38;", `"`, "&#34;", "<", "&#60;", ">", "&#62;")

func escapeAttr(value string) string { return attrEscaper.Replace(value) }

// isOauthDocument: the discovery documents OAuth clients read, two of
// OAuth's own, and OpenID's, which some clients try first.
func isOauthDocument(path string) bool {
	return strings.HasPrefix(path, "/.well-known/oauth-") || strings.HasPrefix(path, "/.well-known/openid-configuration")
}

func isDevelopment() bool {
	v, _ := envValue("NODE_ENV")
	return v == "development"
}

// jsonAnswer is a JSON answer as the SDK's json() writes it.
func jsonAnswer(body any, status int, headers ...string) *Response {
	r := web.NewResponse(status, []byte(js.Stringify(body)),
		"content-type", "application/json; charset=utf-8", "cache-control", "no-store", "x-content-type-options", "nosniff")
	for i := 0; i+1 < len(headers); i += 2 {
		r.Header.Set(headers[i], headers[i+1])
	}
	return r
}

// Coded is an error the dashboard can show in its own language: code names
// it and params fill its placeholders, while error stays the English message.
func Coded(message, code string, status int, params *js.Object, headers ...string) *Response {
	body := js.NewObject("error", message, "code", code)
	if params != nil {
		body.Set("params", params)
	}
	return jsonAnswer(body, status, headers...)
}

func params(pairs ...string) *js.Object { return js.NewObject(stringsToAny(pairs)...) }

// refusedAnswer is a refusal from a check elsewhere: its own code and params
// when the error carries them, or else fallback with its English words as detail.
func refusedAnswer(err error, fallback string, status int) *Response {
	if c := codedOf(err); c != nil {
		return Coded(c.Message, c.Code, status, c.Params)
	}
	return Coded(err.Error(), fallback, status, params("detail", err.Error()))
}

// isJSON reports whether a request's body is JSON by its media type. A
// cross-site form or a no-cors fetch can only send text/plain, urlencoded,
// or multipart, so a JSON media type proves the request came from a page
// allowed to send it.
func isJSON(request *Request) bool {
	return lower(jsTrim(strings.Split(request.Header.Get("content-type"), ";")[0])) == "application/json"
}

var portSuffix = regexp.MustCompile(`:\d*$`)

// HostName is a Host or X-Forwarded-Host value as a bare name: lowercase,
// with no port, no final dot, and no www.
func HostName(value string) string {
	first := lower(jsTrim(strings.Split(value, ",")[0]))
	name := first
	if strings.HasPrefix(first, "[") {
		end := strings.Index(first, "]")
		name = first[:end+1]
	} else {
		name = portSuffix.ReplaceAllString(first, "")
	}
	return strings.TrimPrefix(strings.TrimRight(name, "."), "www.")
}

var (
	embeddedIPv4 = regexp.MustCompile(`(^|\.)\d{1,3}(\.\d{1,3}){3}(\.|$)`)
	privateTLD   = regexp.MustCompile(`\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)$`)
)

// privateName reports whether a domain name is one kept for private
// networks or tests, or has an IPv4 address inside it (as nip.io answers).
func privateName(domain string) bool {
	return embeddedIPv4.MatchString(domain) || privateTLD.MatchString(domain)
}

const smallPageStyle = `<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style>`

// smallPage is a plain page in a visitor's language, for unsubscribing and for a share link that is gone.
func smallPage(lang, body string, status int) *Response {
	html := `<!doctype html><html lang="` + lang + `"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Runlight</title>
` + smallPageStyle + `</head><body><main>` + body + `</main></body></html>`
	return web.NewResponse(status, []byte(html),
		"content-type", "text/html; charset=utf-8",
		"cache-control", "no-store",
		"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
		"referrer-policy", "no-referrer")
}

// acceptedLanguage is the first language a browser asks for that the dashboard speaks, else English.
func acceptedLanguage(request *Request) string {
	for _, part := range strings.Split(request.Header.Get("accept-language"), ",") {
		code := lower(head16(jsTrim(strings.Split(part, ";")[0]), 2))
		if contains(Languages(), code) {
			return code
		}
	}
	return "en"
}

var sheetPathDimensions = map[string]bool{"page": true, "entry": true, "exit": true, "ai_page": true}

// sheetRow is one row for a spreadsheet: a bucket's start as the site's
// local date (and hour), rates as percents, durations in seconds, and paths
// as people write them.
func sheetRow(row *js.Object, timezone, interval, dimension string) *js.Object {
	out := &js.Object{}
	row.Each(func(key string, value any) {
		n, isNum := value.(float64)
		switch {
		case key == "start" && isNum:
			hour := ""
			if interval == "hour" {
				_, h := LocalWeekdayHour(int64(n), timezone)
				hour = fmt.Sprintf(" %02d:00", h)
			}
			out.Set("date", LocalDate(int64(n), timezone)+hour)
		case key == "bounceRate" && isNum:
			out.Set("bounceRatePercent", js.Round(n*1000)/10)
		case (key == "visitDuration" || key == "timeOnPage") && isNum:
			out.Set(key+"Seconds", js.Round(n/1000))
		case key == "value" && sheetPathDimensions[dimension]:
			if s, ok := value.(string); ok {
				out.Set("value", ReadablePath(s))
			} else {
				out.Set(key, value)
			}
		default:
			out.Set(key, value)
		}
	})
	return out
}

// rowsCsv is rows of objects as CSV, with a column for every key the first
// row has, in the units a spreadsheet reads.
func rowsCsv(rows any, timezone, interval, dimension string) string {
	list := js.Arr(js.ToValue(rows))
	readable := make([]*js.Object, len(list))
	for i, r := range list {
		readable[i] = sheetRow(js.Obj(r), timezone, interval, dimension)
	}
	header := []string{"value"}
	if len(readable) > 0 {
		header = readable[0].Keys()
	}
	out := [][]any{}
	for _, r := range readable {
		row := make([]any, len(header))
		for i, k := range header {
			v, ok := r.Get(k)
			if !ok {
				v = js.Undefined{}
			}
			row[i] = v
		}
		out = append(out, row)
	}
	return Csv(header, out)
}

var unsafeFileName = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// download is a file to save, never shown in the browser or kept in a shared cache.
func download(name string, body []byte, contentType string) *Response {
	return web.NewResponse(200, body, "content-type", contentType, "content-disposition", `attachment; filename="`+unsafeFileName.ReplaceAllString(name, "-")+`"`, "cache-control", "private, no-store")
}

// constantTimeEqual compares two secrets without leaking where they differ.
func constantTimeEqual(a, b string) bool {
	if len16(a) != len16(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func cookieValue(token string) string { return sha256Hex("runlight-cookie:" + token) }

// readCookie is a cookie's value, "" when it is not there.
func readCookie(request *Request, name string) string {
	for _, part := range strings.Split(request.Header.Get("cookie"), ";") {
		pieces := strings.Split(jsTrim(part), "=")
		if pieces[0] == name {
			return strings.Join(pieces[1:], "=")
		}
	}
	return ""
}

// bearer is an Authorization: Bearer header's token, "" when there is none.
func bearer(request *Request) string {
	header := request.Header.Get("authorization")
	if strings.HasPrefix(lower(header), "bearer ") {
		return jsTrim(slice16(header, 7, len16(header)))
	}
	return ""
}

func normaliseBase(path string) string {
	trimmed := "/" + strings.Trim(path, "/")
	if trimmed == "/" {
		return ""
	}
	return trimmed
}

func localeURLs(base string) string {
	o := &js.Object{}
	for _, code := range assets.LocaleOrder {
		if code == "en" {
			continue
		}
		o.Set(code, base+"/assets/locale."+code+"."+assets.Build.LocalesHash+".json")
	}
	return js.Stringify(o)
}

// dashboardPage is the dashboard's HTML, which holds no data.
func dashboardPage(base, share, signOut string, geoCredit, accounts bool, signIn string) string {
	var attrs strings.Builder
	if share != "" {
		attrs.WriteString(` data-share="` + escapeAttr(share) + `"`)
	}
	if signOut != "" {
		attrs.WriteString(` data-sign-out="` + escapeAttr(signOut) + `"`)
	}
	if signIn != "" {
		attrs.WriteString(` data-sign-in="` + escapeAttr(signIn) + `"`)
	}
	if geoCredit {
		attrs.WriteString(` data-geo-credit=""`)
	}
	if accounts {
		attrs.WriteString(` data-accounts=""`)
	}
	b := escapeAttr(base)
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Runlight</title>
<link rel="icon" href="` + Icon + `">
<link rel="stylesheet" href="` + b + `/assets/app.` + assets.Build.DashboardHash + `.css">
</head>
<body>
<div id="app" data-base="` + b + `"` + attrs.String() + ` data-world="` + b + `/assets/world.` + assets.Build.WorldHash + `.json" data-locales="` + escapeAttr(localeURLs(base)) + `"></div>
<script type="module" src="` + b + `/assets/app.` + assets.Build.DashboardHash + `.js"></script>
</body>
</html>
`
}

// tokenPrefix starts API tokens, so they are told apart from the main token.
const tokenPrefix = "rl_"

// shareHeader is the header a shared dashboard sends its share id in.
const shareHeader = "x-runlight-share"

// sharedPaths are what a share can read: one site's reports, nothing that changes anything.
var sharedPaths = map[string]bool{"/api/sites": true, "/api/icon": true, "/api/realtime": true, "/api/stats": true, "/api/series": true, "/api/rhythm": true, "/api/breakdown": true, "/api/goals": true, "/api/event-props": true, "/api/export": true, "/api/funnels": true, "/api/journeys": true}

var goalPath = regexp.MustCompile(`^/api/goals/[a-f0-9]{24}$`)

func sharedPath(path string) bool { return sharedPaths[path] || goalPath.MatchString(path) }

var (
	manageImport  = regexp.MustCompile(`^/api/links/import`)
	manageAreas   = regexp.MustCompile(`^/api/(links|link-domains|reports|goals|funnels|shares)(/|$)`)
	manageSite    = regexp.MustCompile(`^/api/sites/[^/]+$`)
	originPattern = regexp.MustCompile(`^https?://[^/?#\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]+$`)
)

// ManagePath reports what a manage token, held by a Runlight hub, may read
// and change: one site's goals, funnels, short links, link domains, email
// reports, and share links, along with its name, timezone, and retention,
// and tickets for the element picker. It may read which mail service sends
// reports, through GET /api/mail, which hides the service's keys. Never
// people, tokens, changes to the mail service, imports, or other sites.
func ManagePath(method, path string) bool {
	switch {
	case manageImport.MatchString(path):
		return false
	case manageAreas.MatchString(path):
		return true
	case path == "/api/pick":
		return method == "POST"
	case path == "/api/mail":
		return method == "GET"
	case manageSite.MatchString(path):
		return method == "PATCH"
	}
	return false
}

const (
	// rulesPlaceholder is where the tracker's click rules go; the script ships with this string in their place.
	rulesPlaceholder = `"__RUNLIGHT_RULES__"`
	// pickTargetPlaceholder is where the picker's one allowed receiver goes.
	pickTargetPlaceholder = `"__RUNLIGHT_PICK_TARGET__"`
	// pickHostsPlaceholder is where the hostnames of the site its ticket names go, as JSON inside a string.
	pickHostsPlaceholder = `"__RUNLIGHT_PICK_HOSTS__"`
	// pickTicketMs is how long a picker ticket works: long enough to find the element, not to be kept.
	pickTicketMs = 30 * 60_000
	// askPerHour and askAtOnce are the questions one person may put to the assistant in an hour, and at once.
	askPerHour = 30
	askAtOnce  = 2
	// viewerDailyDefault is the questions each viewer may ask a day, until an owner sets another number.
	viewerDailyDefault = 50
)

var shareID = regexp.MustCompile(`^[a-f0-9]{32}$`)

const dashboardCSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

func hexText(text string) string { return hex.EncodeToString([]byte(text)) }

func unhexText(text string) string {
	b, _ := hex.DecodeString(text)
	return web.DecodeUTF8(b)
}

// queryValue is url.searchParams.get(name), and whether it is there.
func queryValue(u *whatwg.URL, name string) (string, bool) { return u.SearchParams().Get(name) }

// passThrough answers a read for a site counted by another install by
// asking that install, with its token and its own id for the site, and
// handing back what it says.
func passThrough(ctx context.Context, fetcher Fetcher, remote Remote, path string, u *whatwg.URL, request *Request) *Response {
	target, err := whatwg.Parse(remote.URL + path)
	if err != nil {
		return Coded("Could not reach "+remote.URL, "unreachable", 502, params("host", remote.URL))
	}
	q := target.SearchParams()
	for _, pair := range u.SearchParams().Pairs() {
		q.Append(pair[0], pair[1])
	}
	q.Set("site", remote.Site)
	target.SetSearchParams(q)
	// A change made from the hub goes on to the install with its JSON body; reads carry none.
	write := request != nil && request.Method != "GET" && request.Method != "HEAD"
	headers := web.NewHeaders("authorization", "Bearer "+remote.Token)
	init := FetchInit{Method: "GET", Headers: headers, Redirect: "manual", Timeout: 120 * time.Second}
	if write {
		if ct, ok := request.Header.Lookup("content-type"); ok && ct != "" {
			headers.Set("content-type", ct)
		}
		init.Method = request.Method
		init.Body = []byte(request.Text())
		// A long report or an export is worked out in full before the install sends a byte, so reads get
		// two minutes.
		init.Timeout = 30 * time.Second
	}
	host := whatwg.MustParse(remote.URL).Host()
	answer, err := fetcher.Fetch(ctx, target.Href(), init)
	if err != nil {
		if web.IsTimeout(err) {
			return Coded(host+" took too long to answer. Try a shorter range.", "remote_slow", 504, params("host", host))
		}
		return Coded("Could not reach "+host, "unreachable", 502, params("host", host))
	}
	// What comes back is shown from this server's origin, so it is never taken as a page: JSON, or a
	// download for exports, with sniffing off and nothing allowed to run.
	format, _ := queryValue(u, "format")
	isDownload := path == "/api/export" || (path == "/api/breakdown" && format == "csv")
	back := []string{"cache-control", "private, no-store", "x-content-type-options", "nosniff", "content-security-policy", "default-src 'none'; frame-ancestors 'none'"}
	switch {
	case !isDownload:
		back = append(back, "content-type", "application/json; charset=utf-8")
	case strings.HasPrefix(answer.Header.Get("content-type"), "text/csv"):
		back = append(back, "content-type", "text/csv; charset=utf-8")
	default:
		back = append(back, "content-type", "application/zip")
	}
	if isDownload {
		name := "runlight-export"
		if m := fileName.FindStringSubmatch(answer.Header.Get("content-disposition")); m != nil {
			name = m[1]
		}
		back = append(back, "content-disposition", `attachment; filename="`+name+`"`)
	}
	if answer.Status >= 300 && answer.Status < 400 {
		return Coded(host+" answered with a redirect", "redirected", 502, params("host", host))
	}
	// The install's own errors say what went wrong there; a refused token is this server's problem to report.
	if answer.Status == 401 {
		return Coded(host+" refused the token. Connect it again from the site's settings.", "token_refused", 502, params("host", host))
	}
	// An install's own error is shown here, so it says where it came from, keeps only short text, and
	// carries its code and params for the dashboard to put in its own words.
	if answer.Status >= 400 && !isDownload {
		text := answer.Text()
		var body any
		if len16(text) <= 65_536 {
			body, _ = js.Parse(text)
		}
		message := fmt.Sprintf("answered %d", answer.Status)
		if e, ok := js.Dig(body, "error").(string); ok {
			message = head16(e, 300)
		}
		out := js.NewObject("error", host+": "+message)
		if code, ok := js.Dig(body, "code").(string); ok && errorCode.MatchString(code) {
			kept := &js.Object{}
			if p := js.Obj(js.Dig(body, "params")); p != nil {
				n := 0
				for _, k := range p.Keys() {
					v, isString := p.Value(k).(string)
					if !isString {
						continue
					}
					if n >= 10 {
						break
					}
					kept.Set(head16(k, 40), head16(v, 200))
					n++
				}
			}
			out.Set("code", code)
			out.Set("params", kept)
		}
		return jsonAnswer(out, answer.Status, back...)
	}
	return web.NewResponse(answer.Status, answer.Body, back...)
}

var (
	fileName  = regexp.MustCompile(`filename="([A-Za-z0-9._-]+)"`)
	errorCode = regexp.MustCompile(`^[a-z_]{1,40}$`)
)

// errUnknownSite is the refusal for a site that is not there.
var errUnknownSite = errors.New("Unknown site")
