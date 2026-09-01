#!/bin/zsh
# Builds Tim.app — a proper bundle with an icon, Sparkle updates, so Tim
# runs as itself (its own permissions, Dock presence, real menu-bar name).
set -e
cd "$(dirname "$0")/.."

swift build

APP="Tim.app"
VERSION="${TIM_VERSION:-0.4}"
BUILD_NUMBER="${TIM_BUILD:-$(date +%Y%m%d%H%M)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/debug/Tim "$APP/Contents/MacOS/Tim"
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle framework rides along; point the binary at Frameworks/.
SPARKLE_FRAMEWORK=$(find .build/artifacts -type d -name "Sparkle.framework" | head -1)
if [ -n "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Tim" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tim</string>
    <key>CFBundleDisplayName</key>
    <string>Tim</string>
    <key>CFBundleIdentifier</key>
    <string>com.gabrieljeffrey.tim</string>
    <key>CFBundleExecutable</key>
    <string>Tim</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>SUFeedURL</key>
    <string>https://gabrieljeffrey.com/tim/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>TM8yvT30uFU2LjT3tGN72/bwV1tjrtjZjpnqX9Avtyc=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP (v${VERSION}, build ${BUILD_NUMBER})"
