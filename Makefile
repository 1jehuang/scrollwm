# ScrollWM convenience targets. The scripts are the source of truth; these are
# just short aliases. Run `make help` for the list.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0-dev)

.PHONY: help build test install update sandbox release release-publish notary-setup clean

help:
	@echo "ScrollWM make targets (version $(VERSION)):"
	@echo "  make build           swift build (debug)"
	@echo "  make test            unit + animation + headless integration + 5 fuzzers + state-space"
	@echo "                       (never spawns/moves real windows or steals focus)"
	@echo "  make install         build + install ScrollWM.app to ~/Applications"
	@echo "  make update          rebuild, reinstall in place, relaunch"
	@echo "  make sandbox         live test on disposable windows (safe)"
	@echo "  make notary-setup    one-time Developer ID / notarization setup"
	@echo "  make release         build + sign + notarize + cask (no upload)"
	@echo "  make release-publish build + sign + notarize + cask + GitHub release"
	@echo "  make clean           remove build + dist artifacts"

build:
	swift build

test: build
	.build/debug/WindowLab unittest
	.build/debug/WindowLab animtest
	.build/debug/WindowLab headlesstest
	.build/debug/WindowLab fuzz 1 --seeds 60 --steps 300 --iters 1500
	.build/debug/WindowLab fuzzmodel 1 --seeds 40 --steps 300
	.build/debug/WindowLab fuzzctrl 1 --iters 1500
	.build/debug/WindowLab fuzzdisp 1
	.build/debug/WindowLab fuzzconc 1 --seeds 6 --steps 120
	.build/debug/WindowLab statespace --max-visited 20000 --max-depth 12 --max-windows 4

install:
	./scripts/install.sh

update:
	./scripts/update.sh

sandbox: build
	.build/debug/WindowLab sandbox 4

notary-setup:
	./scripts/setup-developer-id.sh

release:
	./scripts/release.sh $(VERSION)

release-publish:
	./scripts/release.sh $(VERSION) --publish

clean:
	rm -rf .build dist
