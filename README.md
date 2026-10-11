<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <img src="assets/logo.png" alt="Amplify" width="560">
  </picture>
</p>

<p align="center">
  A tiny menu bar app that boosts your Mac's volume past 100%, for every app at once.
</p>

<p align="center">
  <a href="https://github.com/RishikeshSreekumar/amplify/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/RishikeshSreekumar/amplify"></a>
  <img alt="macOS 14.2+" src="https://img.shields.io/badge/macOS-14.2%2B-blue">
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-lightgrey">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

---

## Features

- **System-wide boost.** Makes everything louder: browser, Zoom, Music, games. Boost from 100% up to 300%.
- **Menu bar slider.** Drag to set the boost, or pick a preset (125%, 150%, 200%, 250%, 300%). The current level shows next to the icon.
- **Built-in limiter.** Loud peaks are held just under full scale, so cranking it up doesn't clip harshly.
- **Follows your output.** Switch to headphones, AirPods or a display and Amplify moves with you.
- **No drivers.** Uses Core Audio process taps (macOS 14.2+). No kernel extension, no virtual audio device.
- **Safe by design.** If Amplify quits or crashes, your Mac's audio goes straight back to normal.
- **Open at Login.** On by default, one click to turn off. Boost is restored if it was on when you quit.

## Install

### Homebrew (recommended)

```sh
brew install --cask rishikeshsreekumar/tap/amplify
```

Then open **Amplify** from Applications or Spotlight. Look for the speaker icon in your menu bar.

Update with `brew upgrade --cask amplify`.

### Download

1. Download **Amplify-x.y.dmg** from the [latest release](https://github.com/RishikeshSreekumar/amplify/releases/latest).
2. Open it and drag **Amplify** onto **Applications**.
3. Open Amplify from Applications.

> **"Amplify can't be opened" / "Apple could not verify…"?**
> Amplify isn't signed with a paid Apple Developer certificate yet, so macOS asks you to confirm the first time. Pick one:
>
> - Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Amplify. Then open it again.
> - Or run this once in Terminal:
>   ```sh
>   xattr -dr com.apple.quarantine /Applications/Amplify.app
>   ```
>
> Homebrew installs handle this for you.

### Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/RishikeshSreekumar/amplify.git
cd amplify
./build.sh --install
```

## Using it

Click the Amplify icon in the menu bar:

| Menu item | What it does |
|---|---|
| **Turn Boost On / Off** | Start or stop boosting |
| **Volume Boost** slider | 100% to 300%, in 5% steps. Changes apply live |
| **Presets → 125% … 300%** | Jump to a level and turn boost on |
| **Allow System Audio Recording…** | Shown only if the permission was denied; opens System Settings |
| **Open at Login** | Start Amplify when you log in |

The icon is **filled** with the boost level beside it while boosting, and **dimmed** when off. Your normal volume keys still work on top of the boost.

### Permission

The first time you turn boost on, macOS asks to let Amplify record **system audio**. Amplify needs this to capture what your Mac is playing before making it louder. Nothing is saved or sent anywhere.

If you clicked **Don't Allow**, turn Amplify on under **System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**.

Because Amplify is ad-hoc signed, macOS may ask again after an update.

## Things to know

- **Louder means less headroom.** Already-loud audio can't get much louder without distortion. The limiter keeps it clean-ish, but small laptop speakers will sound strained at high boost. Boost works best on quiet videos, calls and podcasts.
- **One output.** While boosting, all audio plays on your current default output device, even from apps set to use a different one.
- **Tiny delay.** Routing audio through Amplify adds a few milliseconds of latency.

## Uninstall

```sh
brew uninstall --cask amplify          # add --zap to also remove settings
```

Or quit Amplify from its menu and move it from Applications to the Bin.

## How it works

macOS caps every app at 100% volume. Amplify works around that with [Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), added in macOS 14.2:

1. A global **process tap** captures the mixed audio of every app (except Amplify itself) and mutes the originals while it's being read.
2. A private **aggregate device** combines that tap with your current output device.
3. Amplify's audio callback multiplies the captured samples by the boost, runs them through a peak limiter (instant attack, 250 ms release, -1 dBFS ceiling), and plays the result on your output.

The tap uses `mutedWhenTapped`, so the original audio is only muted while Amplify is actively reading it. If Amplify stops for any reason, sound returns at normal volume.

## Development

```sh
./build.sh                # build Amplify.app (universal binary)
./build.sh --install      # build, copy to /Applications and relaunch
swift assets/make_art.swift assets   # regenerate icon + logos
VERSION=1.1 ./release.sh  # package, publish GitHub release, update Homebrew tap
```

The menu bar UI is [`main.swift`](main.swift); the audio engine is [`AudioBooster.swift`](AudioBooster.swift). The icon and logo are drawn in code by [`assets/make_art.swift`](assets/make_art.swift).

## License

[MIT](LICENSE)
