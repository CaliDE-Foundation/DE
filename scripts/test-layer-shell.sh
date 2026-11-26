#!/usr/bin/env bash
# Minimal visible layer-shell smoke test in the nested Devkit session.
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/cali-runtime}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
case "$WAYLAND_DISPLAY" in
  /*) socket="$WAYLAND_DISPLAY" ;;
  *) socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ;;
esac
test -S "$socket" || {
  echo "Run this inside the running CALI Devkit container." >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CALI_LAYER_TEST_DIR="$tmp"
printf '0\n' > "$tmp/clicks"
cat > "$tmp/click.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n=$(cat "$CALI_LAYER_TEST_DIR/clicks")
printf '%s\n' "$((n + 1))" > "$CALI_LAYER_TEST_DIR/clicks"
EOF

cat > "$tmp/config.jsonc" <<'EOF'
{
  "layer": "overlay",
  "position": "bottom",
  "height": 40,
  "exclusive": true,
  "modules-center": [
    "clock",
    "custom/click"
  ],
  "clock": {
    "format": "Layer Shell test - {:%H:%M:%S}",
    "interval": 1,
    "tooltip": true,
    "tooltip-format": "Popup test: {:%H:%M:%S}"
  },
  "custom/click": {
    "exec": "cat \"$CALI_LAYER_TEST_DIR/clicks\"",
    "format": "Click me: {}",
    "on-click": "bash \"$CALI_LAYER_TEST_DIR/click.sh\"",
    "interval": 1,
    "exec-on-event": true,
    "tooltip": false
  }
}
EOF

cat > "$tmp/style.css" <<'EOF'
window#waybar {
  background: #ff0044;
  color: white;
}
#clock, #custom-click { padding: 0 12px; }
#custom-click { background: #242424; }
tooltip { background-color: #242424; color: white; }
tooltip label { color: white; padding: 8px; }
EOF

wayland-info | grep zwlr_layer_shell || {
  echo "Layer Shell not advertised by the nested compositor." >&2
  exit 1
}
waybar -c "$tmp/config.jsonc" -s "$tmp/style.css" -l info
