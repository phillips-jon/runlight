package server

// Location for servers with no platform headers (Cloudflare, Vercel, and
// Netlify send their own, and those always win). Uses DB-IP's free databases
// (CC BY 4.0, https://db-ip.com), downloaded on first start and refreshed
// each month, or any MMDB file the owner points at.

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	runlight "runlight.sh/go"
	"runlight.sh/go/mmdb"
)

// Download fetches a URL's body as a stream, with its status.
type Download func(ctx context.Context, url string) (status int, body io.ReadCloser, err error)

func httpDownload(ctx context.Context, url string) (int, io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return 0, nil, err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	return res.StatusCode, res.Body, nil
}

// month is "2026-10", the month DB-IP names each release after.
func month(ts int64) string { return time.UnixMilli(ts).UTC().Format("2006-01") }

// Geo keeps a DB-IP database current in a folder and answers lookups from
// it. Lookups return nothing until the first download finishes, so startup
// never waits.
type Geo struct {
	dir      string
	mode     string
	log      func(line string)
	download Download

	mu       sync.Mutex
	reader   *mmdb.Reader
	loaded   string
	fetching chan struct{}
}

// NewGeo keeps DB-IP's "city" or "country" database in dir. log gets a line
// when new data is ready or a download fails; nil prints nothing. download
// nil fetches over HTTPS.
func NewGeo(dir, mode string, log func(line string), download Download) (*Geo, error) {
	if mode != "city" && mode != "country" {
		return nil, fmt.Errorf("runlight: no DB-IP database called %q", mode)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	if log == nil {
		log = func(string) {}
	}
	if download == nil {
		download = httpDownload
	}
	return &Geo{dir: dir, mode: mode, log: log, download: download}, nil
}

// Lookup answers from the newest data, or nil before any has loaded.
func (g *Geo) Lookup(ip string) (*runlight.Location, error) {
	g.mu.Lock()
	reader := g.reader
	g.mu.Unlock()
	if reader == nil {
		return nil, nil
	}
	return runlight.LookupFrom(reader)(ip)
}

func (g *Geo) prefix() string { return "dbip-" + g.mode + "-lite-" }

func (g *Geo) file(release string) string {
	return filepath.Join(g.dir, g.prefix()+release+".mmdb")
}

func exists(file string) bool {
	_, err := os.Stat(file)
	return err == nil
}

func (g *Geo) open(file string) error {
	reader, err := mmdb.Open(file)
	if err != nil {
		return err
	}
	base := filepath.Base(file)
	g.mu.Lock()
	g.reader, g.loaded = reader, base[len(base)-12:len(base)-5]
	g.mu.Unlock()
	return nil
}

// Refresh opens the newest file on disk, then fetches this month's if it is
// missing. Safe to call often; a download under way is shared.
func (g *Geo) Refresh(ctx context.Context, now int64) error {
	current := month(now)
	g.mu.Lock()
	loaded := g.loaded
	g.mu.Unlock()
	if loaded == current {
		return nil
	}
	entries, err := os.ReadDir(g.dir)
	if err != nil {
		return err
	}
	names := []string{}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), g.prefix()) && strings.HasSuffix(e.Name(), ".mmdb") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	if len(names) > 0 {
		newest := names[len(names)-1]
		if loaded == "" || newest != filepath.Base(g.file(loaded)) {
			if err := g.open(filepath.Join(g.dir, newest)); err != nil {
				return err
			}
		}
	}
	if exists(g.file(current)) {
		return nil
	}
	g.mu.Lock()
	wait := g.fetching
	if wait == nil {
		wait = make(chan struct{})
		g.fetching = wait
		g.mu.Unlock()
		g.fetch(ctx, current, now)
		g.mu.Lock()
		g.fetching = nil
		close(wait)
	}
	g.mu.Unlock()
	<-wait
	return nil
}

func (g *Geo) fetch(ctx context.Context, release string, now int64) {
	// A new month's file appears a day or so after the month starts; until then, last month's is current.
	t := time.UnixMilli(now).UTC()
	last := month(time.Date(t.Year(), t.Month()-1, 15, 0, 0, 0, 0, time.UTC).UnixMilli())
	for _, name := range []string{release, last} {
		if exists(g.file(name)) {
			g.mu.Lock()
			loaded := g.loaded
			g.mu.Unlock()
			if loaded != name {
				if err := g.open(g.file(name)); err != nil {
					g.log("Runlight: could not open location data: " + err.Error())
				}
			}
			return
		}
		url := "https://download.db-ip.com/free/" + g.prefix() + name + ".mmdb.gz"
		ok, err := g.save(ctx, url, name)
		if err != nil {
			g.log("Runlight: could not download location data from " + url + ": " + err.Error())
			os.Remove(g.file(name) + ".partial")
			continue
		}
		if !ok {
			continue
		}
		// Older releases go once the new one opens.
		entries, _ := os.ReadDir(g.dir)
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), g.prefix()) && e.Name() != filepath.Base(g.file(name)) {
				os.Remove(filepath.Join(g.dir, e.Name()))
			}
		}
		g.log("Runlight: location data from DB-IP (" + name + ") is ready.")
		return
	}
}

// save downloads one release, unzipped beside its final name and moved
// there once it opens. False when the release is not there.
func (g *Geo) save(ctx context.Context, url, name string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	status, body, err := g.download(ctx, url)
	if err != nil {
		return false, err
	}
	defer body.Close()
	if status < 200 || status > 299 {
		return false, nil
	}
	unzipped, err := gzip.NewReader(body)
	if err != nil {
		return false, err
	}
	partial := g.file(name) + ".partial"
	out, err := os.Create(partial)
	if err != nil {
		return false, err
	}
	_, err = io.Copy(out, unzipped)
	if closeErr := out.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return false, err
	}
	if _, err := mmdb.Open(partial); err != nil {
		return false, errors.New("the file is not an MMDB database: " + err.Error())
	}
	if err := os.Rename(partial, g.file(name)); err != nil {
		return false, err
	}
	return true, g.open(g.file(name))
}
