#!/bin/zsh
# Release Tim: signed, notarized, stapled, zipped, appcast updated, and
# uploaded to gabrieljeffrey.com/tim.
#
# One-time setup (already partly done on this Mac):
#   - Developer ID Application cert in the keychain        [present]
#   - Sparkle EdDSA keys (generate_keys)                   [present]
#   - Notary credentials:
#       xcrun notarytool store-credentials TimNotary \
#         --apple-id <apple-id> --team-id VDNJRV3PR9
#
# Usage: TIM_VERSION=0.4 ./Scripts/release.sh
set -e
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Gabriel Jeffrey (VDNJRV3PR9)"
PROFILE="TimNotary"
SFTP_DEST="dh_xvreha@pdx1-shared-a1-34.dreamhost.com"
REMOTE_ROOT="/home/dh_xvreha/gabrieljeffrey.com/tim"
RELEASES_DIR="Releases"
SPARKLE_BIN=$(find .build/artifacts -type d -name bin -path "*sparkle*" | head -1)

./Scripts/make-app.sh

echo "== Signing (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "Tim.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "Tim.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "Tim.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "Tim.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "Tim.app/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "Tim.app"
codesign --verify --deep --strict "Tim.app" && echo "signature OK"

mkdir -p "$RELEASES_DIR"
ZIP="$RELEASES_DIR/Tim.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "Tim.app" "$ZIP"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "== Notarizing"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "Tim.app"
    rm -f "$ZIP"
    ditto -c -k --keepParent "Tim.app" "$ZIP"
else
    echo "!! Skipping notarization — no '$PROFILE' keychain profile."
    echo "   Run: xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id VDNJRV3PR9"
fi

echo "== Appcast"
"$SPARKLE_BIN/generate_appcast" "$RELEASES_DIR" \
    --download-url-prefix "https://gabrieljeffrey.com/tim/" \
    -o "$RELEASES_DIR/appcast.xml"

echo "== Uploading to gabrieljeffrey.com/tim"
sftp -o BatchMode=yes -b - "$SFTP_DEST" <<SFTP
put "$ZIP" "$REMOTE_ROOT/Tim.zip"
put "$RELEASES_DIR/appcast.xml" "$REMOTE_ROOT/appcast.xml"
SFTP

echo "Release complete: https://gabrieljeffrey.com/tim/Tim.zip"
