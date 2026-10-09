package runlight

import (
	"strings"
	"unicode/utf8"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
)

// The few JavaScript string rules the port keeps exactly: lengths and
// slices in UTF-16 code units, trim() with JavaScript's white space, and
// decodeURIComponent's strictness.

func len16(s string) int { return js.Length16(s) }

// head16 is s.slice(0, n), counting UTF-16 code units.
func head16(s string, n int) string { return js.Head16(js.WellFormed(s), n) }

// slice16 is s.slice(start, end), counting UTF-16 code units.
func slice16(s string, start, end int) string { return js.Slice16(js.WellFormed(s), start, end) }

func jsTrim(s string) string { return js.Trim(s) }

func lower(s string) string { return js.ToLower(s) }

func upper(s string) string { return js.ToUpper(s) }

// decodeURIComponent is decodeURIComponent(text), false where it throws: a
// broken escape, or bytes that are not UTF-8.
func decodeURIComponent(text string) (string, bool) {
	for i := 0; i < len(text); i++ {
		if text[i] == '%' && (i+2 >= len(text) || !isHexByte(text[i+1]) || !isHexByte(text[i+2])) {
			return "", false
		}
	}
	out := whatwg.PercentDecode(text)
	if !utf8.ValidString(out) {
		return "", false
	}
	return out, true
}

func isHexByte(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// encodeURIComponent is encodeURIComponent(text).
func encodeURIComponent(text string) string {
	text = js.WellFormed(text)
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.IndexByte("-_.!~*'()", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte("0123456789ABCDEF"[c>>4])
		b.WriteByte("0123456789ABCDEF"[c&15])
	}
	return b.String()
}

// encodeURI is encodeURI(text).
func encodeURI(text string) string {
	text = js.WellFormed(text)
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.IndexByte("-_.!~*'();/?:@&=+$,#", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte("0123456789ABCDEF"[c>>4])
		b.WriteByte("0123456789ABCDEF"[c&15])
	}
	return b.String()
}

// compare16 orders two strings as JavaScript's < does, by UTF-16 code
// units: negative, zero, or positive.
func compare16(a, b string) int {
	if a == b {
		return 0
	}
	x, y := js.Units(a), js.Units(b)
	for i := 0; i < len(x) && i < len(y); i++ {
		if x[i] != y[i] {
			return int(x[i]) - int(y[i])
		}
	}
	return len(x) - len(y)
}

// codeOrder orders text by code point, as SQLite and Postgres's "C"
// collation do, which for UTF-8 is byte order.
func codeOrder(a, b string) int { return strings.Compare(a, b) }
