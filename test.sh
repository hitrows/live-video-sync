#!/bin/bash
# Тесты ядра (Sources/Core): разбор MIDI/MTC, часы, логика шоу
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
  Sources/Core/*.swift Tests/main.swift -o build/core-tests
./build/core-tests
