package runlight

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/zone"
)

// Dates in a site's timezone, without a date library. Ranges are computed
// here as epoch milliseconds so the database only ever compares integers.

// Periods are the named periods a range can be.
var Periods = []string{"today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"}

// Range is a stretch of time in a site's timezone.
type Range struct {
	// From is inclusive.
	From int64 `json:"from"`
	// To is exclusive.
	To int64 `json:"to"`
	// FromDate and ToDate are the first and last local dates covered, YYYY-MM-DD, both inclusive.
	FromDate string `json:"fromDate"`
	ToDate   string `json:"toDate"`
	// Interval is hour, day, week, or month.
	Interval string `json:"interval"`
}

// Bucket is one chart bucket, from Start (inclusive) to End (exclusive).
type Bucket struct {
	Start int64 `json:"start"`
	End   int64 `json:"end"`
}

// IsTimezone reports whether a value is a timezone Intl.DateTimeFormat takes.
func IsTimezone(value string) bool { return zone.Valid(value) }

func location(timezone string) *time.Location {
	loc, err := zone.Load(timezone)
	if err != nil {
		return time.UTC
	}
	return loc
}

// parts is the wall clock in a zone at an instant: year, month, day, hour,
// minute, second, as Intl.DateTimeFormat's parts give them.
func parts(ts int64, timezone string) [6]int64 {
	t := time.UnixMilli(ts).In(location(timezone))
	return [6]int64{int64(t.Year()), int64(t.Month()), int64(t.Day()), int64(t.Hour()), int64(t.Minute()), int64(t.Second())}
}

// offset is the milliseconds the zone is ahead of UTC at an instant.
func offset(ts int64, timezone string) int64 {
	p := parts(ts, timezone)
	return js.DateUTC(p[0], p[1]-1, p[2], p[3], p[4], p[5], 0) - (ts - ts%1000)
}

func dateFields(date string) (int64, int64, int64) {
	var f [3]int64
	for i, s := range strings.SplitN(date, "-", 3) {
		n, _ := strconv.ParseInt(s, 10, 64)
		f[i] = n
	}
	return f[0], f[1], f[2]
}

// StartOf is the instant a local date (and hour) begins in a zone.
func StartOf(date, timezone string, hour int64) int64 {
	y, m, d := dateFields(date)
	guess := js.DateUTC(y, m-1, d, hour, 0, 0, 0)
	first := guess - offset(guess, timezone)
	at := guess - offset(first, timezone)
	// Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
	// happens, and the sum above lands before it; the day then begins when the clocks land, at most a
	// few quarter hours on.
	for i := 0; i < 8; i++ {
		p := parts(at, timezone)
		if js.DateUTC(p[0], p[1]-1, p[2], p[3], 0, 0, 0) >= guess {
			break
		}
		at += 15 * 60_000
	}
	return at
}

// LocalDate is the local date of an instant, YYYY-MM-DD.
func LocalDate(ts int64, timezone string) string {
	p := parts(ts, timezone)
	return fmt.Sprintf("%04d-%02d-%02d", p[0], p[1], p[2])
}

// AddDays is the date a number of days on.
func AddDays(date string, days int64) string {
	y, m, d := dateFields(date)
	return js.ISOString(js.DateUTC(y, m-1, d+days, 0, 0, 0, 0))[:10]
}

// AddMonths is the first of the month a number of months on.
func AddMonths(date string, months int64) string {
	y, m, _ := dateFields(date)
	return js.ISOString(js.DateUTC(y, m-1+months, 1, 0, 0, 0, 0))[:10]
}

var datePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

// IsDate reports whether a value is a real date, YYYY-MM-DD, from 1900 to
// 9998, so the day after any date is a date too.
func IsDate(value string) bool {
	if !datePattern.MatchString(value) || value < "1900" || value >= "9999" {
		return false
	}
	// A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
	y, m, d := dateFields(value)
	if m < 1 || m > 12 || d < 1 || d > 31 {
		return false
	}
	return js.ISOString(js.DateUTC(y, m-1, d, 0, 0, 0, 0))[:10] == value
}

func daysBetween(from, to string) int64 {
	fy, fm, fd := dateFields(from)
	ty, tm, td := dateFields(to)
	return int64(js.Round(float64(js.DateUTC(ty, tm-1, td, 0, 0, 0, 0)-js.DateUTC(fy, fm-1, fd, 0, 0, 0, 0)) / 86_400_000))
}

func defaultInterval(fromDate, toDate string) string {
	days := daysBetween(fromDate, toDate)
	if days < 1 {
		return "hour"
	}
	if days <= 92 {
		return "day"
	}
	return "month"
}

// RangeInput is what a request says about a range. A nil field was not given.
type RangeInput struct {
	Period   *string
	From     *string
	To       *string
	Interval *string
}

func optional(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// ResolveRange reads a named period or custom dates as a range in the
// site's timezone. firstDate is the earliest local date with data, used by
// "all" ("" for none). Nil when the input is not a range.
func ResolveRange(input RangeInput, timezone string, now int64, firstDate string) *Range {
	today := LocalDate(now, timezone)
	var fromDate, toDate string
	from, to := optional(input.From), optional(input.To)
	if from != "" || to != "" {
		if from == "" || to == "" || !IsDate(from) || !IsDate(to) || from > to {
			return nil
		}
		fromDate, toDate = from, to
	} else {
		period := "30d"
		if input.Period != nil {
			period = *input.Period
		}
		switch period {
		case "today":
			fromDate, toDate = today, today
		case "yesterday":
			fromDate = AddDays(today, -1)
			toDate = fromDate
		case "7d":
			fromDate, toDate = AddDays(today, -6), today
		case "30d":
			fromDate, toDate = AddDays(today, -29), today
		case "90d":
			fromDate, toDate = AddDays(today, -89), today
		case "month":
			fromDate, toDate = today[:8]+"01", today
		case "last_month":
			fromDate, toDate = AddMonths(today, -1), AddDays(today[:8]+"01", -1)
		case "year":
			fromDate, toDate = today[:4]+"-01-01", today
		case "12mo":
			fromDate, toDate = AddMonths(today, -11), today
		case "all":
			fromDate, toDate = today, today
			if firstDate != "" && firstDate < today {
				fromDate = firstDate
			}
		default:
			return nil
		}
	}
	interval := optional(input.Interval)
	if interval != "hour" && interval != "day" && interval != "week" && interval != "month" {
		interval = defaultInterval(fromDate, toDate)
	}
	return &Range{From: StartOf(fromDate, timezone, 0), To: StartOf(AddDays(toDate, 1), timezone, 0), FromDate: fromDate, ToDate: toDate, Interval: interval}
}

func addYears(date string, years int64) string {
	y, m, d := dateFields(date)
	shifted := js.DateUTC(y+years, m-1, d, 0, 0, 0, 0)
	// Feb 29 in a year without one becomes Feb 28, not Mar 1.
	sy, sm, _ := js.CivilFromDays(js.FloorDiv(shifted, 86_400_000))
	if sm != m {
		shifted = js.DateUTC(sy, sm-1, 0, 0, 0, 0, 0)
	}
	return js.ISOString(shifted)[:10]
}

// CompareRange is the range a period is compared with: the same number of
// days just before it (previous), the same dates a year earlier (year), or
// custom dates. Nil for off or bad custom dates.
func CompareRange(r Range, mode, timezone, customFrom, customTo string) *Range {
	var fromDate, toDate string
	switch mode {
	case "off":
		return nil
	case "year":
		fromDate, toDate = addYears(r.FromDate, -1), addYears(r.ToDate, -1)
	case "custom":
		if customFrom == "" || customTo == "" || !IsDate(customFrom) || !IsDate(customTo) || customFrom > customTo {
			return nil
		}
		fromDate, toDate = customFrom, customTo
	default:
		days := daysBetween(r.FromDate, r.ToDate) + 1
		fromDate, toDate = AddDays(r.FromDate, -days), AddDays(r.FromDate, -1)
	}
	return &Range{From: StartOf(fromDate, timezone, 0), To: StartOf(AddDays(toDate, 1), timezone, 0), FromDate: fromDate, ToDate: toDate, Interval: r.Interval}
}

const (
	maxBuckets = 1000
	// maxHours is a month of hours. Longer hourly ranges are cut off rather than refused.
	maxHours = 744
)

func weekday(date string) int64 {
	y, m, d := dateFields(date)
	days := js.FloorDiv(js.DateUTC(y, m-1, d, 0, 0, 0, 0), 86_400_000)
	// 1970-01-01 was a Thursday, day 4 of getUTCDay's week.
	return js.Mod(days+4, 7)
}

// Buckets are the chart buckets covering a range, each starting on a local boundary.
func Buckets(r Range, timezone string) []Bucket {
	starts := []int64{}
	if r.Interval == "hour" {
		for t := r.From; t < r.To && len(starts) < maxHours; t += 3_600_000 {
			starts = append(starts, t)
		}
	} else {
		date := r.FromDate
		if r.Interval == "week" {
			date = AddDays(date, -((weekday(date) + 6) % 7))
		} else if r.Interval == "month" {
			date = date[:8] + "01"
		}
		for date <= r.ToDate && len(starts) < maxBuckets {
			starts = append(starts, StartOf(date, timezone, 0))
			switch r.Interval {
			case "day":
				date = AddDays(date, 1)
			case "week":
				date = AddDays(date, 7)
			default:
				date = AddMonths(date, 1)
			}
		}
	}
	out := make([]Bucket, len(starts))
	for i, start := range starts {
		end := r.To
		if i+1 < len(starts) {
			end = starts[i+1]
		}
		out[i] = Bucket{Start: max(start, r.From), End: min(end, r.To)}
	}
	return out
}

// LocalWeekdayHour is the local weekday (Monday is 0) and hour of an instant.
func LocalWeekdayHour(ts int64, timezone string) (int64, int64) {
	p := parts(ts, timezone)
	return (weekday(fmt.Sprintf("%04d-%02d-%02d", p[0], p[1], p[2])) + 6) % 7, p[3]
}
