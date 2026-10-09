package runlight

// Stand-ins for the modules still being ported, so the rest builds and runs.
// Each goes when its module lands.

import (
	"context"
	"errors"

	"runlight.sh/go/internal/whatwg"
)

var errPending = errors.New("not ported yet")

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

func (rt *Routes) assistantAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	return nil, nil
}

func (rt *Routes) mcp(c *call, u *whatwg.URL) (*Response, error) { return nil, errPending }
