#!/bin/zsh
# Builds HFPProbe.app next to this script and signs it ad hoc.
set -e
cd "$(dirname "$0")"
APP=build/HFPProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/HFPProbe" main.swift \
  -framework AppKit -framework IOBluetooth -framework CoreAudio
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
