#!/bin/bash
# Builds MeetRec.app (menu bar app) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/MeetRec.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/meetrec "$APP/Contents/MacOS/MeetRec"
cp transcribe.sh merge.py turns.py "$APP/Contents/Resources/"

# App icon
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift tools/make-icon.swift build/icon-1024.png 1024
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.murilo.meetrec</string>
  <key>CFBundleName</key><string>MeetRec</string>
  <key>CFBundleExecutable</key><string>MeetRec</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.murilo.meetrec</string>
    <key>CFBundleURLSchemes</key><array><string>meetrec</string></array>
  </dict></array>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MeetRec shows live captions of your calls using on-device speech recognition.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MeetRec records your side of calls so it can transcribe your meetings locally.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>MeetRec records the call audio so it can transcribe your meetings locally.</string>
</dict>
</plist>
PLIST

# Stable self-signed identity (~/.meetrec/signing) keeps macOS permissions across rebuilds; ad-hoc otherwise.
IDENTITY=$(security find-identity -p codesigning | awk '/MeetRec Local Signing/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.murilo.meetrec "$APP"

mkdir -p "$HOME/Applications"
pkill -x MeetRec 2>/dev/null || true
rm -rf "$HOME/Applications/MeetRec.app"
cp -R "$APP" "$HOME/Applications/"
echo "installed: $HOME/Applications/MeetRec.app"
