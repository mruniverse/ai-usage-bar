#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_BIN="${SWIFT_BIN:-swift}"
"$SWIFT_BIN" build -c release --triple x86_64-apple-macosx13.0
x64="$("$SWIFT_BIN" build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/AIUsageBar"
"$SWIFT_BIN" build -c release --triple arm64-apple-macosx13.0
arm="$("$SWIFT_BIN" build -c release --triple arm64-apple-macosx13.0 --show-bin-path)/AIUsageBar"
universal="$PWD/.build/AIUsageBar-universal"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" /usr/bin/lipo -create "$x64" "$arm" -output "$universal"
app="$PWD/.build/AI Usage Bar.app"
python3 scripts/generate-icon.py
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/.build/releases"
cp "$universal" "$app/Contents/MacOS/AIUsageBar"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$x64" "$PWD/.build/releases/AIUsageBar-x86_64"
cp "$arm" "$PWD/.build/releases/AIUsageBar-arm64"
cp "$universal" "$PWD/.build/releases/AIUsageBar-universal"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIUsageBar</string>
<key>CFBundleIdentifier</key><string>app.aiusagebar.local</string>
<key>CFBundleName</key><string>AI Usage Bar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf 'Universal app created: %s\nArchitectures: ' "$app"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" /usr/bin/lipo -archs "$app/Contents/MacOS/AIUsageBar"
