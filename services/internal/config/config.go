// Package config locates Cali's configuration files.
package config

import (
	"os"
	"path/filepath"
)

// Version of the Cali services.
const Version = "0.1.0"

// Dir returns $XDG_CONFIG_HOME/cali (default ~/.config/cali).
func Dir() (string, error) {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "cali"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "cali"), nil
}

// File returns the path of the main config file, cali.toml.
func File() (string, error) {
	d, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "cali.toml"), nil
}
