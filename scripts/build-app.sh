#!/bin/zsh
# Builds a release LIT.app into ./build.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product LIT

APP=build/LIT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LIT "$APP/Contents/MacOS/LIT"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/Wordmark.png "$APP/Contents/Resources/Wordmark.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
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
