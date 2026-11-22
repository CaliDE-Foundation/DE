# CaliDE architecture

```
 ┌──────────────────────────── cali-compositor (Zig) ────────────────────────────┐
 │                                                                               │
 │   libsookie (C, Mutter fork)  ◄── C ABI ──  Zig glue  ── C ABI ──►  cali-shell │
 │   KMS, libinput, Wayland,                  MetaPlugin,              (Rust      │
 │   Xwayland, window mgmt,                   session setup,           staticlib) │
 │   Clutter/Cogl scene graph                 signal routing                     │
 └───────────────────────────────────────────────────────────────────────────────┘
                 ▲ D-Bus (org.calide.*)
                 │
   cali-settingsd (Go) ── reads/writes ~/.config/cali/   ◄──  calictl (Go CLI)
```

## Components

### Sookie (`sookie/`, C + Zig)
Our Mutter fork. It stays close to upstream so we can keep rebasing, and it carries
Cali's changes: extra window-management hooks, configurable behavior that upstream
hard-codes, and animation tweaks. New code in Sookie is written in Zig where it fits,
compiled to C-ABI objects and linked through Meson.

### cali-compositor (`compositor/`, Zig)
The session process. It links libsookie and registers a MetaPlugin (the job the GNOME
Shell process does for Mutter). It loads `cali-shell` and passes compositor events
across a small, stable C ABI declared in `shell/include/cali_shell.h`.

### cali-shell (`shell/`, Rust)
All the user-facing shell UI and logic: top bar, Activities overview, app grid,
notifications, quick settings and extensions. It is built as a `staticlib`, and only
the C ABI is public.

### Services (`services/`, Go)
- `cali-settingsd`: owns Cali's configuration and exposes it on D-Bus as `org.calide.Settings`.
- `calictl`: a CLI for scripting and debugging the desktop.

## Order of work
1. Wayland session: Sookie runs nested, then on KMS. Xwayland works for X11 apps.
2. Shell basics at GNOME parity: top bar, overview, launcher.
3. Customization layer, the reason Cali exists.
4. Native X11 session.
