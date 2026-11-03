#!/bin/bash
# A session-scoped guard for the system-wide pmset flag.  It runs as the user;
# sudo is restricted to the two exact pmset commands by an existing authorization.
set -u

action="${1:-}"
state_dir="${2:-}"
deadline="${3:-0}"
test_backend="${SHAKETREE_LID_TEST_BACKEND:-}"
lease="$state_dir/lease"
locked=0

[[ -n "$state_dir" && -d "$state_dir" && ! -L "$state_dir" ]] || exit 2

lock_state() {
    exec 9>"$state_dir/guard.lock" || return 1
    /usr/bin/lockf -s -t 5 9 || { exec 9>&-; return 1; }
    locked=1
}
unlock_state() { exec 9>&-; locked=0; }

boot_id() {
    if [[ -n "$test_backend" ]]; then "$test_backend" boot
    else /usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null; fi
}
read_flag() {
    if [[ -n "$test_backend" ]]; then "$test_backend" read
    else /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; found=1 } END { if (!found) exit 1 }'; fi
}
can_change_flag() {
    if [[ -n "$test_backend" ]]; then "$test_backend" authorized
    else /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 &&
         /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; fi
}
set_flag() {
    if [[ -n "$test_backend" ]]; then "$test_backend" set "$1"
    else /usr/bin/sudo -n /usr/bin/pmset -a disablesleep "$1" >/dev/null 2>&1; fi
}
remove_lease() {
    /bin/rm -f "$lease/owner" "$lease/boot" "$lease/mode"
    /bin/rmdir "$lease" 2>/dev/null
}
release_lease() {
    local mode flag
    mode=$(/bin/cat "$lease/mode" 2>/dev/null || true)
    if [[ "$mode" == "owned" ]]; then
        flag=$(read_flag) || return 1
        [[ "$flag" == 0 || "$flag" == 1 ]] || return 1
        if [[ "$flag" == 1 ]]; then
            set_flag 0 || return 1
            [[ "$(read_flag)" == 0 ]] || return 1
        fi
    fi
    remove_lease
}

recover() {
    local owner recorded_boot current_boot
    lock_state || return 1
    if [[ ! -d "$lease" || -L "$lease" ]]; then unlock_state; return 0; fi
    owner=$(/bin/cat "$lease/owner" 2>/dev/null || true)
    recorded_boot=$(/bin/cat "$lease/boot" 2>/dev/null || true)
    current_boot=$(boot_id) || { unlock_state; return 1; }
    if [[ "$owner" =~ ^[0-9]+$ && -n "$recorded_boot" && "$recorded_boot" == "$current_boot" ]] && /bin/kill -0 "$owner" 2>/dev/null; then
        unlock_state; return 3
    fi
    if release_lease; then unlock_state; return 0; fi
    unlock_state; return 1
}

if [[ "$action" == recover ]]; then
    recover
    exit $?
fi
if [[ "$action" == probe ]]; then
    flag=$(read_flag) || exit 1
    [[ "$flag" == 1 ]] && exit 0
    [[ "$flag" == 0 ]] || exit 1
    can_change_flag && exit 0
    exit 4
fi
[[ "$action" == watch && "$deadline" =~ ^[0-9]+$ ]] || exit 2

lock_state || { echo "ERROR busy"; exit 3; }
if ! /bin/mkdir -m 700 "$lease" 2>/dev/null; then
    unlock_state
    echo "ERROR busy"
    exit 3
fi
printf '%s\n' "$$" > "$lease/owner"
current_boot=$(boot_id) || { remove_lease; unlock_state; echo "ERROR boot"; exit 1; }
printf '%s\n' "$current_boot" > "$lease/boot"
printf '%s\n' external > "$lease/mode"

cleanup() {
    trap - EXIT HUP INT TERM
    if (( ! locked )); then lock_state || { echo "ERROR restore"; return; }; fi
    if [[ "$(/bin/cat "$lease/owner" 2>/dev/null || true)" == "$$" ]] && release_lease; then
        unlock_state; echo "STOPPED"
    else
        unlock_state; echo "ERROR restore"
    fi
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

acquire_if_needed() {
    local flag
    flag=$(read_flag) || { echo "ERROR read"; return 1; }
    case "$flag" in
        1) ;;
        0)
            can_change_flag || { echo "ERROR authorization"; return 1; }
            # Record ownership before changing the persistent system setting so recovery
            # can undo it even if this process is interrupted immediately afterwards.
            printf '%s\n' owned > "$lease/mode"
            set_flag 1 || { echo "ERROR enable"; return 1; }
            [[ "$(read_flag)" == 1 ]] || { echo "ERROR verify"; return 1; }
            ;;
        *) echo "ERROR read"; return 1 ;;
    esac
}

acquire_if_needed || exit 1
echo "READY $(/bin/cat "$lease/mode")"
unlock_state

while :; do
    if (( deadline > 0 )); then
        now=$(/bin/date +%s)
        remaining=$((deadline - now))
        (( remaining > 0 )) || break
        IFS= read -r -t "$remaining" command || break
    else
        IFS= read -r command || break
    fi
    case "$command" in
        STOP) break ;;
        CHECK)
            lock_state || { echo "ERROR busy"; exit 1; }
            acquire_if_needed || exit 1
            echo "READY $(/bin/cat "$lease/mode")"
            unlock_state
            ;;
        DEADLINE\ *)
            next="${command#DEADLINE }"
            [[ "$next" =~ ^[0-9]+$ ]] || { echo "ERROR deadline"; exit 1; }
            deadline="$next"
            ;;
    esac
done
