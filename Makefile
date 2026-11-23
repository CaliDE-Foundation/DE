# CaliDE top-level build. It runs gently: low priority and 2 jobs by default.
JOBS  ?= 2
NICE  ?= nice -n 19
OUT   := out/bin

# Prebuilt Sookie, published by Sookie's CI for every green build of main.
SOOKIE_URL   ?= https://github.com/CaliDE-Foundation/Sookie/releases/download/nightly/sookie-x86_64.tar.xz
SOOKIE_ROOT  := $(abspath out/sookie/root)
SOOKIE_PC    := $(SOOKIE_ROOT)/usr/lib64/pkgconfig

# Container for building and running with Sookie on non-Fedora hosts.
PODMAN       ?= podman
DEV_IMAGE    ?= localhost/calide-dev:fedora45

.PHONY: all shell settings-app compositor compositor-sookie services sookie sookie-fetch \
        test run smoke-sookie container-image container devkit install uninstall clean

all: compositor services

shell:
	$(NICE) cargo build --release -j $(JOBS)

# Cali Settings (GTK 4 + libadwaita); needs their development files.
settings-app:
	mkdir -p $(OUT)
	$(NICE) cargo build --release -j $(JOBS) -p cali-settings
	cp $${CARGO_TARGET_DIR:-target}/release/cali-settings $(OUT)/

compositor: shell
	cd compositor && $(NICE) zig build -j$(JOBS) --prefix ../out

services:
	mkdir -p $(OUT)
	cd services && GOFLAGS=-p=$(JOBS) $(NICE) go build -o ../$(OUT)/ ./cmd/...

# ---- Sookie -----------------------------------------------------------------

# Download the latest Sookie build into out/sookie/root. Its pkg-config files
# are rewritten to point there, so the compositor can link against it.
# The build targets Fedora 45; on other distros use `make container`.
sookie-fetch:
	mkdir -p out/sookie
	curl -fL --retry 3 -o out/sookie/sookie-x86_64.tar.xz $(SOOKIE_URL)
	curl -fsL --retry 3 -o out/sookie/commit $(dir $(SOOKIE_URL))sookie-x86_64.commit
	rm -rf $(SOOKIE_ROOT) && mkdir -p $(SOOKIE_ROOT)
	tar -C $(SOOKIE_ROOT) -xJf out/sookie/sookie-x86_64.tar.xz
	sed -i 's|^prefix=/usr$$|prefix=$(SOOKIE_ROOT)/usr|' $(SOOKIE_PC)/*.pc
	@echo "Sookie $$(cut -c1-9 out/sookie/commit) is in $(SOOKIE_ROOT)"

# Build cali-compositor linked against Sookie. Uses out/sookie/root when it
# exists, otherwise a system-wide Sookie install.
compositor-sookie: shell
	cd compositor && PKG_CONFIG_PATH=$(SOOKIE_PC)$${PKG_CONFIG_PATH:+:$$PKG_CONFIG_PATH} \
	  $(NICE) zig build -j$(JOBS) -Dsookie=true --prefix ../out

# Start the Sookie build headless for a few seconds. Needs Sookie installed
# system-wide (it loads its plugins from /usr), so run it inside `make container`.
smoke-sookie: compositor-sookie
	scripts/smoke-sookie.sh $(OUT)/cali-compositor

# Build Sookie from the submodule with Meson (needs Sookie's dependencies).
sookie:
	[ -d sookie/_build ] || meson setup sookie/_build sookie --prefix=$(abspath out/sookie-local) -Dtests=disabled
	$(NICE) ninja -C sookie/_build -j $(JOBS)

# ---- Fedora 45 container (podman) -------------------------------------------

container-image:
	$(PODMAN) build -t $(DEV_IMAGE) -f scripts/Containerfile .

# Inside Fedora 45: install the latest Sookie over /, build everything with
# Sookie and run the headless smoke test. Uses separate output folders so
# host builds aren't mixed with container builds.
CONTAINER_RUN = $(PODMAN) run --rm -v $(CURDIR):/src:Z \
	  -e CARGO_TARGET_DIR=/src/out/container/target \
	  -e ZIG_LOCAL_CACHE_DIR=/src/out/container/zig-cache \
	  -e GOMODCACHE=/src/out/container/gomod -e GOCACHE=/src/out/container/gocache

container: container-image
	$(CONTAINER_RUN) $(DEV_IMAGE) bash -c '\
	    set -e; scripts/container-sookie.sh; \
	    make JOBS=$(JOBS) OUT=out/container/bin compositor-sookie-container services smoke-sookie-container'

# Open Cali in a window on your desktop (Sookie's devkit) and start an app
# inside it. Close the window or press Ctrl+C to stop.
# Pick apps with CALI_APP, separated by ";", e.g. CALI_APP="gnome-text-editor;gnome-text-editor --new-window".
# CALI_DEBUG_OVERVIEW=<seconds> opens the overview after that many seconds.
HOST_WAYLAND := $(if $(filter /%,$(WAYLAND_DISPLAY)),$(WAYLAND_DISPLAY),$(XDG_RUNTIME_DIR)/$(WAYLAND_DISPLAY))
CALI_APP     ?= gnome-text-editor
PODMAN_TTY   ?= -it

devkit: container-image
	@test -S "$(HOST_WAYLAND)" || { echo "devkit: run this from a Wayland session"; exit 1; }
	$(CONTAINER_RUN) $(PODMAN_TTY) --device /dev/dri \
	  -v $(HOST_WAYLAND):/run/host-wayland.sock \
	  -e WAYLAND_DISPLAY=/run/host-wayland.sock \
	  -e CALI_APP="$(CALI_APP)" -e CALI_DEBUG_OVERVIEW -e CALI_DEBUG_OVERVIEW_PICK -e CALI_DEBUG_WORKSPACES -e CALI_DEBUG_MENU -e CALI_DOCK_FAVORITES -e CALI_DEBUG_APPS -e CALI_DEBUG_SEARCH -e CALI_DEBUG_CALENDAR -e CALI_DEBUG_SWITCHER -e CALI_DEBUG_NOTIFY -e CALI_DEBUG_OSD -e CALI_DEBUG_MINIMIZE -e CALI_DEBUG_CALICTL -e CALI_DEBUG_LOCK -e CALI_DEBUG_UNLOCK -e CALI_DEBUG_SCREENSHOT -e CALI_DEBUG_TILE -e CALI_STATUS_FAKE -e CALI_DEBUG_PICKER -e CALI_DEBUG_APPMENU -e CALI_DEBUG_SECOND_MONITOR -e CALI_DEVKIT_ARGS -e CALI_DEBUG_WOBBLE -e CALI_DEBUG_WOBBLE_FREEZE -e CALI_DEBUG_AUTOSTART -e CALI_DEBUG_FOCUS -e CALI_APP_LATE -e CALI_SETTINGS_PAGE -e CALI_SETTINGS_ADVANCED -e CALI_STATUS_FAKE_ART -e CALI_STATUS_FAKE_APP -e CALI_STATUS_FAKE_TITLE -e CALI_STATUS_FAKE_ARTIST -e CALI_STATUS_FAKE_ICON -e CALI_STATUS_FAKE_LENGTH -e CALI_STATUS_FAKE_POSITION \
	  $(DEV_IMAGE) bash -c '\
	    set -e; scripts/container-sookie.sh; \
	    make JOBS=$(JOBS) compositor-sookie-container; \
	    make JOBS=$(JOBS) OUT=out/container/bin services settings-app; \
	    scripts/install-settings-app.sh; \
	    trap "trap - TERM INT; kill -TERM 0" TERM INT; \
	    scripts/devkit.sh out/container/bin/cali-compositor & wait $$!'

# Container-only helpers: same as above, with container output folders.
compositor-sookie-container:
	cargo build --release -j $(JOBS)
	cd compositor && $(NICE) zig build -j$(JOBS) -Dsookie=true \
	  -Dshell-lib=$$CARGO_TARGET_DIR/release/libcali_shell.a --prefix ../out/container
smoke-sookie-container:
	scripts/smoke-sookie.sh out/container/bin/cali-compositor

# ---- Installing ---------------------------------------------------------------
# For packages: make compositor-sookie services settings-app &&
#   make install PREFIX=/usr DESTDIR=$pkgdir
# The Go services must sit next to cali-compositor (it starts them from there).
PREFIX     ?= /usr/local
SYSCONFDIR ?= /etc
BINDIR     := $(DESTDIR)$(PREFIX)/bin
DATADIR    := $(DESTDIR)$(PREFIX)/share
BINARIES   := cali-compositor cali-settingsd cali-statusd cali-notifyd cali-extd calictl

install:
	@for b in $(BINARIES); do test -x $(OUT)/$$b || { echo "install: $(OUT)/$$b missing; run make compositor-sookie services first"; exit 1; }; done
	install -d $(BINDIR)
	for b in $(BINARIES); do install -m755 $(OUT)/$$b $(BINDIR)/; done
	[ ! -x $(OUT)/cali-settings ] || install -m755 $(OUT)/cali-settings $(BINDIR)/
	install -m755 scripts/cali-session $(BINDIR)/
	install -Dm644 data/cali.desktop $(DATADIR)/wayland-sessions/cali.desktop
	install -Dm644 data/10_calide.gschema.override $(DATADIR)/glib-2.0/schemas/10_calide.gschema.override
	install -Dm644 data/cali-portals.conf $(DATADIR)/xdg-desktop-portal/cali-portals.conf
	install -Dm644 data/pam/cali-lock $(DESTDIR)$(SYSCONFDIR)/pam.d/cali-lock
	install -Dm644 data/org.calide.Settings.desktop $(DATADIR)/applications/org.calide.Settings.desktop
	install -Dm644 data/icons/org.calide.Settings.svg $(DATADIR)/icons/hicolor/scalable/apps/org.calide.Settings.svg
	cd data/extensions && for f in $$(find . -type f); do \
	  install -Dm$$(test -x $$f && echo 755 || echo 644) $$f $(DATADIR)/cali/extensions/$$f; done
	[ -n "$(DESTDIR)" ] || glib-compile-schemas $(DATADIR)/glib-2.0/schemas

uninstall:
	for b in $(BINARIES) cali-settings cali-session; do rm -f $(BINDIR)/$$b; done
	rm -f $(DATADIR)/wayland-sessions/cali.desktop $(DATADIR)/glib-2.0/schemas/10_calide.gschema.override \
	  $(DATADIR)/xdg-desktop-portal/cali-portals.conf $(DESTDIR)$(SYSCONFDIR)/pam.d/cali-lock \
	  $(DATADIR)/applications/org.calide.Settings.desktop $(DATADIR)/icons/hicolor/scalable/apps/org.calide.Settings.svg
	cd data/extensions && for f in $$(find . -type f); do rm -f $(DATADIR)/cali/extensions/$$f; done
	-cd data/extensions && for d in $$(find . -mindepth 1 -type d); do rmdir $(DATADIR)/cali/extensions/$$d; done
	-rmdir $(DATADIR)/cali/extensions $(DATADIR)/cali

# ---- Checks -----------------------------------------------------------------

test:
	$(NICE) cargo test -j $(JOBS)
	cd services && $(NICE) go vet ./... && go test ./...

# Smoke test: run every program so all three languages are exercised.
run: all
	@echo "== Zig compositor -> Rust shell"
	./$(OUT)/cali-compositor
	@echo "== Go CLI"
	./$(OUT)/calictl version
	./$(OUT)/calictl config-path

clean:
	cargo clean
	rm -rf out compositor/.zig-cache compositor/zig-out
