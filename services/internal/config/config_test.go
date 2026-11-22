package config

import (
	"path/filepath"
	"testing"
)

func TestFileUsesXDGConfigHome(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/tmp/xdg")
	got, err := File()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join("/tmp/xdg", "cali", "cali.toml")
	if got != want {
		t.Fatalf("File() = %q, want %q", got, want)
	}
}

func TestFileFallsBackToHome(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("HOME", "/home/someone")
	got, err := File()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join("/home/someone", ".config", "cali", "cali.toml")
	if got != want {
		t.Fatalf("File() = %q, want %q", got, want)
	}
}
