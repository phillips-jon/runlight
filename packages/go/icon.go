package runlight

import (
	"context"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// A site's icon, for the dashboard header: the best icon its home page links
// to, or /favicon.ico. Fetched from the site's own configured origin (never
// from request input), cached in memory for a day.

const (
	iconTimeout  = 4 * time.Second
	iconMaxBytes = 256 * 1024
	iconDay      = 86_400_000
)

// SiteIcon is a site's icon.
type SiteIcon struct {
	Body []byte
	Type string
}

type cachedIcon struct {
	at   int64
	icon *SiteIcon
}

var (
	iconMu    sync.Mutex
	iconCache = map[string]cachedIcon{}
	iconOrder []string
	iconWait  = map[string]chan struct{}{}
)

var (
	linkTag  = regexp.MustCompile(`(?i)<link\b[^>]*>`)
	relSplit = regexp.MustCompile(`[\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]+`)
)

// jsSpace is JavaScript's \s.
const jsSpace = `\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}`

var linkAttr = regexp.MustCompile(`([^` + jsSpace + `"'>/=]+)(?:[` + jsSpace + `]*=[` + jsSpace + `]*(?:"([^"]*)"|'([^']*)'|([^` + jsSpace + `>]+)))?`)

// attrs are a tag's attributes, read one after another so a name inside
// another (data-rel) or inside a value (title="rel=icon") is never taken for
// one. The first of a repeated name counts, as in a browser.
func attrs(tag string) map[string]string {
	out := map[string]string{}
	rest := tag[len("<link"):]
	for _, m := range linkAttr.FindAllStringSubmatchIndex(rest, -1) {
		name := lower(rest[m[2]:m[3]])
		if _, ok := out[name]; ok {
			continue
		}
		value := ""
		for g := 2; g <= 4; g++ {
			if m[2*g] >= 0 {
				value = rest[m[2*g]:m[2*g+1]]
				break
			}
		}
		out[name] = jsTrim(value)
	}
	return out
}

// IconLinks are the icon URLs a page links to, best first:
// apple-touch-icon, then SVG and PNG icons, then any icon.
func IconLinks(html, base string) []string {
	type found struct {
		url   string
		score int
	}
	list := []found{}
	for _, tag := range linkTag.FindAllString(html, -1) {
		attributes := attrs(tag)
		rel := relSplit.Split(lower(attributes["rel"]), -1)
		href := attributes["href"]
		if href == "" || !(contains(rel, "icon") || contains(rel, "apple-touch-icon")) {
			continue
		}
		u, err := whatwg.Parse(href, base)
		if err != nil {
			continue
		}
		url := u.Href()
		// Only https, which is all the fetch below takes.
		if !strings.HasPrefix(url, "https://") {
			continue
		}
		kind := lower(attributes["type"])
		score := 0
		switch {
		case contains(rel, "apple-touch-icon"):
			score = 3
		case strings.Contains(kind, "svg") || strings.HasSuffix(url, ".svg"):
			score = 2
		case strings.Contains(kind, "png") || strings.HasSuffix(url, ".png"):
			score = 1
		}
		list = append(list, found{url, score})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].score > list[j].score })
	out := make([]string, len(list))
	for i, f := range list {
		out[i] = f.url
	}
	return out
}

var iconHeaders = web.NewHeaders("user-agent", "Runlight (+https://runlight.sh)")

func iconImage(ctx context.Context, fetcher Fetcher, url string) *SiteIcon {
	answer, err := web.PublicFetch(ctx, fetcher, url, iconHeaders, iconTimeout, 3, iconMaxBytes, false)
	if err != nil || !answer.OK() {
		return nil
	}
	kind := lower(jsTrim(strings.Split(answer.Header.Get("content-type"), ";")[0]))
	if !strings.HasPrefix(kind, "image/") || len(answer.Body) == 0 {
		return nil
	}
	return &SiteIcon{Body: answer.Body, Type: kind}
}

// FetchIcon is a site's icon, nil when it has none. Lookups under way are
// shared, so many dashboards opening at once share one.
func FetchIcon(ctx context.Context, fetcher Fetcher, origin string, now int64) *SiteIcon {
	for {
		iconMu.Lock()
		if cached, ok := iconCache[origin]; ok {
			wait := int64(iconDay / 24)
			if cached.icon != nil {
				wait = iconDay
			}
			if now-cached.at < wait {
				iconMu.Unlock()
				return cached.icon
			}
		}
		if ch, ok := iconWait[origin]; ok {
			iconMu.Unlock()
			<-ch
			continue
		}
		ch := make(chan struct{})
		iconWait[origin] = ch
		iconMu.Unlock()
		icon := lookUpIcon(ctx, fetcher, origin)
		iconMu.Lock()
		if _, ok := iconCache[origin]; !ok {
			iconOrder = append(iconOrder, origin)
		}
		iconCache[origin] = cachedIcon{at: now, icon: icon}
		// A few hundred sites at most; past that the oldest go, so the cache cannot grow without end.
		if len(iconCache) > 500 {
			delete(iconCache, iconOrder[0])
			iconOrder = iconOrder[1:]
		}
		delete(iconWait, origin)
		close(ch)
		iconMu.Unlock()
		return icon
	}
}

func lookUpIcon(ctx context.Context, fetcher Fetcher, origin string) *SiteIcon {
	var icon *SiteIcon
	// The head is all that is needed, so a huge page is not read to the end.
	page, err := web.PublicFetch(ctx, fetcher, origin+"/", iconHeaders, iconTimeout, 3, 200_000, true)
	if err == nil && page.OK() && strings.Contains(page.Header.Get("content-type"), "html") {
		base := page.URL
		if base == "" {
			base = origin
		}
		links := IconLinks(page.Text(), base)
		for i, url := range links {
			if i >= 4 {
				break
			}
			if icon = iconImage(ctx, fetcher, url); icon != nil {
				break
			}
		}
	}
	if icon == nil {
		icon = iconImage(ctx, fetcher, origin+"/favicon.ico")
	}
	return icon
}
