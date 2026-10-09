package assistant

import (
	"os"
	"testing"

	"runlight.sh/go/internal/js"
)

// testdata/collation.json holds pairs of strings with Node 24's
// Math.sign(a.localeCompare(b)), over ASCII, spaces, controls, and Latin
// letters with marks, precomposed and not.
func TestCollationMatchesNode(t *testing.T) {
	text, err := os.ReadFile("testdata/collation.json")
	if err != nil {
		t.Fatal(err)
	}
	pairs, err := js.Parse(string(text))
	if err != nil {
		t.Fatal(err)
	}
	wrong := 0
	for _, p := range js.Arr(pairs) {
		a, b, want := js.Str(js.Dig(p, 0)), js.Str(js.Dig(p, 1)), int(js.Num(js.Dig(p, 2)))
		if got := localeCompare(a, b); got != want {
			wrong++
			if wrong <= 20 {
				t.Errorf("localeCompare(%q, %q) = %d, want %d", a, b, got, want)
			}
		}
	}
	if wrong > 0 {
		t.Errorf("%d of %d pairs differ", wrong, len(js.Arr(pairs)))
	}
}
