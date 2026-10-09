// Package conformance plays the scenarios of conformance/http.json as the
// TypeScript runner (packages/sdk/test/http-conformance.ts) plays them, and
// returns each step's answer, normalized, in the shape of the file's expect.
package conformance

import (
	"regexp"
	"sort"
	"strings"

	"runlight.sh/go/internal/js"
)

// Headers are those every implementation must send the same, where it sends them.
var Headers = []string{
	"content-type", "cache-control", "location", "set-cookie", "www-authenticate", "allow", "content-disposition",
	"content-security-policy", "x-frame-options", "referrer-policy", "x-content-type-options", "x-robots-tag",
	"access-control-allow-origin", "access-control-allow-methods", "access-control-allow-headers", "access-control-max-age",
}

// random are keys whose string values differ between runs, ports, and releases.
var random = map[string]bool{"token": true, "secret": true, "hint": true, "version": true, "library": true, "language": true, "ticket": true, "recovery": true}

var (
	queryValue = regexp.MustCompile(`([?&](?:code|ticket|secret|code_challenge)=)[^&#\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}"'<>]+`)
	wholeKey   = regexp.MustCompile(`^rlo?_[A-Za-z0-9]+$`)
	wholeHex   = regexp.MustCompile(`^[a-f0-9]{24}$`)
)

func isAlnum(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

func isHexLower(c byte) bool { return (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9') }

// hexRuns replaces every run of 24 or more lowercase hex digits not next to
// another letter or digit with <hex>.
func hexRuns(text string) string {
	var b strings.Builder
	for i := 0; i < len(text); {
		if !isAlnum(text[i]) {
			b.WriteByte(text[i])
			i++
			continue
		}
		j := i
		allHex := true
		for j < len(text) && isAlnum(text[j]) {
			if !isHexLower(text[j]) {
				allHex = false
			}
			j++
		}
		if allHex && j-i >= 24 {
			b.WriteString("<hex>")
		} else {
			b.WriteString(text[i:j])
		}
		i = j
	}
	return b.String()
}

// keyRuns replaces every rl_ or rlo_ token of 20 or more characters with <key>.
func keyRuns(text string) string {
	var b strings.Builder
	for i := 0; i < len(text); {
		if i == 0 || !(isAlnum(text[i-1]) || text[i-1] == '_') {
			for _, prefix := range []string{"rlo_", "rl_"} {
				if strings.HasPrefix(text[i:], prefix) {
					j := i + len(prefix)
					for j < len(text) && isAlnum(text[j]) {
						j++
					}
					if j-i-len(prefix) >= 20 {
						b.WriteString("<key>")
						i = j
						goto next
					}
				}
			}
		}
		b.WriteByte(text[i])
		i++
	next:
	}
	return b.String()
}

// Scrub replaces random parts inside a longer string: secrets in a query,
// and long runs of hex such as ids and signatures.
func Scrub(text string) string {
	text = queryValue.ReplaceAllString(text, "${1}<value>")
	return keyRuns(hexRuns(text))
}

// Normalize makes ids and other random values "<key>", so answers compare
// across runs and implementations.
func Normalize(value any, key string) any {
	switch v := value.(type) {
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = Normalize(e, key)
		}
		return out
	case *js.Object:
		out := &js.Object{}
		v.Each(func(k string, e any) { out.Set(k, Normalize(e, k)) })
		return out
	case string:
		if random[key] || wholeKey.MatchString(v) || wholeHex.MatchString(v) {
			if key == "" {
				return "<value>"
			}
			return "<" + key + ">"
		}
		return Scrub(v)
	}
	return value
}

var cookiePair = regexp.MustCompile(`^([^=;]+)=([^;]*)`)

// CookieShape is a Set-Cookie header with its value as <value>, unless it clears the cookie.
func CookieShape(header string) string {
	m := cookiePair.FindStringSubmatchIndex(header)
	if m == nil {
		return header
	}
	value := "<value>"
	if m[5] == m[4] {
		value = ""
	}
	return header[m[2]:m[3]] + "=" + value + header[m[1]:]
}

// Canonical is an answer as one text to compare: object keys sorted.
func Canonical(value any) string { return js.Stringify(sorted(value)) }

func sorted(value any) any {
	switch v := value.(type) {
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = sorted(e)
		}
		return out
	case *js.Object:
		keys := v.Keys()
		sort.Strings(keys)
		out := &js.Object{}
		for _, k := range keys {
			out.Set(k, sorted(v.Value(k)))
		}
		return out
	}
	return value
}
