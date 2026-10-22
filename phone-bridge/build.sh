#!/bin/zsh
# Builds PhoneBridge.app next to this script and signs it ad hoc.
set -e
cd "$(dirname "$0")"
APP=build/PhoneBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp icon/compiled/AppIcon.icns icon/compiled/Assets.car "$APP/Contents/Resources/"
swiftc -parse-as-library -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/PhoneBridge" Sources/*.swift \
  -framework SwiftUI -framework AppKit -framework IOBluetooth -framework Contacts -framework CoreAudio -framework AVFoundation
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
