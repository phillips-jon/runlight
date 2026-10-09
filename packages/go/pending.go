package runlight

// Stand-ins for the modules still being ported, so the rest builds and runs.
// Each goes when its module lands.

import (
	"context"
	"errors"

	"runlight.sh/go/internal/whatwg"
)

var errPending = errors.New("not ported yet")

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

func (rt *Routes) assistantAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	return nil, nil
}

func (rt *Routes) mcp(c *call, u *whatwg.URL) (*Response, error) { return nil, errPending }
