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

## What's new in 2.0

- **New panel.** Click the menu bar icon for live level meters, boost, effects, equalizer, per-app levels and settings.
- **Sound effects:** Loudness (compressor), Voice Clarity, Auto-Level, Virtual Bass, Mono, stereo Width and Balance.
- **10-band equalizer** with Bass Boost, Treble Boost, Vocal and Loudness Curve presets, or your own curve.
- **Per-app mixer.** Give any app its own level from 0% (muted) to 300%.
- **Volume keys past 100%.** At full volume, Volume Up raises the boost, with an on-screen level display. Turn it on in Settings (needs Accessibility permission).
- **Remembers each output.** Speakers, headphones and AirPods keep their own boost; new headphones start at 100%.
- **Scroll** over the menu bar icon to change the boost; **right-click** to turn Amplify on or off.

After updating, macOS may ask for System Audio Recording permission again, because the app isn't notarized.
