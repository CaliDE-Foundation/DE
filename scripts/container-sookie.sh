#!/usr/bin/env bash
# Inside the Fedora 45 container: install the latest Sookie nightly over /.
set -euo pipefail
URL=${SOOKIE_URL:-https://github.com/CaliDE-Foundation/Sookie/releases/download/nightly}

curl -fL --retry 3 "$URL/sookie-x86_64.tar.xz" | tar -C / -xJ
# Cali's defaults for Sookie's settings (e.g. dynamic workspaces).
data="$(dirname "$0")/../data"
cp "$data/10_calide.gschema.override" /usr/share/glib-2.0/schemas/
# Portals for XDG_CURRENT_DESKTOP=Cali, and the lock screen's PAM service.
install -Dm644 "$data/cali-portals.conf" /usr/share/xdg-desktop-portal/cali-portals.conf
install -Dm644 "$data/pam/cali-lock" /etc/pam.d/cali-lock
glib-compile-schemas /usr/share/glib-2.0/schemas 2>&1 | grep -v "are deprecated" || true
echo "Sookie $(curl -fsL "$URL/sookie-x86_64.commit" | cut -c1-9) installed"
