package whatwg

import (
	"strings"
	"unicode/utf8"
)

// SearchParams is JavaScript's URLSearchParams: name and value pairs kept in
// order, + read as a space, and written back in the
// application/x-www-form-urlencoded form. A name like a[] or a.b is kept
// exactly as sent.
type SearchParams struct {
	pairs [][2]string
}

// ParseQuery is new URLSearchParams(text): a leading ? is dropped.
func ParseQuery(text string) *SearchParams {
	p := &SearchParams{}
	text = strings.TrimPrefix(text, "?")
	if text == "" {
		return p
	}
	for _, part := range strings.Split(text, "&") {
		if part == "" {
			continue
		}
		name, value, _ := strings.Cut(part, "=")
		p.pairs = append(p.pairs, [2]string{formDecode(name), formDecode(value)})
	}
	return p
}

// NewSearchParams is new URLSearchParams(pairs), from name, value, name,
// value...
func NewSearchParams(pairs ...string) *SearchParams {
	p := &SearchParams{}
	for i := 0; i+1 < len(pairs); i += 2 {
		p.Append(pairs[i], pairs[i+1])
	}
	return p
}

func formDecode(s string) string {
	s = PercentDecode(strings.ReplaceAll(s, "+", " "))
	if !utf8.ValidString(s) {
		s = Scrub(s)
	}
	return s
}

// Get is params.get(name): the first value, and whether there is one.
func (p *SearchParams) Get(name string) (string, bool) {
	for _, pair := range p.pairs {
		if pair[0] == name {
			return pair[1], true
		}
	}
	return "", false
}

// Value is params.get(name) ?? "".
func (p *SearchParams) Value(name string) string {
	v, _ := p.Get(name)
	return v
}

// GetAll is params.getAll(name).
func (p *SearchParams) GetAll(name string) []string {
	var out []string
	for _, pair := range p.pairs {
		if pair[0] == name {
			out = append(out, pair[1])
		}
	}
	return out
}

// Has is params.has(name).
func (p *SearchParams) Has(name string) bool {
	_, ok := p.Get(name)
	return ok
}

// Set is params.set(name, value): the first pair of that name takes the
// value and any others go.
func (p *SearchParams) Set(name, value string) {
	found := false
	out := p.pairs[:0:0]
	for _, pair := range p.pairs {
		if pair[0] != name {
			out = append(out, pair)
		} else if !found {
			out = append(out, [2]string{name, value})
			found = true
		}
	}
	if !found {
		out = append(out, [2]string{name, value})
	}
	p.pairs = out
}

// Append is params.append(name, value).
func (p *SearchParams) Append(name, value string) {
	p.pairs = append(p.pairs, [2]string{name, value})
}

// Delete is params.delete(name).
func (p *SearchParams) Delete(name string) {
	out := p.pairs[:0:0]
	for _, pair := range p.pairs {
		if pair[0] != name {
			out = append(out, pair)
		}
	}
	p.pairs = out
}

// Pairs is [...params]: every name and value in order.
func (p *SearchParams) Pairs() [][2]string { return append([][2]string(nil), p.pairs...) }

// Keys is [...params.keys()].
func (p *SearchParams) Keys() []string {
	out := make([]string, len(p.pairs))
	for i, pair := range p.pairs {
		out[i] = pair[0]
	}
	return out
}

// Len is params.size.
func (p *SearchParams) Len() int { return len(p.pairs) }

// String is params.toString().
func (p *SearchParams) String() string {
	parts := make([]string, len(p.pairs))
	for i, pair := range p.pairs {
		parts[i] = FormEncode(pair[0]) + "=" + FormEncode(pair[1])
	}
	return strings.Join(parts, "&")
}

// FormEncode is the form encoding: letters, digits, and *-._ as they are,
// spaces as +, everything else escaped as its UTF-8 bytes.
func FormEncode(text string) string {
	if !utf8.ValidString(text) {
		text = Scrub(text)
	}
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '*', c == '-', c == '.', c == '_':
			b.WriteByte(c)
		case c == ' ':
			b.WriteByte('+')
		default:
			b.WriteByte('%')
			b.WriteByte(hexUpper[c>>4])
			b.WriteByte(hexUpper[c&15])
		}
	}
	return b.String()
}

// Scrub is text as valid UTF-8, each ill-formed sequence replaced by one
// U+FFFD as the WHATWG decoder does (the maximal subpart rule).
func Scrub(text string) string {
	if utf8.ValidString(text) {
		return text
	}
	var b strings.Builder
	for i := 0; i < len(text); {
		c := text[i]
		if c < 0x80 {
			b.WriteByte(c)
			i++
			continue
		}
		need, low, high := 0, byte(0x80), byte(0xbf)
		switch {
		case c >= 0xc2 && c <= 0xdf:
			need = 1
		case c == 0xe0:
			need, low = 2, 0xa0
		case c == 0xed:
			need, high = 2, 0x9f
		case c >= 0xe1 && c <= 0xef:
			need = 2
		case c == 0xf0:
			need, low = 3, 0x90
		case c >= 0xf1 && c <= 0xf3:
			need = 3
		case c == 0xf4:
			need, high = 3, 0x8f
		}
		if need == 0 {
			b.WriteString("�")
			i++
			continue
		}
		j := i + 1
		ok := true
		for k := 0; k < need; k, j = k+1, j+1 {
			lo, hi := byte(0x80), byte(0xbf)
			if k == 0 {
				lo, hi = low, high
			}
			if j >= len(text) || text[j] < lo || text[j] > hi {
				ok = false
				break
			}
		}
		if ok {
			b.WriteString(text[i:j])
		} else {
			b.WriteString("�")
		}
		i = j
	}
	return b.String()
}
