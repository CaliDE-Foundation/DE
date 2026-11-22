# CaliDE top-level build. It runs gently: low priority and 2 jobs by default.
JOBS  ?= 2
NICE  ?= nice -n 19
OUT   := out/bin

.PHONY: all shell compositor services sookie test run clean

all: compositor services

shell:
	$(NICE) cargo build --release -j $(JOBS)

compositor: shell
	cd compositor && $(NICE) zig build -j$(JOBS) --prefix ../out

services:
	mkdir -p $(OUT)
	cd services && GOFLAGS=-p=$(JOBS) $(NICE) go build -o ../$(OUT)/ ./cmd/...

sookie:
	[ -d sookie/_build ] || meson setup sookie/_build sookie --prefix=$(abspath out/sookie) -Dtests=disabled
	$(NICE) ninja -C sookie/_build -j $(JOBS)

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
