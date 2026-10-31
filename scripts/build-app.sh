#!/bin/zsh
# Builds a release LIT.app into ./build.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications
#
# Version (semver, from the latest vX.Y.Z git tag unless LIT_VERSION is set) and build number
# (commit count unless LIT_BUILD is set) go into Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${LIT_VERSION:-$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="${LIT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
echo "Building LIT $VERSION ($BUILD)"

swift build -c release --product LIT

APP=build/LIT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LIT "$APP/Contents/MacOS/LIT"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/Wordmark.png "$APP/Contents/Resources/Wordmark.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LIT</string>
    <key>CFBundleDisplayName</key><string>LIT</string>
    <key>CFBundleIdentifier</key><string>dev.local.lit</string>
    <key>CFBundleExecutable</key><string>LIT</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Sandeep Sarma Josyula · MIT License · No data collected</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Camera RAW Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.camera-raw-image</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.jpeg</string><string>public.tiff</string><string>public.heic</string><string>public.png</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/LIT.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/LIT.app"
fi
