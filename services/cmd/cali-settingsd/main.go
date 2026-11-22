// cali-settingsd owns Cali's configuration and will serve it on D-Bus
// as org.calide.Settings.
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
)

func main() {
	p, err := config.File()
	if err != nil {
		log.Fatalf("cali-settingsd: %v", err)
	}
	log.Printf("cali-settingsd %s: config at %s", config.Version, p)

	// TODO: expose org.calide.Settings on the session bus.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Print("cali-settingsd: shutting down")
}
