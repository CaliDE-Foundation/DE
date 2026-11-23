// cali-notifyd is Cali's notification server. It implements
// org.freedesktop.Notifications on the session bus and asks the shell
// (org.calide.Shell, served by cali-compositor) to show and hide banners.
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
	"github.com/CaliDE-Foundation/DE/services/internal/notify"
)

const (
	busName   = "org.freedesktop.Notifications"
	path      = dbus.ObjectPath("/org/freedesktop/Notifications")
	iface     = "org.freedesktop.Notifications"
	shellName = "org.calide.Shell"
	shellPath = dbus.ObjectPath("/org/calide/Shell")
)

const introspection = `<node>
  <interface name="org.freedesktop.Notifications">
    <method name="GetCapabilities"><arg direction="out" type="as"/></method>
    <method name="Notify">
      <arg direction="in" type="s" name="app_name"/>
      <arg direction="in" type="u" name="replaces_id"/>
      <arg direction="in" type="s" name="app_icon"/>
      <arg direction="in" type="s" name="summary"/>
      <arg direction="in" type="s" name="body"/>
      <arg direction="in" type="as" name="actions"/>
      <arg direction="in" type="a{sv}" name="hints"/>
      <arg direction="in" type="i" name="expire_timeout"/>
      <arg direction="out" type="u" name="id"/>
    </method>
    <method name="CloseNotification"><arg direction="in" type="u" name="id"/></method>
    <method name="GetServerInformation">
      <arg direction="out" type="s" name="name"/>
      <arg direction="out" type="s" name="vendor"/>
      <arg direction="out" type="s" name="version"/>
      <arg direction="out" type="s" name="spec_version"/>
    </method>
    <signal name="NotificationClosed"><arg type="u" name="id"/><arg type="u" name="reason"/></signal>
    <signal name="ActionInvoked"><arg type="u" name="id"/><arg type="s" name="action_key"/></signal>
  </interface>` + introspect.IntrospectDataString + `</node>`

type server struct {
	conn  *dbus.Conn
	store *notify.Store
	shell dbus.BusObject
}

func (s *server) GetCapabilities() ([]string, *dbus.Error) {
	return []string{"body"}, nil
}

func (s *server) GetServerInformation() (string, string, string, string, *dbus.Error) {
	return "Cali", "CaliDE Foundation", config.Version, "1.2", nil
}

func (s *server) Notify(app string, replaces uint32, appIcon, summary, body string,
	actions []string, hints map[string]dbus.Variant, expire int32) (uint32, *dbus.Error) {
	urgency := notify.UrgencyNormal
	if v, ok := hints["urgency"]; ok {
		if b, ok := v.Value().(byte); ok {
			urgency = b
		}
	}
	entry := ""
	if v, ok := hints["desktop-entry"]; ok {
		entry, _ = v.Value().(string)
	}

	id := s.store.Add(replaces, notify.Timeout(expire, urgency), s.expired)
	icon := notify.Icon(appIcon, entry)
	// Fire and forget: if the shell isn't running the notification is just not shown.
	s.shell.Go(shellName+".ShowNotification", dbus.FlagNoReplyExpected, nil, id, app, icon, summary, body)
	return id, nil
}

func (s *server) CloseNotification(id uint32) *dbus.Error {
	if s.store.Remove(id) {
		// The app withdrew it: take it out of the shell's list too.
		s.shell.Go(shellName+".RemoveNotification", dbus.FlagNoReplyExpected, nil, id)
		s.hide(id, notify.ClosedByCall)
	}
	return nil
}

func (s *server) expired(id uint32) {
	s.hide(id, notify.ClosedExpired)
}

// hide takes the banner down; the notification stays in the shell's list
// until the user clears it (or the app withdraws it).
func (s *server) hide(id, reason uint32) {
	s.shell.Go(shellName+".HideNotification", dbus.FlagNoReplyExpected, nil, id)
	if err := s.conn.Emit(path, iface+".NotificationClosed", id, reason); err != nil {
		log.Printf("cali-notifyd: emitting NotificationClosed: %v", err)
	}
}

func main() {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("cali-notifyd: session bus: %v", err)
	}
	defer conn.Close()

	s := &server{conn: conn, store: notify.NewStore(), shell: conn.Object(shellName, shellPath)}
	if err := conn.Export(s, path, iface); err != nil {
		log.Fatalf("cali-notifyd: export: %v", err)
	}
	if err := conn.Export(introspect.Introspectable(introspection), path, "org.freedesktop.DBus.Introspectable"); err != nil {
		log.Fatalf("cali-notifyd: export introspection: %v", err)
	}

	reply, err := conn.RequestName(busName, dbus.NameFlagDoNotQueue)
	if err != nil {
		log.Fatalf("cali-notifyd: request name: %v", err)
	}
	if reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("cali-notifyd: another notification server is already running")
	}

	// The shell tells us when the user dismisses a banner.
	if err := conn.AddMatchSignal(dbus.WithMatchInterface(shellName), dbus.WithMatchMember("NotificationDismissed")); err != nil {
		log.Fatalf("cali-notifyd: watching the shell: %v", err)
	}
	signals := make(chan *dbus.Signal, 16)
	conn.Signal(signals)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	log.Printf("cali-notifyd %s: serving %s", config.Version, busName)

	for {
		select {
		case sig, ok := <-signals:
			if !ok {
				return // bus connection closed: the session ended
			}
			if sig.Name == shellName+".NotificationDismissed" && len(sig.Body) == 1 {
				if id, ok := sig.Body[0].(uint32); ok && s.store.Remove(id) {
					s.hide(id, notify.ClosedDismissed)
				}
			}
		case <-stop:
			return
		case <-conn.Context().Done():
			return
		}
	}
}
