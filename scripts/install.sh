#!/bin/zsh
# 릴리스 빌드를 검증된 임시 위치에 준비한 뒤 /Applications에 교체 설치하고 재실행한다.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="/Applications/Shake Tree.app"
SOURCE="dist/Shake Tree.app"

scripts/build-app.sh release

# 설치 직전 활성 상태를 기억해 짧은 재시작 후 무기한 잠들지 않기를 복원한다.
WAS_AWAKE=0
if /usr/bin/pmset -g assertions \
    | /usr/bin/grep -Eq 'pid [0-9]+\(ShakeTree\).*PreventUserIdleDisplaySleep'
then
    WAS_AWAKE=1
fi

# 먼저 정상 종료를 요청하고 기다린다. 응답하지 않을 때만 TERM으로 마무리한다.
if pgrep -x ShakeTree >/dev/null 2>&1; then
    /usr/bin/osascript -e 'tell application id "dev.yubyeongju.shaketree" to quit' \
        >/dev/null 2>&1 || true
    for _ in {1..50}; do
        pgrep -x ShakeTree >/dev/null 2>&1 || break
        sleep 0.1
    done
fi
if pgrep -x ShakeTree >/dev/null 2>&1; then
    pkill -TERM -x ShakeTree
    for _ in {1..50}; do
        pgrep -x ShakeTree >/dev/null 2>&1 || break
        sleep 0.1
    done
fi
if pgrep -x ShakeTree >/dev/null 2>&1; then
    echo "error: 실행 중인 ShakeTree가 종료되지 않아 설치를 중단합니다" >&2
    exit 1
fi

# 기존 앱을 바로 지우지 않고 같은 볼륨의 임시 폴더에 백업한다. 모든 검증이 끝난
# 뒤에만 임시 폴더를 삭제하므로 중간 실패 시 previous.app으로 복구할 수 있다.
STAGE_DIR="$(mktemp -d /Applications/.shaketree-install.XXXXXX)"
STAGED_APP="$STAGE_DIR/Shake Tree.app"
BACKUP_APP="$STAGE_DIR/previous.app"

/usr/bin/ditto "$SOURCE" "$STAGED_APP"
codesign --verify --strict --verbose=2 "$STAGED_APP"

SOURCE_HASH="$(shasum -a 256 "$SOURCE/Contents/MacOS/ShakeTree" | awk '{print $1}')"
STAGED_HASH="$(shasum -a 256 "$STAGED_APP/Contents/MacOS/ShakeTree" | awk '{print $1}')"
if [[ "$SOURCE_HASH" != "$STAGED_HASH" ]]; then
    echo "error: 임시 설치본의 실행 파일 해시가 빌드와 다릅니다: $STAGE_DIR" >&2
    exit 1
fi

if [[ -e "$TARGET" ]]; then
    mv "$TARGET" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$TARGET"

INSTALLED_HASH="$(shasum -a 256 "$TARGET/Contents/MacOS/ShakeTree" | awk '{print $1}')"
if [[ "$SOURCE_HASH" != "$INSTALLED_HASH" ]]; then
    echo "error: 설치된 실행 파일 해시가 빌드와 다릅니다. 백업: $BACKUP_APP" >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$TARGET"

open "$TARGET"
APP_PID=""
for _ in {1..50}; do
    APP_PID="$(pgrep -x ShakeTree | head -n 1 || true)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.1
done
if [[ -z "$APP_PID" ]]; then
    echo "error: 설치된 앱이 실행되지 않았습니다. 백업: $BACKUP_APP" >&2
    exit 1
fi

RUNNING_COMMAND="$(ps -p "$APP_PID" -o command=)"
if [[ "$RUNNING_COMMAND" != "$TARGET/Contents/MacOS/ShakeTree" ]]; then
    echo "error: 예상과 다른 ShakeTree가 실행 중입니다: $RUNNING_COMMAND" >&2
    echo "백업: $BACKUP_APP" >&2
    exit 1
fi

if (( WAS_AWAKE )); then
    SHAKETREE_POST=toggle-awake "$TARGET/Contents/MacOS/ShakeTree"
fi

# 새 앱과 실행 경로까지 확인된 뒤에만 이전 번들을 제거한다.
rm -rf "$STAGE_DIR"
echo "installed & launched $TARGET (pid $APP_PID, sha256 $INSTALLED_HASH)"
if (( WAS_AWAKE )); then
    echo "restored Keep Awake"
fi
