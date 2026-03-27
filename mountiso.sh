#!/bin/sh

set -eu

media_file="${1:-${VIRTUAL_MEDIA:-${VIRTUAL_ISO:-}}}"
java_pid="${2:-}"

: "${VIRTUAL_MEDIA_START_DELAY:=15}"
: "${VIRTUAL_MEDIA_WINDOW_TIMEOUT:=30}"
: "${VIRTUAL_MEDIA_WINDOW_NAME:=Virtual Media}"
: "${VIRTUAL_MEDIA_MENU_X:=10}"
: "${VIRTUAL_MEDIA_MENU_Y:=10}"
: "${VIRTUAL_MEDIA_LAUNCH_X:=10}"
: "${VIRTUAL_MEDIA_LAUNCH_Y:=30}"
: "${VIRTUAL_MEDIA_PATH_X:=500}"
: "${VIRTUAL_MEDIA_PATH_Y:=80}"
: "${VIRTUAL_MEDIA_MAP_X:=56}"
: "${VIRTUAL_MEDIA_MAP_Y:=63}"

wait_for_pid_window() {
    target_pid="$1"
    timeout="$2"
    end_ts=$(( $(date +%s) + timeout ))

    while [ "$(date +%s)" -lt "$end_ts" ]; do
        window_id="$(xdotool search --onlyvisible --pid "$target_pid" 2>/dev/null | head -n 1 || true)"
        if [ -n "${window_id}" ]; then
            printf '%s\n' "${window_id}"
            return 0
        fi
        sleep 1
    done

    return 1
}

wait_for_named_window() {
    pattern="$1"
    timeout="$2"
    end_ts=$(( $(date +%s) + timeout ))

    while [ "$(date +%s)" -lt "$end_ts" ]; do
        window_id="$(xdotool search --onlyvisible --name "$pattern" 2>/dev/null | head -n 1 || true)"
        if [ -n "${window_id}" ]; then
            printf '%s\n' "${window_id}"
            return 0
        fi
        sleep 1
    done

    return 1
}

click_in_window() {
    window_id="$1"
    x="$2"
    y="$3"

    xdotool windowactivate --sync "$window_id"
    xdotool mousemove --window "$window_id" "$x" "$y"
    xdotool click 1
}

if [ -z "$media_file" ]; then
    exit 0
fi

if [ ! -f "/vmedia/$media_file" ]; then
    echo "Virtual media file /vmedia/$media_file does not exist"
    exit 1
fi

echo "Preparing virtual media mapping for /vmedia/$media_file"
sleep "$VIRTUAL_MEDIA_START_DELAY"

if [ -n "$java_pid" ]; then
    main_window="$(wait_for_pid_window "$java_pid" "$VIRTUAL_MEDIA_WINDOW_TIMEOUT" || true)"
else
    main_window="$(xdotool search --onlyvisible --class java 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${main_window:-}" ]; then
    echo "Unable to find the Java KVM window for virtual media automation"
    exit 1
fi

echo "Opening the Launch Virtual Media menu"
click_in_window "$main_window" "$VIRTUAL_MEDIA_MENU_X" "$VIRTUAL_MEDIA_MENU_Y"
sleep 1
click_in_window "$main_window" "$VIRTUAL_MEDIA_LAUNCH_X" "$VIRTUAL_MEDIA_LAUNCH_Y"

vm_window="$(wait_for_named_window "$VIRTUAL_MEDIA_WINDOW_NAME" "$VIRTUAL_MEDIA_WINDOW_TIMEOUT" || true)"
if [ -z "${vm_window:-}" ]; then
    echo "Unable to find the Virtual Media window"
    exit 1
fi

echo "Entering ISO path and submitting the map request"
click_in_window "$vm_window" "$VIRTUAL_MEDIA_PATH_X" "$VIRTUAL_MEDIA_PATH_Y"
sleep 1
xdotool key --window "$vm_window" ctrl+a >/dev/null 2>&1 || true
xdotool type --window "$vm_window" --delay 1 "/vmedia/$media_file"
sleep 1
click_in_window "$vm_window" "$VIRTUAL_MEDIA_MAP_X" "$VIRTUAL_MEDIA_MAP_Y"
