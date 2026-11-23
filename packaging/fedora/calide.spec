# Cali desktop for Fedora. Needs the sookie package (built from
# https://github.com/CaliDE-Foundation/Sookie the same way as Fedora's
# mutter package) and Zig 0.13 at build time.
Name:           calide
Version:        0.1.0
Release:        1%{?dist}
Summary:        A desktop that feels like GNOME and lets you make it yours
License:        GPL-3.0-or-later
URL:            https://github.com/CaliDE-Foundation/DE
Source0:        %{url}/archive/refs/heads/main.tar.gz#/DE-main.tar.gz

BuildRequires:  cargo rust go make gcc pkgconfig(libsookie-52)
BuildRequires:  pkgconfig(gtk4) pkgconfig(libadwaita-1)
Requires:       sookie dbus-daemon pam pipewire wireplumber
Requires:       xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk
Recommends:     NetworkManager bluez upower

%description
Cali is a Linux desktop environment that keeps GNOME's simplicity, smooth
animations and workflow, and adds the customization GNOME leaves out. It runs
on Sookie, a fork of GNOME's Mutter.

%prep
%autosetup -n DE-main

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
%{_datadir}/applications/org.calide.Settings.desktop
%{_datadir}/icons/hicolor/scalable/apps/org.calide.Settings.svg
%config(noreplace) %{_sysconfdir}/pam.d/cali-lock

%changelog
* Sun Nov 22 2026 CaliDE Foundation - 0.1.0-1
- First package
