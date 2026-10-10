package runlight

import "runlight.sh/go/internal/assets"

// Version is the release, the same for every Runlight package.
const Version = "0.1.0"

// APIVersion is bumped when the HTTP API changes shape, so the dashboard
// and the hub can tell.
const APIVersion = 1

// Icon is the Runlight mark for the dashboard's tab: an R in a rounded lamp
// housing, one corner lit.
var Icon = assets.Build.Icon
