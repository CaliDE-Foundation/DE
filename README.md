<div align="center">

<img src=".github/assets/cali.svg" width="120" alt="Cali logo">

# Cali

**A desktop that feels like GNOME and lets you make it yours.**

[![Build](https://github.com/CaliDE-Foundation/DE/actions/workflows/build.yml/badge.svg)](https://github.com/CaliDE-Foundation/DE/actions/workflows/build.yml)
[![License: GPL v3+](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
![Wayland](https://img.shields.io/badge/Wayland-%2B%20Xwayland-ff8a5b.svg)
![Zig](https://img.shields.io/badge/Zig-0.13-f7a41d.svg?logo=zig&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-stable-b7410e.svg?logo=rust&logoColor=white)
![Go](https://img.shields.io/badge/Go-1.22%2B-00add8.svg?logo=go&logoColor=white)

[Why Cali](#why-cali) · [Architecture](#architecture) · [Building](#building) · [Roadmap](#roadmap) · [Sookie](https://github.com/CaliDE-Foundation/Sookie)

</div>

---

**CaliDE** is a Linux desktop environment for Wayland (with Xwayland), with an X11
session to follow. It keeps what people love about modern GNOME: the simplicity, the
visual consistency, the smooth animations and the intuitive workflow. It removes the
limits on customization and workflow.

Cali doesn't reinvent the Linux desktop. It improves one you already know. If you're
coming from GNOME you'll feel at home right away, with no navigation, window management
or desktop interactions to relearn.

## Why Cali

| | |
|---|---|
| 🏡 **Familiar from minute one** | The same workflow GNOME users already know: Activities, workspaces, the top bar |
| 🎛️ **Your desktop, your rules** | Settings that GNOME hides, removes or leaves to fragile extensions are built in |
| ✨ **Smooth by default** | Built on [Sookie](https://github.com/CaliDE-Foundation/Sookie), our fork of Mutter, the compositor behind GNOME's fluid animations |
| 🧱 **Independent** | Our own shell and our own compositor fork, developed in the open |

## Architecture

```
┌──────────────────────── cali-compositor (Zig) ────────────────────────┐
│  libsookie (C)   ◄── C ABI ──   Zig glue   ── C ABI ──►   cali-shell  │
│  Mutter fork:                   plugin,                    (Rust)     │
│  KMS, input, Wayland,           session,                   top bar,   │
│  Xwayland, animations           events                     overview…  │
└───────────────────────────────────────────────────────────────────────┘
              ▲ D-Bus (org.calide.*)
   cali-settingsd (Go)  ◄──  calictl (Go)
```

| Path | Language | What it is |
|---|---|---|
| [`compositor/`](compositor) | Zig | `cali-compositor`, the session process. It links Sookie and loads the shell |
| [`shell/`](shell) | Rust | `cali-shell`: top bar, overview, launcher, notifications, quick settings |
| [`services/`](services) | Go | `cali-settingsd` (settings daemon) and `calictl` (command-line tool) |
| [`sookie/`](https://github.com/CaliDE-Foundation/Sookie) | C, Zig | Submodule: the Sookie compositor |
| [`docs/`](docs) | | [Architecture notes](docs/architecture.md) |

## Building

You need **Zig 0.13**, **Rust** (stable) and **Go 1.22+**. Sookie also needs **Meson**
and **Ninja**.

```sh
git clone --recurse-submodules https://github.com/CaliDE-Foundation/DE CaliDE
cd CaliDE

make          # build all programs into out/bin/
make test     # Rust tests, go vet, go test
make run      # run each program: Zig → Rust, then Go
make sookie   # build the Sookie compositor
```

Expected output from `make run`:

```
== Zig compositor -> Rust shell
cali-compositor 0.1.0 (shell 0.1.0)
== Go CLI
calictl 0.1.0
/home/you/.config/cali/cali.toml
```

> [!TIP]
> Builds run with low priority and 2 jobs by default. Use `make JOBS=8` on a machine with better cooling.

### With Sookie

`cali-compositor` starts the real compositor when it's built against Sookie. Sookie's CI
publishes every build of `main` as a
[nightly release](https://github.com/CaliDE-Foundation/Sookie/releases/tag/nightly),
so you don't have to compile it yourself.

```sh
make sookie-fetch        # download the latest Sookie into out/sookie/root
make compositor-sookie   # link cali-compositor against it (needs Sookie's libraries)
make container           # any distro: build and test it all in Fedora 45 with podman
```

`make container` installs the nightly Sookie inside a Fedora 45 container, builds
everything against it, then starts Cali headless for a few seconds to check that it runs.
Container builds go to `out/container/`.

Every push and pull request is also built by
[GitHub Actions](https://github.com/CaliDE-Foundation/DE/actions/workflows/build.yml).
Download the `calide-x86_64` artifact from any run.

## Roadmap

- [x] Project layout: Zig compositor, Rust shell, Go services
- [x] Zig ↔ Rust C ABI working
- [x] `cali-compositor` starts Sookie (headless, tested in CI)
- [ ] Nested Wayland session in a window (`--devkit`)
- [ ] Shell basics at GNOME parity: top bar, Activities overview, app grid
- [ ] `cali-settingsd` on D-Bus, `calictl get/set`
- [ ] The customization layer, the reason Cali exists
- [ ] Native X11 session

> [!NOTE]
> Cali is in early development and isn't ready for daily use yet.

## Contributing

Issues and pull requests are welcome. Compositor-level changes go to
[Sookie](https://github.com/CaliDE-Foundation/Sookie). Shell, services and session
changes go here.

## License

Cali is free software under the **GNU General Public License, version 3 or later**.
See [LICENSE](LICENSE). Sookie is licensed separately under GPL-2.0-or-later.

Cali is an independent project and is not affiliated with or endorsed by GNOME.
