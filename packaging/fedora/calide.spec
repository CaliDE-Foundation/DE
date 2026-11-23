# Cali desktop for Fedora, built from a source tarball of this repository
# (git archive --prefix=calide/ -o calide.tar.gz HEAD). Needs the sookie
# package (Sookie's packaging/fedora/sookie.spec) and Zig 0.13 on PATH at
# build time; scripts/fedora-deps.sh installs Zig. The build fetches crates
# and Go modules, so build with network access (rpmbuild, not mock).
%global debug_package %{nil}
%{!?commit: %global commit unknown}
Name:           calide
Version:        0.1.0
Release:        0.git%{commit}%{?dist}
Summary:        A desktop that feels like GNOME and lets you make it yours
License:        GPL-3.0-or-later
URL:            https://github.com/CaliDE-Foundation/DE
Source0:        calide.tar.gz

BuildRequires:  cargo rust go make gcc pkgconfig(libsookie-52)
BuildRequires:  pkgconfig(gtk4) pkgconfig(libadwaita-1)
Requires:       sookie dbus-daemon pam pipewire wireplumber
Requires:       xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk
Recommends:     NetworkManager bluez upower mate-polkit orca python3-gobject

%description
Cali is a Linux desktop environment that keeps GNOME's simplicity, smooth
animations and workflow, and adds the customization GNOME leaves out. It runs
on Sookie, a fork of GNOME's Mutter.

%prep
%autosetup -n calide

%build
make NICE= JOBS=%{_smp_build_ncpus} compositor-sookie services settings-app

%install
make install PREFIX=%{_prefix} SYSCONFDIR=%{_sysconfdir} DESTDIR=%{buildroot}

%files
%license LICENSE
%{_bindir}/cali-*
%{_bindir}/calictl
%{_datadir}/wayland-sessions/cali.desktop
%{_datadir}/glib-2.0/schemas/10_calide.gschema.override
%{_datadir}/xdg-desktop-portal/cali-portals.conf
%{_userunitdir}/cali-session.target
%{_datadir}/applications/org.calide.Settings.desktop
%{_datadir}/icons/hicolor/scalable/apps/org.calide.Settings.svg
%{_datadir}/cali/
%config(noreplace) %{_sysconfdir}/pam.d/cali-lock

%changelog
* Sun Nov 22 2026 CaliDE Foundation - 0.1.0-1
- First package
