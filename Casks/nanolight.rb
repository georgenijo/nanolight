cask "nanolight" do
  version "0.2.11"
  sha256 "04023d4e4a40dbeaf2c99c8aca3e6473d2babd75d31197384dc3258b79abd9d2"

  url "https://github.com/justrach/nanolight/releases/download/v#{version}/nanolight-macos-arm64.dmg"
  name "Nanolight"
  desc "Keyboard launcher for apps, math, search and Raycast extensions"
  homepage "https://github.com/justrach/nanolight"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself; brew only installs it the first time.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Nanolight.app"
end
