# Homebrew cask template. Lives in a tap (e.g. <owner>/homebrew-tap) once
# the repository is public; the release workflow's DMG URL + sha256 fill in
# per release.
cask "overture" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/omerburakpolat/overture/releases/download/v#{version}/Overture-#{version}.dmg"
  name "Overture"
  desc "Kanban harness for Claude Code — cards are agent sessions that move themselves"
  homepage "https://github.com/omerburakpolat/overture"

  auto_updates true # Sparkle
  depends_on macos: ">= :tahoe"

  app "Overture.app"

  zap trash: [
    "~/Library/Application Support/Overture",
  ]
end
