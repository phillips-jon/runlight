// Package whatwg reads and writes URLs and query strings as JavaScript's URL
// and URLSearchParams do, for the http and https URLs Runlight records: the
// host lowercased, backslashes read as slashes, dot segments resolved, and
// the path and query percent-encoded with the WHATWG sets, so a path
// recorded here matches what the tracker sent and what the TypeScript SDK
// stores.
package whatwg

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// URL is a parsed URL, its parts as JavaScript's URL gives them.
type URL struct {
	Protocol string
	Username string
	Password string
	Hostname string
	Port     string
	Pathname string
	Search   string
	Hash     string

	// hasAuthority marks a URL of another scheme written with an authority,
	// such as android-app://com.google.android.gm/.
	hasAuthority bool
}

// ErrInvalid is the error new URL() throws, as a TypeError.
var ErrInvalid = errors.New("Invalid URL")

var defaultPorts = map[string]string{"http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21"}

// Special reports whether the URL's scheme is one of the WHATWG special ones.
func (u *URL) Special() bool {
	_, ok := defaultPorts[u.Protocol]
	return ok
}

// Parse is new URL(input, base): the URL, or ErrInvalid where JavaScript
// throws. base may be "" for none.
func Parse(input string, base ...string) (*URL, error) {
	u := &URL{}
	b := ""
	if len(base) > 0 {
		b = base[0]
	}
	if err := u.parse(input, b, len(base) > 0); err != nil {
		return nil, err
	}
	return u, nil
}

// MustParse is Parse for a URL known to be one.
func MustParse(input string) *URL {
	u, err := Parse(input)
	if err != nil {
		panic(err)
	}
	return u
}

// CanParse is URL.canParse.
func CanParse(input string, base ...string) bool {
	_, err := Parse(input, base...)
	return err == nil
}

func trimC0(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r <= 0x20 })
}

func dropTabs(s string) string {
	if !strings.ContainsAny(s, "\t\n\r") {
		return s
	}
	return strings.NewReplacer("\t", "", "\n", "", "\r", "").Replace(s)
}

func schemeOf(s string) (string, string, bool) {
	if s == "" || !isAlpha(s[0]) {
		return "", "", false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if c == ':' {
			return s[:i], s[i+1:], true
		}
		if !isAlpha(c) && !(c >= '0' && c <= '9') && c != '+' && c != '.' && c != '-' {
			return "", "", false
		}
	}
	return "", "", false
}

func isAlpha(c byte) bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

func (u *URL) parse(input, base string, hasBase bool) error {
	input = dropTabs(trimC0(input))
	scheme, rest, ok := schemeOf(input)
	if !ok {
		if !hasBase {
			return ErrInvalid
		}
		b, err := Parse(base)
		if err != nil {
			return err
		}
		return u.resolve(input, b)
	}
	u.Protocol = strings.ToLower(scheme) + ":"
	if !u.Special() {
		// Not a special scheme (mailto:, data:, javascript:): kept as it came.
		if strings.HasPrefix(rest, "//") {
			// An authority after the scheme (android-app://com.google.android.gm/) is an opaque host, kept in its case.
			rest = rest[2:]
			end := strings.IndexAny(rest, "/?#")
			if end < 0 {
				end = len(rest)
			}
			if err := u.opaqueAuthority(rest[:end]); err != nil {
				return err
			}
			u.hasAuthority = true
			u.tail(rest[end:], "")
			return nil
		}
		rest, u.Hash = cut(rest, '#')
		u.Pathname, u.Search = cut(rest, '?')
		return nil
	}
	rest = strings.ReplaceAll(rest, "\\", "/")
	rest = strings.TrimLeft(rest, "/")
	end := strings.IndexAny(rest, "/?#")
	if end < 0 {
		end = len(rest)
	}
	if err := u.authority(rest[:end]); err != nil {
		return err
	}
	u.tail(rest[end:], "/")
	return nil
}

func (u *URL) resolve(input string, base *URL) error {
	u.Protocol = base.Protocol
	if base.Special() {
		input = strings.ReplaceAll(input, "\\", "/")
	}
	if strings.HasPrefix(input, "//") {
		// A special scheme skips any further slashes before the host: ///x is the host x.
		rest := input[2:]
		if base.Special() {
			rest = strings.TrimLeft(input, "/")
		}
		end := strings.IndexAny(rest, "/?#")
		if end < 0 {
			end = len(rest)
		}
		if err := u.authority(rest[:end]); err != nil {
			return err
		}
		u.tail(rest[end:], "/")
		return nil
	}
	u.Username, u.Password, u.Hostname, u.Port = base.Username, base.Password, base.Hostname, base.Port
	u.hasAuthority = base.hasAuthority
	switch {
	case input == "":
		u.Pathname, u.Search, u.Hash = base.Pathname, base.Search, ""
	case input[0] == '#':
		u.Pathname, u.Search = base.Pathname, base.Search
		if len(input) > 1 {
			u.Hash = "#" + encode(input[1:], fragmentSet)
		}
	case input[0] == '?':
		u.Pathname = base.Pathname
		query, hash := cut(input[1:], '#')
		if query != "" {
			u.Search = "?" + encode(query, querySet)
		}
		if hash != "" {
			u.Hash = "#" + encode(hash[1:], fragmentSet)
		}
	case input[0] == '/':
		u.tail(input, "/")
	default:
		dir := base.Pathname[:strings.LastIndex(base.Pathname, "/")+1]
		u.tail(dir+input, "/")
	}
	return nil
}

func (u *URL) authority(authority string) error {
	if at := strings.LastIndex(authority, "@"); at >= 0 {
		user := authority[:at]
		authority = authority[at+1:]
		name, pass := cut(user, ':')
		u.Username = encode(name, userinfoSet)
		if pass != "" {
			u.Password = encode(pass[1:], userinfoSet)
		}
	}
	port := ""
	var host string
	if strings.HasPrefix(authority, "[") {
		end := strings.IndexByte(authority, ']')
		if end < 0 {
			return ErrInvalid
		}
		h, err := ipv6(authority[1:end])
		if err != nil {
			return err
		}
		host = h
		after := authority[end+1:]
		if after != "" {
			if after[0] != ':' {
				return ErrInvalid
			}
			port = after[1:]
		}
	} else {
		colon := strings.LastIndexByte(authority, ':')
		host = authority
		if colon >= 0 {
			host, port = authority[:colon], authority[colon+1:]
		}
		h, err := domain(host)
		if err != nil {
			return err
		}
		host = h
	}
	if host == "" {
		return ErrInvalid
	}
	if port != "" {
		n, ok := portNumber(port)
		if !ok {
			return ErrInvalid
		}
		port = strconv.Itoa(n)
		if port == defaultPorts[u.Protocol] {
			port = ""
		}
	}
	u.Hostname, u.Port = host, port
	return nil
}

func (u *URL) opaqueAuthority(authority string) error {
	if at := strings.LastIndex(authority, "@"); at >= 0 {
		name, pass := cut(authority[:at], ':')
		u.Username = encode(name, userinfoSet)
		if pass != "" {
			u.Password = encode(pass[1:], userinfoSet)
		}
		authority = authority[at+1:]
	}
	colon := strings.LastIndexByte(authority, ':')
	host, port := authority, ""
	if colon >= 0 {
		host, port = authority[:colon], authority[colon+1:]
	}
	if strings.ContainsAny(host, "\x00 #/:<>?@[\\]^|") {
		return ErrInvalid
	}
	if port != "" {
		n, ok := portNumber(port)
		if !ok {
			return ErrInvalid
		}
		port = strconv.Itoa(n)
	}
	u.Hostname = encode(host, "")
	u.Port = port
	return nil
}

func (u *URL) tail(rest, empty string) {
	rest, hash := cut(rest, '#')
	path, query := cut(rest, '?')
	if path == "" && empty == "" {
		u.Pathname = ""
	} else {
		if path == "" {
			path = empty
		}
		u.Pathname = pathOf(path)
	}
	u.Search, u.Hash = "", ""
	if len(query) > 1 {
		u.Search = "?" + encode(query[1:], querySet)
	}
	if len(hash) > 1 {
		u.Hash = "#" + encode(hash[1:], fragmentSet)
	}
}

// cut is the part before mark, and the rest starting with it.
func cut(s string, mark byte) (string, string) {
	if i := strings.IndexByte(s, mark); i >= 0 {
		return s[:i], s[i:]
	}
	return s, ""
}

// Host is url.host: the hostname and any port that is not the default.
func (u *URL) Host() string {
	if u.Port == "" {
		return u.Hostname
	}
	return u.Hostname + ":" + u.Port
}

// Origin is url.origin; "null" for a scheme that has none.
func (u *URL) Origin() string {
	if !u.Special() {
		return "null"
	}
	return u.Protocol + "//" + u.Host()
}

// portNumber reads a port: digits only, at most 65535.
func portNumber(port string) (int, bool) {
	n := 0
	for i := 0; i < len(port); i++ {
		c := port[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 65535 {
			return 0, false
		}
	}
	return n, true
}

// Href is url.href.
func (u *URL) Href() string {
	if !u.Special() && !u.hasAuthority {
		return u.Protocol + u.Pathname + u.Search + u.Hash
	}
	auth := ""
	if u.Username != "" || u.Password != "" {
		auth = u.Username
		if u.Password != "" {
			auth += ":" + u.Password
		}
		auth += "@"
	}
	return u.Protocol + "//" + auth + u.Host() + u.Pathname + u.Search + u.Hash
}

// String is url.href.
func (u *URL) String() string { return u.Href() }

// Clone is a copy that can be changed apart.
func (u *URL) Clone() *URL {
	c := *u
	return &c
}

// SearchParams is url.searchParams, read now; SetSearchParams writes one back.
func (u *URL) SearchParams() *SearchParams { return ParseQuery(u.Search) }

// SetSearchParams replaces the query with these parameters, as a change to
// url.searchParams writes it: an empty list removes the query.
func (u *URL) SetSearchParams(p *SearchParams) {
	text := p.String()
	if text == "" {
		u.Search = ""
	} else {
		u.Search = "?" + text
	}
}

// SetPathname is assigning url.pathname: tabs and newlines dropped, and for
// http and https a backslash read as a slash.
func (u *URL) SetPathname(path string) {
	path = dropTabs(path)
	if u.Special() {
		path = strings.ReplaceAll(path, "\\", "/")
	}
	if path == "" || path[0] != '/' {
		path = "/" + path
	}
	u.Pathname = pathOf(path)
}

// SetSearch is assigning url.search: one leading "?" dropped and the rest
// percent-encoded, an empty value removing the query.
func (u *URL) SetSearch(search string) {
	if search == "" {
		u.Search = ""
		return
	}
	search = strings.TrimPrefix(dropTabs(search), "?")
	u.Search = "?" + encode(search, querySet)
}

// SetHash is assigning url.hash.
func (u *URL) SetHash(hash string) {
	if hash == "" {
		u.Hash = ""
		return
	}
	hash = strings.TrimPrefix(dropTabs(hash), "#")
	u.Hash = "#" + encode(hash, fragmentSet)
}

const (
	pathSet     = " \"#<>?`{}"
	querySet    = " \"#<>'"
	fragmentSet = " \"<>`"
	userinfoSet = " \"#<>?`{}/:;=@[\\]^|"
)

func pathOf(path string) string {
	segments := strings.Split(path, "/")[1:]
	out := make([]string, 0, len(segments))
	for i, segment := range segments {
		lower := strings.ToLower(segment)
		last := i == len(segments)-1
		switch lower {
		case "..", ".%2e", "%2e.", "%2e%2e":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
			if last {
				out = append(out, "")
			}
		case ".", "%2e":
			if last {
				out = append(out, "")
			}
		default:
			out = append(out, encode(segment, pathSet))
		}
	}
	return "/" + strings.Join(out, "/")
}

const hexUpper = "0123456789ABCDEF"

// encode percent-encodes C0 controls, DEL, bytes past ASCII, and extra;
// escapes already there stay as written. Bytes that are not UTF-8 are
// first read as U+FFFD, as a JavaScript string holds them.
func encode(text, extra string) string {
	if !utf8.ValidString(text) {
		text = Scrub(text)
	}
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if c < 0x21 || c > 0x7e || strings.IndexByte(extra, c) >= 0 {
			b.WriteByte('%')
			b.WriteByte(hexUpper[c>>4])
			b.WriteByte(hexUpper[c&15])
		} else {
			b.WriteByte(c)
		}
	}
	return b.String()
}

// Encode percent-encodes as the path set does, for code that builds a path.
func EncodePath(text string) string { return encode(text, pathSet) }
