package extensions

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
)

const manifest = `{"id":"cpu-monitor","name":"CPU Monitor","description":"d","version":"1","exec":"run.sh",
 "settings":[{"key":"interval","kind":"number","default":2,"min":1,"max":60,"title":"Every"},
             {"key":"style","kind":"string","default":"text","choices":["text","icon"],"title":"Style"}]}`

func writeExt(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "extension.json"), []byte(manifest), 0o644)
	os.WriteFile(filepath.Join(dir, "run.sh"), []byte("#!/bin/sh\n"), 0o644)
}

func TestInstallFolderAndZip(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "src", "cpu")
	writeExt(t, src)
	dest := filepath.Join(base, "installed")
	id, err := Install(src, dest)
	if err != nil || id != "cpu-monitor" {
		t.Fatalf("Install folder: %q %v", id, err)
	}
	if info, err := os.Stat(filepath.Join(dest, "cpu-monitor", "run.sh")); err != nil || info.Mode()&0o100 == 0 {
		t.Fatalf("program should be installed and executable: %v", err)
	}

	// A zip with everything inside a folder, plus an entry escaping it.
	zpath := filepath.Join(base, "ext.zip")
	f, _ := os.Create(zpath)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("cpu-monitor-1.0/extension.json")
	w.Write([]byte(manifest))
	w, _ = zw.Create("cpu-monitor-1.0/run.sh")
	w.Write([]byte("#!/bin/sh\n"))
	zw.Close()
	f.Close()
	if id, err := Install(zpath, dest); err != nil || id != "cpu-monitor" {
		t.Fatalf("Install zip: %q %v", id, err)
	}

	bad := filepath.Join(base, "bad.zip")
	f, _ = os.Create(bad)
	zw = zip.NewWriter(f)
	w, _ = zw.Create("../evil")
	w.Write([]byte("x"))
	zw.Close()
	f.Close()
	if _, err := Install(bad, dest); err == nil {
		t.Fatal("an archive escaping its folder must be refused")
	}

	exts := Scan([]string{dest}, 1)
	if len(exts) != 1 || exts[0].ID != "cpu-monitor" || exts[0].System {
		t.Fatalf("Scan: %+v", exts)
	}
}

func TestSettingsAndState(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "cpu")
	writeExt(t, dir)
	ext, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ext.Check("interval", 100.0); err == nil {
		t.Error("out-of-range number accepted")
	}
	if _, err := ext.Check("style", "huge"); err == nil {
		t.Error("unknown choice accepted")
	}
	v := ext.Values(map[string]any{"interval": 5.0, "style": "nope"})
	if v["interval"] != 5.0 || v["style"] != "text" {
		t.Errorf("Values: %v", v)
	}

	path := filepath.Join(t.TempDir(), "extensions.json")
	st := ReadState(path)
	st.SetEnabled("cpu-monitor", true)
	st.SetEnabled("other", true)
	st.SetEnabled("other", false)
	if err := st.Save(path); err != nil {
		t.Fatal(err)
	}
	if got := ReadState(path); !got.IsEnabled("cpu-monitor") || got.IsEnabled("other") {
		t.Errorf("state round trip: %+v", got)
	}
}

func TestManifestValidation(t *testing.T) {
	for _, m := range []Manifest{
		{ID: "Bad ID", Name: "x", Exec: "a"},
		{ID: "ok", Name: "", Exec: "a"},
		{ID: "ok", Name: "x", Exec: "../escape"},
		{ID: "ok", Name: "x", Exec: "a", Settings: []Setting{{Key: "k", Kind: "color"}}},
	} {
		if m.Validate() == nil {
			t.Errorf("should reject %+v", m)
		}
	}
}
