// Package settings defines Cali's settings and stores them in
// ~/.config/cali/cali.toml (a small TOML subset: key = value lines with
// strings, booleans, numbers and string lists).
package settings

import (
	"bufio"
	"encoding/json"
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

// Setting describes one key, including how Cali Settings shows it.
type Setting struct {
	Kind    Kind
	Default any
	Choices []string // for String: allowed values (nil = any)
	Labels  []string // for String with Choices: what Cali Settings shows
	Min     float64  // for Number
	Max     float64
	Step    float64
	Help    string

	Title    string
	Page     string // Cali Settings page
	Group    string // section on that page
	Advanced bool   // only shown in Advanced mode

	// GNOME setting this one also writes (Sookie and GNOME apps read it).
	GSchema string
	GKey    string
	GValue  func(v any) string // value in gsettings syntax (nil = default formatting)
}

// AccentColors are the accent color names (colors live in cali-shell).
var AccentColors = []string{"coral", "blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate", "custom"}

func b(def bool, title, page, group, help string, advanced bool) Setting {
	return Setting{Kind: Bool, Default: def, Title: title, Page: page, Group: group, Help: help, Advanced: advanced}
}

func n(def, min, max, step float64, title, page, group, help string, advanced bool) Setting {
	return Setting{Kind: Number, Default: def, Min: min, Max: max, Step: step, Title: title, Page: page, Group: group, Help: help, Advanced: advanced}
}

func choice(def string, choices, labels []string, title, page, group, help string, advanced bool) Setting {
	return Setting{Kind: String, Default: def, Choices: choices, Labels: labels, Title: title, Page: page, Group: group, Help: help, Advanced: advanced}
}

func gnome(st Setting, schema, key string, value func(any) string) Setting {
	st.GSchema, st.GKey, st.GValue = schema, key, value
	return st
}

const (
	wmPrefs    = "org.gnome.desktop.wm.preferences"
	mutter     = "org.gnome.mutter"
	iface      = "org.gnome.desktop.interface"
	a11yApps   = "org.gnome.desktop.a11y.applications"
	a11yKeys   = "org.gnome.desktop.a11y.keyboard"
	a11yIface  = "org.gnome.desktop.a11y.interface"
	a11yPage   = "Accessibility"
	gnomeFalse = "false"
)

func quoted(v any) string { return "'" + fmt.Sprint(v) + "'" }

// Schema lists every setting.
var Schema = map[string]Setting{
	// ---- Appearance
	"accent-color": choice("coral", AccentColors,
		[]string{"Coral", "Blue", "Teal", "Green", "Yellow", "Orange", "Red", "Pink", "Purple", "Slate", "Custom"},
		"Accent Color", "Appearance", "Style", "Highlights, toggles and today in the calendar", false),
	"accent-custom": {Kind: String, Default: "#e2725b", Title: "Custom Accent", Page: "Appearance", Group: "Colors",
		Help: "A hex color like #3584e4, used when Accent Color is Custom", Advanced: true},
	"surface-color": choice("charcoal", []string{"charcoal", "black", "slate", "plum", "forest", "mocha", "custom"},
		[]string{"Charcoal", "Black", "Slate", "Plum", "Forest", "Mocha", "Custom"}, "Menus and Popups", "Appearance", "Colors", "Background of menus, popups, notifications and the dock", false),
	"surface-custom": {Kind: String, Default: "#2e2e32", Title: "Custom Menu Color", Page: "Appearance", Group: "Colors",
		Help: "A hex color, used when Menus and Popups is Custom", Advanced: true},
	"panel-color": choice("black", []string{"black", "surface", "accent", "custom"}, []string{"Black", "Same as Menus", "Accent", "Custom"},
		"Top Bar Color", "Appearance", "Colors", "Opacity is on the Top Bar page", false),
	"panel-custom": {Kind: String, Default: "#000000", Title: "Custom Top Bar Color", Page: "Appearance", Group: "Colors",
		Help: "A hex color, used when Top Bar Color is Custom", Advanced: true},
	"dark-style":      b(true, "Dark Style", "Appearance", "Style", "Ask apps to use their dark look", false),
	"corner-radius":   n(18, 0, 32, 1, "Corner Roundness", "Appearance", "Style", "How round menus, popups and the dock are", true),
	"shell-font":      {Kind: String, Default: "Adwaita Sans", Title: "Shell Font", Page: "Appearance", Group: "Style", Help: "Font family for the top bar, menus and overview", Advanced: true},
	"shell-font-size": n(11, 8, 16, 1, "Shell Font Size", "Appearance", "Style", "Base text size in points", true),
	"wallpaper": {Kind: String, Default: "cali-dusk", Title: "Wallpaper", Page: "Appearance", Group: "Background",
		Help: "A built-in gradient (cali-dusk, cali-day, cali-night, cali-forest) or an image path"},
	"wallpaper-style": choice("zoom", []string{"zoom", "centered", "scaled", "stretched", "wallpaper"},
		[]string{"Fill", "Center", "Fit", "Stretch", "Tile"}, "Image Placement", "Appearance", "Background", "How an image wallpaper fits the screen", true),

	// ---- Top bar
	"panel-height":            n(32, 24, 48, 1, "Height", "Top Bar", "Bar", "Bar height in pixels", true),
	"panel-opacity":           n(1, 0, 1, 0.05, "Opacity", "Top Bar", "Bar", "1 is solid black, 0 is fully transparent", false),
	"clock-position":          choice("center", []string{"center", "left", "right"}, []string{"Center", "Left", "Right"}, "Clock Position", "Top Bar", "Clock", "Where the clock sits in the bar", false),
	"clock-show-date":         b(true, "Show Date", "Top Bar", "Clock", "Like “Nov 22”", false),
	"clock-show-weekday":      b(false, "Show Weekday", "Top Bar", "Clock", "Like “Sun”", false),
	"clock-show-seconds":      b(false, "Show Seconds", "Top Bar", "Clock", "Update the clock every second", false),
	"clock-24h":               b(true, "24-Hour Clock", "Top Bar", "Clock", "Off shows 5:30 PM", false),
	"show-workspace-dots":     b(true, "Workspace Dots", "Top Bar", "Indicators", "The workspace indicator on the left", false),
	"show-battery-percentage": b(false, "Battery Percentage", "Top Bar", "Indicators", "Show the charge next to the battery icon", false),
	"show-keyboard-indicator": b(true, "Keyboard Layout", "Top Bar", "Indicators", "Show the layout when you have more than one", true),

	// ---- Overview and dock
	"hot-corner":          b(true, "Hot Corner", "Overview", "Overview", "Open the overview by pushing the pointer into the top-left corner", false),
	"overview-search":     b(true, "Search Field", "Overview", "Overview", "Show the search field in the overview (typing searches either way)", true),
	"overview-dim":        n(0.43, 0, 0.9, 0.05, "Background Dimming", "Overview", "Overview", "How much the wallpaper darkens behind the overview", true),
	"overview-window-gap": n(32, 8, 96, 4, "Window Spacing", "Overview", "Overview", "Space between windows in the overview", true),
	"app-folders":         b(true, "App Folders", "Overview", "App Grid", "Group utilities and system apps into folders", false),
	"dock-favorites": {Kind: StringList, Default: []string{
		"org.gnome.Nautilus.desktop", "firefox.desktop", "org.gnome.TextEditor.desktop",
		"org.gnome.Console.desktop", "org.gnome.Software.desktop", "org.gnome.Settings.desktop",
	}, Title: "Favorite Apps", Page: "Overview", Group: "Dock", Help: "Desktop file names, separated by commas"},
	"dock-mode": choice("overview", []string{"overview", "always", "autohide"}, []string{"In the Overview (GNOME)", "Always on the Desktop", "On the Desktop, Hide Until Pointed At"},
		"Show the Dock", "Overview", "Dock", "Where the dock appears", false),
	"dock-position": choice("bottom", []string{"bottom", "left", "right"}, []string{"Bottom", "Left", "Right"},
		"Desktop Dock Position", "Overview", "Dock", "Screen edge for the desktop dock", false),
	"dock-icon-size":    n(48, 32, 80, 4, "Icon Size", "Overview", "Dock", "Size of dock icons in pixels", false),
	"dock-running-dots": b(true, "Running Dots", "Overview", "Dock", "A dot under apps that are open", true),
	"media-controls":    b(true, "Media Controls", "Overview", "Calendar", "Show what's playing above the notifications", false),

	// ---- Windows
	"animation-speed":    n(1.0, 0, 3, 0.25, "Animation Speed", "Windows", "Animations", "1 is normal, 0 turns animations off", false),
	"open-animation":     choice("scale", []string{"scale", "fade", "slide", "none"}, []string{"Grow", "Fade", "Slide Up", "None"}, "Opening Windows", "Windows", "Animations", "How new windows appear", false),
	"close-animation":    choice("scale", []string{"scale", "fade", "none"}, []string{"Shrink", "Fade", "None"}, "Closing Windows", "Windows", "Animations", "How windows disappear", false),
	"minimize-animation": choice("dock", []string{"dock", "fade", "none"}, []string{"Into the Dock", "Fade", "None"}, "Minimizing", "Windows", "Animations", "How minimized windows leave", false),
	"wobbly-windows":     b(false, "Wobbly Windows", "Windows", "Animations", "Windows wobble like jelly while you drag them", false),
	"wobbly-strength":    n(0.5, 0.1, 1, 0.05, "Wobble Amount", "Windows", "Animations", "How far windows bend", true),
	"wobbly-friction":    n(0.25, 0.05, 0.9, 0.05, "Wobble Settling", "Windows", "Animations", "Higher settles faster", true),
	"focus-mode": gnome(choice("click", []string{"click", "sloppy", "mouse"}, []string{"Click", "Hover", "Hover (Strict)"},
		"Focus Windows By", "Windows", "Behavior", "Click a window, or just point at it", false), wmPrefs, "focus-mode", quoted),
	"titlebar-buttons": gnome(choice("appmenu:close", []string{"appmenu:close", "appmenu:minimize,maximize,close", "close,minimize,maximize:appmenu", "appmenu:minimize,close"},
		[]string{"Close Only", "All on the Right", "All on the Left", "Minimize and Close"}, "Titlebar Buttons", "Windows", "Behavior", "Which buttons windows show", false), wmPrefs, "button-layout", quoted),
	"double-click-titlebar": gnome(choice("toggle-maximize", []string{"toggle-maximize", "minimize", "none"}, []string{"Maximize", "Minimize", "Nothing"},
		"Double-Click Titlebar", "Windows", "Behavior", "What double-clicking a titlebar does", true), wmPrefs, "action-double-click-titlebar", quoted),
	"edge-tiling":          gnome(b(true, "Snap to Edges", "Windows", "Behavior", "Drag windows to a screen edge to fill half of it", false), mutter, "edge-tiling", nil),
	"center-new-windows":   gnome(b(false, "Center New Windows", "Windows", "Behavior", "Open windows in the middle of the screen", false), mutter, "center-new-windows", nil),
	"attach-modal-dialogs": gnome(b(false, "Attach Dialogs", "Windows", "Behavior", "Dialogs stick to their parent window", true), mutter, "attach-modal-dialogs", nil),
	"dynamic-workspaces":   gnome(b(true, "Dynamic Workspaces", "Windows", "Workspaces", "Add and remove workspaces automatically", false), mutter, "dynamic-workspaces", nil),
	"workspace-count": gnome(n(4, 1, 12, 1, "Number of Workspaces", "Windows", "Workspaces", "Used when workspaces aren't dynamic", false), wmPrefs, "num-workspaces",
		func(v any) string { return strconv.Itoa(int(v.(float64))) }),
	"workspaces-only-on-primary": gnome(b(true, "Workspaces on Main Screen Only", "Windows", "Workspaces", "Other screens show the same windows on every workspace", true), mutter, "workspaces-only-on-primary", nil),

	// ---- Tiling
	"tiling-mode": choice("off", []string{"off", "dwindle", "scrolling"}, []string{"Off (Floating)", "Hyprland-Style (Dwindle)", "Niri-Style (Scrolling Columns)"},
		"Tiling", "Tiling", "Layout", "Arrange windows automatically", false),
	"tiling-new-windows":  choice("tiled", []string{"tiled", "floating"}, []string{"Tiled", "Floating"}, "New Windows", "Tiling", "Layout", "Super+T moves a window in or out of the layout", false),
	"tiling-gap":          n(8, 0, 48, 2, "Gap Between Windows", "Tiling", "Layout", "Pixels between tiled windows", false),
	"tiling-outer-gap":    n(12, 0, 64, 2, "Gap at Screen Edges", "Tiling", "Layout", "Pixels between windows and the screen edge", true),
	"tiling-split-ratio":  n(0.5, 0.2, 0.8, 0.05, "Split Ratio", "Tiling", "Dwindle", "How much room the first window of each split gets", true),
	"tiling-column-width": n(0.5, 0.25, 1, 0.05, "Column Width", "Tiling", "Scrolling", "Share of the screen each column takes", true),

	// ---- Accessibility
	"screen-reader": gnome(b(false, "Screen Reader", a11yPage, "Seeing", "Orca reads the screen aloud (Super+Alt+S)", false), a11yApps, "screen-reader-enabled", nil),
	"high-contrast": gnome(b(false, "High Contrast", a11yPage, "Seeing", "Stronger colors and outlines in the shell and apps", false), a11yIface, "high-contrast", nil),
	"large-text": gnome(b(false, "Large Text", a11yPage, "Seeing", "Bigger text in the shell and apps", false), iface, "text-scaling-factor",
		func(v any) string {
			if v == true {
				return "1.25"
			}
			return "1.0"
		}),
	"cursor-size": gnome(choice("24", []string{"24", "32", "48", "64", "96"}, []string{"Default", "Medium", "Large", "Larger", "Largest"},
		"Cursor Size", a11yPage, "Seeing", "How big the pointer is", false), iface, "cursor-size", func(v any) string { return fmt.Sprint(v) }),
	"reduce-motion": gnome(b(false, "Reduce Motion", a11yPage, "Seeing", "Turn off animations and wobbling", false), iface, "enable-animations",
		func(v any) string {
			if v == true {
				return gnomeFalse
			}
			return "true"
		}),
	"visual-alerts":  gnome(b(false, "Visual Alerts", a11yPage, "Hearing", "Flash the screen when an alert sound plays", false), wmPrefs, "visual-bell", nil),
	"sticky-keys":    gnome(b(false, "Sticky Keys", a11yPage, "Typing", "Press shortcuts one key at a time", false), a11yKeys, "stickykeys-enable", nil),
	"slow-keys":      gnome(b(false, "Slow Keys", a11yPage, "Typing", "Keys must be held a moment before they count", false), a11yKeys, "slowkeys-enable", nil),
	"bounce-keys":    gnome(b(false, "Bounce Keys", a11yPage, "Typing", "Ignore fast repeated presses of the same key", false), a11yKeys, "bouncekeys-enable", nil),
	"mouse-keys":     gnome(b(false, "Mouse Keys", a11yPage, "Pointing", "Move the pointer with the number pad", false), a11yKeys, "mousekeys-enable", nil),
	"focus-outlines": b(true, "Focus Outlines", a11yPage, "Typing", "Highlight what the keyboard is on in shell menus (Tab, arrows, Enter)", true),

	// ---- Behavior
	"alt-tab-mode":              choice("apps", []string{"apps", "windows"}, []string{"Apps", "Windows"}, "Alt+Tab Switches", "Behavior", "Switching", "Between apps or between every window", false),
	"alt-tab-current-workspace": b(true, "Current Workspace Only", "Behavior", "Switching", "Alt+Tab only shows this workspace", true),
	"do-not-disturb":            b(false, "Do Not Disturb", "Behavior", "Notifications", "Hide banners (they still go in the list)", false),
	"notification-position":     choice("top-center", []string{"top-center", "top-right"}, []string{"Top Center", "Top Right"}, "Banner Position", "Behavior", "Notifications", "Where notification banners appear", true),
	"idle-delay":                n(5.0, 0, 120, 1, "Blank Screen After", "Behavior", "Screen", "Minutes without input (0 = never)", false),
	"lock-on-idle":              b(true, "Lock When Blank", "Behavior", "Screen", "Ask for your password after the screen blanks", false),
	"keyboard-layouts": {Kind: StringList, Default: []string{"us"}, Title: "Keyboard Layouts", Page: "Behavior", Group: "Keyboard",
		Help: "xkb names separated by commas (us, de, us+dvorak); Super+Space switches"},
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
	mu       sync.Mutex
	path     string
	values   map[string]any
	defaults map[string]any // system-wide defaults (/etc/xdg/cali/cali.toml)
}

// Open loads path (a missing file means all defaults). Unknown or invalid
// entries are skipped so a bad line never breaks the desktop.
func Open(path string) (*Store, error) {
	values, err := ReadFile(path)
	if os.IsNotExist(err) {
		err = nil
	}
	if err != nil {
		return nil, err
	}
	return &Store{path: path, values: values, defaults: map[string]any{}}, nil
}

// ReadFile parses a settings file, skipping unknown or invalid entries.
func ReadFile(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]any{}, err
	}
	return ParseText(string(data)), nil
}

// ParseText parses settings in the file format, skipping unknown or invalid
// entries so a bad line never breaks the desktop.
func ParseText(text string) map[string]any {
	values := map[string]any{}
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		key, value, ok := parseLine(sc.Text())
		if !ok {
			continue
		}
		if v, err := Validate(key, value); err == nil {
			values[key] = v
		}
	}
	return values
}

// LoadDefaults reads system-wide defaults that replace the built-in ones,
// most important file first (the order of XDG_CONFIG_DIRS). Missing files
// are fine.
func (st *Store) LoadDefaults(paths ...string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	for i := len(paths) - 1; i >= 0; i-- {
		values, _ := ReadFile(paths[i])
		for k, v := range values {
			st.defaults[k] = v
		}
	}
}

// Export writes every setting that differs from the built-in defaults, in
// the settings file format, so a whole setup can be shared or restored.
func (st *Store) Export() string {
	var b strings.Builder
	b.WriteString("# Cali setup, exported by Cali Settings. Import it in Cali Settings or with `calictl import`.\n")
	for _, k := range Keys() {
		v, _ := st.Get(k)
		if fmt.Sprint(v) != fmt.Sprint(Schema[k].Default) {
			fmt.Fprintf(&b, "%s = %s\n", k, encode(v))
		}
	}
	return b.String()
}

// Get returns key's value, or its default.
func (st *Store) Get(key string) (any, bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if v, ok := st.values[key]; ok {
		return v, true
	}
	if v, ok := st.defaults[key]; ok {
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

// SchemaJSON describes every setting for Cali Settings, which builds its
// pages from it.
func SchemaJSON() string {
	type entry struct {
		Key      string   `json:"key"`
		Kind     string   `json:"kind"`
		Title    string   `json:"title"`
		Help     string   `json:"help"`
		Page     string   `json:"page"`
		Group    string   `json:"group"`
		Advanced bool     `json:"advanced"`
		Choices  []string `json:"choices,omitempty"`
		Labels   []string `json:"labels,omitempty"`
		Min      float64  `json:"min"`
		Max      float64  `json:"max"`
		Step     float64  `json:"step"`
	}
	kinds := map[Kind]string{Bool: "bool", String: "string", Number: "number", StringList: "list"}
	var out []entry
	for _, k := range Keys() {
		st := Schema[k]
		out = append(out, entry{k, kinds[st.Kind], st.Title, st.Help, st.Page, st.Group, st.Advanced, st.Choices, st.Labels, st.Min, st.Max, st.Step})
	}
	data, _ := json.Marshal(out)
	return string(data)
}

// GSettingsValue is key's value in gsettings syntax, if it maps to a GNOME setting.
func GSettingsValue(key string, value any) (schema, gkey, text string, ok bool) {
	st, found := Schema[key]
	if !found || st.GSchema == "" {
		return "", "", "", false
	}
	if st.GValue != nil {
		return st.GSchema, st.GKey, st.GValue(value), true
	}
	return st.GSchema, st.GKey, fmt.Sprint(value), true
}
