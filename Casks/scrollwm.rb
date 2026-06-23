cask "scrollwm" do
  version "0.1.0"
  sha256 "8bcd9344e7765d0d0206f7f4817018f5de423ad04a84b17de512af891ed94ae7"

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
