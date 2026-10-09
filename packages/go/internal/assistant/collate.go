package assistant

// order is every printable ASCII character, the ASCII spaces, and U+0085
// in the order Node's localeCompare (ICU's root collation) sorts them; a
// letter's two cases share a place, the small one first.
const order = "\t\n\v\f\r\u0085 _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ"

// element is one collation element: a primary weight (the letter), a
// secondary one (its marks), and a tertiary one (its case). Zero is a
// weight the level skips.
type element struct{ primary, secondary, tertiary int }

// primaries holds the primary weight of each character in order.
var primaries = func() map[rune]int {
	p := map[rune]int{}
	weight := 0
	for _, c := range order {
		// A capital shares the small letter's weight.
		if c < 'A' || c > 'Z' {
			weight++
		}
		p[c] = weight
	}
	return p
}()

const (
	common = 1
	upper  = 2
	// noBreak is the tertiary weight of U+00A0, a space that sorts after the plain one.
	noBreak = 3
	// beyond is the first primary weight past those in order, for characters ranked by code point.
	beyond = 1000
)

func markRank(r rune) int {
	for i, m := range combiningMarks {
		if m == r {
			return i + 1
		}
	}
	return 0
}

// elements are the collation elements of text.
func elements(text string) []element {
	var out []element
	letter := func(c rune) element {
		if c >= 'A' && c <= 'Z' {
			return element{primaries[c], common, upper}
		}
		return element{primaries[c], common, common}
	}
	for _, r := range text {
		switch {
		case primaries[r] != 0:
			out = append(out, letter(r))
		case r == 0xa0:
			out = append(out, element{primaries[' '], common, noBreak})
		case r < 0x20 || r >= 0x7f && r < 0xa0:
			// Controls are ignored altogether.
		case latin[r].base != 0:
			a := latin[r]
			out = append(out, letter(rune(a.base)))
			for _, m := range a.marks {
				out = append(out, element{0, common + int(m), common})
			}
		case markRank(r) != 0:
			out = append(out, element{0, common + markRank(r), common})
		default:
			out = append(out, element{beyond + int(r), common, common})
		}
	}
	return out
}

// localeCompare is a.localeCompare(b) as Node has it, with ICU's root
// collation: letters before their marks before their case, level by level,
// so "e" < "é" < "f" and "ab" < "aB" < "Ab". It is exact for ASCII and for
// Latin letters whose marks decompose; any other character sorts after z by
// its code point, where ICU has an order of its own.
func localeCompare(a, b string) int {
	ea, eb := elements(a), elements(b)
	for level := 0; level < 3; level++ {
		if order := compareLevel(ea, eb, level); order != 0 {
			return order
		}
	}
	return 0
}

func compareLevel(a, b []element, level int) int {
	weights := func(es []element) []int {
		var out []int
		for _, e := range es {
			w := [3]int{e.primary, e.secondary, e.tertiary}[level]
			if w != 0 {
				out = append(out, w)
			}
		}
		return out
	}
	wa, wb := weights(a), weights(b)
	for i := 0; i < len(wa) && i < len(wb); i++ {
		if wa[i] != wb[i] {
			if wa[i] < wb[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(wa) < len(wb):
		return -1
	case len(wa) > len(wb):
		return 1
	}
	return 0
}
