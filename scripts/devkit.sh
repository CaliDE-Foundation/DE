#!/usr/bin/env bash
# Inside the container: open Cali in a window on the host desktop (Sookie's
# devkit), then start apps inside the nested session (CALI_APP, separated by ;).
#
# Expects the host Wayland socket in $WAYLAND_DISPLAY (an absolute path) and
# Sookie installed system-wide (scripts/container-sookie.sh).
set -euo pipefail

BIN=${1:-out/container/bin/cali-compositor}
APP=${CALI_APP:-gnome-text-editor}

export XDG_RUNTIME_DIR=/tmp/cali-runtime
rm -rf "$XDG_RUNTIME_DIR"
mkdir -m 700 -p "$XDG_RUNTIME_DIR"

if [ ! -S "$WAYLAND_DISPLAY" ]; then
  echo "devkit: host Wayland socket not found at $WAYLAND_DISPLAY" >&2
  exit 1
fi

# Everything below runs in a private D-Bus session. The devkit window receives
# the picture over PipeWire, so PipeWire and WirePlumber run inside it too.
exec dbus-run-session -- bash -c '
  set -u
  pipewire >/tmp/pipewire.log 2>&1 &
  wireplumber >/tmp/wireplumber.log 2>&1 &
  sleep 1

  # Start the apps once the nested compositor is accepting clients.
  (
    for _ in $(seq 100); do
      [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break
      sleep 0.2
    done
    sleep 1
    IFS=";" read -ra apps <<< "$1"
    for app in "${apps[@]}"; do
      echo "devkit: starting $app inside Cali"
      WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland $app >>/tmp/app.log 2>&1 &
      sleep 0.7
    done
    wait
  ) &

  exec "$0" --wayland --devkit --no-x11
' "$BIN" "$APP"
