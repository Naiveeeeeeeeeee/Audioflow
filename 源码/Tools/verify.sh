#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh work/verification-app
BIN="$PWD/work/verification-app/声流.app/Contents/MacOS/SoundFlow"
RUN_DIR="$PWD/work/verification-$(date +%Y%m%d-%H%M%S)"
"$BIN" --self-test "$RUN_DIR/audio"
"$BIN" --render-preview "$RUN_DIR/ui"
if [ "${1:-}" = "--capture" ]; then
  SDK="${SOUNDFLOW_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
  if [ ! -d "$SDK" ]; then SDK="$(xcrun --show-sdk-path)"; fi
  HELPER="$PWD/work/BackgroundEmitter.app"
  mkdir -p "$HELPER/Contents/MacOS"
  cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>BackgroundAudioCheck</string><key>CFBundleIdentifier</key><string>studio.twiggy.SoundFlow.BackgroundEmitter</string><key>CFBundleExecutable</key><string>BackgroundEmitter</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
  xcrun swiftc -sdk "$SDK" -target arm64-apple-macos14.0 Tools/BackgroundEmitter.swift -o "$HELPER/Contents/MacOS/BackgroundEmitter" -framework AppKit -framework AVFoundation
  codesign --force --sign - "$HELPER"
  HELPER_B="$PWD/work/BackgroundEmitterB.app"
  mkdir -p "$HELPER_B/Contents/MacOS"
  cp "$HELPER/Contents/MacOS/BackgroundEmitter" "$HELPER_B/Contents/MacOS/BackgroundEmitter"
  sed 's/studio.twiggy.SoundFlow.BackgroundEmitter</studio.twiggy.SoundFlow.BackgroundEmitterB</;s/BackgroundAudioCheck</BackgroundAudioCheckB</' "$HELPER/Contents/Info.plist" > "$HELPER_B/Contents/Info.plist"
  codesign --force --sign - "$HELPER_B"
  "$BIN" --capture-smoke "$RUN_DIR/capture" "$HELPER/Contents/MacOS/BackgroundEmitter" "$HELPER_B/Contents/MacOS/BackgroundEmitter"
fi
printf 'Verification output: %s\n' "$RUN_DIR"
