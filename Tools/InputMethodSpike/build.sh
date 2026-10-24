#!/bin/bash
# build.sh [keyboard]: spike IM (palette by default) + tisctl
# M0315 spike (not shipped): a minimal input method pFlow could drive, plus tisctl for TIS register/enable/select.
# Palette by default; "keyboard" builds the keyboard-type variant. Driven by the Debug harness specs im:<target> / imside:<target>.
set -e
cd "$(dirname "$0")"
rm -rf out; mkdir -p "out/pFlowInput.app/Contents/MacOS" out/pFlowInput.app/Contents/Resources
if [ "${1:-}" = keyboard ]; then cp Info-keyboard.plist out/pFlowInput.app/Contents/Info.plist; else cp Info.plist out/pFlowInput.app/Contents/; fi
sips -s format tiff -z 32 32 /System/Applications/TextEdit.app/Contents/Resources/AppIcon.icns --out out/pFlowInput.app/Contents/Resources/icon.tiff >/dev/null 2>&1 || true
swiftc -O -target arm64-apple-macos27.0 -framework InputMethodKit -framework Cocoa -framework Carbon main.swift -o out/pFlowInput.app/Contents/MacOS/pFlowInput
codesign -s - --force out/pFlowInput.app
swiftc -O -target arm64-apple-macos27.0 tisctl.swift -o out/tisctl
codesign -s - --force out/tisctl
echo built
