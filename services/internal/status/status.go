// Package status turns what the system reports (NetworkManager, UPower,
// BlueZ, PipeWire's wpctl, the backlight) into the shell's status values.
package status

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
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

// Media is what's playing (from an MPRIS player), for the media card.
type Media struct {
	Player   string // D-Bus name, e.g. org.mpris.MediaPlayer2.firefox
	Identity string // the app, e.g. "Mozilla Firefox"
	Title    string
	Artist   string
	ArtPath  string // local file ("" if none)
	Length   int64  // microseconds
	Position int64  // microseconds
	Playing  bool
	Output   string // audio output name, e.g. "Arctis Nova Pro"
	Icon     string // the app's icon: a file path, or an icon name
}

// Map converts media to D-Bus friendly values.
func (m Media) Map() map[string]any {
	return map[string]any{
		"player": m.Player, "identity": m.Identity, "title": m.Title, "artist": m.Artist,
		"art": m.ArtPath, "length": m.Length, "position": m.Position, "playing": m.Playing,
		"output": m.Output, "icon": m.Icon,
	}
}

// PlayerState is one MPRIS player's PlaybackStatus.
type PlayerState struct {
	Name   string
	Status string // Playing, Paused, Stopped
}

// PickPlayer chooses whose media to show: a playing player first, then a
// paused one, then any. "" if there are none.
func PickPlayer(players []PlayerState) string {
	for _, want := range []string{"Playing", "Paused"} {
		for _, p := range players {
			if p.Status == want {
				return p.Name
			}
		}
	}
	if len(players) > 0 {
		return players[0].Name
	}
	return ""
}

// ArtLocation splits an MPRIS art URL into a local path or a URL to fetch.
func ArtLocation(artURL string) (path, remote string) {
	switch {
	case strings.HasPrefix(artURL, "file://"):
		p := strings.TrimPrefix(artURL, "file://")
		if unescaped, err := url.PathUnescape(p); err == nil {
			p = unescaped
		}
		return p, ""
	case strings.HasPrefix(artURL, "http://"), strings.HasPrefix(artURL, "https://"):
		return "", artURL
	case strings.HasPrefix(artURL, "/"):
		return artURL, ""
	}
	return "", ""
}

// NodeDescription reads the device name from `wpctl inspect` output
// (the node.description line).
func NodeDescription(out string) string {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "*"))
		if v, ok := strings.CutPrefix(line, "node.description = "); ok {
			return strings.Trim(v, `"`)
		}
	}
	return ""
}

// DesktopFileIcon returns the Icon= value of a .desktop file's main section.
func DesktopFileIcon(contents string) string {
	inMain := false
	for _, line := range strings.Split(contents, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			inMain = line == "[Desktop Entry]"
			continue
		}
		if v, ok := strings.CutPrefix(line, "Icon="); ok && inMain {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// AppIcon finds the icon for an MPRIS DesktopEntry (e.g. "spotify") under
// the given XDG data directories: the matching .desktop file's Icon, as a
// file when one can be found in the hicolor theme, otherwise as a name.
// Flatpak apps often report a short entry ("spotify") while their file is
// com.spotify.Client.desktop, so a file whose name contains the entry also
// counts.
func AppIcon(entry string, dataDirs []string) string {
	if entry == "" {
		return ""
	}
	entry = strings.TrimSuffix(entry, ".desktop")
	icon := ""
	for _, dir := range dataDirs {
		if data, err := os.ReadFile(filepath.Join(dir, "applications", entry+".desktop")); err == nil {
			icon = DesktopFileIcon(string(data))
			break
		}
	}
	if icon == "" {
		lower := strings.ToLower(entry)
	search:
		for _, dir := range dataDirs {
			files, _ := filepath.Glob(filepath.Join(dir, "applications", "*.desktop"))
			for _, f := range files {
				if strings.Contains(strings.ToLower(filepath.Base(f)), lower) {
					if data, err := os.ReadFile(f); err == nil {
						if icon = DesktopFileIcon(string(data)); icon != "" {
							break search
						}
					}
				}
			}
		}
	}
	if icon == "" {
		icon = entry
	}
	if filepath.IsAbs(icon) {
		return icon
	}
	for _, dir := range dataDirs {
		for _, size := range []string{"scalable", "256x256", "128x128", "96x96", "64x64", "48x48"} {
			for _, ext := range []string{".svg", ".png"} {
				f := filepath.Join(dir, "icons", "hicolor", size, "apps", icon+ext)
				if _, err := os.Stat(f); err == nil {
					return f
				}
			}
		}
	}
	return icon
}

// DataDirs lists the XDG data directories, plus Flatpak's exports.
func DataDirs() []string {
	var dirs []string
	home, _ := os.UserHomeDir()
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		dirs = append(dirs, d)
	} else if home != "" {
		dirs = append(dirs, filepath.Join(home, ".local", "share"))
	}
	sys := os.Getenv("XDG_DATA_DIRS")
	if sys == "" {
		sys = "/usr/local/share:/usr/share"
	}
	dirs = append(dirs, filepath.SplitList(sys)...)
	if home != "" {
		dirs = append(dirs, filepath.Join(home, ".local", "share", "flatpak", "exports", "share"))
	}
	return append(dirs, "/var/lib/flatpak/exports/share")
}
