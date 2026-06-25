cask "scrollwm" do
  version "0.1.2"
  sha256 "215943c534ba22042b078f88d18343c920615955a96148d94cb316f1e034ce41"

  url "https://github.com/1jehuang/scrollwm/releases/download/v#{version}/ScrollWM-#{version}.zip"
  name "ScrollWM"
  desc "Scrolling (PaperWM-style) window manager for macOS"
  homepage "https://github.com/1jehuang/scrollwm"

  depends_on macos: ">= :sonoma"

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
