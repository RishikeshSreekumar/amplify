cask "amplify" do
  version "2.0"
  sha256 "7801bd2510257fb8b8c494a9b5d9d1fde1ff976eaf60ba2872869532b7d70a84"

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
