#!/bin/zsh
# Builds Ledly.app (release, universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Ledly.app
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-1}
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Ledly

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Firmware"
cp "$BIN" "$APP/Contents/MacOS/Ledly"
# Precompiled Nano firmware, one per data pin (see firmware/build.sh).
cp firmware/hex/*.hex "$APP/Contents/Resources/Firmware/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Ledly</string>
    <key>CFBundleIdentifier</key><string>com.egluu.ledly</string>
    <key>CFBundleName</key><string>Ledly</string>
    <key>CFBundleDisplayName</key><string>Ledly</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Ledly offers an API on the local network to control the LED strip.</string>
    <key>NSBonjourServices</key><array><string>_wled._tcp</string></array>
</dict>
</plist>
PLIST

# A stable identity keeps the Screen Recording permission across builds (macOS ties it to the
# signature). Uses SIGN_IDENTITY, else the first "Apple Development" certificate, else ad-hoc (CI).
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
(cd build && rm -f Ledly.zip && ditto -c -k --keepParent Ledly.app Ledly.zip)
echo "Built $APP ($VERSION) and build/Ledly.zip"
