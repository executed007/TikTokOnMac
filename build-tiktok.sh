#!/bin/sh
# Builds TikTok as a native Mac app from a decrypted TikTok .ipa you supply.
#
#   ./build-tiktok.sh /path/to/TikTok.ipa [Applications folder]
#
# The app lands in /Applications (or the folder you pass) as TikTok.app. Your TikTok data
# lives in ~/Library/Containers/com.zhiliaoapp.musically and is kept across rebuilds, so
# running this again with a newer .ipa updates the app without logging you out.
set -eu
cd "$(dirname "$0")"

IPA="${1:-}"
DEST="${2:-/Applications}"
if [ -z "$IPA" ] || [ ! -f "$IPA" ]; then
    echo "usage: $0 /path/to/TikTok.ipa [Applications folder]" >&2
    exit 64
fi
if [ "$(uname -m)" != arm64 ]; then
    echo "TikTok for Mac needs a Mac with Apple silicon." >&2
    exit 1
fi

echo "== Building Catalyst Runner"
./build.sh > build/build.log 2>&1 || { cat build/build.log; exit 1; }

# Check the archive before doing any work: it must be TikTok, and it must be decrypted.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$IPA" 'Payload/*.app/Info.plist' -d "$WORK"
INFO="$(ls "$WORK"/Payload/*.app/Info.plist)"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
if [ "$ID" != com.zhiliaoapp.musically ]; then
    echo "This is $ID, not TikTok (com.zhiliaoapp.musically). For other apps use build/catalyst-runner install." >&2
    exit 1
fi
echo "== Found TikTok $VERSION ($BUILD)"

# Settings tuned for TikTok, written only if you have not chosen your own.
SETTINGS="$HOME/Library/Application Support/CatalystRunner/Settings/$ID.plist"
if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    cat > "$SETTINGS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>hideTitleBar</key><true/>
  <key>windowSize</key><string>default</string>
  <key>arrowKeysScrollFeed</key><true/>
  <key>lockCameraOrientation</key><true/>
  <key>cropCameraToPortrait</key><true/>
  <key>volume</key><real>1</real>
  <key>sandbox</key><true/>
</dict></plist>
EOF
fi

# Quit TikTok first: macOS will not open the new build while the old one is still running.
if pgrep -f 'TikTok\.app/TikTok$' > /dev/null; then
    echo "== Quitting TikTok"
    pkill -TERM -f 'TikTok\.app/TikTok$' || true
    for _ in $(seq 1 20); do pgrep -f 'TikTok\.app/TikTok$' > /dev/null || break; sleep 0.5; done
    pkill -KILL -f 'TikTok\.app/TikTok$' 2>/dev/null || true
fi
echo "== Converting (this takes a minute)"
./build/catalyst-runner install "$IPA" | grep -v '^Converting MachO' || exit 1
./build/catalyst-runner export "$ID" --to "$DEST"
echo
echo "Done. Open TikTok from $DEST, Launchpad or Spotlight."
echo "The first launch asks for camera and microphone access when you record."
