#!/bin/zsh
# Builds build/PhoneBridge-<version>.dmg from build/PhoneBridge.app, with a drag-to-Applications window.
# Run ./build.sh first. Finder sets the window layout, so macOS can ask once to let the terminal control Finder.
set -e
cd "$(dirname "$0")/.."
APP=build/PhoneBridge.app
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
VOL="PhoneBridge $VERSION"
OUT="build/PhoneBridge-$VERSION.dmg"
WORK=$(mktemp -d)
SETFILE=/Applications/Xcode.app/Contents/Developer/usr/bin/SetFile

# Window background, in 1x and 2x for Retina screens.
swift dmg/dmg-background.swift "$WORK/bg.png" 1
swift dmg/dmg-background.swift "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff"

mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/PhoneBridge.app"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname "$VOL" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach "$WORK/rw.dmg" -noautoopen
MNT="/Volumes/$VOL"
mkdir "$MNT/.background"
cp "$WORK/background.tiff" "$MNT/.background/"

osascript <<EOF
with timeout of 60 seconds
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 500}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "PhoneBridge.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    update without registering applications
    delay 2
    close
  end tell
end tell
end timeout
EOF

# Finder drops a volume icon that is added before the layout step, so add it last.
cp icon/compiled/AppIcon.icns "$MNT/.VolumeIcon.icns"
if [ -x "$SETFILE" ]; then
  "$SETFILE" -c icnC "$MNT/.VolumeIcon.icns"
  "$SETFILE" -a C "$MNT"
fi
sync
hdiutil detach "$MNT" -quiet

hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
codesign --force --sign - "$OUT"
hdiutil verify "$OUT"
rm -rf "$WORK"
shasum -a 256 "$OUT"
