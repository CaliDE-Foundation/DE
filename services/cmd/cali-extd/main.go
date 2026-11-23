// cali-extd runs Cali extensions and manages them for Cali Settings, on the
// session bus as org.calide.Extensions. Each extension that is on runs as
// its own process (so a broken one can't take the desktop down); it is
// restarted if it crashes (up to three times in a minute) and when its
// settings change.
//
// Extensions live in ~/.local/share/cali/extensions (installed by the user)
// and $XDG_DATA_DIRS/cali/extensions (installed for everyone). Which ones
// are on, and their settings, are kept in ~/.config/cali/extensions.json.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"

	"github.com/CaliDE-Foundation/DE/services/internal/config"
	"github.com/CaliDE-Foundation/DE/services/internal/extensions"
)

const (
	busName = "org.calide.Extensions"
	path    = dbus.ObjectPath("/org/calide/Extensions")
	iface   = "org.calide.Extensions"
)

const introspection = `<node>
  <interface name="org.calide.Extensions">
    <method name="List"><arg direction="out" type="s" name="json"/></method>
    <method name="SetEnabled"><arg direction="in" type="s" name="id"/><arg direction="in" type="b" name="enabled"/></method>
    <method name="Install"><arg direction="in" type="s" name="source"/><arg direction="out" type="s" name="id"/></method>
    <method name="Remove"><arg direction="in" type="s" name="id"/></method>
    <method name="SetSetting"><arg direction="in" type="s" name="id"/><arg direction="in" type="s" name="key"/><arg direction="in" type="v" name="value"/></method>
    <signal name="Changed"/>
  </interface>` + introspect.IntrospectDataString + `</node>`

// run is one running extension process.
type run struct {
	cmd      *exec.Cmd
	stopping bool
	crashes  []time.Time
	err      string
}

type server struct {
	conn      *dbus.Conn
	mu        sync.Mutex
	userDir   string
	dirs      []string
	stateFile string
	state     extensions.State
	exts      map[string]*extensions.Extension
	runs      map[string]*run
	errors    map[string]string // last error per extension (crashed too often, bad exec)
}

func dbusErr(err error) *dbus.Error {
	return dbus.NewError("org.calide.Extensions.Error", []any{err.Error()})
}

func dataDirs() (user string, all []string) {
	home, _ := os.UserHomeDir()
	user = filepath.Join(home, ".local", "share", "cali", "extensions")
	if x := os.Getenv("XDG_DATA_HOME"); x != "" {
		user = filepath.Join(x, "cali", "extensions")
	}
	all = []string{user}
	sys := os.Getenv("XDG_DATA_DIRS")
	if sys == "" {
		sys = "/usr/local/share:/usr/share"
	}
	for _, d := range filepath.SplitList(sys) {
		if d != "" {
			all = append(all, filepath.Join(d, "cali", "extensions"))
		}
	}
	return user, all
}

// rescan reloads the installed extensions. Call with s.mu held.
func (s *server) rescan() {
	s.exts = map[string]*extensions.Extension{}
	for _, e := range extensions.Scan(s.dirs, 1) {
		s.exts[e.ID] = e
	}
}

// listItem is one extension as Cali Settings sees it.
type listItem struct {
	*extensions.Extension
	Enabled bool           `json:"enabled"`
	Running bool           `json:"running"`
	Error   string         `json:"error,omitempty"`
	Values  map[string]any `json:"values"`
}

func (s *server) List() (string, *dbus.Error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rescan()
	items := []listItem{}
	for _, e := range extensions.Scan(s.dirs, 1) {
		r := s.runs[e.ID]
		items = append(items, listItem{
			Extension: e,
			Enabled:   s.state.IsEnabled(e.ID),
			Running:   r != nil && !r.stopping,
			Error:     s.errors[e.ID],
			Values:    e.Values(s.state.Settings[e.ID]),
		})
	}
	data, err := json.Marshal(items)
	if err != nil {
		return "", dbusErr(err)
	}
	return string(data), nil
}

func (s *server) SetEnabled(id string, on bool) *dbus.Error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rescan()
	if _, ok := s.exts[id]; !ok && on {
		return dbusErr(fmt.Errorf("no extension %q", id))
	}
	s.state.SetEnabled(id, on)
	if err := s.state.Save(s.stateFile); err != nil {
		return dbusErr(err)
	}
	delete(s.errors, id)
	if on {
		s.start(id)
	} else {
		s.stop(id)
	}
	s.changed()
	return nil
}

// Install adds an extension from a folder, .zip, .tar.gz or a web address
// of one of those. It starts off; Cali Settings turns it on.
func (s *server) Install(source string) (string, *dbus.Error) {
	if strings.HasPrefix(source, "https://") || strings.HasPrefix(source, "http://") {
		file, err := download(source)
		if err != nil {
			return "", dbusErr(err)
		}
		defer os.Remove(file)
		source = file
	}
	source = strings.TrimPrefix(source, "file://")
	s.mu.Lock()
	defer s.mu.Unlock()
	id, err := extensions.Install(source, s.userDir)
	if err != nil {
		return "", dbusErr(err)
	}
	s.rescan()
	if s.runs[id] != nil {
		s.stop(id) // an update: restart the new version
		s.start(id)
	}
	s.changed()
	return id, nil
}

func (s *server) Remove(id string) *dbus.Error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rescan()
	e, ok := s.exts[id]
	if !ok {
		return dbusErr(fmt.Errorf("no extension %q", id))
	}
	if e.System {
		return dbusErr(fmt.Errorf("%s is installed for everyone; remove it with your package manager", e.Name))
	}
	s.stop(id)
	if err := os.RemoveAll(e.Dir); err != nil {
		return dbusErr(err)
	}
	s.state.SetEnabled(id, false)
	delete(s.state.Settings, id)
	_ = s.state.Save(s.stateFile)
	s.rescan()
	s.changed()
	return nil
}

func (s *server) SetSetting(id, key string, value dbus.Variant) *dbus.Error {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.exts[id]
	if !ok {
		return dbusErr(fmt.Errorf("no extension %q", id))
	}
	v, err := e.Check(key, value.Value())
	if err != nil {
		return dbusErr(err)
	}
	if s.state.Settings[id] == nil {
		s.state.Settings[id] = map[string]any{}
	}
	s.state.Settings[id][key] = v
	if err := s.state.Save(s.stateFile); err != nil {
		return dbusErr(err)
	}
	if s.runs[id] != nil {
		s.stop(id)
		s.start(id)
	}
	s.changed()
	return nil
}

func (s *server) changed() {
	_ = s.conn.Emit(path, iface+".Changed")
}

// ---- Running extensions -------------------------------------------------------------

// settingsFile writes the extension's current settings for it to read.
func (s *server) settingsFile(e *extensions.Extension) string {
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	file := filepath.Join(dir, "cali", "extensions", e.ID+".json")
	data, _ := json.MarshalIndent(e.Values(s.state.Settings[e.ID]), "", "  ")
	_ = os.MkdirAll(filepath.Dir(file), 0o755)
	_ = os.WriteFile(file, data, 0o644)
	return file
}

// start runs an extension. Call with s.mu held.
func (s *server) start(id string) {
	e, ok := s.exts[id]
	if !ok || s.runs[id] != nil && !s.runs[id].stopping {
		return
	}
	cmd := exec.Command(filepath.Join(e.Dir, e.Exec))
	cmd.Dir = e.Dir
	cmd.Env = append(os.Environ(),
		"CALI_EXTENSION_ID="+e.ID,
		"CALI_EXTENSION_DIR="+e.Dir,
		"CALI_EXTENSION_SETTINGS="+s.settingsFile(e))
	cmd.Stdout = prefixWriter(e.ID)
	cmd.Stderr = prefixWriter(e.ID)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
	prev := s.runs[id]
	r := &run{cmd: cmd}
	if prev != nil {
		r.crashes = prev.crashes
	}
	if err := cmd.Start(); err != nil {
		s.errors[id] = "couldn't start: " + err.Error()
		log.Printf("cali-extd: %s: %v", id, err)
		return
	}
	s.runs[id] = r
	log.Printf("cali-extd: started %s", id)
	go s.wait(id, r)
}

func (s *server) wait(id string, r *run) {
	err := r.cmd.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.runs[id] == r {
		delete(s.runs, id)
	}
	if r.stopping || !s.state.IsEnabled(id) {
		return
	}
	// It quit on its own: restart, unless it keeps crashing.
	now := time.Now()
	recent := []time.Time{}
	for _, t := range r.crashes {
		if now.Sub(t) < time.Minute {
			recent = append(recent, t)
		}
	}
	recent = append(recent, now)
	if len(recent) > 3 {
		s.errors[id] = fmt.Sprintf("stopped after crashing %d times in a minute (%v)", len(recent), err)
		log.Printf("cali-extd: %s: %s", id, s.errors[id])
		s.changed()
		return
	}
	log.Printf("cali-extd: %s exited (%v); restarting", id, err)
	s.runs[id] = &run{crashes: recent, stopping: true} // placeholder carrying the crash history
	go func() {
		time.Sleep(time.Second)
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.state.IsEnabled(id) {
			s.start(id)
		}
	}()
}

// stop ends an extension (its whole process group). Call with s.mu held.
func (s *server) stop(id string) {
	r := s.runs[id]
	if r == nil {
		return
	}
	r.stopping = true
	delete(s.runs, id)
	if r.cmd != nil && r.cmd.Process != nil {
		_ = syscall.Kill(-r.cmd.Process.Pid, syscall.SIGTERM)
		go func(p *os.Process) {
			time.Sleep(3 * time.Second)
			_ = syscall.Kill(-p.Pid, syscall.SIGKILL)
		}(r.cmd.Process)
	}
	log.Printf("cali-extd: stopped %s", id)
}

func (s *server) stopAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id := range s.runs {
		s.stop(id)
	}
}

type lineWriter struct{ id string }

func (w lineWriter) Write(p []byte) (int, error) {
	for _, line := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		log.Printf("[%s] %s", w.id, line)
	}
	return len(p), nil
}

func prefixWriter(id string) io.Writer { return lineWriter{id} }

func download(url string) (string, error) {
	client := http.Client{Timeout: 60 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download failed: %s", resp.Status)
	}
	ext := ".tar.gz"
	if strings.HasSuffix(strings.ToLower(url), ".zip") {
		ext = ".zip"
	}
	f, err := os.CreateTemp("", "cali-extension-*"+ext)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := io.Copy(f, io.LimitReader(resp.Body, 64<<20)); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

func main() {
	cfgDir, err := config.Dir()
	if err != nil {
		log.Fatalf("cali-extd: %v", err)
	}
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("cali-extd: session bus: %v", err)
	}
	defer conn.Close()

	user, all := dataDirs()
	s := &server{conn: conn, userDir: user, dirs: all, stateFile: filepath.Join(cfgDir, "extensions.json"),
		runs: map[string]*run{}, errors: map[string]string{}}
	s.state = extensions.ReadState(s.stateFile)

	if err := conn.Export(s, path, iface); err != nil {
		log.Fatalf("cali-extd: export: %v", err)
	}
	if err := conn.Export(introspect.Introspectable(introspection), path, "org.freedesktop.DBus.Introspectable"); err != nil {
		log.Fatalf("cali-extd: export introspection: %v", err)
	}
	reply, err := conn.RequestName(busName, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("cali-extd: %s is taken (already running?)", busName)
	}

	// Start the extensions that are on, once the shell's panel API is up.
	go func() {
		for i := 0; i < 50; i++ {
			var owner string
			if conn.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, "org.calide.Shell").Store(&owner) == nil {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		s.rescan()
		for _, id := range s.state.Enabled {
			s.start(id)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	s.stopAll()
}
