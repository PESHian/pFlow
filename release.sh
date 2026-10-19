#!/usr/bin/env bash
#
# Builds, signs, notarizes, staples, and packages Yap for distribution.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your keychain (create it in
#      Xcode: Settings > Accounts > Manage Certificates > + ).
#   2. Notarization credentials stored under the profile name below:
#        xcrun notarytool store-credentials yap-notary \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# ./release.sh: Developer ID signed and notarized pFlow disk image.
# ./release.sh --testing [built-app]: package an existing signed development app.

set -euo pipefail

APP="Yap"
SCHEME="Yap"
CONFIG="Release"
BUILD_DIR="build"
DIST_DIR="dist"
ENTITLEMENTS="${PFLOW_ENTITLEMENTS_FILE:-Sources/Yap.entitlements}"
NOTARY_PROFILE="${YAP_NOTARY_PROFILE:-yap-notary}"

info() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31mError:\033[0m %s\n" "$1" >&2; exit 1; }

TESTING=false
if [ "${1:-}" = "--testing" ]; then
  [ "$#" -le 2 ] || fail "Usage: ./release.sh --testing [built-app]"
  TESTING=true
  APP_PATH="${2:-$BUILD_DIR/Build/Products/$CONFIG/$APP.app}"
elif [ "$#" -gt 0 ]; then
  fail "Usage: ./release.sh [--testing [built-app]]"
fi

if ! $TESTING; then
# --- 1. Find the Developer ID Application identity -------------------------------
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
[ -n "$IDENTITY" ] || fail "No 'Developer ID Application' certificate found. Create one in Xcode first."
info "Signing as: $IDENTITY"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "Notarization profile '$NOTARY_PROFILE' not set up. See the header of this script."

# --- 2. Build -------------------------------------------------------------------
info "Generating project"
xcodegen generate

info "Building $CONFIG"
xcodebuild -project "$APP.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  clean build | grep -E "error:|BUILD"

APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$APP.app"
[ -d "$APP_PATH" ] || fail "Build did not produce $APP_PATH"

# --- 3. Sign, inside-out, with Hardened Runtime + secure timestamp --------------
info "Signing nested code"
while IFS= read -r nested; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
done < <(find "$APP_PATH/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" -o -name "whisper-cli" \))

info "Signing app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP_PATH"
fi

[ -d "$APP_PATH" ] || fail "No app at $APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")

# --- 4. Package a drag-to-install DMG -------------------------------------------
info "Building disk image"
mkdir -p "$DIST_DIR"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/pFlow by Pesh.app"
cp LICENSE "$STAGING/LICENSE.txt"
ln -s /Applications "$STAGING/Applications"
SUFFIX=""
if $TESTING; then SUFFIX="-testing"; fi
DMG="$DIST_DIR/pFlow-$VERSION$SUFFIX.dmg"
rm -f "$DMG"
hdiutil create -volname "pFlow by Pesh" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

if $TESTING; then
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
  info "Testing download: $DMG (development signed, not notarized)."
  exit 0
fi

# Sign the disk image itself, not just the app inside it, or `spctl -t open`
# rejects the download with "no usable signature".
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# --- 5. Notarize + staple -------------------------------------------------------
info "Submitting for notarization (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

info "Stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

info "Done: $DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || true
