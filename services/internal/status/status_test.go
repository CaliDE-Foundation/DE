package status

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNetworkState(t *testing.T) {
	cases := []struct {
		state uint32
		kind  string
		want  uint32
	}{
		{70, "802-3-ethernet", NetWired},
		{70, "802-11-wireless", NetWifi},
		{60, "802-11-wireless", NetWifi},
		{40, "", NetConnecting},
		{20, "", NetOffline},
		{10, "", NetOffline},
		{0, "", NetUnknown},
	}
	for _, c := range cases {
		if got := NetworkState(c.state, c.kind); got != c.want {
			t.Errorf("NetworkState(%d, %q) = %d, want %d", c.state, c.kind, got, c.want)
		}
	}
}

func TestParseWpctlVolume(t *testing.T) {
	v, m, err := ParseWpctlVolume("Volume: 0.45\n")
	if err != nil || v != 0.45 || m {
		t.Errorf("plain: %v %v %v", v, m, err)
	}
	v, m, err = ParseWpctlVolume("Volume: 0.30 [MUTED]\n")
	if err != nil || v != 0.30 || !m {
		t.Errorf("muted: %v %v %v", v, m, err)
	}
	if _, _, err := ParseWpctlVolume("Translate ID error: '@DEFAULT_AUDIO_SINK@' is not a valid ID"); err == nil {
		t.Error("error output accepted")
	}
}

func TestBrightnessStep(t *testing.T) {
	if got := BrightnessStep(500, 1000, 0.1); got != 600 {
		t.Errorf("up: %d", got)
	}
	if got := BrightnessStep(20, 1000, -0.1); got != 10 {
		t.Errorf("should stop at 1%%, got %d", got)
	}
	if got := BrightnessStep(990, 1000, 0.1); got != 1000 {
		t.Errorf("should stop at max, got %d", got)
	}
	if got := BrightnessStep(5, 0, 0.1); got != 5 {
		t.Errorf("no backlight: %d", got)
	}
}

func TestMiscHelpers(t *testing.T) {
	if Clamp(1.4) != 1 || Clamp(-0.2) != 0 || Clamp(0.5) != 0.5 {
		t.Error("Clamp")
	}
	if !BatteryCharging(1) || !BatteryCharging(4) || BatteryCharging(2) {
		t.Error("BatteryCharging")
	}
	if u := Unknown(); u.Volume != -1 || u.Battery != -1 || u.Brightness != -1 {
		t.Error("Unknown should mark levels as unavailable")
	}
}

func TestSortNetworks(t *testing.T) {
	got := SortNetworks([]WifiNetwork{
		{SSID: "B", Strength: 40},
		{SSID: "", Strength: 99},
		{SSID: "A", Strength: 30, Active: true},
		{SSID: "B", Strength: 70},
		{SSID: "C", Strength: 90},
	})
	want := []string{"A", "C", "B"}
	if len(got) != len(want) {
		t.Fatalf("got %d networks, want %d", len(got), len(want))
	}
	for i, n := range got {
		if n.SSID != want[i] {
			t.Errorf("position %d: %s, want %s", i, n.SSID, want[i])
		}
	}
	if got[2].Strength != 70 {
		t.Errorf("duplicate SSID should keep the strongest, got %d", got[2].Strength)
	}
}

func TestSSIDAndIcons(t *testing.T) {
	if SSID([]byte("Caf\xc3\xa9")) != "Café" || SSID([]byte{0xff}) != "?" {
		t.Error("SSID decoding")
	}
	if SignalIcon(90) != "network-wireless-signal-excellent-symbolic" || SignalIcon(10) != "network-wireless-signal-weak-symbolic" {
		t.Error("SignalIcon")
	}
	st, nets, devs := Fake()
	if !st.WifiAvailable || len(nets) == 0 || !nets[0].Active || len(devs) == 0 {
		t.Error("Fake data should describe a connected laptop")
	}
}

func TestPickPlayer(t *testing.T) {
	ps := []PlayerState{{"a", "Stopped"}, {"b", "Paused"}, {"c", "Playing"}}
	if got := PickPlayer(ps); got != "c" {
		t.Errorf("playing first: %s", got)
	}
	if got := PickPlayer(ps[:2]); got != "b" {
		t.Errorf("then paused: %s", got)
	}
	if got := PickPlayer(nil); got != "" {
		t.Errorf("none: %s", got)
	}
}

func TestArtLocationAndDescription(t *testing.T) {
	if p, r := ArtLocation("file:///home/me/My%20Music/cover.jpg"); p != "/home/me/My Music/cover.jpg" || r != "" {
		t.Errorf("file url: %q %q", p, r)
	}
	if p, r := ArtLocation("https://i.scdn.co/image/abc"); p != "" || r != "https://i.scdn.co/image/abc" {
		t.Errorf("web url: %q %q", p, r)
	}
	if p, r := ArtLocation("data:image/png;base64,xyz"); p != "" || r != "" {
		t.Errorf("unsupported: %q %q", p, r)
	}
	out := "id 52, type PipeWire:Interface:Node\n    alsa.card = \"2\"\n  * node.description = \"Arctis Nova Pro Wireless\"\n  * node.name = \"alsa_output.usb\"\n"
	if d := NodeDescription(out); d != "Arctis Nova Pro Wireless" {
		t.Errorf("description: %q", d)
	}
}

func TestPickPreferred(t *testing.T) {
	players := []PlayerState{{Name: "a", Status: "Paused"}, {Name: "b", Status: "Playing"}}
	if got := PickPreferred(players, "a"); got != "a" {
		t.Errorf("chosen player should win, got %q", got)
	}
	if got := PickPreferred(players, "gone"); got != "b" {
		t.Errorf("without the chosen one, the playing one, got %q", got)
	}
}

func TestAppIcon(t *testing.T) {
	dir := t.TempDir()
	apps := filepath.Join(dir, "applications")
	icons := filepath.Join(dir, "icons", "hicolor", "scalable", "apps")
	if err := os.MkdirAll(apps, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(icons, 0o755); err != nil {
		t.Fatal(err)
	}
	desktop := "[Desktop Entry]\nName=Spotify\nIcon=com.spotify.Client\n[Desktop Action x]\nIcon=other\n"
	if err := os.WriteFile(filepath.Join(apps, "com.spotify.Client.desktop"), []byte(desktop), 0o644); err != nil {
		t.Fatal(err)
	}
	svg := filepath.Join(icons, "com.spotify.Client.svg")
	if err := os.WriteFile(svg, []byte("<svg/>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := AppIcon("spotify", []string{dir}); got != svg {
		t.Errorf("AppIcon(spotify) = %q, want %q", got, svg)
	}
	if got := AppIcon("firefox", []string{dir}); got != "firefox" {
		t.Errorf("unknown app should fall back to its name, got %q", got)
	}
	if got := AppIcon("", []string{dir}); got != "" {
		t.Errorf("no entry should give no icon, got %q", got)
	}
}
