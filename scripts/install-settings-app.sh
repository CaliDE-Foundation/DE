#!/usr/bin/env bash
# Inside the container: make the freshly built Cali Settings launchable from
# the dock, app grid and system menu (desktop file and icon in /usr/share).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
bin="${1:-$here/out/container/bin/cali-settings}"

[ -x "$bin" ] || { echo "install-settings-app: $bin not built"; exit 0; }
sed "s|^Exec=.*|Exec=$bin|" "$here/data/org.calide.Settings.desktop" \
  > /usr/share/applications/org.calide.Settings.desktop
install -Dm644 "$here/data/icons/org.calide.Settings.svg" \
  /usr/share/icons/hicolor/scalable/apps/org.calide.Settings.svg
