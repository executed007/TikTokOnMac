# TikTokOnMac

**The full TikTok app, running natively on Apple silicon Macs.**
Built from your own TikTok IPA, with a Mac volume control and keyboard navigation.

> Unofficial. Not affiliated with TikTok or ByteDance. This repository contains no TikTok
> code, icon or app: you bring your own decrypted `.ipa`, and the builder turns it into a Mac app.

TikTokOnMac is powered by **Catalyst Runner**, a general tool, also included here, for running
iOS apps on Apple silicon Macs. These Macs run iPhone code natively and macOS already ships the
iOS frameworks, so there is no emulation and no virtual machine: TikTok runs at full speed in
its own Mac window.

---

## Why not just use tiktok.com?

TikTok in a browser is built for watching. TikTokOnMac runs the real TikTok app, so you get
everything the app does, including the things the website can't show or can't do:

| | TikTokOnMac | TikTok in a browser |
|---|:---:|:---:|
| Record with **filters, effects and stickers** | ✓ | ✗ |
| **Voice messages**: listen and send | ✓ | ✗ |
| **Shared comments** in chats | ✓ | ✗ |
| **Repost comments** | ✓ | ✗ |
| **Games, effects, cards and Photo Swap** in chats | ✓ | ✗ |
| **Shared feed** | ✓ | ✗ |
| **Streak pets** in conversations | ✓ | ✗ |
| **Go LIVE** from your camera, where your account can | ✓ | Needs separate streaming software |
| Watch, like, comment, follow, search | ✓ | ✓ |

In a browser, most of those chat items arrive as *"This message type isn't supported.
Download TikTok app to view this message."* Streak pets don't appear in the conversation at all.

Feature availability still depends on TikTok itself: your account, your region and the TikTok
version you build from.

## Features

| | |
|---|---|
| **Camera** | Record in portrait with your Mac's camera, with effects, filters and stickers. |
| **Volume** | A speaker button in the top-right corner opens a volume slider; scroll over it to adjust. The Volume menu has ⌘↑ louder, ⌘↓ quieter and ⌘0 mute. |
| **Keyboard** | ↑ and ↓ move to the previous and next video. |
| **A real Mac app** | Lives in `/Applications` with its own icon; open it from Launchpad, Spotlight or the Dock. Full-height layout with the window buttons tucked into the corner. |
| **Private by design** | Runs in its own sandbox, so it only sees its own files. Camera and microphone access is asked once and remembered. |
| **Easy updates** | Build again from a newer `.ipa` and carry on where you left off: your account and data stay in `~/Library/Containers/com.zhiliaoapp.musically`. |

---

## Install

### From Releases (no developer tools needed)

From the [Releases](../../releases) page, download:

- **TikTokOnMac Builder**: turns your TikTok `.ipa` into `/Applications/TikTok.app`.
- **Catalyst Runner** *(optional)*: the app for installing and managing any iOS app, with
  per-app settings such as volume.

Then:

```bash
unzip TikTokOnMac-Builder.zip
cd TikTokOnMac-Builder
./build-tiktok.sh ~/Downloads/TikTok.ipa
```

Both are signed ad hoc, not with an Apple Developer ID. The builder clears the download flag
on its own files. For Catalyst Runner, right-click the app and choose **Open** the first time.

### From source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/executed007/TikTokOnMac.git
cd TikTokOnMac
./build-tiktok.sh ~/Downloads/TikTok.ipa
```

### Your `.ipa`

The builder needs a **decrypted** TikTok `.ipa`; App Store downloads are encrypted and are
refused. Use a copy you are entitled to use. This project does not provide one and does not
explain how to obtain one.

### Tested with

| | |
|---|---|
| TikTok | 47.7.0 (build 477034), bundle `com.zhiliaoapp.musically` |
| Built against | iOS SDK 27.1 (Xcode 27.1), minimum iOS 15.0 |
| Mac | macOS 26.6 on Apple silicon |

To update TikTok, run the builder again with a newer `.ipa`. If a version doesn't work,
please open an issue with its version number.

## Requirements

- A Mac with Apple silicon (M1 or later), macOS 14 or later

---

## Catalyst Runner

Catalyst Runner installs and runs any decrypted iOS app. Drop an `.ipa` on its window, or
click **+**: it is converted, installed and launched.

- Click an app to run it. A green dot means it is running.
- The slider button on a card opens that app's settings.
- Right-click for **Add to Applications**, Show in Finder, the app's data and Uninstall.
- **Uninstall** keeps the app's data; **Uninstall and Delete Data** removes it for good.

### Per-app settings

Stored in `~/Library/Application Support/CatalystRunner/Settings/<bundle id>.plist`.

| Setting | Default | What it does |
|---|---|---|
| Volume | 100% | Level for everything the app plays. Applies immediately. |
| Show a volume button in the app | on | Speaker button and slider in the window's top-right corner |
| Hide the title bar | on | Full-height layout, window buttons in the corner |
| Size at launch | app decides | Phone (430 × 932) or tablet (1024 × 768) |
| Arrow keys move through feeds | on | ↑ and ↓ page a full-screen swipe feed |
| Keep the picture upright | on | Keeps the camera image level whatever the app asks for |
| Crop to a portrait frame | on | Gives the app a 9:16 portrait image from the Mac camera |
| Run in a sandbox | on | Own private container and remembered permissions |

### Command line

```bash
./build/catalyst-runner install App.ipa --run         # or an .app folder
./build/catalyst-runner list
./build/catalyst-runner run com.example.app
./build/catalyst-runner export com.example.app        # copy into ~/Applications (--to <folder>)
./build/catalyst-runner uninstall com.example.app     # --delete-data to remove its data too
./build/catalyst-runner inspect App.app/App           # platform, minimum OS, encrypted?
```

### How it works

1. **Convert.** Every Mach-O in the app is thinned to arm64, checked for FairPlay
   encryption, and has its version load command replaced with
   `LC_BUILD_VERSION { platform: Mac Catalyst, minos 11.0, sdk 14.0 }`, the same approach
   [PlayCover](https://github.com/PlayCover/PlayCover) uses ([Sources/MachO.swift](Sources/MachO.swift)).
   [EVIDENCE.md](EVIDENCE.md) documents how PlayCover does it.
2. **Prepare.** The app gets a Mac icon built from its own icon, Mac camera settings in its
   Info.plist, and `RunnerShim.dylib` as a load command.
3. **Sign.** Every binary is signed ad hoc, innermost first, and the app gets App Sandbox
   entitlements ([Sources/Installer.swift](Sources/Installer.swift)).
4. **Adapt at runtime.** [Shim/RunnerShim.m](Shim/RunnerShim.m) loads inside the app and
   fits it to the Mac: window layout, portrait camera framing, arrow-key navigation through
   an AppKit key monitor, and a volume control that scales the app's AudioUnit and
   AudioQueue output. The volume button sits in its own transparent window above the app,
   so every other click goes straight to the app.

### Tests

```bash
./build.sh        # Mach-O conversion, camera framing, AudioQueue and AudioUnit volume
./test-live.sh    # builds a UIKit app, installs it, launches it sandboxed, reinstalls, uninstalls
```

## Limits

- Apple silicon only. Encrypted App Store apps are refused.
- Rebuilding re-signs the app, so macOS confirms camera and microphone access again.
- No touch-to-keyboard mapping or device spoofing, unlike PlayCover's PlayTools.
- Apps that need iOS frameworks macOS does not ship will not launch.

## Legal

TikTokOnMac and Catalyst Runner are not affiliated with, endorsed by or connected to TikTok,
ByteDance or Apple. TikTok is a trademark of its owner. This repository contains no TikTok
code, assets or binaries. Apps you build with it are for your own use on your own Mac: do
not share them.

Licensed under the [MIT License](LICENSE).
