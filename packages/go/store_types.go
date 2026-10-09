package runlight

import "runlight.sh/go/internal/js"

// SiteRow is a site as the store keeps it.
type SiteRow struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Hostnames []string `json:"hostnames"`
	Timezone  string   `json:"timezone"`
}


// GoalRow is something worth counting. An event goal counts a named event;
// a page goal counts pageviews of a path or pattern (/thanks*); a click goal
// is a rule the tracker applies itself, sending an event named after the
// goal. Event and page goals are worked out when stats are read, so a new
// one counts past visits too; a click goal counts from when the tracker
// starts sending its event.
type GoalRow struct {
	ID   string `json:"id"`
	Site string `json:"site"`
	Name string `json:"name"`
	// Kind is event, page, or click.
	Kind string `json:"kind"`
	// Match is the event name, the path pattern, or for a click goal a CSS selector or URL pattern.
	Match string `json:"match"`
	// ClickBy is, for click goals, what Match is: selector or link.
	ClickBy string `json:"clickBy"`
	// ValueMode is none, fixed (the same amount each time), or prop (the amount sent in an event property).
	ValueMode string  `json:"valueMode"`
	Value     float64 `json:"value"`
	ValueProp string  `json:"valueProp"`
	Currency  string  `json:"currency"`
	CreatedAt int64   `json:"createdAt"`
}

// ReportRow is someone who gets a site's report by email. Token is the unsubscribe key.
type ReportRow struct {
	ID    string `json:"id"`
	Site  string `json:"site"`
	Email string `json:"email"`
	// Frequency is weekly or monthly.
	Frequency string `json:"frequency"`
	Lang      string `json:"lang"`
	Token     string `json:"token"`
	// Origin is where the dashboard lives, for the links in the email.
	Origin string `json:"origin"`
	// LastPeriod is the last period sent, like w:2026-09-28 or m:2026-09, so nothing goes out twice.
	LastPeriod string `json:"lastPeriod"`
	LastSentAt *int64 `json:"lastSentAt"`
	CreatedAt  int64  `json:"createdAt"`
}

// GoalTotals are a goal's conversions, converting visitors, and revenue.
type GoalTotals struct {
	Conversions int64   `json:"conversions"`
	Visitors    int64   `json:"visitors"`
	Revenue     float64 `json:"revenue"`
}

// ShareRow is a public, read-only view of one site's stats, opened by its unguessable id.
type ShareRow struct {
	ID        string `json:"id"`
	Site      string `json:"site"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"createdAt"`
}

// FunnelStep is one step of a funnel: reaching a page (with * as a wildcard), or sending an event.
type FunnelStep struct {
	// Kind is page or event.
	Kind  string `json:"kind"`
	Match string `json:"match"`
}

// FunnelRow is steps a visit is expected to take in order, such as pricing,
// then signup, then the welcome page.
type FunnelRow struct {
	ID        string       `json:"id"`
	Site      string       `json:"site"`
	Name      string       `json:"name"`
	Steps     []FunnelStep `json:"steps"`
	CreatedAt int64        `json:"createdAt"`
}

// TokenRow is an API token. Only its hash is stored; the token itself is shown once.
type TokenRow struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Site is "" for a token that reads every site; otherwise the one site it may read.
	Site string `json:"site"`
	// Scope is read, which reads stats, or manage, which for a Runlight hub also changes its one site's
	// goals, funnels, short links, link domains, email reports, and share links, along with its name,
	// timezone, and retention, and gets tickets for the element picker.
	Scope string `json:"scope"`
	Hash  string `json:"hash"`
	// Hint is the token's last four characters, so people can tell theirs apart.
	Hint       string `json:"hint"`
	CreatedAt  int64  `json:"createdAt"`
	LastUsedAt *int64 `json:"lastUsedAt"`
}

// LinkRow is a short link.
type LinkRow struct {
	ID   string `json:"id"`
	Site string `json:"site"`
	// Domain is a custom link domain, or "" for the app's own.
	Domain    string `json:"domain"`
	Slug      string `json:"slug"`
	Name      string `json:"name"`
	URL       string `json:"url"`
	CreatedAt int64  `json:"createdAt"`
	UpdatedAt int64  `json:"updatedAt"`
}

// LinkWithStats is a link with its clicks in a range.
type LinkWithStats struct {
	LinkRow
	Clicks   int64 `json:"clicks"`
	Visitors int64 `json:"visitors"`
}

// JSValue writes the link's fields, then its clicks and visitors.
func (l LinkWithStats) JSValue() any {
	o := js.ToValue(l.LinkRow).(*js.Object)
	o.Set("clicks", l.Clicks)
	o.Set("visitors", l.Visitors)
	return o
}

// SessionRow is a visit as it starts.
type SessionRow struct {
	ID             string
	Site           string
	Visitor        string
	StartedAt      int64
	Hostname       string
	ReferrerHost   string
	ReferrerPath   string
	Source         string
	Channel        string
	UtmSource      string
	UtmMedium      string
	UtmCampaign    string
	UtmTerm        string
	UtmContent     string
	Country        string
	Region         string
	City           string
	Browser        string
	BrowserVersion string
	OS             string
	OSVersion      string
	Device         string
	Screen         string
	Language       string
}

// EventRow is one recorded row: a pageview, event, engagement ping, short
// link click, or AI agent fetch.
type EventRow struct {
	Site      string
	Ts        int64
	Kind      string
	Visitor   string
	Session   string
	Pageview  string
	Path      string
	Hostname  string
	Title     string
	Name      string
	Props     *js.Object
	EngagedMs int64
	Scroll    *int
	Link      string
}

// Stats are a range's headline numbers.
type Stats struct {
	Visitors      int64   `json:"visitors"`
	Visits        int64   `json:"visits"`
	Pageviews     int64   `json:"pageviews"`
	ViewsPerVisit float64 `json:"viewsPerVisit"`
	// BounceRate is 0 to 1.
	BounceRate float64 `json:"bounceRate"`
	// VisitDuration is the mean engaged time per visit, milliseconds.
	VisitDuration int64 `json:"visitDuration"`
}

// SeriesPoint is one chart bucket's numbers.
type SeriesPoint struct {
	Start     int64 `json:"start"`
	Visitors  int64 `json:"visitors"`
	Visits    int64 `json:"visits"`
	Pageviews int64 `json:"pageviews"`
	// ViewsPerVisit, BounceRate, and VisitDuration are of the visits that started in this bucket.
	ViewsPerVisit float64 `json:"viewsPerVisit"`
	BounceRate    float64 `json:"bounceRate"`
	VisitDuration int64   `json:"visitDuration"`
}

// BreakdownRow is one value of a breakdown. A nil field is not reported for
// that dimension.
type BreakdownRow struct {
	Value      string   `json:"value"`
	Visitors   int64    `json:"visitors"`
	Visits     *int64   `json:"visits,omitempty"`
	BounceRate *float64 `json:"bounceRate,omitempty"`
	Pageviews  *int64   `json:"pageviews,omitempty"`
	Events     *int64   `json:"events,omitempty"`
	// TimeOnPage is the mean engaged time per pageview, milliseconds, for pages. A view under a second counts as none.
	TimeOnPage *int64 `json:"timeOnPage,omitempty"`
	// ScrollDepth is the mean deepest scroll, percent, for pages, over the pageviews that reported one.
	ScrollDepth *int64 `json:"scrollDepth,omitempty"`
	// VisitDuration is the mean engaged time per visit, milliseconds, for visit dimensions.
	VisitDuration *int64 `json:"visitDuration,omitempty"`
	Fetches       *int64 `json:"fetches,omitempty"`
}

// ValueCount is a value and how many visitors it had.
type ValueCount struct {
	Value    string `json:"value"`
	Visitors int64  `json:"visitors"`
}

// RecentRow is one of the latest pageviews and events: what happened, never who.
type RecentRow struct {
	Ts      int64  `json:"ts"`
	Kind    string `json:"kind"`
	Path    string `json:"path"`
	Name    string `json:"name"`
	Country string `json:"country"`
	City    string `json:"city"`
	Source  string `json:"source"`
	Device  string `json:"device"`
}

// Realtime is what is happening now.
type Realtime struct {
	Visitors  int64        `json:"visitors"`
	Pages     []ValueCount `json:"pages"`
	Sources   []ValueCount `json:"sources"`
	Countries []ValueCount `json:"countries"`
	// Minutes are pageviews per minute for the last 30 minutes, oldest first.
	Minutes []int64 `json:"minutes"`
	// Recent are the latest pageviews and events, newest first.
	Recent []RecentRow `json:"recent"`
}

// HourlyRow is the visits that started in one quarter hour since the epoch.
type HourlyRow struct {
	Quarter   int64 `json:"quarter"`
	Visits    int64 `json:"visits"`
	Visitors  int64 `json:"visitors"`
	Pageviews int64 `json:"pageviews"`
	Bounced   int64 `json:"bounced"`
}

// PageviewRef is the pageview an engagement ping or event belongs to, with
// when its visit started and was last active.
type PageviewRef struct {
	Session   string `json:"session"`
	Visitor   string `json:"visitor"`
	Path      string `json:"path"`
	Hostname  string `json:"hostname"`
	Ts        int64  `json:"ts"`
	StartedAt int64  `json:"startedAt"`
	LastAt    int64  `json:"lastAt"`
}

// OpenSession is a visitor's session still open.
type OpenSession struct {
	ID      string `json:"id"`
	Visitor string `json:"visitor"`
}

// JourneyRow is one pageview of a visit, in order.
type JourneyRow struct {
	Session string `json:"session"`
	Path    string `json:"path"`
}

// PropKey is an event property name and how many events sent it.
type PropKey struct {
	Key    string `json:"key"`
	Events int64  `json:"events"`
}

// PropValue is a value one property of an event took.
type PropValue struct {
	Value    string `json:"value"`
	Events   int64  `json:"events"`
	Visitors int64  `json:"visitors"`
}

// GoalBreakdownRow is a goal's totals for one value.
type GoalBreakdownRow struct {
	Value string `json:"value"`
	GoalTotals
}

// JSValue writes the value first, then the totals.
func (g GoalBreakdownRow) JSValue() any {
	return js.NewObject("value", g.Value, "conversions", g.Conversions, "visitors", g.Visitors, "revenue", g.Revenue)
}

// GoalSeriesPoint is a goal's conversions and revenue in one bucket.
type GoalSeriesPoint struct {
	Start       int64   `json:"start"`
	Conversions int64   `json:"conversions"`
	Revenue     float64 `json:"revenue"`
}

// LinkSeriesPoint is one link's clicks in one bucket.
type LinkSeriesPoint struct {
	Start    int64 `json:"start"`
	Clicks   int64 `json:"clicks"`
	Visitors int64 `json:"visitors"`
}

// LinkDomain is a custom domain for short links, and the site it belongs to.
type LinkDomain struct {
	Domain string `json:"domain"`
	Site   string `json:"site"`
}

// Setting is one install-wide setting.
type Setting struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func i64(n int64) *int64 { return &n }

func f64(n float64) *float64 { return &n }
