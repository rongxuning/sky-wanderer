// Command api is the entrypoint the Vercel Go preset can see.
//
// Discovery runs before buildCommand and only accepts main.go,
// cmd/api/main.go, or cmd/server/main.go at the project root. This file
// is that entry. The HTTP server stays in codes/core; local development
// is still `go run ./codes/core/cmd/api`.
package main

import (
	"fmt"
	"os"

	"skywanderer/codes/core/gateway"
)

func main() {
	if err := gateway.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}
