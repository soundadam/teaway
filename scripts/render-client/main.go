package main

import (
	"fmt"
	"os"

	"github.com/soundadam/teaway/internal/tui"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: render-client menu|shutdown")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "menu":
		fmt.Print(tui.PreviewMenu())
	case "shutdown":
		fmt.Print(tui.PreviewShutdown())
	default:
		fmt.Fprintln(os.Stderr, "usage: render-client menu|shutdown")
		os.Exit(2)
	}
}
