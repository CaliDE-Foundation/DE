#!/usr/bin/env bash
# Live negotiated xdg-decoration smoke test; run in a disposable Devkit.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/cali-runtime}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
case "$WAYLAND_DISPLAY" in
  /*) socket="$WAYLAND_DISPLAY" ;;
  *) socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ;;
esac
test -S "$socket" || { echo "Nested Wayland socket missing: $socket" >&2; exit 1; }
for command in wayland-info alacritty; do
  command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }
done
info=$(wayland-info)
if ! grep -q zxdg_decoration_manager_v1 <<< "$info"; then
  echo "Decoration protocol not advertised. Start Devkit with SOOKIE_EXPERIMENTAL_SSD=1." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/alacritty.toml" <<'EOF'
[window]
decorations = "Full"
title = "CALI SSD test"
dynamic_title = false
EOF
echo "Decoration global advertised. Opening a fresh Wayland Alacritty."
echo "Check one title bar, drag, resize, double-click, maximize/restore,"
echo "minimize/restore, then close using the native close button."
echo "Do not enter passwords in this disposable test window."
echo "Negotiated mode will be reported here after the test window closes."

status=0
WAYLAND_DEBUG=client WINIT_UNIX_BACKEND=wayland alacritty --config-file "$tmp/alacritty.toml" 2>"$tmp/wayland.log" || status=$?
echo
grep -E 'zxdg_toplevel_decoration_v1#[0-9]+\.configure\(' "$tmp/wayland.log" || true
if (( status != 0 )); then
  echo "FAIL: Alacritty exited with status $status." >&2
  grep -iE 'error|failed|panic' "$tmp/wayland.log" | tail -n 12 >&2 || true
  exit "$status"
fi
if grep -Eq 'zxdg_toplevel_decoration_v1#[0-9]+\.configure\(2\)' "$tmp/wayland.log"; then
  echo "PASS: server-side decoration negotiation (mode 2)."
elif grep -Eq 'zxdg_toplevel_decoration_v1#[0-9]+\.configure\(1\)' "$tmp/wayland.log"; then
  echo "CSD selected (mode 1): native SSD not negotiated for this client."
  exit 2
else
  echo "INCONCLUSIVE: no decoration configure event captured." >&2
  exit 3
fi
echo "Visual geometry and control behavior still require your observation."
