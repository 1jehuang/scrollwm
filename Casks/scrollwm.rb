cask "scrollwm" do
  version "0.2.0"
  sha256 "5c1e06888be8098a2b4926cb937ecd6d9cc0a3b80548833de994d15503559581"

  url "https://github.com/1jehuang/scrollwm/releases/download/v#{version}/ScrollWM-#{version}.zip"
  name "ScrollWM"
  desc "Scrolling (PaperWM-style) window manager for macOS"
  homepage "https://github.com/1jehuang/scrollwm"

  depends_on macos: ">= :sonoma"

  # ScrollWM updates itself in place (in-app updater, see Updater.swift), so
  # tell Homebrew not to flag it outdated or clobber a self-updated bundle.
  auto_updates true

  app "ScrollWM.app"

  # Expose the `scrollwm` CLI on PATH. The bundle's main executable dispatches
  # any subcommand, so this is the same entry point the app uses.
  binary "#{appdir}/ScrollWM.app/Contents/MacOS/ScrollWM", target: "scrollwm"

  # The app is ad-hoc/self-signed (not notarized); strip quarantine so it
  # opens without the Gatekeeper block. Homebrew also does this for casks.
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
