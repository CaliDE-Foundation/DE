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
    <method name="ListWifiNetworks"><arg direction="out" type="a(sybb)"/></method>
    <method name="ConnectWifi"><arg direction="in" type="s" name="ssid"/></method>
    <method name="ListBluetoothDevices"><arg direction="out" type="a(ssbb)"/></method>
    <method name="SetBluetoothDeviceConnected"><arg direction="in" type="s" name="path"/><arg direction="in" type="b"/></method>
    <signal name="Changed"><arg type="a{sv}"/></signal>
  </interface>` + introspect.IntrospectDataString + `</node>`

type server struct {
	session *dbus.Conn
	system  *dbus.Conn // nil when there is no system bus

	mu   sync.Mutex
	last status.Status

	// Fake mode (CALI_STATUS_FAKE=1): made-up hardware, for testing the shell.
	fake        bool
	fakeStatus  status.Status
	fakeNets    []status.WifiNetwork
	fakeDevices []status.BluetoothDevice
}

// ---- Reading ---------------------------------------------------------------------

func (s *server) read() status.Status {
	if s.fake {
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.fakeStatus
	}
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
	if s.fake {
		s.mu.Lock()
		s.fakeStatus.Volume, s.fakeStatus.Muted = status.Clamp(v), false
		s.mu.Unlock()
		return s.refresh().Volume, nil
	}
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
	if s.fake {
		s.mu.Lock()
		s.fakeStatus.Muted = !s.fakeStatus.Muted
		s.mu.Unlock()
		return s.refresh().Muted, nil
	}
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
	if s.fake {
		s.mu.Lock()
		s.fakeStatus.WifiEnabled = on
		s.mu.Unlock()
	}
	if s.system != nil {
		const nm = "org.freedesktop.NetworkManager"
		s.system.Object(nm, "/org/freedesktop/NetworkManager").SetProperty(nm+".WirelessEnabled", dbus.MakeVariant(on))
	}
	s.refresh()
	return nil
}

func (s *server) SetBluetoothEnabled(on bool) *dbus.Error {
	if s.fake {
		s.mu.Lock()
		s.fakeStatus.BluetoothEnabled = on
		s.mu.Unlock()
	}
	if adapter, ok := s.bluezAdapter(); ok {
		s.system.Object("org.bluez", adapter).SetProperty("org.bluez.Adapter1.Powered", dbus.MakeVariant(on))
	}
	s.refresh()
	return nil
}

// ---- Wi-Fi networks and Bluetooth devices -------------------------------------------

type wifiEntry struct {
	SSID     string
	Strength uint8
	Active   bool
	Secured  bool
}

type deviceEntry struct {
	Name      string
	Path      string
	Paired    bool
	Connected bool
}

const nmName = "org.freedesktop.NetworkManager"

// wifiDevice returns the first Wi-Fi device's path.
func (s *server) wifiDevice() (dbus.ObjectPath, bool) {
	if s.system == nil {
		return "", false
	}
	devices, _ := prop[[]dbus.ObjectPath](s.system, nmName, "/org/freedesktop/NetworkManager", nmName+".AllDevices")
	for _, d := range devices {
		if t, ok := prop[uint32](s.system, nmName, d, nmName+".Device.DeviceType"); ok && t == 2 {
			return d, true
		}
	}
	return "", false
}

// accessPoints lists the networks the Wi-Fi device sees, with their paths.
func (s *server) accessPoints() ([]status.WifiNetwork, map[string]dbus.ObjectPath) {
	paths := map[string]dbus.ObjectPath{}
	dev, ok := s.wifiDevice()
	if !ok {
		return nil, paths
	}
	var aps []dbus.ObjectPath
	if s.system.Object(nmName, dev).Call(nmName+".Device.Wireless.GetAllAccessPoints", 0).Store(&aps) != nil {
		return nil, paths
	}
	active, _ := prop[dbus.ObjectPath](s.system, nmName, dev, nmName+".Device.Wireless.ActiveAccessPoint")
	var nets []status.WifiNetwork
	for _, ap := range aps {
		raw, _ := prop[[]byte](s.system, nmName, ap, nmName+".AccessPoint.Ssid")
		strength, _ := prop[uint8](s.system, nmName, ap, nmName+".AccessPoint.Strength")
		wpa, _ := prop[uint32](s.system, nmName, ap, nmName+".AccessPoint.WpaFlags")
		rsn, _ := prop[uint32](s.system, nmName, ap, nmName+".AccessPoint.RsnFlags")
		ssid := status.SSID(raw)
		if old, seen := paths[ssid]; !seen || old == "" || ap == active {
			paths[ssid] = ap
		}
		nets = append(nets, status.WifiNetwork{SSID: ssid, Strength: strength, Active: ap == active, Secured: wpa != 0 || rsn != 0})
	}
	return status.SortNetworks(nets), paths
}

func (s *server) ListWifiNetworks() ([]wifiEntry, *dbus.Error) {
	nets := s.fakeNets
	if !s.fake {
		nets, _ = s.accessPoints()
	}
	out := make([]wifiEntry, 0, len(nets))
	for _, n := range nets {
		out = append(out, wifiEntry(n))
	}
	return out, nil
}

// ConnectWifi joins a network: with its saved profile if there is one,
// otherwise by creating one (open networks; secured ones need a password
// prompt, which comes from NetworkManager's secret agent).
func (s *server) ConnectWifi(ssid string) *dbus.Error {
	if s.fake {
		s.mu.Lock()
		for i := range s.fakeNets {
			s.fakeNets[i].Active = s.fakeNets[i].SSID == ssid
		}
		s.fakeNets = status.SortNetworks(s.fakeNets)
		s.mu.Unlock()
		return nil
	}
	dev, ok := s.wifiDevice()
	if !ok {
		return dbus.NewError("org.calide.Status.Error.NoWifi", []any{"no Wi-Fi device"})
	}
	_, paths := s.accessPoints()
	ap, ok := paths[ssid]
	if !ok {
		return dbus.NewError("org.calide.Status.Error.NotFound", []any{"network not found: " + ssid})
	}
	nm := s.system.Object(nmName, "/org/freedesktop/NetworkManager")
	var active dbus.ObjectPath
	if nm.Call(nmName+".ActivateConnection", 0, dbus.ObjectPath("/"), dev, ap).Store(&active) == nil {
		return nil
	}
	var conn, act dbus.ObjectPath
	err := nm.Call(nmName+".AddAndActivateConnection", 0, map[string]map[string]dbus.Variant{}, dev, ap).Store(&conn, &act)
	if err != nil {
		return dbus.NewError("org.calide.Status.Error.Failed", []any{err.Error()})
	}
	return nil
}

func (s *server) ListBluetoothDevices() ([]deviceEntry, *dbus.Error) {
	if s.fake {
		out := make([]deviceEntry, 0, len(s.fakeDevices))
		for _, d := range s.fakeDevices {
			out = append(out, deviceEntry(d))
		}
		return out, nil
	}
	if s.system == nil {
		return nil, nil
	}
	var objects map[dbus.ObjectPath]map[string]map[string]dbus.Variant
	if s.system.Object("org.bluez", "/").Call("org.freedesktop.DBus.ObjectManager.GetManagedObjects", 0).Store(&objects) != nil {
		return nil, nil
	}
	var out []deviceEntry
	for p, ifaces := range objects {
		dev, ok := ifaces["org.bluez.Device1"]
		if !ok {
			continue
		}
		get := func(k string) any { return dev[k].Value() }
		name, _ := get("Alias").(string)
		paired, _ := get("Paired").(bool)
		connected, _ := get("Connected").(bool)
		if paired {
			out = append(out, deviceEntry{Name: name, Path: string(p), Paired: paired, Connected: connected})
		}
	}
	return out, nil
}

func (s *server) SetBluetoothDeviceConnected(path string, on bool) *dbus.Error {
	if s.fake {
		s.mu.Lock()
		for i := range s.fakeDevices {
			if s.fakeDevices[i].Path == path {
				s.fakeDevices[i].Connected = on
			}
		}
		s.mu.Unlock()
		return nil
	}
	if s.system == nil {
		return nil
	}
	method := "org.bluez.Device1.Disconnect"
	if on {
		method = "org.bluez.Device1.Connect"
	}
	if call := s.system.Object("org.bluez", dbus.ObjectPath(path)).Call(method, 0); call.Err != nil {
		return dbus.NewError("org.calide.Status.Error.Failed", []any{call.Err.Error()})
	}
	return nil
}

func main() {
	session, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("cali-statusd: session bus: %v", err)
	}
	defer session.Close()

	s := &server{session: session, last: status.Unknown()}
	if os.Getenv("CALI_STATUS_FAKE") == "1" {
		s.fake = true
		s.fakeStatus, s.fakeNets, s.fakeDevices = status.Fake()
		log.Printf("cali-statusd: fake hardware (CALI_STATUS_FAKE=1)")
	}
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
