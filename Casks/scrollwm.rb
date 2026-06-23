cask "scrollwm" do
  version "0.1.1"
  sha256 "ccdc60de6c82bbd67567d3214c183c81141eede1bc72be34c2eb713beb167b1f"

  url "https://github.com/1jehuang/scrollwm/releases/download/v#{version}/ScrollWM-#{version}.zip"
  name "ScrollWM"
  desc "Scrolling (PaperWM-style) window manager for macOS"
  homepage "https://github.com/1jehuang/scrollwm"

  depends_on macos: ">= :sonoma"

  app "ScrollWM.app"

  # Expose the  CLI on PATH. The bundle wrapper routes any subcommand
  # to the binary, so this is the same entry point the app uses.
  binary "#{appdir}/ScrollWM.app/Contents/MacOS/ScrollWM", target: "scrollwm"

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
