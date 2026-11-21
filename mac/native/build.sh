#!/bin/bash
# AISessionViewer.app (Claude Code + Antigravity 統合Swiftネイティブ版・Node不要) をビルドする
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AISessionViewer"
BUNDLE="$APP_NAME.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RES_DIR="$BUNDLE/Contents/Resources"
ARCH="$(uname -m)"

mkdir -p "$MACOS_DIR" "$RES_DIR"

swiftc -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macos14.0" \
  -parse-as-library \
  -lsqlite3 \
  Sources/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

# UI一式とアプリアイコンをバンドルに同梱
cp ../../index.html ../../marked.min.js "$RES_DIR/"
if [[ -f Assets/AppIcon.icns ]]; then
  cp Assets/AppIcon.icns "$RES_DIR/AppIcon.icns"
fi

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AISessionViewer</string>
    <key>CFBundleIdentifier</key>
    <string>local.ai-session-viewer</string>
    <key>CFBundleName</key>
    <string>AI Session Viewer</string>
    <key>CFBundleDisplayName</key>
    <string>AI Session Viewer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" 2>/dev/null || true

echo "✅ Built: $(pwd)/$BUNDLE"
