cask "amplify" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RishikeshSreekumar/amplify/releases/download/v#{version}/Amplify-#{version}.zip"
  name "Amplify"
  desc "Menu bar app to boost system-wide volume past 100%"
  homepage "https://github.com/RishikeshSreekumar/amplify"

  # Core Audio process taps need macOS 14.2 or later.
  depends_on macos: :sonoma

  app "Amplify.app"

  # The app is ad-hoc signed (not notarized), so clear the quarantine flag
  # to let it launch without a Gatekeeper prompt.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Amplify.app"]
  end

  uninstall quit: "work.mando.amplify"

  zap trash: "~/Library/Preferences/work.mando.amplify.plist"
end
