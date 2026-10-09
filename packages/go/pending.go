package runlight

// Stand-ins for the modules still being ported, so the rest builds and runs.
// Each goes when its module lands.

import (
	"context"
	"errors"

	"runlight.sh/go/internal/whatwg"
)

var errPending = errors.New("not ported yet")

// AccountsWeb is the sign-in accounts' pages and APIs.
type AccountsWeb struct{}

// FirstAccount says who may make the first account.
type FirstAccount struct {
	Mode  string
	Token string
}

// AccountsWebOptions configure the accounts.
type AccountsWebOptions struct {
	Runlight     *Runlight
	Secret       string
	Base         string
	Now          func() int64
	FirstAccount FirstAccount
	Home         func(context.Context) string
	Forgot       string
}

// NewAccountsWeb makes the accounts.
func NewAccountsWeb(options AccountsWebOptions) *AccountsWeb { return &AccountsWeb{} }

// Access is what a request may do.
func (a *AccountsWeb) Access(ctx context.Context, request *Request) Access { return AccessNone }

// Handle answers the accounts' own paths, nil for others.
func (a *AccountsWeb) Handle(ctx context.Context, request *Request, path string) (*Response, error) {
	return nil, nil
}

// AccountOf is the account a request comes from.
func (a *AccountsWeb) AccountOf(ctx context.Context, request *Request) string { return "" }

// TokenMade notes who made a token.
func (a *AccountsWeb) TokenMade(ctx context.Context, token TokenRow, by string) bool { return true }

type oauthHost struct {
	r         *Runlight
	base      string
	isOwner   func(ctx context.Context, request *Request) bool
	isReader  func(ctx context.Context, request *Request) bool
	signIn    string
	accountOf func(ctx context.Context, request *Request) string
	tokenMade func(ctx context.Context, token TokenRow, by string) bool
}

func (o *oauthHost) respond(c *call, path string, u *whatwg.URL) (*Response, error) { return nil, nil }

// ConnectError is why connecting another install failed.
type ConnectError struct{ CodedError }

func (*ConnectError) isRangeError() {}

// StartConnect begins connecting another install.
func StartConnect(ctx context.Context, r *Runlight, url any, back, site string) (string, error) {
	return "", errPending
}

// FinishConnect ends connecting another install.
func FinishConnect(ctx context.Context, r *Runlight, q *whatwg.SearchParams) (string, error) {
	return "", errPending
}

// ImportStep is one step of a link import.
func ImportStep(ctx context.Context, r *Runlight, site, source string, credentials map[string]string, cursor *string, done float64) (any, error) {
	return nil, errPending
}

func isImportError(err error) bool { return false }

// UmamiWebsites lists an Umami account's websites.
func UmamiWebsites(ctx context.Context, r *Runlight, credentials map[string]string) (any, error) {
	return nil, errPending
}

// ImportUmamiVisits is one step of an Umami visit import.
func ImportUmamiVisits(ctx context.Context, r *Runlight, site string, credentials map[string]string, website string, cursor *string) (any, error) {
	return nil, errPending
}

// ImportCsvVisits imports a batch of visits from a CSV file.
func ImportCsvVisits(ctx context.Context, r *Runlight, site string, rows any) (any, error) {
	return nil, errPending
}

// SiteIcon is a site's icon.
type SiteIcon struct {
	Body []byte
	Type string
}

// FetchIcon is a site's icon, nil when it has none.
func FetchIcon(ctx context.Context, fetcher Fetcher, origin string, now int64) *SiteIcon { return nil }

// Period is one report period.
type Period struct {
	Key   string
	DueAt int64
}

// LastPeriod is the last full period of a frequency.
func LastPeriod(frequency string, now int64, timezone string) Period { return Period{} }

// DeliverReport builds and sends one report.
func (r *Runlight) DeliverReport(ctx context.Context, report ReportRow, site SiteRow, period *Period) error {
	return errPending
}

// SendReports sends every report that is due.
func (r *Runlight) SendReports(ctx context.Context) (ReportsCount, error) { return ReportsCount{}, nil }

func (rt *Routes) assistantAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	return nil, nil
}

func (rt *Routes) mcp(c *call, u *whatwg.URL) (*Response, error) { return nil, errPending }
