package runlight

import (
	"regexp"
	"strings"
)

// Client is what a user agent says about the browser, system, and device.
type Client struct {
	Browser        string `json:"browser"`
	BrowserVersion string `json:"browserVersion"`
	OS             string `json:"os"`
	OSVersion      string `json:"osVersion"`
	// Device is desktop, mobile, or tablet.
	Device string `json:"device"`
}

// ClientHints are the low entropy client hints Chromium browsers send on
// every request. A nil field was not sent.
type ClientHints struct {
	Brands   *string
	Mobile   *string
	Platform *string
}

// AiAgentOf is the AI agent a user agent names, or nil.
func AiAgentOf(ua string) *AiAgent {
	lower := lower(ua)
	for i := range AiAgents {
		if strings.Contains(lower, AiAgents[i].Token) {
			agent := AiAgents[i]
			return &agent
		}
	}
	return nil
}

var mozillaOrOpera = regexp.MustCompile(`mozilla|opera`)

// IsBot reports whether a user agent is clearly not a person in a browser.
func IsBot(ua string) bool {
	if len16(ua) < 20 || !mozillaOrOpera.MatchString(foldASCII(ua)) {
		return true
	}
	return matchesBotPattern(ua)
}

var browsers = []struct {
	name    string
	pattern *regexp.Regexp
}{
	{"Edge", regexp.MustCompile(`(?:Edg|EdgA|EdgiOS|Edge)/(\d+)`)},
	{"Opera", regexp.MustCompile(`(?:OPR|OPiOS|Opera)/(\d+)`)},
	{"Samsung Internet", regexp.MustCompile(`SamsungBrowser/(\d+)`)},
	{"Yandex Browser", regexp.MustCompile(`YaBrowser/(\d+)`)},
	{"Vivaldi", regexp.MustCompile(`Vivaldi/(\d+)`)},
	{"UC Browser", regexp.MustCompile(`UCBrowser/(\d+)`)},
	{"DuckDuckGo", regexp.MustCompile(`(?:Ddg|DuckDuckGo)/(\d+)`)},
	{"Facebook", regexp.MustCompile(`FB(?:AV|_IAB)/(\d+)`)},
	{"Instagram", regexp.MustCompile(`Instagram (\d+)`)},
	{"Firefox", regexp.MustCompile(`(?:Firefox|FxiOS)/(\d+)`)},
	{"Chrome", regexp.MustCompile(`(?:CriOS|Chrome)/(\d+)`)},
	{"Safari", regexp.MustCompile(`Version/(\d+)[\d.]* (?:Mobile/[^\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]+ )?Safari/`)},
	{"Internet Explorer", regexp.MustCompile(`(?:MSIE |Trident/[^\n\r\x{2028}\x{2029}]*rv:)(\d+)`)},
}

var windowsVersions = map[string]string{
	"10.0": "10",
	"6.3":  "8.1",
	"6.2":  "8",
	"6.1":  "7",
	"6.0":  "Vista",
	"5.1":  "XP",
}

var (
	webView      = regexp.MustCompile(`; wv\)`)
	braveBrand   = regexp.MustCompile(`"Brave"`)
	windowsNT    = regexp.MustCompile(`Windows NT (\d+\.\d+)`)
	appleMobile  = regexp.MustCompile(`(?:iPhone|iPad|iPod)[^\n\r\x{2028}\x{2029}]*? OS (\d+)`)
	androidVer   = regexp.MustCompile(`Android (\d+)`)
	android      = regexp.MustCompile(`Android`)
	chromeOS     = regexp.MustCompile(`CrOS`)
	macOS        = regexp.MustCompile(`Mac OS X|Macintosh`)
	linux        = regexp.MustCompile(`Linux|X11`)
	tabletUA     = regexp.MustCompile(`iPad|Tablet|PlayBook|Silk`)
	mobileWord   = regexp.MustCompile(`Mobile`)
	mobileUA     = regexp.MustCompile(`Mobi|iPhone|iPod|Opera Mini|IEMobile`)
	ipadWidths   = map[int]bool{768: true, 810: true, 820: true, 834: true, 1024: true}
	quoteRemover = strings.NewReplacer(`"`, "")
)

func unquote(value *string) string {
	if value == nil {
		return ""
	}
	return jsTrim(quoteRemover.Replace(*value))
}

// ParseClient reads the browser, system, and device from a user agent, its
// client hints, and the screen's width (nil when not sent).
func ParseClient(ua string, hints ClientHints, screenWidth *int) Client {
	browser, browserVersion := "Other", ""
	for _, b := range browsers {
		if m := b.pattern.FindStringSubmatch(ua); m != nil {
			browser, browserVersion = b.name, m[1]
			break
		}
	}
	if browser == "Chrome" && webView.MatchString(ua) {
		browser = "Android WebView"
	}
	// Brave looks like Chrome in the user agent but names itself in the hints.
	if browser == "Chrome" && hints.Brands != nil && braveBrand.MatchString(*hints.Brands) {
		browser = "Brave"
	}

	os, osVersion := "Other", ""
	if m := windowsNT.FindStringSubmatch(ua); m != nil {
		os, osVersion = "Windows", windowsVersions[m[1]]
	} else if m := appleMobile.FindStringSubmatch(ua); m != nil {
		os, osVersion = "iOS", m[1]
	} else if m := androidVer.FindStringSubmatch(ua); m != nil {
		os, osVersion = "Android", m[1]
	} else if android.MatchString(ua) {
		os = "Android"
	} else if chromeOS.MatchString(ua) {
		os = "Chrome OS"
	} else if macOS.MatchString(ua) {
		// macOS froze its version in the user agent at 10.15, so it says nothing.
		os = "macOS"
	} else if linux.MatchString(ua) {
		os = "Linux"
	}
	platform := unquote(hints.Platform)
	if os == "Other" && platform != "" {
		os = platform
	}

	device := "desktop"
	if tabletUA.MatchString(ua) || (os == "Android" && !mobileWord.MatchString(ua)) {
		device = "tablet"
	} else if mobileUA.MatchString(ua) || unquote(hints.Mobile) == "?1" {
		device = "mobile"
	} else if os == "macOS" && screenWidth != nil && ipadWidths[*screenWidth] {
		// iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
		device = "tablet"
		os = "iOS"
	}
	return Client{browser, browserVersion, os, osVersion, device}
}
