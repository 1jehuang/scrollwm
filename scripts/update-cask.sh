#!/bin/bash
# Regenerate the Homebrew cask (Casks/scrollwm.rb) for the current VERSION,
# pointing at that version's release zip and embedding its SHA-256.
#
# Run after scripts/package-release.sh (it reads dist/ScrollWM-<ver>.zip), or in
# CI right before publishing. Users install with:
#   brew tap 1jehuang/scrollwm https://github.com/1jehuang/scrollwm
#   brew install --cask scrollwm
#
# Notarization-aware: if dist/ScrollWM.app is notarized + stapled (built with a
# Developer ID cert and run through scripts/notarize.sh), the emitted cask drops
# the quarantine-stripping postflight - a notarized app opens with no Gatekeeper
# warning, so the xattr hack is unnecessary (and undesirable). Otherwise the
# cask keeps stripping quarantine so ad-hoc/self-signed downloads still open.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$REPO_DIR/VERSION")}"
ZIP="$REPO_DIR/dist/ScrollWM-$VERSION.zip"
APP="$REPO_DIR/dist/ScrollWM.app"
CASK_DIR="$REPO_DIR/Casks"
CASK="$CASK_DIR/scrollwm.rb"

[[ -f "$ZIP" ]] || { echo "missing $ZIP; run scripts/package-release.sh first" >&2; exit 1; }
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# Detect a stapled (notarized) bundle so we can omit the quarantine workaround.
NOTARIZED=0
if [[ -d "$APP" ]] && xcrun stapler validate "$APP" >/dev/null 2>&1; then
    NOTARIZED=1
fi

if [[ "$NOTARIZED" == "1" ]]; then
    GATEKEEPER_BLOCK="  # Notarized + stapled: opens with no Gatekeeper warning, no workaround needed."
else
    GATEKEEPER_BLOCK="  # The app is ad-hoc/self-signed (not notarized); strip quarantine so it
  # opens without the Gatekeeper block. Homebrew also does this for casks.
  postflight do
    system_command \"/usr/bin/xattr\",
                   args: [\"-dr\", \"com.apple.quarantine\", \"#{appdir}/ScrollWM.app\"],
                   sudo: false
  end"
fi

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

  # ScrollWM updates itself in place (in-app updater, see Updater.swift), so
  # tell Homebrew not to flag it outdated or clobber a self-updated bundle.
  auto_updates true

  app "ScrollWM.app"

  # Expose the \`scrollwm\` CLI on PATH. The bundle's main executable dispatches
  # any subcommand, so this is the same entry point the app uses.
  binary "#{appdir}/ScrollWM.app/Contents/MacOS/ScrollWM", target: "scrollwm"

$GATEKEEPER_BLOCK

  uninstall quit: "dev.scrollwm.app"

  zap trash: [
    "~/Library/Application Support/ScrollWM",
    "~/Library/Application Support/ScrollWM-Sandbox",
  ]
end
RUBY

echo "wrote $CASK (version $VERSION, sha256 $SHA, notarized=$NOTARIZED)"
