#!/bin/zsh
# Release Tim: signed, notarized, stapled, zipped, appcast updated, and
# published as a GitHub release — which is where the app looks for updates
# (SUFeedURL → releases/latest/download/appcast.xml) and where the site's
# Download button points (releases/latest/download/Tim.zip).
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
REPO="gjeffrey/Tim"
RELEASES_DIR="Releases"
gh auth status >/dev/null 2>&1 || { echo "!! gh isn't logged in (gh auth login)"; exit 1; }
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
    echo "!! v$VERSION already exists on GitHub. Bump TIM_VERSION, or delete the release first."
    exit 1
fi
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
# One zip per version, kept in Releases/ so the appcast keeps every
# version it has ever listed (generate_appcast drops items whose archive
# is gone).
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
# Each version's zip lives under its own tag, so the prefix is rewritten
# per item: …/download/Tim-0.8.zip → …/download/v0.8/Tim-0.8.zip.
"$SPARKLE_BIN/generate_appcast" "$RELEASES_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/" \
    -o "$RELEASES_DIR/appcast.xml"
sed -i '' -E 's#(releases/download/)Tim-([0-9.]+)\.zip#\1v\2/Tim-\2.zip#g' "$RELEASES_DIR/appcast.xml"

echo "== Publishing v$VERSION on GitHub"
# Three assets: the versioned zip the appcast names, Tim.zip for the
# site's stable Download link (releases/latest/download/Tim.zip), and
# the appcast itself (releases/latest/download/appcast.xml — the feed).
# Notes come from Releases/notes-$VERSION.md when there is one.
cp "$ZIP" "$RELEASES_DIR/Tim.zip"
NOTES=(--generate-notes)
[ -f "$RELEASES_DIR/notes-$VERSION.md" ] && NOTES=(--notes-file "$RELEASES_DIR/notes-$VERSION.md")
gh release create "v$VERSION" -R "$REPO" --title "Tim $VERSION" "${NOTES[@]}" \
    "$ZIP" "$RELEASES_DIR/Tim.zip" "$RELEASES_DIR/appcast.xml"

echo "Release complete: https://github.com/$REPO/releases/tag/v$VERSION"
