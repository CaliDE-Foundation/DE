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

.PHONY: all shell compositor compositor-sookie services sookie sookie-fetch \
        test run smoke-sookie container-image container clean

all: compositor services

shell:
	$(NICE) cargo build --release -j $(JOBS)

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
container: container-image
	$(PODMAN) run --rm -v $(CURDIR):/src:Z \
	  -e CARGO_TARGET_DIR=/src/out/container/target \
	  -e ZIG_LOCAL_CACHE_DIR=/src/out/container/zig-cache \
	  $(DEV_IMAGE) bash -c '\
	    set -e; \
	    curl -fL --retry 3 $(SOOKIE_URL) | tar -C / -xJ; \
	    make JOBS=$(JOBS) OUT=out/container/bin compositor-sookie-container services smoke-sookie-container'

# Container-only helpers: same as above, with container output folders.
compositor-sookie-container:
	cargo build --release -j $(JOBS)
	cd compositor && $(NICE) zig build -j$(JOBS) -Dsookie=true \
	  -Dshell-lib=$$CARGO_TARGET_DIR/release/libcali_shell.a --prefix ../out/container
smoke-sookie-container:
	scripts/smoke-sookie.sh out/container/bin/cali-compositor

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
