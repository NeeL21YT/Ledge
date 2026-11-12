#!/bin/bash
# Builds a release binary and wraps it in build/Ledge.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Ledge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Ledge" "$APP/Contents/MacOS/Ledge"
# Compile the icon: Assets.car for macOS 26 (full-size icon) plus a Ledge.icns fallback for older systems.
ICONOUT=$(mktemp -d)
xcrun actool Resources/Ledge.icon --compile "$ICONOUT" --output-format human-readable-text \
    --output-partial-info-plist "$ICONOUT/partial.plist" --app-icon Ledge --include-all-app-icons \
    --development-region en --target-device mac --minimum-deployment-target 13.0 --platform macosx >/dev/null
cp "$ICONOUT/Assets.car" "$ICONOUT/Ledge.icns" "$APP/Contents/Resources/"
rm -rf "$ICONOUT"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Ledge</string>
    <key>CFBundleIdentifier</key><string>app.ledge.mac</string>
    <key>CFBundleIconFile</key><string>Ledge</string>
    <key>CFBundleIconName</key><string>Ledge</string>
    <key>CFBundleName</key><string>Ledge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.5.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>Ledge</string>
        <key>CFBundleURLSchemes</key><array><string>ledge</string></array>
    </dict></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
