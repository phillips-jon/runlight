package runlight

import "strings"

// Report queries: which dimensions exist, where each lives, and how filters
// are read from a URL. Shared by every store.

// eventDimensions are the dimensions recorded per event, and their columns.
var eventDimensions = [][2]string{
	{"page", "path"},
	{"hostname", "hostname"},
	{"event", "name"},
}

// sessionDimensions are the dimensions recorded once per session, from its
// first request, and their columns.
var sessionDimensions = [][2]string{
	{"entry", "entry_path"},
	{"exit", "exit_path"},
	{"referrer", "referrer_host"},
	{"source", "source"},
	{"channel", "channel"},
	{"utm_source", "utm_source"},
	{"utm_medium", "utm_medium"},
	{"utm_campaign", "utm_campaign"},
	{"utm_term", "utm_term"},
	{"utm_content", "utm_content"},
	{"country", "country"},
	{"region", "region"},
	{"city", "city"},
	{"browser", "browser"},
	{"browser_version", "browser_version"},
	{"os", "os"},
	{"os_version", "os_version"},
	{"device", "device"},
	{"screen", "screen"},
	{"language", "language"},
}

// Dimensions is every report dimension: the event ones, the session ones,
// then the AI agent fetches, which are their own rows outside visits.
var Dimensions = func() []string {
	out := []string{}
	for _, d := range eventDimensions {
		out = append(out, d[0])
	}
	for _, d := range sessionDimensions {
		out = append(out, d[0])
	}
	return append(out, "ai_agent", "ai_page")
}()

// Filter is one report filter: dimension, op (is, not, or contains), and value.
type Filter struct {
	Dimension string `json:"dimension"`
	Op        string `json:"op"`
	Value     string `json:"value"`
}

// Query is what a report reads: a site, a range from (inclusive) to
// (exclusive) in epoch milliseconds, and filters.
type Query struct {
	Site    string   `json:"site"`
	From    int64    `json:"from"`
	To      int64    `json:"to"`
	Filters []Filter `json:"filters"`
}

func lookupDimension(list [][2]string, value string) (string, bool) {
	for _, d := range list {
		if d[0] == value {
			return d[1], true
		}
	}
	return "", false
}

// IsDimension reports whether a value names a report dimension.
func IsDimension(value string) bool {
	for _, d := range Dimensions {
		if d == value {
			return true
		}
	}
	return false
}

// IsSessionDimension reports whether a dimension is recorded per visit.
func IsSessionDimension(value string) bool {
	_, ok := lookupDimension(sessionDimensions, value)
	return ok
}

// IsEventDimension reports whether a dimension is recorded per event.
func IsEventDimension(value string) bool {
	_, ok := lookupDimension(eventDimensions, value)
	return ok
}

// ParseFilter reads dimension:op:value, where the value may itself contain colons.
func ParseFilter(text string) *Filter {
	first := strings.Index(text, ":")
	if first < 0 {
		return nil
	}
	second := strings.Index(text[first+1:], ":")
	if second < 0 {
		return nil
	}
	second += first + 1
	dimension, op, value := text[:first], text[first+1:second], text[second+1:]
	if !IsSessionDimension(dimension) && !IsEventDimension(dimension) {
		return nil
	}
	if op != "is" && op != "not" && op != "contains" {
		return nil
	}
	return &Filter{Dimension: dimension, Op: op, Value: head16(value, 500)}
}

// MaxFilters is the most filters a query takes, which keeps every statement
// within Cloudflare D1's 100 values.
const MaxFilters = 6
