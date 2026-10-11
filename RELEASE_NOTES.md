## Install

**Homebrew (recommended)**

```sh
brew install --cask rishikeshsreekumar/tap/amplify
```

**Manual:** download `Amplify-{{VERSION}}.dmg` below, open it and drag Amplify to Applications.

The first time you open it, macOS may say it can't verify the app (it isn't notarized yet). Go to **System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Amplify.app
```

The first time you turn boost on, allow **System Audio Recording** when macOS asks.

Needs macOS 14.2 or later. Runs natively on Apple Silicon and Intel.

## What's in it

- Boost all system audio from 100% to 300% from the menu bar
- Live slider plus presets (125%, 150%, 200%, 250%, 300%)
- Peak limiter to avoid harsh clipping
- Follows your default output device (headphones, AirPods, displays)
- No drivers or kernel extensions: uses Core Audio process taps
- Audio returns to normal instantly if the app quits or crashes
- Open at Login
