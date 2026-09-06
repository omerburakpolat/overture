# Source of truth for the Homebrew cask. The published copy lives in
# github.com/omerburakpolat/homebrew-tap at Casks/overture.rb — a release
# is not finished until version + sha256 are updated there too
# (docs/RELEASING.md). Verified with `brew style` and `brew audit --cask`.
cask "overture" do
  version "0.1.0"
  sha256 "7d275fabe49e68f786458e05408e8bfd69ea14546f85bdac4c9115de84b0b2b1"

  url "https://github.com/omerburakpolat/overture/releases/download/v#{version}/Overture-#{version}.dmg"
  name "Overture"
  desc "Kanban harness for Claude Code — cards are agent sessions that move themselves"
  homepage "https://github.com/omerburakpolat/overture"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true # Sparkle
  # The binary is arm64-only (verified with `lipo -archs`). Without this,
  # brew would happily install an app that cannot launch on an Intel Mac.
  depends_on arch: :arm64
  depends_on macos: :tahoe # MACOSX_DEPLOYMENT_TARGET = 26.0

  app "Overture.app"

  zap trash: [
    "~/Library/Application Support/Overture",
    "~/Library/Caches/dev.overture.Overture",
    "~/Library/HTTPStorages/dev.overture.Overture",
    "~/Library/Preferences/dev.overture.Overture.plist",
    "~/Library/Saved Application State/dev.overture.Overture.savedState",
  ]

  caveats <<~EOS
    Overture drives your own Claude Code CLI with your own login. Install and
    sign in to it first:

      claude auth login

    Overture never bundles, redistributes, or proxies Claude Code or your
    credentials.
  EOS
end
