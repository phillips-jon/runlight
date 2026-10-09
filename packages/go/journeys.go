package runlight

import (
	"math"
	"sort"
	"strings"
)

// Journeys: the paths visits take through a site, page by page. Each
// visit's pages are read in order, a page seen twice in a row (a refresh)
// counts once, and the path is cut to a number of steps, from a start page
// and to an end page when those are chosen. The answer lines the paths up
// in columns, one per step, with the flows between them, as Umami's
// journeys do.

// JourneyOptions say which journeys to read.
type JourneyOptions struct {
	Steps float64
	Start string
	End   string
	// Through, when set, keeps only paths that show this page at this step (0-based), to follow one page.
	Through *JourneyThrough
}

// JourneyThrough is a page at a step.
type JourneyThrough struct {
	Step  float64
	Value string
}

// JourneyItem is a page seen at a step and how many visits saw it there.
type JourneyItem struct {
	Value  string `json:"value"`
	Visits int    `json:"visits"`
}

// JourneyColumn is one step.
type JourneyColumn struct {
	// Items are the pages seen at this step, most visits first, with the rest as "" (other pages).
	Items []JourneyItem `json:"items"`
	// Visits reached this step.
	Visits int `json:"visits"`
	// Left went no further than this step.
	Left int `json:"left"`
}

// JourneyLink is visits moving from a page at one step to a page at the next. "" is any other page.
type JourneyLink struct {
	Step   int    `json:"step"`
	From   string `json:"from"`
	To     string `json:"to"`
	Visits int    `json:"visits"`
}

// JourneyPath is one whole path and how many visits took it.
type JourneyPath struct {
	Pages  []string `json:"pages"`
	Visits int      `json:"visits"`
}

// JourneysResult is the journeys of a range.
type JourneysResult struct {
	Visits  int             `json:"visits"`
	Columns []JourneyColumn `json:"columns"`
	Links   []JourneyLink   `json:"links"`
	// Paths are the commonest whole paths.
	Paths []JourneyPath `json:"paths"`
}

// PagesPerVisit is how many pages of a visit to read: enough to find a
// start page and still have the steps after it.
const PagesPerVisit = 40

const journeyTop = 8

func indexOf(pages []string, page string) int {
	for i, p := range pages {
		if p == page {
			return i
		}
	}
	return -1
}

// Journeys lines up visits' pages in columns, one per step.
func Journeys(rows []JourneyRow, options JourneyOptions) JourneysResult {
	steps := 5
	if f := math.Floor(options.Steps); !math.IsNaN(f) && f != 0 && !math.IsInf(f, 0) {
		steps = int(math.Min(math.Max(f, 2), 8))
	} else if math.IsInf(f, 1) {
		steps = 8
	} else if math.IsInf(f, -1) {
		steps = 2
	}
	// Group each visit's pages, dropping refreshes.
	visits := map[string][]string{}
	order := []string{}
	for _, row := range rows {
		pages, ok := visits[row.Session]
		if !ok {
			order = append(order, row.Session)
		}
		if len(pages) == 0 || pages[len(pages)-1] != row.Path {
			pages = append(pages, row.Path)
		}
		visits[row.Session] = pages
	}
	sequences := [][]string{}
	// Visits that went on past the last step shown, so they never count as having gone no further.
	cut := map[int]bool{}
	for _, session := range order {
		pages := visits[session]
		if options.Start != "" {
			at := indexOf(pages, options.Start)
			if at < 0 {
				continue
			}
			pages = pages[at:]
		}
		if options.End != "" {
			at := indexOf(pages, options.End)
			if at < 0 {
				continue
			}
			pages = pages[:at+1]
		}
		more := len(pages) > steps
		if more {
			pages = pages[:steps]
		}
		if options.Through != nil {
			// pages[step], undefined for a step that is not a whole number in range.
			step := options.Through.Step
			if step != math.Trunc(step) || step < 0 || step >= float64(len(pages)) || pages[int(step)] != options.Through.Value {
				continue
			}
		}
		if more {
			cut[len(sequences)] = true
		}
		sequences = append(sequences, pages)
	}

	columns := []JourneyColumn{}
	kept := []map[string]bool{}
	for i := 0; i < steps; i++ {
		counts := map[string]int{}
		values := []string{}
		reached, left := 0, 0
		for k, s := range sequences {
			if len(s) <= i {
				continue
			}
			reached++
			if len(s) == i+1 && !cut[k] {
				left++
			}
			if _, ok := counts[s[i]]; !ok {
				values = append(values, s[i])
			}
			counts[s[i]]++
		}
		sort.SliceStable(values, func(a, b int) bool {
			if counts[values[a]] != counts[values[b]] {
				return counts[values[a]] > counts[values[b]]
			}
			return compare16(values[a], values[b]) < 0
		})
		top := values[:min(journeyTop, len(values))]
		rest := 0
		for _, v := range values[min(journeyTop, len(values)):] {
			rest += counts[v]
		}
		set := map[string]bool{}
		for _, v := range top {
			set[v] = true
		}
		kept = append(kept, set)
		if reached == 0 {
			break
		}
		items := []JourneyItem{}
		for _, v := range top {
			items = append(items, JourneyItem{v, counts[v]})
		}
		if rest > 0 {
			items = append(items, JourneyItem{"", rest})
		}
		columns = append(columns, JourneyColumn{Items: items, Visits: reached, Left: left})
	}

	links := map[string]*JourneyLink{}
	linkOrder := []string{}
	for _, s := range sequences {
		for i := 0; i+1 < len(s) && i+1 < len(columns); i++ {
			from, to := "", ""
			if kept[i][s[i]] {
				from = s[i]
			}
			if kept[i+1][s[i+1]] {
				to = s[i+1]
			}
			key := string(rune(i)) + "\x00" + from + "\x00" + to
			link, ok := links[key]
			if !ok {
				link = &JourneyLink{Step: i, From: from, To: to}
				links[key] = link
				linkOrder = append(linkOrder, key)
			}
			link.Visits++
		}
	}
	paths := map[string]*JourneyPath{}
	pathOrder := []string{}
	for _, s := range sequences {
		key := strings.Join(s, "\x00")
		path, ok := paths[key]
		if !ok {
			path = &JourneyPath{Pages: s}
			paths[key] = path
			pathOrder = append(pathOrder, key)
		}
		path.Visits++
	}

	out := JourneysResult{Visits: len(sequences), Columns: columns, Links: []JourneyLink{}, Paths: []JourneyPath{}}
	for _, key := range linkOrder {
		out.Links = append(out.Links, *links[key])
	}
	// Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
	sort.SliceStable(out.Links, func(a, b int) bool {
		x, y := out.Links[a], out.Links[b]
		if x.Step != y.Step {
			return x.Step < y.Step
		}
		if x.Visits != y.Visits {
			return x.Visits > y.Visits
		}
		if c := compare16(x.From, y.From); c != 0 {
			return c < 0
		}
		return compare16(x.To, y.To) < 0
	})
	sort.SliceStable(pathOrder, func(a, b int) bool {
		x, y := paths[pathOrder[a]], paths[pathOrder[b]]
		if x.Visits != y.Visits {
			return x.Visits > y.Visits
		}
		return compare16(pathOrder[a], pathOrder[b]) < 0
	})
	for _, key := range pathOrder[:min(20, len(pathOrder))] {
		out.Paths = append(out.Paths, *paths[key])
	}
	return out
}
