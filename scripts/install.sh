#!/bin/zsh
# 빌드 후 /Applications에 설치하고 재실행한다.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh release

pkill -x ShakeTree 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/Shake Tree.app"
cp -R "dist/Shake Tree.app" /Applications/
open "/Applications/Shake Tree.app"
echo 'installed & launched /Applications/Shake Tree.app'
