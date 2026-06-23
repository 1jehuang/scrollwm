#!/bin/bash
# Regenerate the Homebrew cask (Casks/scrollwm.rb) for the current VERSION,
# pointing at that version's release zip and embedding its SHA-256.
#
# Run after scripts/package-release.sh (it reads dist/ScrollWM-<ver>.zip), or in
# CI right before publishing. Users install with:
#   brew tap 1jehuang/scrollwm https://github.com/1jehuang/scrollwm
#   brew install --cask scrollwm
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$REPO_DIR/VERSION")}"
ZIP="$REPO_DIR/dist/ScrollWM-$VERSION.zip"
CASK_DIR="$REPO_DIR/Casks"
CASK="$CASK_DIR/scrollwm.rb"

[[ -f "$ZIP" ]] || { echo "missing $ZIP; run scripts/package-release.sh first" >&2; exit 1; }
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

mkdir -p "$CASK_DIR"
cat > "$CASK" <<RUBY
cask "scrollwm" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/1jehuang/scrollwm/releases/download/v#{version}/ScrollWM-#{version}.zip"
  name "ScrollWM"
  desc "Scrolling (PaperWM-style) window manager for macOS"
  homepage "https://github.com/1jehuang/scrollwm"

  depends_on macos: ">= :sonoma"

  app "ScrollWM.app"

  # The app is ad-hoc signed (not notarized); strip quarantine so it opens
  # without the Gatekeeper block. Homebrew also does this for casks by default.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ScrollWM.app"],
                   sudo: false
  end

  uninstall quit: "dev.scrollwm.app"

  zap trash: [
    "~/Library/Application Support/ScrollWM",
    "~/Library/Application Support/ScrollWM-Sandbox",
  ]
end
RUBY

echo "wrote $CASK (version $VERSION, sha256 $SHA)"
