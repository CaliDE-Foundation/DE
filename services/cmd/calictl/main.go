// calictl is the command-line tool for the Cali desktop.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/godbus/dbus/v5"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
	"github.com/CaliDE-Foundation/DE/services/internal/settings"
)

const usage = `usage: calictl <command>

commands:
  list               show every setting and its value
  get KEY            print one setting
  set KEY VALUE      change a setting (lists: comma-separated)
  reset KEY          go back to the default
  export [FILE]      save your whole setup (stdout without FILE)
  import FILE        load a setup; settings it leaves out go back to defaults
  ext list           show installed extensions
  ext install SRC    install from a folder, .zip, .tar.gz or https:// link
  ext on|off ID      turn an extension on or off
  ext remove ID      uninstall an extension
  version            print the version
  config-path        print the settings file location

Changes apply right away when Cali is running.
`

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "calictl: "+format+"\n", args...)
	os.Exit(1)
}

// settingsd returns the running settings service, or nil.
func settingsd() dbus.BusObject {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return nil
	}
	var owner string
	if conn.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, "org.calide.SettingsDaemon").Store(&owner) != nil {
		return nil
	}
	return conn.Object("org.calide.SettingsDaemon", "/org/calide/Settings")
}

// fileStore is used when cali-settingsd isn't running.
func fileStore() *settings.Store {
	path, err := config.File()
	if err != nil {
		fail("%v", err)
	}
	st, err := settings.Open(path)
	if err != nil {
		fail("%v", err)
	}
	return st
}

func get(key string) any {
	if _, ok := settings.Schema[key]; !ok {
		fail("unknown setting %q (see calictl list)", key)
	}
	if obj := settingsd(); obj != nil {
		var v dbus.Variant
		if err := obj.Call("org.calide.Settings.Get", 0, key).Store(&v); err != nil {
			fail("%v", err)
		}
		return v.Value()
	}
	v, _ := fileStore().Get(key)
	return v
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "version":
		fmt.Println("calictl", config.Version)
	case "config-path":
		p, err := config.File()
		if err != nil {
			fail("%v", err)
		}
		fmt.Println(p)
	case "list":
		for _, k := range settings.Keys() {
			fmt.Printf("%-20s %s\n", k, settings.Format(get(k)))
		}
	case "get":
		if len(args) != 1 {
			fail("usage: calictl get KEY")
		}
		fmt.Println(settings.Format(get(args[0])))
	case "set":
		if len(args) < 2 {
			fail("usage: calictl set KEY VALUE")
		}
		// Words after the key form the value, so quotes are optional.
		value, err := settings.Parse(args[0], strings.Join(args[1:], " "))
		if err != nil {
			fail("%v", err)
		}
		if obj := settingsd(); obj != nil {
			if err := obj.Call("org.calide.Settings.Set", 0, args[0], dbus.MakeVariant(value)).Err; err != nil {
				fail("%v", err)
			}
			return
		}
		if _, err := fileStore().Set(args[0], value); err != nil {
			fail("%v", err)
		}
	case "reset":
		if len(args) != 1 {
			fail("usage: calictl reset KEY")
		}
		if obj := settingsd(); obj != nil {
			if err := obj.Call("org.calide.Settings.Reset", 0, args[0]).Err; err != nil {
				fail("%v", err)
			}
			return
		}
		if err := fileStore().Reset(args[0]); err != nil {
			fail("%v", err)
		}
	case "export":
		var text string
		if obj := settingsd(); obj != nil {
			if err := obj.Call("org.calide.Settings.Export", 0).Store(&text); err != nil {
				fail("%v", err)
			}
		} else {
			text = fileStore().Export()
		}
		if len(args) == 0 {
			fmt.Print(text)
		} else if err := os.WriteFile(args[0], []byte(text), 0o644); err != nil {
			fail("%v", err)
		}
	case "import":
		if len(args) != 1 {
			fail("usage: calictl import FILE")
		}
		data, err := os.ReadFile(args[0])
		if err != nil {
			fail("%v", err)
		}
		obj := settingsd()
		if obj == nil {
			fail("Cali isn't running; start it and try again")
		}
		var n uint32
		if err := obj.Call("org.calide.Settings.Import", 0, string(data)).Store(&n); err != nil {
			fail("%v", err)
		}
		fmt.Printf("imported %d settings\n", n)
	case "ext":
		extCommand(args)
	default:
		fmt.Fprintf(os.Stderr, "calictl: unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
}

// extCommand talks to cali-extd (org.calide.Extensions).
func extCommand(args []string) {
	if len(args) == 0 {
		fail("usage: calictl ext list|install SRC|on ID|off ID|remove ID")
	}
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		fail("%v", err)
	}
	obj := conn.Object("org.calide.Extensions", "/org/calide/Extensions")
	need := func(n int) {
		if len(args) != n {
			fail("usage: calictl ext %s ID", args[0])
		}
	}
	switch args[0] {
	case "list":
		var text string
		if err := obj.Call("org.calide.Extensions.List", 0).Store(&text); err != nil {
			fail("is Cali running? %v", err)
		}
		var items []struct {
			ID, Name, Version, Error string
			Enabled, Running, System bool
		}
		if err := json.Unmarshal([]byte(text), &items); err != nil {
			fail("%v", err)
		}
		for _, it := range items {
			state := "off"
			if it.Enabled {
				state = "on"
			}
			if it.Running {
				state += ", running"
			}
			if it.Error != "" {
				state += ", " + it.Error
			}
			fmt.Printf("%-24s %-28s %s (%s)\n", it.ID, it.Name, it.Version, state)
		}
	case "install":
		need(2)
		src := args[1]
		if !strings.Contains(src, "://") {
			if abs, err := filepath.Abs(src); err == nil {
				src = abs
			}
		}
		var id string
		if err := obj.Call("org.calide.Extensions.Install", 0, src).Store(&id); err != nil {
			fail("%v", err)
		}
		fmt.Printf("installed %s (turn it on with: calictl ext on %s)\n", id, id)
	case "on", "off":
		need(2)
		if err := obj.Call("org.calide.Extensions.SetEnabled", 0, args[1], args[0] == "on").Err; err != nil {
			fail("%v", err)
		}
	case "remove":
		need(2)
		if err := obj.Call("org.calide.Extensions.Remove", 0, args[1]).Err; err != nil {
			fail("%v", err)
		}
	default:
		fail("unknown ext command %q", args[0])
	}
}
