package runlight

// Stand-ins for the modules still being ported, so the rest builds and runs.
// Each goes when its module lands.

import (
	"errors"

	"runlight.sh/go/internal/whatwg"
)

var errPending = errors.New("not ported yet")

func (rt *Routes) assistantAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	return nil, nil
}

func (rt *Routes) mcp(c *call, u *whatwg.URL) (*Response, error) { return nil, errPending }
