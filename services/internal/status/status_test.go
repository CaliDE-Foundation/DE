package status

import "testing"

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
