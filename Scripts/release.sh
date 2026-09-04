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

# The version this release is stamped and NAMED with. make-app.sh reads
# TIM_VERSION from the environment; release.sh needs it by name too, for
# the versioned artifact and the site's download link. (Without this the
# zip shipped as "Tim-.zip".)
VERSION="${TIM_VERSION:-0.4}"

IDENTITY="Developer ID Application: Gabriel Jeffrey (VDNJRV3PR9)"

# Notary auth, in order of preference: a keychain profile (TimNotary, or
# the one Little Ripper set up), else the App Store Connect API key file
# Loch uses (key file + NOTARY_ISSUER_ID env), else skip with instructions.
NOTARY_AUTH=()
for profile in TimNotary littleripper-notary; do
    if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
        NOTARY_AUTH=(--keychain-profile "$profile")
        echo "▸ Notary auth: keychain profile $profile"
        break
    fi
done
KEY_ID="${NOTARY_KEY_ID:-A634227VQG}"
KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
if [ ${#NOTARY_AUTH[@]} -eq 0 ] && [ -f "$KEY_FILE" ] && [ -n "$NOTARY_ISSUER_ID" ]; then
    NOTARY_AUTH=(--key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    echo "▸ Notary auth: API key $KEY_ID"
fi
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
# Versioned artifact: the site is behind Cloudflare, which caches zips
# for two days — a same-named upload was served stale to Sparkle (and
# failed its signature check). A new name per release is a new URL.
ZIP="$RELEASES_DIR/Tim-$VERSION.zip"
rm -f "$ZIP" "$RELEASES_DIR/Tim.zip"
ditto -c -k --keepParent "Tim.app" "$ZIP"

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
    echo "== Notarizing"
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple "Tim.app"
    rm -f "$ZIP"
    ditto -c -k --keepParent "Tim.app" "$ZIP"
else
    echo "!! Skipping notarization — no notary credentials found."
    echo "   Either: xcrun notarytool store-credentials TimNotary --apple-id <id> --team-id VDNJRV3PR9"
    echo "   or set NOTARY_ISSUER_ID (with AuthKey_${KEY_ID}.p8 in ~/.appstoreconnect/private_keys)."
fi

echo "== Appcast"
"$SPARKLE_BIN/generate_appcast" "$RELEASES_DIR" \
    --download-url-prefix "https://gabrieljeffrey.com/tim/" \
    -o "$RELEASES_DIR/appcast.xml"

# The site's Download button follows the versioned file, so it can never
# point at a stale edge copy. (Examples/tim is the page's mirror.)
sed -i '' "s#https://gabrieljeffrey.com/tim/Tim\(-[0-9.]*\)\{0,1\}\.zip#https://gabrieljeffrey.com/tim/Tim-$VERSION.zip#g" Examples/tim/index.html

echo "== Uploading to gabrieljeffrey.com/tim"
# The versioned zip is what the appcast points at; Tim.zip stays the
# site's stable download link (uncached at the edge via .htaccess).
sftp -o BatchMode=yes -b - "$SFTP_DEST" <<SFTP
put "$ZIP" "$REMOTE_ROOT/$(basename "$ZIP")"
put "$ZIP" "$REMOTE_ROOT/Tim.zip"
put "$RELEASES_DIR/appcast.xml" "$REMOTE_ROOT/appcast.xml"
put "Scripts/tim-htaccess" "$REMOTE_ROOT/.htaccess"
put "Examples/tim/index.html" "$REMOTE_ROOT/index.html"
SFTP

echo "Release complete: https://gabrieljeffrey.com/tim/$(basename "$ZIP") (and Tim.zip)"
