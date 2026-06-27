#!/bin/bash
# Build and install ScrollWM.app to ~/Applications (or a path you pass).
#
# Safe by design:
#   - builds release binary from this repo
#   - assembles a proper .app bundle via scripts/make-bundle.sh
#   - installs to ~/Applications by default (no sudo, no system files touched)
#   - never auto-launches; never touches windows until you click Arrange
#
# Usage:
#   ./scripts/install.sh                   # arm64, install to ~/Applications
#   ./scripts/install.sh /Applications     # install system-wide (may need perms)
#   ./scripts/install.sh --universal       # build a universal (Intel+ARM) bundle
#   ./scripts/install.sh --universal /Applications
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=signing-lib.sh
source "$REPO_DIR/scripts/signing-lib.sh"
VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo 0.0.0-dev)"

UNIVERSAL=0
DEST_DIR=""
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        *) DEST_DIR="$arg" ;;
    esac
done
DEST_DIR="${DEST_DIR:-$HOME/Applications}"
APP="$DEST_DIR/ScrollWM.app"

cd "$REPO_DIR"
if [[ "$UNIVERSAL" == "1" ]]; then
    echo "==> building universal release binary (arm64 + x86_64)"
    swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WindowLab"
else
    echo "==> building release binary"
    swift build -c release 2>&1 | tail -1
    BIN="$(swift build -c release --show-bin-path)/WindowLab"
fi
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }

# Pick the best available signing identity (Developer ID > self-signed > ad-hoc;
# see scripts/signing-lib.sh). A stable identity keeps the Accessibility grant
# across updates; a Developer ID identity additionally produces a notarizable,
# hardened-runtime bundle. Override with SCROLLWM_SIGN_ID=... if you must.
SIGN_ID="$(scrollwm_detect_identity)"
SIGN_NOTE="$(scrollwm_identity_note "$SIGN_ID")"

echo "==> assembling + signing bundle ($SIGN_NOTE)"
mkdir -p "$DEST_DIR"
"$REPO_DIR/scripts/make-bundle.sh" "$APP" "$BIN" "$SIGN_ID" "$VERSION"

echo "==> verifying"
"$APP/Contents/MacOS/ScrollWM" help >/dev/null && echo "    binary runs"

# Ensure $1 is on PATH for bash, zsh and fish so `scrollwm` works in a fresh
# terminal no matter which shell the user runs. Idempotent (re-runnable) and a
# no-op for standard locations every shell already includes (Homebrew etc.), so
# we only edit shell rc files when we fell back to a personal bin dir. We never
# CREATE ~/.bash_profile when it's absent (doing so would shadow ~/.profile);
# we only append to it if it already exists.
scrollwm_ensure_path() {
    local dir="$1"
    case "$dir" in
        /opt/homebrew/bin|/usr/local/bin|/usr/bin|/bin|/usr/sbin|/sbin)
            return 0 ;;   # already on the default PATH for every shell
    esac

    local begin="# >>> ScrollWM CLI (added by installer) >>>"
    local end="# <<< ScrollWM CLI <<<"

    # POSIX-style shells: zsh + bash. The runtime guard avoids duplicating the
    # entry if the dir is somehow already on PATH; the begin-marker grep avoids
    # appending the block twice across re-installs.
    local rcs=("$HOME/.zshrc" "$HOME/.bashrc")
    [[ -e "$HOME/.bash_profile" ]] && rcs+=("$HOME/.bash_profile")
    local rc
    for rc in "${rcs[@]}"; do
        if [[ -e "$rc" ]] && grep -qF "$begin" "$rc" 2>/dev/null; then continue; fi
        {
            printf '\n%s\n' "$begin"
            printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$dir" "$dir"
            printf '%s\n' "$end"
        } >> "$rc"
        echo "    ensured PATH in $rc"
    done

    # fish: conf.d/*.fish is auto-sourced; overwrite is naturally idempotent.
    local fishconf="$HOME/.config/fish/conf.d/scrollwm.fish"
    mkdir -p "$(dirname "$fishconf")"
    cat > "$fishconf" <<FISH
$begin
if test -d $dir
    fish_add_path $dir
end
$end
FISH
    echo "    ensured PATH in $fishconf"
    echo "    open a new terminal (or source your shell rc) to pick up 'scrollwm'."
}

# Put `scrollwm` on PATH so you can drive the running app from a shell
# (scrollwm arrange / focus / width / status ...). The bundle's main executable
# dispatches any subcommand, so the symlink target is that binary. Pick the
# first user-writable bin dir on PATH; fall back to ~/.local/bin.
echo "==> installing 'scrollwm' CLI on PATH"
CLI_TARGET="$APP/Contents/MacOS/ScrollWM"
CLI_LINK=""
for d in "/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin" "$HOME/bin"; do
    if [[ -d "$d" && -w "$d" ]]; then CLI_LINK="$d/scrollwm"; break; fi
done
if [[ -z "$CLI_LINK" ]]; then
    mkdir -p "$HOME/.local/bin"; CLI_LINK="$HOME/.local/bin/scrollwm"
fi
ln -sf "$CLI_TARGET" "$CLI_LINK"
echo "    linked $CLI_LINK -> ScrollWM.app"
# Wire that dir onto PATH for bash, zsh and fish (no-op for standard dirs).
scrollwm_ensure_path "$(dirname "$CLI_LINK")"

cat <<DONE

Installed: $APP  (v$VERSION)

First run:
  1. open "$APP"      (menu-bar icon appears; nothing is touched yet)
  2. ScrollWM opens System Settings to Privacy & Security -> Accessibility.
     Flip the ScrollWM switch ON -- its one and only permission.
  3. It continues automatically (no relaunch) and arranges your current
     windows. After that it's dormant until you Arrange again
     (menu-bar icon -> "Arrange Windows into Strip", or run: scrollwm arrange).
  (Already granted on a prior install? It skips all this and starts silently.)

Controls (also in the in-app tutorial):
  ctrl+opt+left/right   focus previous/next column
  ctrl+opt+1..9         jump to column N
  opt+1/2/3/4           focused column width 25/50/75/100%
  cmd+shift+h / cmd+shift+l   move focused column left/right
  cmd+q                 close focused window
  ctrl+opt+esc          toggle arrange/release
  menu -> Release       restore all windows to original positions
  menu -> Quit          also restores everything

CLI (drive the running app from a shell):
  scrollwm arrange | release | toggle
  scrollwm focus <next|prev|N> | move <left|right> | width <25|50|75|100>
  scrollwm status            # JSON snapshot of the strip
  scrollwm --help            # full list

Note: $SIGN_NOTE.
DONE
