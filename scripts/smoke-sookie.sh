#!/usr/bin/env bash
# Starts cali-compositor with Sookie headless for a few seconds.
# Passes if the compositor is still running when the timer stops it.
set -uo pipefail

BIN=${1:-out/bin/cali-compositor}
SECONDS_TO_RUN=${SMOKE_SECONDS:-10}

runtime=$(mktemp -d)
chmod 700 "$runtime"
trap 'rm -rf "$runtime"' EXIT

echo "Running $BIN headless for ${SECONDS_TO_RUN}s..."
XDG_RUNTIME_DIR=$runtime dbus-run-session -- \
  timeout --signal=TERM "$SECONDS_TO_RUN" \
  "$BIN" --wayland --headless --no-x11 --virtual-monitor 1280x720
rc=$?

if [ "$rc" -eq 124 ]; then
  echo "ok: Sookie started and kept running"
  exit 0
fi
echo "failed: cali-compositor exited early with status $rc"
exit 1
