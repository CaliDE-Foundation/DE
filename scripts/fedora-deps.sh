#!/usr/bin/env bash
# Installs everything needed to build and run CaliDE with Sookie on Fedora 45.
# Used by scripts/Containerfile (make container) and by GitHub Actions.
set -euo pipefail

ZIG_VERSION=0.13.0

# mutter-devel pulls in the development files for every library Sookie links
# against (GLib, Clutter's deps, Wayland, libinput, ...). Sookie replaces
# Mutter's own files when its tarball is extracted over /.
dnf install -y --setopt=install_weak_deps=False \
  mutter-devel \
  cargo rust golang gcc \
  make curl tar xz git findutils \
  dbus-daemon dbus-tools

if [ ! -x /opt/zig/zig ]; then
  curl -fL --retry 3 -o /tmp/zig.tar.xz \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
  mkdir -p /opt/zig
  tar -C /opt/zig --strip-components=1 -xJf /tmp/zig.tar.xz
  rm /tmp/zig.tar.xz
fi
ln -sf /opt/zig/zig /usr/local/bin/zig

dnf clean all
zig version

# Desktop pieces for `make devkit`: the devkit window (GTK4, libadwaita),
# PipeWire for its picture, Mesa for rendering, a test app, and the GTK4 /
# libadwaita headers for building Cali Settings.
if [ "${1:-}" = "--desktop" ]; then
  dnf install -y --setopt=install_weak_deps=False \
    gtk4 libadwaita libei pipewire wireplumber \
    mesa-dri-drivers mesa-libEGL mesa-vulkan-drivers \
    adwaita-sans-fonts adwaita-icon-theme gnome-text-editor \
    gtk4-devel libadwaita-devel \
    xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk dconf \
    python3-gobject
  dnf clean all
fi
