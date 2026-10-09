package runlight

import (
	"regexp"
	"strings"
	"unicode"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
)

// Page is what a pageview's URL says.
type Page struct {
	Hostname string `json:"hostname"`
	Path     string `json:"path"`
	Utm      Utm    `json:"utm"`
	// Ref is a ref or source query parameter, used when there is no utm_source.
	Ref string `json:"ref"`
	// Paid says a click id such as gclid was present. The id itself is never kept.
	Paid bool `json:"paid"`
}

// Utm is a URL's UTM parameters.
type Utm struct {
	Source   string `json:"source"`
	Medium   string `json:"medium"`
	Campaign string `json:"campaign"`
	Term     string `json:"term"`
	Content  string `json:"content"`
}

// Attribution is where a visit came from.
type Attribution struct {
	ReferrerHost string `json:"referrerHost"`
	ReferrerPath string `json:"referrerPath"`
	Source       string `json:"source"`
	Channel      string `json:"channel"`
}

var clickIDs = []string{"gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "ttclid", "twclid", "li_fat_id", "yclid"}

var (
	paidMediums   = regexp.MustCompile(`^(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)$`)
	emailMediums  = regexp.MustCompile(`^(e-?mail|newsletter|mail)$`)
	socialMediums = regexp.MustCompile(`^(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)$`)
)

var (
	sourceByHost  = map[string]*KnownSource{}
	sourceByAlias = map[string]*KnownSource{}
)

func init() {
	for i := range Sources {
		s := &Sources[i]
		for _, host := range s.Hosts {
			sourceByHost[host] = s
		}
		for _, alias := range s.Aliases {
			sourceByAlias[alias] = s
		}
	}
}

// clip is (value ?? "").trim().slice(0, max).
func clip(value string, max int) string {
	return head16(jsTrim(value), max)
}

// StripWww lowercases a host and drops a leading www.
func StripWww(host string) string {
	return strings.TrimPrefix(lower(host), "www.")
}

// SourceForHost is the most specific known source for a host:
// mail.google.com before google.com. Android apps send their package name
// as the referrer (com.google.android.gm for Gmail), which is matched the
// same way. Hosts known only by their shape (click trackers, webmail) come
// last.
func SourceForHost(host string) *KnownSource {
	clean := StripWww(host)
	candidate := clean
	for strings.Contains(candidate, ".") {
		if found, ok := sourceByHost[candidate]; ok {
			return found
		}
		candidate = candidate[strings.Index(candidate, ".")+1:]
	}
	for _, rule := range sourcePatterns {
		if rule.pattern.MatchString(clean) {
			name := rule.name
			if name == "" {
				name = clean
			}
			return &KnownSource{Name: name, Kind: rule.kind, Hosts: []string{}}
		}
	}
	return nil
}

// SourceForAlias is the known source a utm_source, ref, or source value names.
func SourceForAlias(value string) *KnownSource {
	key := jsTrim(lower(value))
	if found, ok := sourceByAlias[key]; ok {
		return found
	}
	if found, ok := sourceByHost[StripWww(key)]; ok {
		return found
	}
	return nil
}

var schemeHTTP = regexp.MustCompile(`^(?i:https?)://`)

// RecordedPath is a path a person wrote, in the form paths are recorded: the
// path of a pasted URL, with a leading slash, percent-encoded as the
// browser's URL parser encodes it, and with a hash route kept, as ParsePage
// keeps it. False when it is not a path or a URL.
func RecordedPath(input string) (string, bool) {
	var u *whatwg.URL
	var err error
	if schemeHTTP.MatchString(input) {
		u, err = whatwg.Parse(input)
	} else {
		path := input
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}
		u, err = whatwg.Parse(path, "https://x.invalid")
	}
	if err != nil {
		return "", false
	}
	return ParsePage(u).Path, true
}

var encodedRun = regexp.MustCompile(`(?:%[0-9A-Fa-f]{2})+`)

// ReadablePath is a recorded path as people write it, for showing and
// exporting: /caf%C3%A9 as /café. Only text is decoded; an encoded slash,
// space, or other mark that would change the path's meaning stays as it is.
func ReadablePath(path string) string {
	return encodedRun.ReplaceAllStringFunc(path, func(run string) string {
		text, ok := decodeURIComponent(run)
		if !ok {
			return run
		}
		for _, r := range text {
			if js.IsSpace(r) || r == '/' || r == '?' || r == '#' || r == '%' || unicode.Is(unicode.C, r) {
				return run
			}
		}
		return text
	})
}

// ParsePage reads a pageview's URL.
func ParsePage(u *whatwg.URL) Page {
	q := u.SearchParams()
	path := u.Pathname
	if path == "" {
		path = "/"
	}
	// The tracker only sends a hash when the site asked for hash routing.
	if len(u.Hash) > 1 {
		path += u.Hash
	}
	ref, ok := q.Get("ref")
	if !ok {
		ref = q.Value("source")
	}
	paid := false
	for _, id := range clickIDs {
		if q.Has(id) {
			paid = true
			break
		}
	}
	return Page{
		Hostname: StripWww(u.Hostname),
		Path:     head16(path, 1000),
		Utm: Utm{
			Source:   clip(q.Value("utm_source"), 200),
			Medium:   lower(clip(q.Value("utm_medium"), 200)),
			Campaign: clip(q.Value("utm_campaign"), 200),
			Term:     clip(q.Value("utm_term"), 200),
			Content:  clip(q.Value("utm_content"), 200),
		},
		Ref:  clip(ref, 200),
		Paid: paid,
	}
}

// Attribute works out where a visit came from. internalHosts are the site's
// own hostnames: a referrer on one of them is navigation within the site,
// not a source.
func Attribute(page Page, referrer string, internalHosts []string) Attribution {
	referrerHost, referrerPath := "", ""
	if referrer != "" {
		// Not a URL is treated as no referrer.
		if u, err := whatwg.Parse(referrer); err == nil {
			// Android apps refer as android-app://<package>/.
			if u.Protocol == "http:" || u.Protocol == "https:" || u.Protocol == "android-app:" {
				host := StripWww(u.Hostname)
				internal := false
				for _, h := range internalHosts {
					if h == host {
						internal = true
					}
				}
				if host != page.Hostname && !internal {
					referrerHost = host
					if u.Protocol != "android-app:" {
						referrerPath = head16(u.Pathname, 500)
					}
				}
			}
		}
	}

	tagged := page.Utm.Source
	if tagged == "" {
		tagged = page.Ref
	}
	var known *KnownSource
	if tagged != "" {
		known = SourceForAlias(tagged)
	} else if referrerHost != "" {
		known = SourceForHost(referrerHost)
	}
	source := tagged
	if source == "" {
		source = referrerHost
	}
	kind := ""
	if known != nil {
		source = known.Name
		kind = known.Kind
	} else if referrerHost != "" {
		if s := SourceForHost(referrerHost); s != nil {
			kind = s.Kind
		}
	}
	medium := page.Utm.Medium

	var channel string
	switch {
	case (page.Paid || paidMediums.MatchString(medium)) && kind == "search":
		channel = "Paid Search"
	case kind == "ai":
		channel = "AI"
	case emailMediums.MatchString(medium) || kind == "email":
		channel = "Email"
	case kind == "search":
		channel = "Organic Search"
	case socialMediums.MatchString(medium) || kind == "social":
		channel = "Social"
	case page.Utm.Source != "" || page.Utm.Medium != "" || page.Utm.Campaign != "":
		channel = "Campaign"
	case referrerHost != "" || page.Ref != "":
		channel = "Referral"
	default:
		channel = "Direct"
	}
	return Attribution{referrerHost, referrerPath, source, channel}
}
