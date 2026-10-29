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
