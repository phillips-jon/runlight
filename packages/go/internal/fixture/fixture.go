// Package fixture finds the language-neutral fixtures the tests replay:
// conformance/ at the repository's root, and the PHP package's
// tests/fixtures, which every port reads rather than copies.
package fixture

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"runlight.sh/go/internal/js"
)

// Root is the repository's root: the first directory up from this file
// that holds conformance/.
func Root() string {
	_, file, _, _ := runtime.Caller(0)
	dir := filepath.Dir(file)
	for {
		if st, err := os.Stat(filepath.Join(dir, "conformance", "http.json")); err == nil && !st.IsDir() {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// Path is a file under the repository's root.
func Path(parts ...string) string {
	return filepath.Join(append([]string{Root()}, parts...)...)
}

// Read is a fixture's text, failing the test when it is missing.
func Read(t testing.TB, parts ...string) string {
	t.Helper()
	b, err := os.ReadFile(Path(parts...))
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return string(b)
}

// JSON is a fixture parsed as JSON.parse reads it.
func JSON(t testing.TB, parts ...string) any {
	t.Helper()
	v, err := js.Parse(Read(t, parts...))
	if err != nil {
		t.Fatalf("fixture %v: %v", parts, err)
	}
	return v
}

// PHP is one of packages/php/tests/fixtures, parsed.
func PHP(t testing.TB, name string) any {
	t.Helper()
	return JSON(t, "packages", "php", "tests", "fixtures", name)
}
