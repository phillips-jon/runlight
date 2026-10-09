// Package web holds requests and answers shaped like the Fetch API's, so
// the port reads the same as the TypeScript SDK: a Request with an absolute
// URL, a method, headers, and a body; a Response with a status, headers,
// and a body; and a Fetcher, the stand-in for fetch(), which every outgoing
// request goes through so tests can pass a fake.
package web

import (
	"sort"
	"strings"
	"unicode/utf8"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
)

// Headers are matched without regard to case, as the Fetch API's are. Get
// joins repeated values with ", "; Set-Cookie is kept apart, since its values
// may hold commas, and read back with SetCookies.
type Headers struct {
	values map[string][]string
}

// NewHeaders is headers from name and value pairs.
func NewHeaders(pairs ...string) *Headers {
	h := &Headers{}
	for i := 0; i+1 < len(pairs); i += 2 {
		h.Append(pairs[i], pairs[i+1])
	}
	return h
}

// clean drops line breaks and NUL and trims, so nothing a caller passes can add a header of its own.
func clean(value string) string {
	if strings.ContainsAny(value, "\r\n\x00") {
		value = strings.NewReplacer("\r", "", "\n", "", "\x00", "").Replace(value)
	}
	return strings.Trim(value, " \t")
}

// Get is headers.get(name): every value joined with ", ", or "" when there is none.
func (h *Headers) Get(name string) string {
	v, _ := h.Lookup(name)
	return v
}

// Lookup is headers.get(name), and whether the header is there at all.
func (h *Headers) Lookup(name string) (string, bool) {
	if h == nil || h.values == nil {
		return "", false
	}
	v, ok := h.values[strings.ToLower(name)]
	if !ok {
		return "", false
	}
	return strings.Join(v, ", "), true
}

// Has is headers.has(name).
func (h *Headers) Has(name string) bool {
	_, ok := h.Lookup(name)
	return ok
}

// Set is headers.set(name, value).
func (h *Headers) Set(name, value string) {
	if h.values == nil {
		h.values = map[string][]string{}
	}
	h.values[strings.ToLower(name)] = []string{clean(value)}
}

// Append is headers.append(name, value).
func (h *Headers) Append(name, value string) {
	if h.values == nil {
		h.values = map[string][]string{}
	}
	key := strings.ToLower(name)
	h.values[key] = append(h.values[key], clean(value))
}

// Delete is headers.delete(name).
func (h *Headers) Delete(name string) {
	if h != nil && h.values != nil {
		delete(h.values, strings.ToLower(name))
	}
}

// SetCookies is headers.getSetCookie().
func (h *Headers) SetCookies() []string {
	if h == nil || h.values == nil {
		return nil
	}
	return append([]string(nil), h.values["set-cookie"]...)
}

// Values are every value of a header, in order.
func (h *Headers) Values(name string) []string {
	if h == nil || h.values == nil {
		return nil
	}
	return append([]string(nil), h.values[strings.ToLower(name)]...)
}

// Names are the header names, lowercased, in name order.
func (h *Headers) Names() []string {
	if h == nil {
		return nil
	}
	names := make([]string, 0, len(h.values))
	for k := range h.values {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

// Each calls fn for every header in name order, as iterating Fetch Headers
// gives them: each Set-Cookie on its own, the others joined.
func (h *Headers) Each(fn func(name, value string)) {
	for _, name := range h.Names() {
		if name == "set-cookie" {
			for _, v := range h.values[name] {
				fn(name, v)
			}
			continue
		}
		fn(name, strings.Join(h.values[name], ", "))
	}
}

// Clone is a copy that can be changed apart.
func (h *Headers) Clone() *Headers {
	c := &Headers{values: map[string][]string{}}
	if h != nil {
		for k, v := range h.values {
			c.values[k] = append([]string(nil), v...)
		}
	}
	return c
}

// Len is how many names there are.
func (h *Headers) Len() int {
	if h == nil {
		return 0
	}
	return len(h.values)
}

// Request is an incoming request, shaped like the Fetch API's.
type Request struct {
	// URL is absolute: https://example.com/runlight/api/stats?site=x.
	URL    string
	Method string
	Header *Headers
	Body   []byte
	// RemoteAddress is the address the request came from, before any proxy header is read.
	RemoteAddress string
}

// NewRequest is a request; the method is upper-cased as fetch does.
func NewRequest(method, url string, header *Headers, body []byte) *Request {
	if header == nil {
		header = &Headers{}
	}
	return &Request{URL: url, Method: strings.ToUpper(method), Header: header, Body: body}
}

// Text is request.text(): the body decoded as UTF-8, a byte order mark
// dropped and every ill-formed sequence one U+FFFD.
func (r *Request) Text() string { return DecodeUTF8(r.Body) }

// JSON is request.json(): the body parsed, or an error where JSON.parse throws.
func (r *Request) JSON() (any, error) { return js.Parse(r.Text()) }

// Parsed is new URL(request.url).
func (r *Request) Parsed() *whatwg.URL {
	u, err := whatwg.Parse(r.URL)
	if err != nil {
		return &whatwg.URL{Protocol: "https:", Pathname: "/"}
	}
	return u
}

// With is the same request with another URL, method, headers, or body (nil keeps it).
func (r *Request) With(url *string, method *string, header *Headers, body []byte) *Request {
	c := *r
	if url != nil {
		c.URL = *url
	}
	if method != nil {
		c.Method = *method
	}
	if header != nil {
		c.Header = header
	}
	if body != nil {
		c.Body = body
	}
	return &c
}

// DecodeUTF8 is TextDecoder's decode: a byte order mark dropped and every
// ill-formed sequence one U+FFFD.
func DecodeUTF8(b []byte) string {
	s := string(b)
	s = strings.TrimPrefix(s, "\xef\xbb\xbf")
	if utf8.ValidString(s) {
		return s
	}
	return whatwg.Scrub(s)
}

// Response is an answer, shaped like the Fetch API's.
type Response struct {
	Status int
	Header *Headers
	Body   []byte
	// URL is where a fetched answer came from, after any redirects.
	URL string
}

// NewResponse is an answer with headers from name and value pairs.
func NewResponse(status int, body []byte, headers ...string) *Response {
	return &Response{Status: status, Header: NewHeaders(headers...), Body: body}
}

// JSONResponse is Response.json(): the body JSON as JSON.stringify writes
// it, with application/json and any other headers given.
func JSONResponse(value any, status int, headers ...string) *Response {
	r := NewResponse(status, []byte(js.Stringify(value)), "content-type", "application/json")
	for i := 0; i+1 < len(headers); i += 2 {
		r.Header.Set(headers[i], headers[i+1])
	}
	return r
}

// OK is response.ok.
func (r *Response) OK() bool { return r.Status >= 200 && r.Status < 300 }

// Text is response.text().
func (r *Response) Text() string { return DecodeUTF8(r.Body) }

// JSON is response.json().
func (r *Response) JSON() (any, error) { return js.Parse(r.Text()) }
