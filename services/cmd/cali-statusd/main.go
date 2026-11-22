// cali-statusd reports network, Bluetooth, battery, volume and brightness
// to the shell as org.calide.Status on the session bus, and changes them
// when asked (volume keys, quick settings). Missing services (no
// NetworkManager, no battery, ...) simply show as unavailable.
package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
	"github.com/CaliDE-Foundation/DE/services/internal/status"
)

const (
	busName = "org.calide.Status"
	path    = dbus.ObjectPath("/org/calide/Status")
	iface   = "org.calide.Status"
	sink    = "@DEFAULT_AUDIO_SINK@"
	poll    = 2 * time.Second
)

const introspection = `<node>
  <interface name="org.calide.Status">
    <method name="GetAll"><arg direction="out" type="a{sv}"/></method>
    <method name="SetVolume"><arg direction="in" type="d"/><arg direction="out" type="d"/></method>
    <method name="AdjustVolume"><arg direction="in" type="d"/><arg direction="out" type="d"/></method>
    <method name="ToggleMute"><arg direction="out" type="b"/></method>
    <method name="AdjustBrightness"><arg direction="in" type="d"/><arg direction="out" type="d"/></method>
    <method name="SetWifiEnabled"><arg direction="in" type="b"/></method>
    <method name="SetBluetoothEnabled"><arg direction="in" type="b"/></method>
    <signal name="Changed"><arg type="a{sv}"/></signal>
  </interface>` + introspect.IntrospectDataString + `</node>`

type server struct {
	session *dbus.Conn
	system  *dbus.Conn // nil when there is no system bus

	mu   sync.Mutex
	last status.Status
}

// ---- Reading ---------------------------------------------------------------------

func (s *server) read() status.Status {
	st := status.Unknown()
	s.readNetwork(&st)
	s.readBluetooth(&st)
	s.readBattery(&st)
	readVolume(&st)
	if b, max, _, ok := backlight(); ok && max > 0 {
		st.Brightness = float64(b) / float64(max)
	}
	return st
}

func prop[T any](conn *dbus.Conn, dest string, p dbus.ObjectPath, name string) (T, bool) {
	var zero T
	v, err := conn.Object(dest, p).GetProperty(name)
	if err != nil {
		return zero, false
	}
	t, ok := v.Value().(T)
	return t, ok
}

func (s *server) readNetwork(st *status.Status) {
	if s.system == nil {
		return
	}
	const nm, nmPath = "org.freedesktop.NetworkManager", dbus.ObjectPath("/org/freedesktop/NetworkManager")
	state, ok := prop[uint32](s.system, nm, nmPath, nm+".State")
	if !ok {
		return
	}
	kind, _ := prop[string](s.system, nm, nmPath, nm+".PrimaryConnectionType")
	st.Network = status.NetworkState(state, kind)
	st.WifiEnabled, _ = prop[bool](s.system, nm, nmPath, nm+".WirelessEnabled")
	devices, _ := prop[[]dbus.ObjectPath](s.system, nm, nmPath, nm+".AllDevices")
	for _, d := range devices {
		if t, ok := prop[uint32](s.system, nm, d, nm+".Device.DeviceType"); ok && t == 2 { // NM_DEVICE_TYPE_WIFI
			st.WifiAvailable = true
			break
		}
	}
}

// bluezAdapter finds the first Bluetooth adapter's object path.
func (s *server) bluezAdapter() (dbus.ObjectPath, bool) {
	if s.system == nil {
		return "", false
	}
	var objects map[dbus.ObjectPath]map[string]map[string]dbus.Variant
	err := s.system.Object("org.bluez", "/").Call("org.freedesktop.DBus.ObjectManager.GetManagedObjects", 0).Store(&objects)
	if err != nil {
		return "", false
	}
	for p, ifaces := range objects {
		if _, ok := ifaces["org.bluez.Adapter1"]; ok {
			return p, true
		}
	}
	return "", false
}

func (s *server) readBluetooth(st *status.Status) {
	adapter, ok := s.bluezAdapter()
	if !ok {
		return
	}
	st.BluetoothAvailable = true
	st.BluetoothEnabled, _ = prop[bool](s.system, "org.bluez", adapter, "org.bluez.Adapter1.Powered")
}

func (s *server) readBattery(st *status.Status) {
	if s.system == nil {
		return
	}
	const up, dev = "org.freedesktop.UPower", dbus.ObjectPath("/org/freedesktop/UPower/devices/DisplayDevice")
	present, ok := prop[bool](s.system, up, dev, up+".Device.IsPresent")
	if !ok || !present {
		return
	}
	if pct, ok := prop[float64](s.system, up, dev, up+".Device.Percentage"); ok {
		st.Battery = pct / 100
	}
	state, _ := prop[uint32](s.system, up, dev, up+".Device.State")
	st.Charging = status.BatteryCharging(state)
}

func wpctl(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "wpctl", args...).Output()
	return string(out), err
}

func readVolume(st *status.Status) {
	out, err := wpctl("get-volume", sink)
	if err != nil {
		return
	}
	if v, m, err := status.ParseWpctlVolume(out); err == nil {
		st.Volume, st.Muted = v, m
	}
}

// backlight returns the first backlight's brightness, max and name.
func backlight() (int, int, string, bool) {
	dirs, _ := filepath.Glob("/sys/class/backlight/*")
	for _, d := range dirs {
		b, err1 := readInt(filepath.Join(d, "brightness"))
		m, err2 := readInt(filepath.Join(d, "max_brightness"))
		if err1 == nil && err2 == nil {
			return b, m, filepath.Base(d), true
		}
	}
	return 0, 0, "", false
}

func readInt(p string) (int, error) {
	data, err := os.ReadFile(p)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(data)))
}

// ---- Publishing --------------------------------------------------------------------

func variants(st status.Status) map[string]dbus.Variant {
	out := map[string]dbus.Variant{}
	for k, v := range st.Map() {
		out[k] = dbus.MakeVariant(v)
	}
	return out
}

// refresh re-reads everything and signals the shell if anything changed.
func (s *server) refresh() status.Status {
	st := s.read()
	s.mu.Lock()
	changed := st != s.last
	s.last = st
	s.mu.Unlock()
	if changed {
		if err := s.session.Emit(path, iface+".Changed", variants(st)); err != nil {
			log.Printf("cali-statusd: emitting Changed: %v", err)
		}
	}
	return st
}

// ---- Methods -----------------------------------------------------------------------

func (s *server) GetAll() (map[string]dbus.Variant, *dbus.Error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return variants(s.last), nil
}

func (s *server) SetVolume(v float64) (float64, *dbus.Error) {
	wpctl("set-mute", sink, "0")
	wpctl("set-volume", "-l", "1.0", sink, strconv.FormatFloat(status.Clamp(v), 'f', 2, 64))
	return s.refresh().Volume, nil
}

func (s *server) AdjustVolume(delta float64) (float64, *dbus.Error) {
	s.mu.Lock()
	current := s.last.Volume
	s.mu.Unlock()
	if current < 0 {
		return -1, nil
	}
	return s.SetVolume(current + delta)
}

func (s *server) ToggleMute() (bool, *dbus.Error) {
	wpctl("set-mute", sink, "toggle")
	return s.refresh().Muted, nil
}

func (s *server) AdjustBrightness(delta float64) (float64, *dbus.Error) {
	b, max, name, ok := backlight()
	if !ok || s.system == nil {
		return -1, nil
	}
	next := status.BrightnessStep(b, max, delta)
	// logind lets the session's user set the backlight without root.
	call := s.system.Object("org.freedesktop.login1", "/org/freedesktop/login1/session/auto").
		Call("org.freedesktop.login1.Session.SetBrightness", 0, "backlight", name, uint32(next))
	if call.Err != nil {
		log.Printf("cali-statusd: setting brightness: %v", call.Err)
	}
	return s.refresh().Brightness, nil
}

func (s *server) SetWifiEnabled(on bool) *dbus.Error {
	if s.system != nil {
		const nm = "org.freedesktop.NetworkManager"
		s.system.Object(nm, "/org/freedesktop/NetworkManager").SetProperty(nm+".WirelessEnabled", dbus.MakeVariant(on))
	}
	s.refresh()
	return nil
}

func (s *server) SetBluetoothEnabled(on bool) *dbus.Error {
	if adapter, ok := s.bluezAdapter(); ok {
		s.system.Object("org.bluez", adapter).SetProperty("org.bluez.Adapter1.Powered", dbus.MakeVariant(on))
	}
	s.refresh()
	return nil
}

func main() {
	session, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("cali-statusd: session bus: %v", err)
	}
	defer session.Close()

	s := &server{session: session, last: status.Unknown()}
	if system, err := dbus.ConnectSystemBus(); err == nil {
		s.system = system
		defer system.Close()
	} else {
		log.Printf("cali-statusd: no system bus, network/battery/Bluetooth unavailable: %v", err)
	}

	if err := session.Export(s, path, iface); err != nil {
		log.Fatalf("cali-statusd: export: %v", err)
	}
	if err := session.Export(introspect.Introspectable(introspection), path, "org.freedesktop.DBus.Introspectable"); err != nil {
		log.Fatalf("cali-statusd: export introspection: %v", err)
	}
	reply, err := session.RequestName(busName, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("cali-statusd: %s is already taken (%v)", busName, err)
	}
	s.refresh()
	log.Printf("cali-statusd %s: serving %s", config.Version, busName)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			s.refresh()
		case <-stop:
			return
		case <-session.Context().Done():
			return
		}
	}
}
