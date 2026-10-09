package whatwg

import (
	"math"
	"net/netip"
	"strconv"
	"strings"
	"unicode/utf8"
)

// domain reads a special URL's host: percent-decoded, checked for the
// characters a host cannot hold, lowercased, a name outside ASCII written
// in punycode, and an IPv4 address in any form browsers accept written in
// dotted decimal.
func domain(host string) (string, error) {
	host = PercentDecode(host)
	if !utf8.ValidString(host) {
		return "", ErrInvalid
	}
	for i := 0; i < len(host); i++ {
		c := host[i]
		if c <= 0x20 || c == 0x7f || strings.IndexByte("#%/:<>?@[\\]^|", c) >= 0 {
			return "", ErrInvalid
		}
	}
	lower := strings.ToLower(host)
	if !isASCII(lower) {
		ascii, ok := ToASCII(lower)
		if !ok {
			return "", ErrInvalid
		}
		lower = ascii
	}
	if ip, ok, err := ipv4(lower); err != nil {
		return "", err
	} else if ok {
		return ip, nil
	}
	return lower, nil
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// ipv4 reads a host that ends in a number as an IPv4 address in any form
// browsers accept (0x7f.1, 2130706433), written back in dotted decimal. A
// host whose last label is not a number is a name, and false.
func ipv4(host string) (string, bool, error) {
	parts := strings.Split(host, ".")
	if parts[len(parts)-1] == "" && len(parts) > 1 {
		parts = parts[:len(parts)-1]
	}
	last := parts[len(parts)-1]
	if !isNumberLabel(last) {
		return "", false, nil
	}
	if len(parts) > 4 {
		return "", false, ErrInvalid
	}
	numbers := make([]float64, 0, len(parts))
	for _, part := range parts {
		n, ok := ipv4Number(part)
		if !ok {
			return "", false, ErrInvalid
		}
		numbers = append(numbers, n)
	}
	value := numbers[len(numbers)-1]
	for _, n := range numbers[:len(numbers)-1] {
		if n > 255 {
			return "", false, ErrInvalid
		}
	}
	if value >= math.Pow(256, float64(5-len(numbers))) {
		return "", false, ErrInvalid
	}
	for i, n := range numbers[:len(numbers)-1] {
		value += n * math.Pow(256, float64(3-i))
	}
	v := uint32(value)
	return strconv.Itoa(int(v>>24)) + "." + strconv.Itoa(int(v>>16&255)) + "." + strconv.Itoa(int(v>>8&255)) + "." + strconv.Itoa(int(v&255)), true, nil
}

func isNumberLabel(s string) bool {
	if s == "" {
		return false
	}
	if strings.HasPrefix(s, "0x") || strings.HasPrefix(s, "0X") {
		for i := 2; i < len(s); i++ {
			if !isHex(s[i]) {
				return false
			}
		}
		return true
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func ipv4Number(s string) (float64, bool) {
	if s == "" {
		return 0, false
	}
	base := 10
	switch {
	case len(s) >= 2 && (s[:2] == "0x" || s[:2] == "0X"):
		s, base = s[2:], 16
	case len(s) >= 2 && s[0] == '0':
		s, base = s[1:], 8
	}
	if s == "" {
		return 0, true
	}
	n := 0.0
	for i := 0; i < len(s); i++ {
		var d int
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			d = int(c - '0')
		case c >= 'a' && c <= 'f':
			d = int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = int(c-'A') + 10
		default:
			return 0, false
		}
		if d >= base {
			return 0, false
		}
		n = n*float64(base) + float64(d)
	}
	return n, true
}

func isHex(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// ipv6 reads the text between a host's brackets and writes it as the URL
// standard serialises it, in brackets.
func ipv6(text string) (string, error) {
	addr, err := netip.ParseAddr(text)
	if err != nil || !addr.Is6() || addr.Zone() != "" {
		return "", ErrInvalid
	}
	b := addr.As16()
	var pieces [8]uint16
	for i := range pieces {
		pieces[i] = uint16(b[2*i])<<8 | uint16(b[2*i+1])
	}
	// The first longest run of two or more zero pieces is compressed.
	start, length := -1, 0
	for i := 0; i < 8; {
		if pieces[i] != 0 {
			i++
			continue
		}
		j := i
		for j < 8 && pieces[j] == 0 {
			j++
		}
		if j-i > length && j-i > 1 {
			start, length = i, j-i
		}
		i = j
	}
	var out strings.Builder
	out.WriteByte('[')
	for i := 0; i < 8; i++ {
		if i == start {
			if i == 0 {
				out.WriteString("::")
			} else {
				out.WriteByte(':')
			}
			i += length - 1
			continue
		}
		out.WriteString(strconv.FormatUint(uint64(pieces[i]), 16))
		if i < 7 {
			out.WriteByte(':')
		}
	}
	out.WriteByte(']')
	return out.String(), nil
}

// PercentDecode decodes every %XX escape into its byte, leaving a % that
// starts no escape as it is, as the URL standard's percent-decode does.
func PercentDecode(s string) string {
	if strings.IndexByte(s, '%') < 0 {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			b.WriteByte(unhex(s[i+1])<<4 | unhex(s[i+2]))
			i += 2
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func unhex(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	}
	return c - 'A' + 10
}

// ToASCII writes a lowercased host name outside ASCII in punycode, label
// by label (bücher.example as xn--bcher-kva.example), as IDNA does for the
// names people type. It does not apply UTS 46's other mappings.
func ToASCII(host string) (string, bool) {
	labels := strings.Split(host, ".")
	for i, label := range labels {
		if isASCII(label) {
			continue
		}
		encoded, ok := punycode(label)
		if !ok {
			return "", false
		}
		labels[i] = "xn--" + encoded
	}
	out := strings.Join(labels, ".")
	return out, len(out) <= 253 || strings.HasSuffix(out, ".") && len(out) <= 254
}

// punycode is RFC 3492's encoding of one label.
func punycode(label string) (string, bool) {
	const (
		base        = 36
		tmin        = 1
		tmax        = 26
		skew        = 38
		damp        = 700
		initialBias = 72
		initialN    = 128
	)
	runes := []rune(label)
	var out []byte
	for _, r := range runes {
		if r < 0x80 {
			out = append(out, byte(r))
		}
	}
	b := len(out)
	h := b
	if b > 0 {
		out = append(out, '-')
	}
	digit := func(d int) byte {
		if d < 26 {
			return byte('a' + d)
		}
		return byte('0' + d - 26)
	}
	adapt := func(delta, numPoints int, first bool) int {
		if first {
			delta /= damp
		} else {
			delta /= 2
		}
		delta += delta / numPoints
		k := 0
		for delta > ((base-tmin)*tmax)/2 {
			delta /= base - tmin
			k += base
		}
		return k + (base-tmin+1)*delta/(delta+skew)
	}
	n, delta, bias := initialN, 0, initialBias
	for h < len(runes) {
		m := math.MaxInt32
		for _, r := range runes {
			if int(r) >= n && int(r) < m {
				m = int(r)
			}
		}
		delta += (m - n) * (h + 1)
		n = m
		for _, r := range runes {
			if int(r) < n {
				delta++
			}
			if int(r) == n {
				q := delta
				for k := base; ; k += base {
					t := k - bias
					if t < tmin {
						t = tmin
					} else if t > tmax {
						t = tmax
					}
					if q < t {
						break
					}
					out = append(out, digit(t+(q-t)%(base-t)))
					q = (q - t) / (base - t)
				}
				out = append(out, digit(q))
				bias = adapt(delta, h+1, h == b)
				delta = 0
				h++
			}
		}
		delta++
		n++
	}
	return string(out), true
}
