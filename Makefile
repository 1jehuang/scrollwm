# ScrollWM convenience targets. The scripts are the source of truth; these are
# just short aliases. Run `make help` for the list.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0-dev)

.PHONY: help build test install update sandbox release release-publish notary-setup clean

help:
	@echo "ScrollWM make targets (version $(VERSION)):"
	@echo "  make build           swift build (debug)"
	@echo "  make test            unit + animation tests (no AX needed)"
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
