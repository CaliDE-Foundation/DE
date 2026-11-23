// Package extensions finds, installs and configures Cali extensions.
//
// An extension is a folder holding extension.json and one program (any
// language). cali-extd runs the program while the extension is on; the
// program talks to the shell over D-Bus (org.calide.Shell.Panel) and reads
// its settings from the JSON file named by $CALI_EXTENSION_SETTINGS. When a
// setting changes, cali-extd restarts it.
package extensions

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Setting describes one option an extension offers (shown in Cali Settings).
type Setting struct {
	Key     string   `json:"key"`
	Kind    string   `json:"kind"` // bool, number, string
	Default any      `json:"default"`
	Title   string   `json:"title"`
	Help    string   `json:"help,omitempty"`
	Min     float64  `json:"min,omitempty"`
	Max     float64  `json:"max,omitempty"`
	Step    float64  `json:"step,omitempty"`
	Choices []string `json:"choices,omitempty"`
	Labels  []string `json:"labels,omitempty"`
}

// Manifest is extension.json.
type Manifest struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	Version     string    `json:"version"`
	Author      string    `json:"author,omitempty"`
	URL         string    `json:"url,omitempty"`
	Exec        string    `json:"exec"`
	Settings    []Setting `json:"settings,omitempty"`
}

// Extension is an installed extension.
type Extension struct {
	Manifest
	Dir    string `json:"dir"`
	System bool   `json:"system"` // installed for everyone (can't be removed here)
}

var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,63}$`)

// Validate checks a manifest for the fields Cali needs.
func (m *Manifest) Validate() error {
	switch {
	case !idPattern.MatchString(m.ID):
		return fmt.Errorf("id %q: use lowercase letters, digits, dots and dashes", m.ID)
	case strings.TrimSpace(m.Name) == "":
		return errors.New("name is missing")
	case m.Exec == "" || strings.Contains(m.Exec, "..") || filepath.IsAbs(m.Exec):
		return fmt.Errorf("exec %q must be a file inside the extension", m.Exec)
	}
	for _, s := range m.Settings {
		switch s.Kind {
		case "bool", "number", "string":
		default:
			return fmt.Errorf("setting %q: kind must be bool, number or string", s.Key)
		}
	}
	return nil
}

// Load reads dir/extension.json.
func Load(dir string) (*Extension, error) {
	data, err := os.ReadFile(filepath.Join(dir, "extension.json"))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("extension.json: %w", err)
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return &Extension{Manifest: m, Dir: dir}, nil
}

// Scan lists the extensions under the given directories. Earlier
// directories win when two hold the same id (the user's own copy first).
func Scan(dirs []string, systemFrom int) []*Extension {
	seen := map[string]bool{}
	var out []*Extension
	for i, base := range dirs {
		entries, _ := os.ReadDir(base)
		for _, e := range entries {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			ext, err := Load(filepath.Join(base, e.Name()))
			if err != nil || seen[ext.ID] {
				continue
			}
			ext.System = i >= systemFrom
			seen[ext.ID] = true
			out = append(out, ext)
		}
	}
	sort.Slice(out, func(a, b int) bool { return strings.ToLower(out[a].Name) < strings.ToLower(out[b].Name) })
	return out
}

// Install copies an extension (a folder, .zip or .tar.gz) into dest/<id>,
// replacing an older copy. Returns the extension's id.
func Install(source, dest string) (string, error) {
	// Unpack next to the destination so the final move is a rename.
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return "", err
	}
	tmp, err := os.MkdirTemp(dest, ".install-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)

	info, err := os.Stat(source)
	if err != nil {
		return "", err
	}
	switch {
	case info.IsDir():
		err = copyTree(source, tmp)
	case strings.HasSuffix(source, ".zip"):
		err = unzip(source, tmp)
	case strings.HasSuffix(source, ".tar.gz"), strings.HasSuffix(source, ".tgz"):
		err = untar(source, tmp)
	default:
		return "", errors.New("pick an extension folder, .zip or .tar.gz")
	}
	if err != nil {
		return "", err
	}
	root, err := findRoot(tmp)
	if err != nil {
		return "", err
	}
	ext, err := Load(root)
	if err != nil {
		return "", err
	}
	target := filepath.Join(dest, ext.ID)
	if err := os.RemoveAll(target); err != nil {
		return "", err
	}
	if err := os.Rename(root, target); err != nil {
		return "", err
	}
	_ = os.Chmod(filepath.Join(target, ext.Exec), 0o755)
	return ext.ID, nil
}

// findRoot finds extension.json at the top or one folder down (archives
// usually wrap everything in a folder).
func findRoot(dir string) (string, error) {
	if _, err := os.Stat(filepath.Join(dir, "extension.json")); err == nil {
		return dir, nil
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.IsDir() {
			if _, err := os.Stat(filepath.Join(dir, e.Name(), "extension.json")); err == nil {
				return filepath.Join(dir, e.Name()), nil
			}
		}
	}
	return "", errors.New("no extension.json found")
}

// safeJoin keeps archive entries inside dir.
func safeJoin(dir, name string) (string, error) {
	p := filepath.Join(dir, name)
	if !strings.HasPrefix(p, filepath.Clean(dir)+string(os.PathSeparator)) {
		return "", fmt.Errorf("bad path in archive: %s", name)
	}
	return p, nil
}

func writeFile(path string, r io.Reader, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode&0o755|0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, io.LimitReader(r, 64<<20))
	return err
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if !d.Type().IsRegular() {
			return nil // skip links and devices
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		return writeFile(target, f, info.Mode())
	})
}

func unzip(src, dst string) error {
	r, err := zip.OpenReader(src)
	if err != nil {
		return err
	}
	defer r.Close()
	for _, f := range r.File {
		path, err := safeJoin(dst, f.Name)
		if err != nil {
			return err
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o755); err != nil {
				return err
			}
			continue
		}
		if !f.Mode().IsRegular() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		err = writeFile(path, rc, f.Mode())
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func untar(src, dst string) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		path, err := safeJoin(dst, h.Name)
		if err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(path, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeFile(path, tr, os.FileMode(h.Mode)); err != nil {
				return err
			}
		}
	}
}

// ---- Settings ---------------------------------------------------------------------

// Values merges an extension's saved settings over its defaults.
func (e *Extension) Values(saved map[string]any) map[string]any {
	out := map[string]any{}
	for _, s := range e.Settings {
		out[s.Key] = s.Default
		if v, ok := saved[s.Key]; ok {
			if checked, err := e.Check(s.Key, v); err == nil {
				out[s.Key] = checked
			}
		}
	}
	return out
}

// Check validates a value for one of the extension's settings.
func (e *Extension) Check(key string, v any) (any, error) {
	for _, s := range e.Settings {
		if s.Key != key {
			continue
		}
		switch s.Kind {
		case "bool":
			if b, ok := v.(bool); ok {
				return b, nil
			}
		case "number":
			var f float64
			switch x := v.(type) {
			case float64:
				f = x
			case int32:
				f = float64(x)
			case int64:
				f = float64(x)
			default:
				return nil, fmt.Errorf("%s needs a number", key)
			}
			if s.Max > s.Min && (f < s.Min || f > s.Max) {
				return nil, fmt.Errorf("%s must be between %g and %g", key, s.Min, s.Max)
			}
			return f, nil
		case "string":
			if str, ok := v.(string); ok {
				if len(s.Choices) > 0 && !contains(s.Choices, str) {
					return nil, fmt.Errorf("%s: %q isn't one of the choices", key, str)
				}
				return str, nil
			}
		}
		return nil, fmt.Errorf("%s needs a %s", key, s.Kind)
	}
	return nil, fmt.Errorf("%s has no setting %q", e.ID, key)
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// State is what cali-extd keeps in ~/.config/cali/extensions.json.
type State struct {
	Enabled  []string                  `json:"enabled"`
	Settings map[string]map[string]any `json:"settings"`
}

// ReadState loads the state file (missing means nothing enabled).
func ReadState(path string) State {
	st := State{Settings: map[string]map[string]any{}}
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &st)
	}
	if st.Settings == nil {
		st.Settings = map[string]map[string]any{}
	}
	return st
}

// Save writes the state file atomically.
func (st State) Save(path string) error {
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// IsEnabled reports whether id is on.
func (st State) IsEnabled(id string) bool { return contains(st.Enabled, id) }

// SetEnabled turns id on or off.
func (st *State) SetEnabled(id string, on bool) {
	out := st.Enabled[:0]
	for _, x := range st.Enabled {
		if x != id {
			out = append(out, x)
		}
	}
	if on {
		out = append(out, id)
	}
	sort.Strings(out)
	st.Enabled = out
}
