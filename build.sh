#!/bin/sh
# Runs the unit tests, then builds build/catalyst-runner and build/Catalyst Runner.app.
set -eu
cd "$(dirname "$0")"
TARGET="$(uname -m)-apple-macos14.0"
mkdir -p build

echo "== Unit tests"
swiftc -O -target "$TARGET" Sources/MachO.swift Tests/main.swift -o build/macho-tests
./build/macho-tests

echo "== Building RunnerShim.dylib"
SDK="$(xcrun --show-sdk-path)"
xcrun clang -dynamiclib -fobjc-arc -O2 -target arm64-apple-ios14.0-macabi -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -framework UIKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework QuartzCore -framework AudioToolbox -framework Foundation \
    -install_name @executable_path/Frameworks/RunnerShim.dylib \
    Shim/RunnerShim.m -o build/RunnerShim.dylib

echo "== Helper library tests"
xcrun clang -fobjc-arc -Wno-everything -target arm64-apple-ios14.0-macabi -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Foundation \
    Tests/Shim/crop-test.m -o build/shim-tests
./build/shim-tests "$PWD/build/RunnerShim.dylib"
mkdir -p build/VolumeTest.app
xcrun clang -Wno-everything -target arm64-apple-ios14.0-macabi -isysroot "$SDK" \
    -framework AudioToolbox Tests/Shim/volume-test.m -o build/VolumeTest.app/volume-test
./build/VolumeTest.app/volume-test "$PWD/build/RunnerShim.dylib"

echo "== Building catalyst-runner"
swiftc -O -target "$TARGET" Sources/MachO.swift Sources/Installer.swift Sources/MacIcon.swift Sources/main.swift -o build/catalyst-runner
echo "Built build/catalyst-runner"

echo "== Building Catalyst Runner.app"
APP="build/Catalyst Runner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/RunnerShim.dylib "$APP/Contents/Resources/"
cp App/Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -target "$TARGET" \
    Sources/MachO.swift Sources/Installer.swift Sources/MacIcon.swift App/App.swift \
    -o "$APP/Contents/MacOS/CatalystRunner"
codesign --force --sign - "$APP"
echo "Built $APP"
