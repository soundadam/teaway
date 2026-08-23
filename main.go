package main

import (
	"os"

	"github.com/soundadam/teaway/cmd"
	"github.com/soundadam/teaway/internal/privilege"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == privilege.InternalCommand {
		os.Exit(privilege.RunHelper(os.Args[2:]))
	}
	os.Exit(cmd.Execute())
}
