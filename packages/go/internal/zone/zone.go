// Package zone loads time zones as Intl.DateTimeFormat names them, from Go's
// own zone database (the system's, $ZONEINFO, or the one an app embeds by
// importing time/tzdata): without regard to case, so "america/new_york" is
// New York, and a fixed offset ("+05:30", "-0800", "+05") is a zone too.
package zone

import (
	"archive/zip"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"runlight.sh/go/internal/js"
)

var (
	mu     sync.Mutex
	cache  = map[string]*time.Location{}
	failed = map[string]bool{}
	names  map[string]string // lowercased name to the database's spelling, built on first need
)

// ErrUnknown is a name that is not a time zone.
var ErrUnknown = errors.New("unknown time zone")

// Load is the zone an IANA name (or a fixed offset) names, matched without
// regard to case.
func Load(name string) (*time.Location, error) {
	mu.Lock()
	defer mu.Unlock()
	if loc, ok := cache[name]; ok {
		return loc, nil
	}
	if failed[name] {
		return nil, ErrUnknown
	}
	loc, err := load(name)
	if len(cache)+len(failed) >= 2000 {
		cache = map[string]*time.Location{}
		failed = map[string]bool{}
	}
	if err != nil {
		failed[name] = true
		return nil, err
	}
	cache[name] = loc
	return loc, nil
}

// Valid reports whether Intl.DateTimeFormat takes the name as a time zone.
func Valid(name string) bool {
	_, err := Load(name)
	return err == nil
}

func load(name string) (*time.Location, error) {
	// "Local" is Go's name for the process zone, not an IANA zone, and "" is no zone.
	if name == "" || strings.EqualFold(name, "local") || strings.ContainsAny(name, "\x00\\") || strings.HasPrefix(name, "/") || strings.Contains(name, "..") {
		return nil, ErrUnknown
	}
	if loc, ok := fixedOffset(name); ok {
		return loc, nil
	}
	if strings.EqualFold(name, "utc") {
		return time.UTC, nil
	}
	if names == nil {
		names = index()
	}
	key := js.ToLower(name)
	canonical, ok := names[key]
	if legacy, isLegacy := icuOnly[key]; isLegacy {
		canonical, ok = legacy, true
	}
	if !ok {
		if len(names) > 0 {
			return nil, ErrUnknown
		}
		canonical = name
	}
	loc, err := time.LoadLocation(canonical)
	if err != nil {
		return nil, ErrUnknown
	}
	return loc, nil
}

// fixedOffset reads "+HH", "+HHMM" or "+HH:MM" (or "-"), as Intl reads an
// offset time zone.
func fixedOffset(name string) (*time.Location, bool) {
	// ICU reads a minus sign (U+2212) as a hyphen.
	name = strings.Replace(name, "−", "-", 1)
	if len(name) < 3 || (name[0] != '+' && name[0] != '-') {
		return nil, false
	}
	rest := name[1:]
	var hh, mm string
	switch len(rest) {
	case 2:
		hh, mm = rest, "00"
	case 4:
		hh, mm = rest[:2], rest[2:]
	case 5:
		if rest[2] != ':' {
			return nil, false
		}
		hh, mm = rest[:2], rest[3:]
	default:
		return nil, false
	}
	h, err1 := strconv.Atoi(hh)
	m, err2 := strconv.Atoi(mm)
	if err1 != nil || err2 != nil || h > 23 || m > 59 || strings.ContainsAny(hh+mm, "+-") {
		return nil, false
	}
	sec := (h*60 + m) * 60
	if name[0] == '-' {
		sec = -sec
	}
	return time.FixedZone(name, sec), true
}

// icuOnly are zone names ICU takes that the time zone database no longer
// has, or never had: Java's three-letter ids and the System V zones, each
// with the zone ICU reads it as. It also holds the old names the database
// made links in 2024b (WET is Europe/Lisbon), which some systems, Debian and
// Ubuntu among them, still build as zones of their own with other history:
// ICU reads them as the links, as the PHP, Python, and Ruby ports do.
var icuOnly = map[string]string{
	"cet": "Europe/Brussels", "eet": "Europe/Athens", "est": "America/Panama", "hst": "Pacific/Honolulu",
	"met": "Europe/Brussels", "mst": "America/Phoenix", "wet": "Europe/Lisbon",
	"act": "Australia/Darwin", "aet": "Australia/Sydney", "agt": "America/Argentina/Buenos_Aires", "art": "Africa/Cairo",
	"ast": "America/Anchorage", "bet": "America/Sao_Paulo", "bst": "Asia/Dhaka", "cat": "Africa/Maputo",
	"cnt": "America/St_Johns", "cst": "America/Chicago", "ctt": "Asia/Shanghai", "eat": "Africa/Nairobi",
	"ect": "Europe/Paris", "iet": "America/Indiana/Indianapolis", "ist": "Asia/Kolkata", "jst": "Asia/Tokyo",
	"mit": "Pacific/Apia", "net": "Asia/Yerevan", "nst": "Pacific/Auckland", "plt": "Asia/Karachi",
	"pnt": "America/Phoenix", "prt": "America/Puerto_Rico", "pst": "America/Los_Angeles", "sst": "Pacific/Guadalcanal",
	"vst":          "Asia/Ho_Chi_Minh",
	"systemv/ast4": "Etc/GMT+4", "systemv/ast4adt": "America/Halifax", "systemv/est5": "Etc/GMT+5",
	"systemv/est5edt": "America/New_York", "systemv/cst6": "Etc/GMT+6", "systemv/cst6cdt": "America/Chicago",
	"systemv/mst7": "Etc/GMT+7", "systemv/mst7mdt": "America/Denver", "systemv/pst8": "Etc/GMT+8",
	"systemv/pst8pdt": "America/Los_Angeles", "systemv/yst9": "Etc/GMT+9", "systemv/yst9ydt": "America/Anchorage",
	"systemv/hst10": "Etc/GMT+10", "canada/east-saskatchewan": "America/Regina", "us/pacific-new": "America/Los_Angeles",
}

// notZones are files in a zone database that are not zones Intl knows.
var notZones = map[string]bool{"factory": true, "localtime": true, "posixrules": true, "leapseconds": true, "tzdata.zi": true, "zone.tab": true, "zone1970.tab": true, "iso3166.tab": true, "+version": true, "leap-seconds.list": true, "security": true, "sourcedir": true, "zonenow.tab": true}

// index lists every zone name the database has, lowercased, from the
// places Go's time package reads zones from.
func index() map[string]string {
	out := map[string]string{}
	add := func(name string) {
		lower := js.ToLower(name)
		if name == "" || strings.Contains(name, ".") || notZones[lower] || strings.HasPrefix(lower, "posix/") || strings.HasPrefix(lower, "right/") {
			return
		}
		if _, ok := out[lower]; !ok {
			out[lower] = name
		}
	}
	walkDir := func(root string) {
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if rel, err := filepath.Rel(root, path); err == nil {
				add(filepath.ToSlash(rel))
			}
			return nil
		})
	}
	walkZip := func(file string) {
		r, err := zip.OpenReader(file)
		if err != nil {
			return
		}
		defer r.Close()
		for _, f := range r.File {
			if !strings.HasSuffix(f.Name, "/") {
				add(f.Name)
			}
		}
	}
	if env := os.Getenv("ZONEINFO"); env != "" {
		if info, err := os.Stat(env); err == nil && info.IsDir() {
			walkDir(env)
		} else {
			walkZip(env)
		}
	}
	for _, dir := range []string{"/usr/share/zoneinfo", "/usr/share/lib/zoneinfo", "/usr/lib/locale/TZ", "/etc/zoneinfo"} {
		walkDir(dir)
	}
	// The same file time.LoadLocation falls back to.
	//lint:ignore SA1019 time.LoadLocation itself reads runtime.GOROOT's zoneinfo.zip
	walkZip(filepath.Join(runtime.GOROOT(), "lib", "time", "zoneinfo.zip"))
	return out
}
