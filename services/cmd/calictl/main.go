// calictl is the command-line tool for the Cali desktop.
package main

import (
	"fmt"
	"os"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
)

const usage = `usage: calictl <command>

commands:
  version       print the version
  config-path   print the config file location
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println("calictl", config.Version)
	case "config-path":
		p, err := config.File()
		if err != nil {
			fmt.Fprintln(os.Stderr, "calictl:", err)
			os.Exit(1)
		}
		fmt.Println(p)
	default:
		fmt.Fprintf(os.Stderr, "calictl: unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
}
