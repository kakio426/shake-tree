#!/bin/zsh
# swift build 결과물을 "Shake Tree.app" 번들로 포장한다.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"

BIN=".build/$CONFIG/ShakeTree"
APP="dist/Shake Tree.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/ShakeTree"

# Codex/Claude 사용량 조회 CLI를 함께 번들 (CodexBar 앱 없이 동작).
# vendor/codexbar-cli 는 CodexBar.app(MIT)의 Helpers/CodexBarCLI 를 복사해 둔 것.
if [[ -f vendor/codexbar-cli ]]; then
    cp vendor/codexbar-cli "$APP/Contents/Helpers/codexbar-cli"
    chmod +x "$APP/Contents/Helpers/codexbar-cli"
else
    echo "warning: vendor/codexbar-cli 없음 — 사용량 기능이 비활성화됩니다"
fi

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: Resources/AppIcon.icns 없음 — scripts/build-icon.sh 먼저 실행하세요"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ShakeTree</string>
    <key>CFBundleIdentifier</key><string>dev.yubyeongju.shaketree</string>
    <key>CFBundleName</key><string>Shake Tree</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 개인용 ad-hoc 서명 (TCC 권한이 재빌드 간에 유지되도록).
# 주의: 번들된 codexbar-cli 는 재서명하지 않는다 — 원본(steipete Developer ID) 서명을
# 유지해야 Chrome 쿠키 등 키체인 접근 권한이 살아있어 Claude 사용량을 읽을 수 있다.
# 그래서 --deep 없이 우리 실행 파일과 앱만 서명한다.
codesign --force --sign - "$APP/Contents/MacOS/ShakeTree"
codesign --force --sign - "$APP"

echo "built $APP"
