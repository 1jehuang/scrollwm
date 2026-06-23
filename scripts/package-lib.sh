# shellcheck shell=bash
# package-lib.sh - shared release-artifact packaging, sourced by other scripts.
#
# `scrollwm_package_artifacts <dist-dir> <app-path> <version>` produces, in the
# given dist dir:
#   ScrollWM-<version>.zip   ditto zip of the bundle (curl installer / brew)
#   ScrollWM-<version>.dmg   drag-to-Applications disk image
#   SHA256SUMS.txt           checksums for the two artifacts
#
# It is idempotent: re-running overwrites the artifacts. notarize.sh calls it a
# SECOND time after stapling so the published zip/dmg contain the stapled ticket
# (a stapled app opens offline with no Gatekeeper warning).
#
# Defining-only; sourcing has no side effects.

scrollwm_package_artifacts() {
    local dist="$1" app="$2" version="$3"
    local zip="$dist/ScrollWM-$version.zip"
    local dmg="$dist/ScrollWM-$version.dmg"

    [[ -d "$app" ]] || { echo "package: app not found: $app" >&2; return 1; }

    echo "==> zipping -> $(basename "$zip")"
    rm -f "$zip"
    # ditto preserves the bundle's signature/metadata correctly (unlike plain zip).
    ( cd "$dist" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$app")" "$zip" )

    echo "==> building dmg -> $(basename "$dmg")"
    rm -f "$dmg"
    local stage
    stage="$(mktemp -d)"
    cp -R "$app" "$stage/ScrollWM.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "ScrollWM" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
    rm -rf "$stage"
    echo "    wrote $(basename "$dmg")"

    echo "==> checksums"
    ( cd "$dist" && shasum -a 256 "ScrollWM-$version.zip" "ScrollWM-$version.dmg" | tee SHA256SUMS.txt )
}
