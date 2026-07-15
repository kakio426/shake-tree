#!/bin/zsh
# AppIconArt.swift로 1024px 소스를 렌더링해 Resources/AppIcon.icns를 생성한다.
# 아이콘 디자인을 바꿀 때만 다시 실행하면 되고, build-app.sh는 이 결과물을 그대로 복사한다.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build

TMP=$(mktemp -d)
SHAKETREE_APPICON="$TMP/icon_1024.png" .build/debug/ShakeTree

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "built Resources/AppIcon.icns"
