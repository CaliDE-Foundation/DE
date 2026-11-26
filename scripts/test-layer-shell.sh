#!/usr/bin/env bash
# Minimal visible layer-shell smoke test in the nested Devkit session.
set -euo pipefail

export XDG_RUNTIME_DIR=/tmp/cali-runtime
export WAYLAND_DISPLAY=wayland-0
test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" || {
  echo "Run this inside the running CALI Devkit container." >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/config.jsonc" <<'EOF'
{
  "layer": "overlay",
  "position": "bottom",
  "height": 40,
  "exclusive": true,
  "modules-center": ["clock"],
  "clock": { "format": "Layer Shell test - {:%H:%M:%S}", "interval": 1 }
}
EOF

cat > "$tmp/style.css" <<'EOF'
window#waybar {
  background: #ff0044;
  color: white;
}
#clock { padding: 0 12px; }
EOF

wayland-info | grep zwlr_layer_shell || {
  echo "Layer Shell not advertised by the nested compositor." >&2
  exit 1
}
waybar -c "$tmp/config.jsonc" -s "$tmp/style.css" -l info
