#!/bin/bash
# Сборка build/LiveVideoSync.app (Apple Silicon, macOS 15+), ad-hoc подпись,
# плюс утилиты: build/mtc-emulator (эмулятор Logic) и build/make-test-videos.
set -euo pipefail
cd "$(dirname "$0")"

TARGET=arm64-apple-macos15.0
APP=build/LiveVideoSync.app
mkdir -p build

xcrun swiftc -O -swift-version 5 -target "$TARGET" -module-name LiveVideoSync \
  Sources/Core/*.swift Sources/Shared/*.swift Sources/LiveVideoSync/*.swift -o build/LiveVideoSync

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv build/LiveVideoSync "$APP/Contents/MacOS/LiveVideoSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

xcrun swiftc -O -swift-version 5 -target "$TARGET" -module-name MTCEmulator \
  Sources/Core/*.swift Sources/MTCEmulator/*.swift -o build/mtc-emulator
xcrun swiftc -O -swift-version 5 -target "$TARGET" -module-name MakeTestVideos \
  Tools/MakeTestVideos/*.swift -o build/make-test-videos

echo "Готово: $APP, build/mtc-emulator, build/make-test-videos"
