// Package status turns what the system reports (NetworkManager, UPower,
// BlueZ, PipeWire's wpctl, the backlight) into the shell's status values.
package status

import (
	"fmt"
	"strconv"
	"strings"
)

// Network states sent to the shell.
const (
	NetUnknown    uint32 = 0
	NetOffline    uint32 = 1
	NetWired      uint32 = 2
	NetWifi       uint32 = 3
	NetConnecting uint32 = 4
)

// Status is everything the top bar and quick settings show.
// Volume, Battery and Brightness are 0-1, or -1 when not available.
type Status struct {
	Network            uint32
	WifiAvailable      bool
	WifiEnabled        bool
	BluetoothAvailable bool
	BluetoothEnabled   bool
	Volume             float64
	Muted              bool
	Battery            float64
	Charging           bool
	Brightness         float64
}

// Unknown is the status before anything has been read.
func Unknown() Status {
	return Status{Volume: -1, Battery: -1, Brightness: -1}
}

// Map converts a status to D-Bus friendly values.
func (s Status) Map() map[string]any {
	return map[string]any{
		"network":             s.Network,
		"wifi-available":      s.WifiAvailable,
		"wifi-enabled":        s.WifiEnabled,
		"bluetooth-available": s.BluetoothAvailable,
		"bluetooth-enabled":   s.BluetoothEnabled,
		"volume":              s.Volume,
		"muted":               s.Muted,
		"battery":             s.Battery,
		"charging":            s.Charging,
		"brightness":          s.Brightness,
	}
}

// NetworkState maps NetworkManager's global State and primary connection
// type to a shell network state.
func NetworkState(nmState uint32, primaryType string) uint32 {
	switch {
	case nmState >= 50: // NM_STATE_CONNECTED_LOCAL and up
		if strings.Contains(primaryType, "wireless") {
			return NetWifi
		}
		return NetWired
	case nmState == 40: // CONNECTING
		return NetConnecting
	case nmState >= 10: // ASLEEP, DISCONNECTED, DISCONNECTING
		return NetOffline
	default:
		return NetUnknown
	}
}

// ParseWpctlVolume reads `wpctl get-volume` output such as
// "Volume: 0.45" or "Volume: 0.45 [MUTED]".
func ParseWpctlVolume(out string) (volume float64, muted bool, err error) {
	fields := strings.Fields(out)
	if len(fields) < 2 || fields[0] != "Volume:" {
		return -1, false, fmt.Errorf("unexpected wpctl output %q", strings.TrimSpace(out))
	}
	volume, err = strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return -1, false, err
	}
	muted = strings.Contains(out, "[MUTED]")
	return volume, muted, nil
}

// Clamp keeps a level in 0-1.
func Clamp(v float64) float64 {
	switch {
	case v < 0:
		return 0
	case v > 1:
		return 1
	}
	return v
}

// BatteryCharging reports whether UPower's device State means charging
// (1 = charging, 4 = fully charged while plugged in).
func BatteryCharging(upowerState uint32) bool {
	return upowerState == 1 || upowerState == 4
}

// BrightnessStep moves a backlight level by delta (0-1 scale) and returns
// the new raw value, never going fully dark.
func BrightnessStep(current, max int, delta float64) int {
	if max <= 0 {
		return current
	}
	minimum := max / 100
	if minimum < 1 {
		minimum = 1
	}
	next := int(float64(current) + delta*float64(max) + 0.5*sign(delta))
	if next < minimum {
		next = minimum
	}
	if next > max {
		next = max
	}
	return next
}

func sign(f float64) float64 {
	if f < 0 {
		return -1
	}
	return 1
}

// WifiNetwork is one network in the Wi-Fi picker.
type WifiNetwork struct {
	SSID     string
	Strength uint8 // 0-100
	Active   bool
	Secured  bool
}

// BluetoothDevice is one paired or nearby device.
type BluetoothDevice struct {
	Name      string
	Path      string
	Paired    bool
	Connected bool
}

// SSID turns NetworkManager's raw SSID bytes into text ("" if hidden).
func SSID(raw []byte) string {
	return strings.ToValidUTF8(string(raw), "?")
}

// SortNetworks merges duplicate SSIDs (several access points, keeping the
// strongest), drops hidden ones, and puts the active network first, then
// the rest by strength.
func SortNetworks(in []WifiNetwork) []WifiNetwork {
	best := map[string]WifiNetwork{}
	var order []string
	for _, n := range in {
		if n.SSID == "" {
			continue
		}
		old, seen := best[n.SSID]
		if !seen {
			order = append(order, n.SSID)
		}
		if !seen || n.Strength > old.Strength {
			n.Active = n.Active || old.Active
			best[n.SSID] = n
		} else if n.Active {
			old.Active = true
			best[n.SSID] = old
		}
	}
	out := make([]WifiNetwork, 0, len(best))
	for _, ssid := range order {
		out = append(out, best[ssid])
	}
	sortStable(out, func(a, b WifiNetwork) bool {
		if a.Active != b.Active {
			return a.Active
		}
		return a.Strength > b.Strength
	})
	return out
}

// SignalIcon is the symbolic icon for a signal strength.
func SignalIcon(strength uint8) string {
	switch {
	case strength >= 75:
		return "network-wireless-signal-excellent-symbolic"
	case strength >= 50:
		return "network-wireless-signal-good-symbolic"
	case strength >= 25:
		return "network-wireless-signal-ok-symbolic"
	default:
		return "network-wireless-signal-weak-symbolic"
	}
}

func sortStable[T any](s []T, less func(a, b T) bool) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && less(s[j], s[j-1]); j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// Fake returns made-up networks and devices, for testing the shell
// without hardware (CALI_STATUS_FAKE=1).
func Fake() (Status, []WifiNetwork, []BluetoothDevice) {
	st := Status{Network: NetWifi, WifiAvailable: true, WifiEnabled: true,
		BluetoothAvailable: true, BluetoothEnabled: true,
		Volume: 0.55, Battery: 0.72, Charging: false, Brightness: 0.8}
	nets := SortNetworks([]WifiNetwork{
		{SSID: "Cali Home", Strength: 82, Active: true, Secured: true},
		{SSID: "Coffee Shop", Strength: 61},
		{SSID: "Neighbors 5G", Strength: 38, Secured: true},
		{SSID: "Library", Strength: 24},
	})
	devs := []BluetoothDevice{
		{Name: "Headphones", Path: "/fake/dev_1", Paired: true, Connected: true},
		{Name: "Keyboard", Path: "/fake/dev_2", Paired: true},
	}
	return st, nets, devs
}
