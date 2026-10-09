// Package importers brings links and their click history in from other
// shorteners and from Umami, over their HTTP APIs. Writing what comes back
// into Runlight (importStep, writeLink, and the Umami visit import) belongs
// to the root package, which calls this one.
package importers

import (
	"context"
	"math"

	"runlight.sh/go/internal/js"
)

// ForeignLink is a link as another shortener describes it, before it becomes
// a Runlight link. A field the service sent as something other than text is
// read as String() reads it, and a missing or null one as "".
type ForeignLink struct {
	// SourceID is the other service's id, so a re-run recognises the link.
	SourceID string `json:"sourceId"`
	Slug     string `json:"slug"`
	// Domain is the short link's domain there. Shortener-owned domains (bit.ly, dub.sh) are not kept.
	Domain    string `json:"domain"`
	Name      string `json:"name"`
	URL       string `json:"url"`
	CreatedAt int64  `json:"createdAt"`
}

// ForeignClick is one click with whatever the other service knows about it:
// "ts" (milliseconds, NaN when the service's time does not parse), and
// whichever of "visit" (groups clicks into one visit), "referrer", "path" and
// "query" (path and query of the short URL as clicked, for campaign tags),
// "country", "region", "city", "browser", "os", "device", "screen", and
// "language" it knows. The fields are the service's own values, as TS keeps
// them: a field it does not know is left out, one it sent as null is null,
// and the keys are in the order the importer wrote them.
type ForeignClick struct{ *js.Object }

// clickOf is a click with these key and value pairs, leaving out the ones
// that hold js.Undefined, as JSON.stringify would.
func clickOf(pairs ...any) ForeignClick {
	o := js.NewObject()
	for i := 0; i+1 < len(pairs); i += 2 {
		if _, u := pairs[i+1].(js.Undefined); !u {
			o.Set(pairs[i].(string), pairs[i+1])
		}
	}
	return ForeignClick{o}
}

// JSValue writes the click as its fields.
func (c ForeignClick) JSValue() any { return c.Object }

// TS is the click's time in milliseconds, NaN when it has none.
func (c ForeignClick) TS() float64 {
	if n, ok := c.Value("ts").(float64); ok {
		return n
	}
	return math.NaN()
}

// Text is a field's value when it is text, and whether it is.
func (c ForeignClick) Text(name string) (string, bool) {
	s, ok := c.Value(name).(string)
	return s, ok
}

// DailyClicks is clicks per day, for services that only keep counts.
type DailyClicks struct {
	// Day is YYYY-MM-DD, UTC.
	Day    string  `json:"day"`
	Clicks float64 `json:"clicks"`
}

// ForeignItem is one link a step found: its history as clicks or daily
// counts (nil when the service gave none), or Known when Runlight has it.
type ForeignItem struct {
	Link   ForeignLink
	Clicks []ForeignClick
	Daily  []DailyClicks
	Known  bool
}

// JSValue writes the item as TS's object: clicks and daily left out while
// nil, known only when true.
func (i ForeignItem) JSValue() any {
	o := js.NewObject("link", i.Link)
	if i.Clicks != nil {
		o.Set("clicks", i.Clicks)
	}
	if i.Daily != nil {
		o.Set("daily", i.Daily)
	}
	if i.Known {
		o.Set("known", true)
	}
	return o
}

// FailedLink is a link an import step could not write.
type FailedLink struct {
	Slug   string     `json:"slug"`
	Reason string     `json:"reason"`
	Code   *string    `json:"code,omitempty"`
	Params *js.Object `json:"params,omitempty"`
}

// ImportStep is what one step of an import did. The page keeps calling until
// Cursor is nil.
type ImportStep struct {
	Cursor *string `json:"cursor"`
	// Done and Total are links handled so far and in all, for the progress
	// bar. Total is nil when the service does not say.
	Done    int64        `json:"done"`
	Total   *float64     `json:"total"`
	Links   int64        `json:"links"`
	Clicks  int64        `json:"clicks"`
	Skipped int64        `json:"skipped"`
	Failed  []FailedLink `json:"failed"`
}

// Credentials are what the person typed for the service: a key, a token, an
// address, or a username and password.
type Credentials = map[string]string

// Known reports whether a link from this source is already in Runlight, so
// its history need not be fetched again: imported from this source before,
// or the same slug to the same destination brought in some other way.
type Known func(ctx context.Context, sourceID, slug, url string) (bool, error)

// StepInput is what an importer's step works from. Credentials come with
// every step and are never stored.
type StepInput struct {
	Credentials Credentials
	// Cursor is where the last step stopped, nil (or "") to start.
	Cursor *string
	Known  Known
	// Now is Runlight's clock, in milliseconds: the date of a link the
	// source gives none for, and where Umami's history ends.
	Now int64
}

// StepResult is one step's links and where the next step starts.
type StepResult struct {
	Cursor *string       `json:"cursor"`
	Total  *float64      `json:"total"`
	Links  []ForeignItem `json:"links"`
}

// Importer is one shortener. Step does a bounded slice of work (a few links)
// and hands back a cursor, so imports run in small requests that fit any
// host's time limit and can show progress. Every request goes through client.
type Importer interface {
	Step(ctx context.Context, client *Client, in StepInput) (*StepResult, error)
}

// Importers are the sources Runlight imports links from, by name.
var Importers = map[string]Importer{"umami": Umami, "dub": Dub, "bitly": Bitly, "shortio": Shortio, "rebrandly": Rebrandly}

// Sources are the names of Importers, in TS's order.
var Sources = []string{"umami", "dub", "bitly", "shortio", "rebrandly"}

// ImportError is why an import stopped, as a code the dashboard says in its
// own words.
type ImportError struct {
	Message string
	Code    string
	// Params are the code's values, keys in TS's order; an empty object when there are none.
	Params *js.Object
}

func (e *ImportError) Error() string { return e.Message }

// NewImportError is an ImportError with params given as key and value pairs.
func NewImportError(message, code string, params ...string) *ImportError {
	o := js.NewObject()
	for i := 0; i+1 < len(params); i += 2 {
		o.Set(params[i], params[i+1])
	}
	return &ImportError{Message: message, Code: code, Params: o}
}

// cursorState is the cursor's JSON, or nil when there is none.
func cursorState(cursor *string) (any, bool, error) {
	if cursor == nil || *cursor == "" {
		return nil, false, nil
	}
	v, err := js.Parse(*cursor)
	return v, true, err
}

func strPtr(s string) *string { return &s }
