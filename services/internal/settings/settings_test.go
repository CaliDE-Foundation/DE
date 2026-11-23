package settings

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestDefaultsAreValid(t *testing.T) {
	for _, k := range Keys() {
		if _, err := Validate(k, Schema[k].Default); err != nil {
			t.Errorf("default for %s is invalid: %v", k, err)
		}
	}
}

func TestValidate(t *testing.T) {
	if _, err := Validate("accent-color", "chartreuse"); err == nil {
		t.Error("unknown accent color accepted")
	}
	if _, err := Validate("animation-speed", 9.0); err == nil {
		t.Error("out-of-range speed accepted")
	}
	if v, err := Validate("animation-speed", int32(2)); err != nil || v != 2.0 {
		t.Errorf("int speed: got %v, %v", v, err)
	}
	if _, err := Validate("hot-corner", "yes"); err == nil {
		t.Error("string accepted for a bool")
	}
	if _, err := Validate("nope", true); err == nil {
		t.Error("unknown key accepted")
	}
}

func TestParse(t *testing.T) {
	if v, _ := Parse("hot-corner", "false"); v != false {
		t.Errorf("bool: %v", v)
	}
	if v, _ := Parse("animation-speed", "0.5"); v != 0.5 {
		t.Errorf("number: %v", v)
	}
	if v, _ := Parse("dock-favorites", "a.desktop, b.desktop,"); !reflect.DeepEqual(v, []string{"a.desktop", "b.desktop"}) {
		t.Errorf("list: %v", v)
	}
	if _, err := Parse("accent-color", "nope"); err == nil {
		t.Error("bad choice accepted")
	}
}

func TestStoreRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cali", "cali.toml")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := st.Get("accent-color"); v != "coral" {
		t.Errorf("default accent: %v", v)
	}
	changed, err := st.Set("accent-color", "teal")
	if err != nil || !changed {
		t.Fatalf("set: %v %v", changed, err)
	}
	if changed, _ := st.Set("accent-color", "teal"); changed {
		t.Error("setting the same value reported a change")
	}
	st.Set("dock-favorites", []string{`we"ird.desktop`, "b.desktop"})
	st.Set("animation-speed", 0.75)
	st.Set("hot-corner", false)

	again, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"accent-color": "teal", "animation-speed": 0.75, "hot-corner": false,
		"dock-favorites": []string{`we"ird.desktop`, "b.desktop"}}
	for k, v := range want {
		if got, _ := again.Get(k); !reflect.DeepEqual(got, v) {
			t.Errorf("%s after reload = %#v, want %#v", k, got, v)
		}
	}

	if err := again.Reset("accent-color"); err != nil {
		t.Fatal(err)
	}
	if v, _ := again.Get("accent-color"); v != "coral" {
		t.Errorf("after reset: %v", v)
	}
}

func TestBadLinesAreSkipped(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cali.toml")
	os.WriteFile(path, []byte("# comment\nhot-corner = maybe\naccent-color = \"pink\"\nnonsense\nunknown = 1\n"), 0o644)
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := st.Get("accent-color"); v != "pink" {
		t.Errorf("accent: %v", v)
	}
	if v, _ := st.Get("hot-corner"); v != true {
		t.Errorf("invalid line should fall back to default, got %v", v)
	}
}

func TestSchemaMetadata(t *testing.T) {
	for _, k := range Keys() {
		st := Schema[k]
		if st.Title == "" || st.Page == "" || st.Group == "" {
			t.Errorf("%s is missing its title, page or group", k)
		}
		if st.Choices != nil && st.Labels != nil && len(st.Choices) != len(st.Labels) {
			t.Errorf("%s has %d choices but %d labels", k, len(st.Choices), len(st.Labels))
		}
		if st.Kind == Number && st.Step <= 0 {
			t.Errorf("%s needs a step", k)
		}
	}
	if len(Schema) < 45 {
		t.Errorf("expected the big list, got %d settings", len(Schema))
	}
	if !strings.Contains(SchemaJSON(), `"key":"tiling-mode"`) {
		t.Error("SchemaJSON should list tiling-mode")
	}
}

func TestGSettingsValue(t *testing.T) {
	if s, k, v, ok := GSettingsValue("focus-mode", "sloppy"); !ok || s != "org.gnome.desktop.wm.preferences" || k != "focus-mode" || v != "'sloppy'" {
		t.Errorf("focus-mode: %s %s %s %v", s, k, v, ok)
	}
	if _, _, v, ok := GSettingsValue("workspace-count", 6.0); !ok || v != "6" {
		t.Errorf("workspace-count: %s %v", v, ok)
	}
	if _, _, v, ok := GSettingsValue("edge-tiling", false); !ok || v != "false" {
		t.Errorf("edge-tiling: %s %v", v, ok)
	}
	if _, _, _, ok := GSettingsValue("accent-color", "blue"); ok {
		t.Error("accent-color is Cali-only")
	}
}
