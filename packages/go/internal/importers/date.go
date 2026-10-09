package importers

import (
	"errors"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
)

var (
	isoDate = regexp.MustCompile(`^([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:[Tt](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?([Zz]|[+-]\d{2}:\d{2})?)?$`)
	// The forms V8's fallback parser takes that services send: a date and
	// time with a space or T, and an offset without a colon or a zone name.
	looseDate = regexp.MustCompile(`^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[Tt ]+(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?\s*(?:([Zz]|UTC|GMT|UT)?([+-]\d{2}:?\d{2})?)?$`)
	mailDates = []string{
		"Mon, 2 Jan 2006 15:04:05 MST", "Mon, 2 Jan 2006 15:04:05 -0700", "2 Jan 2006 15:04:05 MST", "2 Jan 2006 15:04:05 -0700",
		"Mon Jan 2 2006 15:04:05 MST-0700", "Mon Jan 2 2006 15:04:05 GMT-0700", "Monday, 02-Jan-06 15:04:05 MST", "Mon Jan 2 15:04:05 2006",
	}
)

const maxTime = 8.64e15

// ParseDate is Date.parse(value): milliseconds, or NaN for anything that is
// not a date. The ISO forms are read as JavaScript reads them (a date alone
// is UTC, a date and time without an offset is local time). V8's fallback
// parser takes far more; this takes the forms the services here send
// ("2026-01-01T00:00:00+0000", "2026-01-01 10:00:00", and the mail style
// "Thu, 01 Jan 2026 00:00:00 GMT"). A value that is not text is NaN.
func ParseDate(value any) float64 {
	s, ok := value.(string)
	if !ok {
		return math.NaN()
	}
	s = js.Trim(s)
	if m := isoDate.FindStringSubmatch(s); m != nil {
		return isoMs(m)
	}
	if m := looseDate.FindStringSubmatch(s); m != nil {
		return looseMs(m)
	}
	for _, layout := range mailDates {
		if t, err := time.Parse(layout, s); err == nil {
			return float64(t.UnixMilli())
		}
	}
	return math.NaN()
}

func num(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}

func millis(fraction string) int64 {
	if fraction == "" {
		return 0
	}
	return num((fraction + "00")[:3])
}

func daysIn(year, month int64) int64 {
	switch month {
	case 2:
		if (year%4 == 0 && year%100 != 0) || year%400 == 0 {
			return 29
		}
		return 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

func clip(ms int64) float64 {
	if math.Abs(float64(ms)) > maxTime {
		return math.NaN()
	}
	return float64(ms)
}

func isoMs(m []string) float64 {
	year := num(m[1])
	month, day := int64(1), int64(1)
	if m[2] != "" {
		month = num(m[2])
	}
	if m[3] != "" {
		day = num(m[3])
	}
	timed := m[4] != ""
	hour, minute, second := num(m[4]), num(m[5]), num(m[6])
	ms := millis(m[7])
	if m[1] == "-000000" || month < 1 || month > 12 || day < 1 || day > daysIn(year, month) || hour > 24 || minute > 59 || second > 59 || (hour == 24 && (minute != 0 || second != 0 || ms != 0)) {
		return math.NaN()
	}
	utc := js.DateUTC(year, month-1, day, hour, minute, second, ms)
	zone := m[8]
	switch {
	case strings.EqualFold(zone, "Z") || (!timed && zone == ""):
		return clip(utc)
	case zone != "":
		return clip(utc - offsetMs(zone))
	}
	return clip(local(year, month, day, hour, minute, second, ms))
}

func looseMs(m []string) float64 {
	year, month, day := num(m[1]), num(m[2]), num(m[3])
	hour, minute, second := num(m[4]), num(m[5]), num(m[6])
	ms := millis(m[7])
	if month < 1 || month > 12 || day < 1 || day > daysIn(year, month) || hour > 24 || minute > 59 || second > 59 || (hour == 24 && (minute != 0 || second != 0 || ms != 0)) {
		return math.NaN()
	}
	utc := js.DateUTC(year, month-1, day, hour, minute, second, ms)
	if m[9] != "" {
		return clip(utc - offsetMs(m[9]))
	}
	if m[8] != "" {
		return clip(utc)
	}
	return clip(local(year, month, day, hour, minute, second, ms))
}

// offsetMs is "+02:00" or "+0200" in milliseconds.
func offsetMs(zone string) int64 {
	digits := strings.ReplaceAll(zone[1:], ":", "")
	n := (num(digits[:2])*60 + num(digits[2:])) * 60_000
	if zone[0] == '-' {
		return -n
	}
	return n
}

// local is a wall time in the process's zone, as JavaScript reads one without an offset.
func local(year, month, day, hour, minute, second, ms int64) int64 {
	return time.Date(int(year), time.Month(month), int(day), int(hour), int(minute), int(second), int(ms)*int(time.Millisecond), time.Local).UnixMilli()
}

// errInvalidTime is the RangeError toISOString throws for a time that is not one.
var errInvalidTime = errors.New("Invalid time value")

// isoString is new Date(ms).toISOString().
func isoString(ms float64) (string, error) {
	if math.IsNaN(ms) || math.IsInf(ms, 0) || math.Abs(ms) > maxTime {
		return "", errInvalidTime
	}
	// TimeClip truncates toward zero.
	return js.ISOString(int64(ms)), nil
}
