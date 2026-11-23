// cali-settingsd owns Cali's settings (~/.config/cali/cali.toml) and serves
// them on the session bus (name org.calide.SettingsDaemon, interface
// org.calide.Settings). The shell and Cali
// Settings read and change them through it and get Changed signals.
package main

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
	"github.com/CaliDE-Foundation/DE/services/internal/settings"
)

const (
	busName = "org.calide.SettingsDaemon" // org.calide.Settings is the app's ID
	path    = dbus.ObjectPath("/org/calide/Settings")
	iface   = "org.calide.Settings"
)

const introspection = `<node>
  <interface name="org.calide.Settings">
    <method name="GetAll"><arg direction="out" type="a{sv}"/></method>
    <method name="GetSchema"><arg direction="out" type="s"/></method>
    <method name="Get"><arg direction="in" type="s" name="key"/><arg direction="out" type="v"/></method>
    <method name="Set"><arg direction="in" type="s" name="key"/><arg direction="in" type="v" name="value"/></method>
    <method name="Reset"><arg direction="in" type="s" name="key"/></method>
    <method name="Export"><arg direction="out" type="s" name="setup"/></method>
    <method name="Import"><arg direction="in" type="s" name="setup"/><arg direction="out" type="u" name="applied"/></method>
    <signal name="Changed"><arg type="s" name="key"/><arg type="v" name="value"/></signal>
  </interface>` + introspect.IntrospectDataString + `</node>`

type server struct {
	conn  *dbus.Conn
	store *settings.Store
}

func dbusErr(err error) *dbus.Error {
	return dbus.NewError("org.calide.Settings.Error.Invalid", []any{err.Error()})
}

func (s *server) GetAll() (map[string]dbus.Variant, *dbus.Error) {
	out := map[string]dbus.Variant{}
	for k, v := range s.store.All() {
		out[k] = dbus.MakeVariant(v)
	}
	return out, nil
}

// GetSchema describes every setting (JSON), so Cali Settings can build its pages.
func (s *server) GetSchema() (string, *dbus.Error) {
	return settings.SchemaJSON(), nil
}

func (s *server) Get(key string) (dbus.Variant, *dbus.Error) {
	v, ok := s.store.Get(key)
	if !ok {
		return dbus.Variant{}, dbus.NewError("org.calide.Settings.Error.UnknownKey", []any{key})
	}
	return dbus.MakeVariant(v), nil
}

func (s *server) Set(key string, value dbus.Variant) *dbus.Error {
	changed, err := s.store.Set(key, value.Value())
	if err != nil {
		return dbusErr(err)
	}
	if changed {
		s.changed(key)
	}
	return nil
}

func (s *server) Reset(key string) *dbus.Error {
	if err := s.store.Reset(key); err != nil {
		return dbusErr(err)
	}
	s.changed(key)
	return nil
}

// Export returns the whole setup (every changed setting) as text.
func (s *server) Export() (string, *dbus.Error) {
	return s.store.Export(), nil
}

// Import replaces the setup: settings in the text are set, every other one
// goes back to its default. Returns how many settings it read.
func (s *server) Import(text string) (uint32, *dbus.Error) {
	values := settings.ParseText(text)
	for _, k := range settings.Keys() {
		old, _ := s.store.Get(k)
		var err error
		if v, ok := values[k]; ok {
			_, err = s.store.Set(k, v)
		} else {
			err = s.store.Reset(k)
		}
		if err != nil {
			return 0, dbusErr(err)
		}
		if now, _ := s.store.Get(k); fmt.Sprint(now) != fmt.Sprint(old) {
			s.changed(k)
		}
	}
	return uint32(len(values)), nil
}

func (s *server) changed(key string) {
	v, _ := s.store.Get(key)
	applyGNOME(key, v)
	if err := s.conn.Emit(path, iface+".Changed", key, dbus.MakeVariant(v)); err != nil {
		log.Printf("cali-settingsd: emitting Changed: %v", err)
	}
}

// applyGNOME writes settings that GNOME components read: dark style (GTK and
// libadwaita apps follow it) and the window settings Sookie reads.
func applyGNOME(key string, v any) {
	schema, gkey, text := "", "", ""
	if key == "dark-style" {
		schema, gkey, text = "org.gnome.desktop.interface", "color-scheme", "'default'"
		if v == true {
			text = "'prefer-dark'"
		}
	} else if sch, k, t, ok := settings.GSettingsValue(key, v); ok {
		schema, gkey, text = sch, k, t
	} else {
		return
	}
	if err := exec.Command("gsettings", "set", schema, gkey, text).Run(); err != nil {
		log.Printf("cali-settingsd: setting %s %s: %v", schema, gkey, err)
	}
}

func main() {
	file, err := config.File()
	if err != nil {
		log.Fatalf("cali-settingsd: %v", err)
	}
	store, err := settings.Open(file)
	if err != nil {
		log.Fatalf("cali-settingsd: reading %s: %v", file, err)
	}
	store.LoadDefaults(systemDefaults()...)

	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("cali-settingsd: session bus: %v", err)
	}
	defer conn.Close()

	s := &server{conn: conn, store: store}
	if err := conn.Export(s, path, iface); err != nil {
		log.Fatalf("cali-settingsd: export: %v", err)
	}
	if err := conn.Export(introspect.Introspectable(introspection), path, "org.freedesktop.DBus.Introspectable"); err != nil {
		log.Fatalf("cali-settingsd: export introspection: %v", err)
	}
	reply, err := conn.RequestName(busName, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("cali-settingsd: %s is already taken (%v)", busName, err)
	}

	for _, k := range settings.Keys() {
		v, _ := store.Get(k)
		applyGNOME(k, v)
	}
	log.Printf("cali-settingsd %s: settings in %s", config.Version, file)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-stop:
	case <-conn.Context().Done():
	}
}

// systemDefaults lists cali/cali.toml in each XDG_CONFIG_DIRS entry
// (default /etc/xdg), where distributions put their own defaults.
func systemDefaults() []string {
	dirs := os.Getenv("XDG_CONFIG_DIRS")
	if dirs == "" {
		dirs = "/etc/xdg"
	}
	var out []string
	for _, d := range filepath.SplitList(dirs) {
		if d != "" {
			out = append(out, filepath.Join(d, "cali", "cali.toml"))
		}
	}
	return out
}
