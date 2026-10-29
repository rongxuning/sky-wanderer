// Package sport is the core-business extension point for workouts, tracks,
// and routes. Account login stays in the user package. The gateway mounts
// whatever Routes returns; this stage returns none.
package sport

import "net/http"

type Route struct {
	Method  string
	Pattern string
	Handler http.Handler
}

// Routes will carry movement and track endpoints. Core calls this when it
// builds the HTTP gateway so those routes stay next to the product, not the
// account package.
func Routes() []Route { return nil }
