// Package settings defines Cali's settings and stores them in
// ~/.config/cali/cali.toml (a small TOML subset: key = value lines with
// strings, booleans, numbers and string lists).
package settings

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Kind is a setting's value type.
type Kind int

const (
	Bool Kind = iota
	String
	Number
	StringList
)

// Setting describes one key.
type Setting struct {
	Kind    Kind
	Default any
	Choices []string // for String: allowed values (nil = any)
	Min     float64  // for Number
	Max     float64
	Help    string
}

// AccentColors are the accent color names (colors live in cali-shell).
var AccentColors = []string{"coral", "blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"}

// Schema lists every setting.
var Schema = map[string]Setting{
	"accent-color":       {Kind: String, Default: "coral", Choices: AccentColors, Help: "Highlight color"},
	"dark-style":         {Kind: Bool, Default: true, Help: "Ask apps to use their dark style"},
	"clock-show-weekday": {Kind: Bool, Default: false, Help: "Show the weekday in the top bar clock"},
	"clock-show-seconds": {Kind: Bool, Default: false, Help: "Show seconds in the top bar clock"},
	"hot-corner":         {Kind: Bool, Default: true, Help: "Open the overview from the top-left corner"},
	"animation-speed":    {Kind: Number, Default: 1.0, Min: 0, Max: 3, Help: "Animation speed (0 turns animations off)"},
	"do-not-disturb":   {Kind: Bool, Default: false, Help: "Hide notification banners (they still go in the list)"},
	"idle-delay":       {Kind: Number, Default: 5.0, Min: 0, Max: 120, Help: "Minutes of inactivity before the screen blanks (0 = never)"},
	"lock-on-idle":     {Kind: Bool, Default: true, Help: "Lock the screen when it blanks"},
	"wallpaper":        {Kind: String, Default: "cali-dusk", Help: "A built-in gradient (cali-dusk, cali-day, cali-night, cali-forest) or an image path"},
	"keyboard-layouts": {Kind: StringList, Default: []string{"us"}, Help: "Keyboard layouts (xkb names, e.g. us,de); Super+Space switches"},
	"dock-favorites": {Kind: StringList, Default: []string{
		"org.gnome.Nautilus.desktop", "firefox.desktop", "org.gnome.TextEditor.desktop",
		"org.gnome.Console.desktop", "org.gnome.Software.desktop", "org.gnome.Settings.desktop",
	}, Help: "Apps in the dock"},
}

// Keys returns the setting names, sorted.
func Keys() []string {
	keys := make([]string, 0, len(Schema))
	for k := range Schema {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Validate checks value against key's schema and returns it normalized
// (e.g. ints become float64, []any becomes []string).
func Validate(key string, value any) (any, error) {
	s, ok := Schema[key]
	if !ok {
		return nil, fmt.Errorf("unknown setting %q", key)
	}
	switch s.Kind {
	case Bool:
		if b, ok := value.(bool); ok {
			return b, nil
		}
	case String:
		if str, ok := value.(string); ok {
			if s.Choices != nil && !contains(s.Choices, str) {
				return nil, fmt.Errorf("%s must be one of %s", key, strings.Join(s.Choices, ", "))
			}
			return str, nil
		}
	case Number:
		var f float64
		switch n := value.(type) {
		case float64:
			f = n
		case float32:
			f = float64(n)
		case int:
			f = float64(n)
		case int32:
			f = float64(n)
		case int64:
			f = float64(n)
		default:
			return nil, fmt.Errorf("%s must be a number", key)
		}
		if f < s.Min || f > s.Max {
			return nil, fmt.Errorf("%s must be between %g and %g", key, s.Min, s.Max)
		}
		return f, nil
	case StringList:
		switch l := value.(type) {
		case []string:
			return append([]string(nil), l...), nil
		case []any:
			out := make([]string, 0, len(l))
			for _, v := range l {
				str, ok := v.(string)
				if !ok {
					return nil, fmt.Errorf("%s must be a list of strings", key)
				}
				out = append(out, str)
			}
			return out, nil
		}
	}
	return nil, fmt.Errorf("%s has the wrong type", key)
}

// Parse turns text from the command line into a value for key:
// "true"/"false", numbers, a single string, or a comma-separated list.
func Parse(key, text string) (any, error) {
	s, ok := Schema[key]
	if !ok {
		return nil, fmt.Errorf("unknown setting %q", key)
	}
	switch s.Kind {
	case Bool:
		b, err := strconv.ParseBool(text)
		if err != nil {
			return nil, fmt.Errorf("%s must be true or false", key)
		}
		return b, nil
	case Number:
		f, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return nil, fmt.Errorf("%s must be a number", key)
		}
		return Validate(key, f)
	case StringList:
		var out []string
		for _, part := range strings.Split(text, ",") {
			if p := strings.TrimSpace(part); p != "" {
				out = append(out, p)
			}
		}
		return out, nil
	default:
		return Validate(key, text)
	}
}

// Format shows a value the way calictl prints it.
func Format(value any) string {
	switch v := value.(type) {
	case []string:
		return strings.Join(v, ",")
	case float64:
		return strconv.FormatFloat(v, 'g', -1, 64)
	default:
		return fmt.Sprint(v)
	}
}

// Store holds the current settings and their file.
type Store struct {
	mu     sync.Mutex
	path   string
	values map[string]any
}

// Open loads path (a missing file means all defaults). Unknown or invalid
// entries are skipped so a bad line never breaks the desktop.
func Open(path string) (*Store, error) {
	st := &Store{path: path, values: map[string]any{}}
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return st, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		key, value, ok := parseLine(sc.Text())
		if !ok {
			continue
		}
		if v, err := Validate(key, value); err == nil {
			st.values[key] = v
		}
	}
	return st, sc.Err()
}

// Get returns key's value, or its default.
func (st *Store) Get(key string) (any, bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if v, ok := st.values[key]; ok {
		return v, true
	}
	s, ok := Schema[key]
	return s.Default, ok
}

// All returns every setting's current value.
func (st *Store) All() map[string]any {
	out := map[string]any{}
	for _, k := range Keys() {
		out[k], _ = st.Get(k)
	}
	return out
}

// Set validates and saves a value. It reports whether the value changed.
func (st *Store) Set(key string, value any) (bool, error) {
	v, err := Validate(key, value)
	if err != nil {
		return false, err
	}
	old, _ := st.Get(key)
	st.mu.Lock()
	st.values[key] = v
	st.mu.Unlock()
	if fmt.Sprint(old) == fmt.Sprint(v) {
		return false, st.save()
	}
	return true, st.save()
}

// Reset returns key to its default.
func (st *Store) Reset(key string) error {
	if _, ok := Schema[key]; !ok {
		return fmt.Errorf("unknown setting %q", key)
	}
	st.mu.Lock()
	delete(st.values, key)
	st.mu.Unlock()
	return st.save()
}

func (st *Store) save() error {
	st.mu.Lock()
	defer st.mu.Unlock()
	var b strings.Builder
	b.WriteString("# Cali settings. Edit with Cali Settings or `calictl set`.\n")
	for _, k := range Keys() {
		if v, ok := st.values[k]; ok {
			fmt.Fprintf(&b, "%s = %s\n", k, encode(v))
		}
	}
	if err := os.MkdirAll(filepath.Dir(st.path), 0o755); err != nil {
		return err
	}
	tmp := st.path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, st.path)
}

func encode(v any) string {
	switch x := v.(type) {
	case string:
		return strconv.Quote(x)
	case []string:
		q := make([]string, len(x))
		for i, s := range x {
			q[i] = strconv.Quote(s)
		}
		return "[" + strings.Join(q, ", ") + "]"
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64)
	default:
		return fmt.Sprint(x)
	}
}

// parseLine reads `key = value`, ignoring blanks and # comments.
func parseLine(line string) (string, any, bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", nil, false
	}
	key, raw, ok := strings.Cut(line, "=")
	if !ok {
		return "", nil, false
	}
	key, raw = strings.TrimSpace(key), strings.TrimSpace(raw)
	switch {
	case raw == "true" || raw == "false":
		return key, raw == "true", true
	case strings.HasPrefix(raw, `"`):
		s, err := strconv.Unquote(raw)
		return key, s, err == nil
	case strings.HasPrefix(raw, "[") && strings.HasSuffix(raw, "]"):
		inner := strings.TrimSpace(raw[1 : len(raw)-1])
		out := []string{}
		for inner != "" {
			s, rest, err := unquotePrefix(inner)
			if err != nil {
				return "", nil, false
			}
			out = append(out, s)
			inner = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(rest), ","))
		}
		return key, out, true
	default:
		f, err := strconv.ParseFloat(raw, 64)
		return key, f, err == nil
	}
}

// unquotePrefix reads one quoted string from the start of s.
func unquotePrefix(s string) (string, string, error) {
	if !strings.HasPrefix(s, `"`) {
		return "", "", fmt.Errorf("expected a string")
	}
	for i := 1; i < len(s); i++ {
		if s[i] == '\\' {
			i++
			continue
		}
		if s[i] == '"' {
			v, err := strconv.Unquote(s[:i+1])
			return v, s[i+1:], err
		}
	}
	return "", "", fmt.Errorf("unterminated string")
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
