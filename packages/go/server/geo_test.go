package server

import (
	"context"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestAFailedDownloadLeavesNothingAndIsTriedAgain(t *testing.T) {
	dir := t.TempDir()
	asked := []string{}
	lines := []string{}
	geo, err := NewGeo(dir, "city", func(line string) { lines = append(lines, line) }, func(_ context.Context, url string) (int, io.ReadCloser, error) {
		asked = append(asked, url)
		return 404, io.NopCloser(strings.NewReader("nope")), nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := geo.Refresh(context.Background(), time.Date(2026, 10, 1, 3, 0, 0, 0, time.UTC).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	// Early in a month, last month's release stands in.
	want := []string{"https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz", "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz"}
	if !reflect.DeepEqual(asked, want) {
		t.Fatal(asked)
	}
	if found, _ := geo.Lookup("8.8.8.8"); found != nil {
		t.Fatal(found)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatal(entries)
	}
	if err := geo.Refresh(context.Background(), time.Date(2026, 10, 1, 4, 0, 0, 0, time.UTC).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if len(asked) != 4 {
		t.Fatal("not tried again on the next check")
	}
	// A body that is not gzip is said once and leaves no partial file.
	geo.download = func(context.Context, string) (int, io.ReadCloser, error) {
		return 200, io.NopCloser(strings.NewReader("not gzip")), nil
	}
	if err := geo.Refresh(context.Background(), time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 || len(lines) != 2 {
		t.Fatal(entries, lines)
	}
}
