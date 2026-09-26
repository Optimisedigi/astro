cask "astro" do
  version "0.1.0"
  sha256 "83633c44f210f86da9b72180ad385b4d0e4e4c3b00424e55f2c5cb8cb56891fe"

  url "https://github.com/Optimisedigi/astro/releases/download/v#{version}/Astro.dmg"
  name "Astro"
  desc "Menu bar AI assistant with chat, voice, images, journal and reminders"
  homepage "https://github.com/Optimisedigi/astro"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Astro.app"

  uninstall quit: "com.universe.app"
end
