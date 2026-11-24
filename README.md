<div align="center">

# Cali

A desktop that feels like GNOME and lets you make it yours.

[![Build](https://github.com/CaliDE-Foundation/DE/actions/workflows/build.yml/badge.svg)](https://github.com/CaliDE-Foundation/DE/actions/workflows/build.yml)

<img src=".github/assets/devkit.png" width="640" alt="Cali running in a window">

</div>

## Build

```sh
git clone --recurse-submodules https://github.com/CaliDE-Foundation/DE
cd DE
make            # Zig, Rust and Go
make devkit     # run Cali in a window (podman)
```

Change settings with **Cali Settings** or `calictl set accent-color teal`; they apply right away.

Built on [Sookie](https://github.com/CaliDE-Foundation/Sookie). GPL-3.0-or-later.
