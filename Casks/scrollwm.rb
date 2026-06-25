cask "scrollwm" do
  version "0.1.3"
  sha256 "f421388493d71ae9a9d26f054c2c0e45053b019fa3cbb967bd4e5f4d4133f075"

  url "https://github.com/1jehuang/scrollwm/releases/download/v#{version}/ScrollWM-#{version}.zip"
  name "ScrollWM"
  desc "Scrolling (PaperWM-style) window manager for macOS"
  homepage "https://github.com/1jehuang/scrollwm"

  depends_on macos: ">= :sonoma"

  # ScrollWM has an in-app updater, but it deliberately DEFERS to Homebrew when
  # it detects a Caskroom install (see UpdateCoordinator.presentHomebrewManaged):
  # it never clobbers a brew-managed bundle, it tells the user to run
  # `brew upgrade --cask scrollwm` instead. So Homebrew must own updates here ->
  # auto_updates stays false (the default) so `brew outdated`/`brew upgrade`
  # actually see and apply new versions. Setting it true would make brew skip the
  # cask (upgraded only with --greedy), stranding cask users on a stale build.
  auto_updates false

  app "ScrollWM.app"

  # Expose the `scrollwm` CLI on PATH. The bundle's main executable dispatches
  # any subcommand, so this is the same entry point the app uses. Homebrew
  # creates this symlink on install and removes it on uninstall.
  binary "#{appdir}/ScrollWM.app/Contents/MacOS/ScrollWM", target: "scrollwm"

  # Homebrew quarantines downloaded cask apps by DEFAULT. This build is
  # ad-hoc/self-signed (not notarized), so that quarantine would trip the
  # Gatekeeper "unidentified developer" block. Strip it post-install so the app
  # opens normally (equivalent to right-click -> Open once). A notarized build
  # would not need this; update-cask.sh omits this block when it detects a
  # stapled bundle.
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
