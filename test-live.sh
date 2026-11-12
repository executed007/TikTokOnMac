#!/bin/sh
# End-to-end test: package a UIKit app as an iOS .ipa, install it with catalyst-runner,
# then launch it and check that it stays up. Requires Apple silicon.
set -eu
cd "$(dirname "$0")"
[ -x build/catalyst-runner ] || ./build.sh
WORK="$(mktemp -d)"
trap 'pkill -f "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SDK="$(xcrun --show-sdk-path)"
APP="$WORK/Payload/Fixture.app"
mkdir -p "$APP"

echo "== Building the iOS fixture"
# The Command Line Tools ship no iPhoneOS SDK, so link against the Catalyst UIKit and
# then stamp the binary as a real iOS one (platform 2), which is what an .ipa contains.
swiftc -O -parse-as-library -target arm64-apple-ios14.0-macabi -sdk "$SDK" \
    -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift" \
    Tests/Fixture/App.swift -o "$WORK/Fixture.catalyst"
vtool -set-build-version ios 14.0 17.0 -replace -output "$APP/Fixture" "$WORK/Fixture.catalyst" 2>/dev/null
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.catalyst-runner.fixture</string>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundleName</key><string>Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>14.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
EOF
# A plain square icon, the way an .ipa ships one.
swift -e 'import AppKit; let i = NSImage(size: NSSize(width: 180, height: 180)); i.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 180, height: 180).fill(); i.unlockFocus(); try! NSBitmapImageRep(data: i.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))' "$APP/AppIcon60x60@3x.png" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" \
    -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" \
    -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60" "$APP/Info.plist"
(cd "$WORK" && zip -qr Fixture.ipa Payload)
echo "before: $(./build/catalyst-runner inspect "$APP/Fixture" | head -1)"

echo "== Installing"
./build/catalyst-runner install "$WORK/Fixture.ipa" --library "$WORK/Library"
INSTALLED="$WORK/Library/dev.catalyst-runner.fixture.app"
echo "after:  $(./build/catalyst-runner inspect "$INSTALLED/Fixture" | head -1)"
./build/catalyst-runner inspect "$INSTALLED/Fixture" | grep -q "Mac Catalyst"
codesign --verify --deep --strict "$INSTALLED"

echo "== Launching"
# The installed app is sandboxed, so it cannot write a marker outside its container.
# Instead, require the process to still be alive, with the helper library loaded, after 6 seconds.
open -n "$INSTALLED"
sleep 6
PID="$(pgrep -f "$INSTALLED/Fixture" | head -1)"
[ -n "$PID" ] || { echo "FAIL: the app is not running 6 seconds after launch"; exit 1; }
vmmap "$PID" 2>/dev/null | grep -q RunnerShim.dylib || { echo "FAIL: RunnerShim.dylib is not loaded"; exit 1; }
codesign -d --entitlements - "$INSTALLED" 2>/dev/null | grep -q app-sandbox || { echo "FAIL: the app is not sandboxed"; exit 1; }
echo "PASS: the app launched sandboxed with the helper library loaded"

echo "== Mac app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INSTALLED/Info.plist" 2>/dev/null)" = AppIcon ] \
    && [ -s "$INSTALLED/AppIcon.icns" ] || { echo "FAIL: no Mac icon"; exit 1; }
./build/catalyst-runner export dev.catalyst-runner.fixture --to "$WORK/Applications" --library "$WORK/Library" > /dev/null
EXPORTED="$WORK/Applications/Fixture.app"
codesign --verify --deep --strict "$EXPORTED" || { echo "FAIL: the standalone copy is not validly signed"; exit 1; }
echo "PASS: Mac icon built and standalone copy added"

echo "== Reinstalling a changed build"
DATA="$HOME/Library/Containers/dev.catalyst-runner.fixture/Data"
mkdir -p "$DATA/Documents"
echo saved > "$DATA/Documents/keep.txt"
pkill -f "$INSTALLED/Fixture" || true
sleep 1
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2" "$APP/Info.plist"      # different signature
./build/catalyst-runner install "$APP" --library "$WORK/Library" > /dev/null
open -n "$INSTALLED"
sleep 5
pgrep -f "$INSTALLED/Fixture" > /dev/null || { echo "FAIL: the reinstalled app is not running"; exit 1; }
[ "$(cat "$DATA/Documents/keep.txt")" = saved ] || { echo "FAIL: app data was lost on reinstall"; exit 1; }
echo "PASS: app data survived the reinstall"

echo "== Uninstalling with data"
pkill -f "$INSTALLED/Fixture" || true
sleep 1
./build/catalyst-runner uninstall dev.catalyst-runner.fixture --delete-data --library "$WORK/Library"
[ ! -e "$INSTALLED" ] || { echo "FAIL: the app is still installed"; exit 1; }
[ ! -e "$EXPORTED" ] || { echo "FAIL: the standalone copy is still there"; exit 1; }
[ -z "$(find "$DATA" -type f 2>/dev/null)" ] || { echo "FAIL: app data is still there: $(find "$DATA" -type f | head -5 | tr '\n' ' ')"; exit 1; }
echo "PASS: the app and its data are gone"
