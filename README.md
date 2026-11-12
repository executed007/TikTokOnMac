# TikTokOnMac

**An unofficial, native TikTok for Apple silicon Macs, built from your own decrypted IPA.**
Recording that works, a volume control, arrow-key scrolling, and your login kept across updates.

> Not affiliated with TikTok or ByteDance. This repository contains no TikTok code, icon or
> app: you bring your own decrypted `.ipa`, and the builder turns it into a Mac app.

TikTokOnMac is powered by **Catalyst Runner**, a general tool included here for running
iOS apps on Apple silicon Macs. Apple silicon Macs run iPhone code natively, and macOS
already ships the iOS frameworks. Catalyst Runner converts a decrypted iOS app so macOS treats it as a Mac app, signs it,
and adds a small helper library that fixes what iPhone apps get wrong on a Mac: the
camera, the window, the keyboard and the volume. No emulation, no virtual machine.

It is a small, readable reimplementation of the approach [PlayCover](https://github.com/PlayCover/PlayCover)
uses. [EVIDENCE.md](EVIDENCE.md) documents how PlayCover does it, with the evidence.

---

## Build TikTok for Mac

```bash
git clone https://github.com/executed007/TikTokOnMac.git
cd TikTokOnMac
./build-tiktok.sh ~/Downloads/TikTok.ipa
```

That builds TikTok into `/Applications/TikTok.app`, ready for Launchpad, Spotlight and the
Dock. To update, run the same command with a newer `.ipa`: your login and data are kept.

**What you get on top of plain sideloading**

| | |
|---|---|
| Camera | Recording works. Upright picture, true portrait framing (no squashed video), and no crash from macOS's own camera effects. |
| Feed | ↑ and ↓ move to the previous or next video. |
| Volume | A speaker button in the top-right corner opens a volume slider (or scroll over it). Also a Volume menu with ⌘↑, ⌘↓ and ⌘0 to mute. |
| Window | The title bar no longer covers the top of the app. |
| Privacy | The app runs in its own sandbox: it never asks for your Documents or Desktop, and camera and microphone answers are remembered. |
| Updates | Rebuild from a newer `.ipa` any time; data lives in `~/Library/Containers/com.zhiliaoapp.musically` and survives. |

**Tested with**

| | |
|---|---|
| TikTok | 47.7.0 (build 477034), bundle `com.zhiliaoapp.musically` |
| Built against | iOS SDK 27.1 (Xcode 27.1), minimum iOS 15.0 |
| Mac | macOS 26.6 on Apple silicon |

Newer TikTok versions usually work; if one doesn't, please open an issue with the version.

**Getting the `.ipa`.** It must be *decrypted*: App Store downloads are encrypted and the
builder refuses them. Use a copy you are entitled to use. This project does not provide one
and does not explain how to obtain one.

---

## Requirements

- A Mac with Apple silicon, macOS 14 or later
- Xcode Command Line Tools: `xcode-select --install`

## Catalyst Runner, the app

`./build.sh` runs the tests and builds `build/Catalyst Runner.app`. Drop any decrypted
`.ipa` on its window, or click **+**: it is converted, installed and launched.

- Click an app to run it. A green dot means it is running.
- The slider button on a card opens that app's settings.
- Right-click for **Add to Applications**, Show in Finder, app data and Uninstall.
- **Uninstall** keeps the app's data; **Uninstall and Delete Data** removes it for good.

### Per-app settings

Stored in `~/Library/Application Support/CatalystRunner/Settings/<bundle id>.plist`.

| Setting | Default | What it does |
|---|---|---|
| Volume | 100% | Scales everything the app plays. Applies immediately. |
| Show a volume button in the app | on | The speaker button and slider in the window's top-right corner |
| Hide the title bar | on | Hides the title strip and keeps content clear of the window buttons |
| Size at launch | app decides | Phone (430 × 932) or tablet (1024 × 768) |
| Arrow keys move through feeds | on | ↑ and ↓ page a full-screen swipe feed |
| Keep the picture upright | on | Ignores the app's camera rotation requests |
| Crop to a portrait frame | on | Hands the app the centre 9:16 strip of the Mac camera |
| Run in a sandbox | on | Own container, remembered permissions; changing it re-signs the app |

## Command line

```bash
./build/catalyst-runner install App.ipa --run         # or an .app folder
./build/catalyst-runner list
./build/catalyst-runner run com.example.app
./build/catalyst-runner export com.example.app        # copy into ~/Applications (--to <folder>)
./build/catalyst-runner uninstall com.example.app     # --delete-data to remove its data too
./build/catalyst-runner inspect App.app/App           # platform, minimum OS, encrypted?
```

## How it works

1. **Convert.** Every Mach-O in the app is thinned to arm64, checked for FairPlay
   encryption, and has its version load command replaced with
   `LC_BUILD_VERSION { platform: Mac Catalyst, minos 11.0, sdk 14.0 }`, exactly as
   PlayCover does ([Sources/MachO.swift](Sources/MachO.swift)).
2. **Patch.** The Info.plist opts out of macOS camera effects and gains a Mac icon built
   from the app's own icon; `RunnerShim.dylib` is added as a load command.
3. **Sign.** Every binary is signed ad hoc, innermost first, and the app gets App Sandbox
   entitlements ([Sources/Installer.swift](Sources/Installer.swift)).
4. **Help at runtime.** [Shim/RunnerShim.m](Shim/RunnerShim.m) loads inside the app. It
   hides the title bar, guards the camera calls that throw on macOS, crops and rotates
   camera frames, turns arrow keys into feed paging through an AppKit key monitor, and
   scales audio by wrapping the app's AudioUnit render callback and AudioQueue volume.
   The volume button lives in its own transparent window above the app, so the app
   cannot cover it and every other click passes straight through.

## Tests

```bash
./build.sh        # Mach-O conversion, camera crop, AudioQueue and AudioUnit volume
./test-live.sh    # builds a UIKit app, installs it, launches it sandboxed, reinstalls, uninstalls
```

## Limits

- Apple silicon only. Encrypted App Store apps are refused.
- No touch-to-keyboard mapping and no device spoofing, unlike PlayCover's PlayTools.
- Apps that need iOS frameworks macOS does not ship will not launch.
- Reinstalling re-signs an app, so macOS asks for camera and microphone again.

## Legal

Catalyst Runner is not affiliated with, endorsed by or connected to TikTok, ByteDance or
Apple. TikTok is a trademark of its owner. This repository contains no TikTok code, assets
or binaries. Apps you build with it are for your own use on your own Mac: do not share them.

Licensed under the [MIT License](LICENSE).
