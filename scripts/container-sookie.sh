#!/usr/bin/env bash
# Inside the Fedora 45 container: install the latest Sookie nightly over /.
set -euo pipefail
URL=${SOOKIE_URL:-https://github.com/CaliDE-Foundation/Sookie/releases/download/nightly}

curl -fL --retry 3 "$URL/sookie-x86_64.tar.xz" | tar -C / -xJ
glib-compile-schemas /usr/share/glib-2.0/schemas
echo "Sookie $(curl -fsL "$URL/sookie-x86_64.commit" | cut -c1-9) installed"
