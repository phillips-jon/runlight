package runlight

import (
	"time"
	"unicode"
)

// localeCompare orders text roughly as ICU's root collation does for the
// names people give sites: spaces and punctuation first, then digits, then
// letters, letters compared without regard to case or accents first, and a
// lower-case letter before its capital when that is all that differs.
func localeCompare(a, b string) int {
	x, y := []rune(a), []rune(b)
	// Primary: class, then the letter without case or accent.
	for i := 0; i < len(x) && i < len(y); i++ {
		if d := primary(x[i]) - primary(y[i]); d != 0 {
			return sign(d)
		}
	}
	if len(x) != len(y) {
		return sign(len(x) - len(y))
	}
	// Tertiary: lower case before upper case, then code point.
	for i := range x {
		if x[i] == y[i] {
			continue
		}
		lx, ly := unicode.IsLower(x[i]), unicode.IsLower(y[i])
		if lx != ly {
			if lx {
				return -1
			}
			return 1
		}
		return sign(int(x[i]) - int(y[i]))
	}
	return 0
}

func sign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	}
	return 0
}

// accents maps the accented Latin letters people type to their base letter.
var accents = map[rune]rune{
	'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a',
	'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e', 'ě': 'e',
	'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ł': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n',
	'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's',
	'ť': 't', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
}

func primary(r rune) int {
	l := unicode.ToLower(r)
	if base, ok := accents[l]; ok {
		l = base
	}
	switch {
	case unicode.IsSpace(l) || unicode.IsPunct(l) || unicode.IsSymbol(l):
		return int(l)
	case unicode.IsDigit(l):
		return 0x100000 + int(l)
	}
	return 0x200000 + int(l)
}

// dateLayouts are the forms of a date Date.parse reads that log readers send.
var dateLayouts = []string{
	time.RFC3339Nano,
	"2006-01-02T15:04:05.999999999",
	"2006-01-02T15:04",
	"2006-01-02",
	time.RFC1123,
	time.RFC1123Z,
	"Mon, 2 Jan 2006 15:04:05 MST",
	"02/Jan/2006:15:04:05 -0700",
}

// parseTime is a time read in a layout, as epoch milliseconds; a time with
// no zone is UTC.
func parseTime(layout, text string) (int64, error) {
	t, err := time.Parse(layout, text)
	if err != nil {
		return 0, err
	}
	return t.UnixMilli(), nil
}
