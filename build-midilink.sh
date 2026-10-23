#!/bin/bash
# Сборка build/MIDILink.app — universal (Intel + Apple Silicon), macOS 11+, ad-hoc подпись.
# Только AppKit, без SwiftUI и async — на Big Sur не нужна libswift_Concurrency.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MIDILink.app
OBJ=build/obj
mkdir -p "$OBJ"
BINS=()
for arch in x86_64 arm64; do
  out="$OBJ/MIDILink-$arch"
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos11.0" -module-name MIDILink \
    Sources/Shared/*.swift Sources/MIDILink/*.swift -o "$out"
  BINS+=("$out")
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/MIDILink"
cp Resources/MIDILink/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Готово: $APP"
