#!/bin/zsh
# Rebuilds the PhoneBridge icon (version 2) from draw-icon.swift.
# Output: compiled/Assets.car (the macOS 26+ icon) and compiled/AppIcon.icns (for older macOS).
# Needs Xcode for actool.
set -e
cd "$(dirname "$0")"
swift draw-icon.swift icon-1024.png
swift draw-icon.swift layer-bridge.png layer-bridge
swift draw-icon.swift layer-handset.png layer-handset
cp layer-bridge.png layer-handset.png AppIcon.icon/Assets/
rm -rf compiled && mkdir compiled
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun actool AppIcon.icon --compile compiled \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist compiled/partial.plist --output-format human-readable-text
