package mail

import (
	"encoding/base64"
	"errors"
	"strings"
	"unicode/utf8"

	"runlight.sh/go/internal/js"
)

// These stand in for the browser globals the TypeScript reaches for: btoa,
// atob, encodeURIComponent, and decodeURIComponent, with the same answers
// and the same failures.

var (
	errInvalidCharacter = errors.New("Invalid character")
	errURIMalformed     = errors.New("URI malformed")
)

// btoa is base64 of text read as Latin-1, refusing a character past U+00FF
// as the browser's does.
func btoa(text string) (string, error) {
	b := make([]byte, 0, len(text))
	for _, u := range js.Units(text) {
		if u > 0xff {
			return "", errInvalidCharacter
		}
		b = append(b, byte(u))
	}
	return base64.StdEncoding.EncodeToString(b), nil
}

// atob is forgiving-base64 decode: ASCII whitespace dropped, padding
// optional, and bits past the last whole byte ignored.
func atob(text string) ([]byte, error) {
	text = strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\t', '\n', '\f', '\r':
			return -1
		}
		return r
	}, text)
	if len(text)%4 == 0 {
		if strings.HasSuffix(text, "==") {
			text = text[:len(text)-2]
		} else if strings.HasSuffix(text, "=") {
			text = text[:len(text)-1]
		}
	}
	if len(text)%4 == 1 {
		return nil, errInvalidCharacter
	}
	b, err := base64.RawStdEncoding.DecodeString(text)
	if err != nil {
		return nil, errInvalidCharacter
	}
	return b, nil
}

// encodeURIComponent is JavaScript's: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( )
// percent-encoded as UTF-8, failing on text that is not well formed.
func encodeURIComponent(text string) (string, error) {
	if !utf8.ValidString(text) {
		return "", errURIMalformed
	}
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if 'A' <= c && c <= 'Z' || 'a' <= c && c <= 'z' || '0' <= c && c <= '9' || strings.IndexByte("-_.!~*'()", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&15])
	}
	return b.String(), nil
}

func unhex(c byte) (byte, bool) {
	switch {
	case '0' <= c && c <= '9':
		return c - '0', true
	case 'a' <= c && c <= 'f':
		return c - 'a' + 10, true
	case 'A' <= c && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// decodeURIComponent is JavaScript's: every escape decoded, failing as it
// does on one that is cut short or is not UTF-8.
func decodeURIComponent(text string) (string, error) {
	if !strings.Contains(text, "%") {
		return text, nil
	}
	octet := func(i int) (byte, bool) {
		if i+2 >= len(text) || text[i] != '%' {
			return 0, false
		}
		hi, ok1 := unhex(text[i+1])
		lo, ok2 := unhex(text[i+2])
		return hi<<4 | lo, ok1 && ok2
	}
	var b strings.Builder
	for i := 0; i < len(text); {
		if text[i] != '%' {
			b.WriteByte(text[i])
			i++
			continue
		}
		first, ok := octet(i)
		if !ok {
			return "", errURIMalformed
		}
		i += 3
		if first < 0x80 {
			b.WriteByte(first)
			continue
		}
		n := 0
		for first<<n&0x80 != 0 {
			n++
		}
		if n == 1 || n > 4 {
			return "", errURIMalformed
		}
		seq := []byte{first}
		for k := 1; k < n; k++ {
			next, ok := octet(i)
			if !ok || next&0xc0 != 0x80 {
				return "", errURIMalformed
			}
			seq = append(seq, next)
			i += 3
		}
		if r, size := utf8.DecodeRune(seq); r == utf8.RuneError || size != n {
			return "", errURIMalformed
		}
		b.Write(seq)
	}
	return b.String(), nil
}

// lessUnits orders strings as JavaScript's < does, by UTF-16 code units.
func lessUnits(a, b string) bool {
	ua, ub := js.Units(a), js.Units(b)
	for i := 0; i < len(ua) && i < len(ub); i++ {
		if ua[i] != ub[i] {
			return ua[i] < ub[i]
		}
	}
	return len(ua) < len(ub)
}

// isLineTerminator is what JavaScript's . does not match.
func isLineTerminator(r rune) bool {
	return r == '\n' || r == '\r' || r == ' ' || r == ' '
}
