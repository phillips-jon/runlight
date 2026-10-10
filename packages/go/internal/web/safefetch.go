package web

import (
	"context"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"

	"runlight.sh/go/internal/whatwg"
)

// Fetches from addresses that other people's input names, such as the icon
// links on a site's home page or a link domain, go only to the public
// internet. Only https is fetched, never a private, loopback, link-local,
// or metadata address, and redirects are followed by hand under the same
// rules. The real Fetcher checks the address the connection uses
// (FetchInit.PublicOnly).

var dottedQuad = regexp.MustCompile(`^\d{1,3}$`)

func v4(text string) []int {
	parts := strings.Split(text, ".")
	if len(parts) != 4 {
		return nil
	}
	out := make([]int, 4)
	for i, p := range parts {
		if !dottedQuad.MatchString(p) {
			return nil
		}
		n, _ := strconv.Atoi(p)
		if n > 255 {
			return nil
		}
		out[i] = n
	}
	return out
}

func publicV4(a []int) bool {
	switch {
	case a[0] == 0 || a[0] == 10 || a[0] == 127 || a[0] >= 224:
		return false
	case a[0] == 100 && a[1] >= 64 && a[1] < 128:
		return false
	case a[0] == 169 && a[1] == 254:
		return false
	case a[0] == 172 && a[1] >= 16 && a[1] < 32:
		return false
	case a[0] == 192 && a[1] == 168:
		return false
	case a[0] == 192 && a[1] == 0 && (a[2] == 0 || a[2] == 2):
		return false
	case a[0] == 198 && (a[1] == 18 || a[1] == 19):
		return false
	case a[0] == 198 && a[1] == 51 && a[2] == 100:
		return false
	case a[0] == 203 && a[1] == 0 && a[2] == 113:
		return false
	}
	return true
}

var (
	v4Tail  = regexp.MustCompile(`(\d{1,3}(?:\.\d{1,3}){3})$`)
	v6Group = regexp.MustCompile(`^[0-9a-f]{1,4}$`)
)

// v6 is an IPv6 address as eight 16-bit groups, or nil when it is not one.
func v6(text string) []int {
	address := strings.ToLower(strings.SplitN(strings.TrimSuffix(strings.TrimPrefix(text, "["), "]"), "%", 2)[0])
	// A trailing IPv4 address becomes the last two groups.
	if m := v4Tail.FindStringSubmatch(address); m != nil {
		four := v4(m[1])
		if four == nil {
			return nil
		}
		address = address[:len(address)-len(m[1])] + strconv.FormatInt(int64(four[0]<<8|four[1]), 16) + ":" + strconv.FormatInt(int64(four[2]<<8|four[3]), 16)
	}
	halves := strings.Split(address, "::")
	if len(halves) > 2 {
		return nil
	}
	var head, rest []string
	if halves[0] != "" {
		head = strings.Split(halves[0], ":")
	}
	if len(halves) == 2 && halves[1] != "" {
		rest = strings.Split(halves[1], ":")
	}
	missing := 8 - len(head) - len(rest)
	if (len(halves) == 1 && missing != 0) || (len(halves) == 2 && missing < 1) {
		return nil
	}
	groups := append([]string{}, head...)
	if len(halves) == 2 {
		for i := 0; i < missing; i++ {
			groups = append(groups, "0")
		}
	}
	groups = append(groups, rest...)
	out := make([]int, len(groups))
	for i, g := range groups {
		if !v6Group.MatchString(g) {
			return nil
		}
		n, _ := strconv.ParseInt(g, 16, 32)
		out[i] = int(n)
	}
	return out
}

// PublicAddress reports whether an IP address, v4 or v6, is on the public
// internet. Anything that is not an address is not.
func PublicAddress(ip string) bool {
	if four := v4(ip); four != nil {
		return publicV4(four)
	}
	g := v6(ip)
	if g == nil {
		return false
	}
	embedded := func(hi, lo int) []int { return []int{hi >> 8, hi & 255, lo >> 8, lo & 255} }
	zero := func(from, to int) bool {
		for i := from; i < to; i++ {
			if g[i] != 0 {
				return false
			}
		}
		return true
	}
	// IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
	if zero(0, 5) && (g[5] == 0xffff || g[5] == 0) {
		if g[5] == 0 && g[6] == 0 && g[7] <= 1 {
			return false
		}
		return publicV4(embedded(g[6], g[7]))
	}
	if g[0] == 0x64 && g[1] == 0xff9b && zero(2, 6) {
		return publicV4(embedded(g[6], g[7]))
	}
	// 6to4 carries an IPv4 address in its second and third groups.
	if g[0] == 0x2002 {
		return publicV4(embedded(g[1], g[2]))
	}
	if g[0]&0xfe00 == 0xfc00 || g[0]&0xffc0 == 0xfe80 || g[0]&0xff00 == 0xff00 {
		return false
	}
	// Teredo, documentation, and discard prefixes.
	if g[0] == 0x2001 && (g[1] == 0 || g[1] == 0xdb8) {
		return false
	}
	if g[0] == 0x100 && zero(1, 4) {
		return false
	}
	return true
}

// Resolver looks a name up; net.DefaultResolver unless a test sets another.
var Resolver = func(ctx context.Context, name string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, name)
}

// PublicAddresses are the public addresses a name resolves to, for setting
// up DNS records. None where it does not resolve.
func PublicAddresses(ctx context.Context, name string) []string {
	found, err := Resolver(ctx, name)
	if err != nil {
		return []string{}
	}
	out := []string{}
	seen := map[string]bool{}
	for _, a := range found {
		if PublicAddress(a) && !seen[a] {
			seen[a] = true
			out = append(out, a)
		}
	}
	return out
}

// ResolvesPrivately reports whether a name resolves to an address off the
// public internet. False when it does not resolve.
func ResolvesPrivately(ctx context.Context, name string) bool {
	found, err := Resolver(ctx, name)
	if err != nil {
		return false
	}
	for _, a := range found {
		if !PublicAddress(a) {
			return true
		}
	}
	return false
}

// PublicFetch fetches an https URL on the public internet as init says,
// following up to redirects redirects that stay on it, within init.Timeout
// in all (30 seconds when zero). Only a GET follows redirects; anything else
// comes back with the redirect as it is. It fails with a
// *PrivateAddressError for an address off it, and a timed-out FetchError
// when time runs out. A redirect past the last one comes back as it is.
func PublicFetch(ctx context.Context, fetcher Fetcher, target string, init FetchInit, redirects int) (*Response, error) {
	if init.Timeout <= 0 {
		init.Timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, init.Timeout)
	defer cancel()
	init.Method = strings.ToUpper(init.Method)
	if init.Method == "" {
		init.Method = "GET"
	}
	if init.Method != "GET" {
		redirects = 0
	}
	init.Redirect = "manual"
	init.PublicOnly = true
	u, err := whatwg.Parse(target)
	if err != nil {
		return nil, &FetchError{Message: "Invalid URL"}
	}
	for hop := 0; ; hop++ {
		if u.Protocol != "https:" {
			return nil, &PrivateAddressError{u.Href()}
		}
		host := strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(u.Hostname, "["), "]"))
		if (v4(host) != nil || v6(host) != nil) && !PublicAddress(host) {
			return nil, &PrivateAddressError{host}
		}
		if host == "localhost" || strings.HasSuffix(host, ".localhost") {
			return nil, &PrivateAddressError{host}
		}
		answer, err := fetcher.Fetch(ctx, u.Href(), init)
		if err != nil {
			// Whichever way the runtime says it gave up, the caller hears that time ran out.
			if ctx.Err() != nil {
				return nil, &FetchError{Message: "The operation was aborted due to timeout", Timeout: true}
			}
			return nil, err
		}
		location := answer.Header.Get("location")
		if answer.Status < 300 || answer.Status >= 400 || location == "" || hop >= redirects {
			return answer, nil
		}
		next, err := whatwg.Parse(location, u.Href())
		if err != nil {
			return nil, &FetchError{Message: "Invalid URL"}
		}
		u = next
	}
}
