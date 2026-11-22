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
