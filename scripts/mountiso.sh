#!/bin/sh

set -eu

media_file="${1:-${VIRTUAL_MEDIA:-${VIRTUAL_ISO:-}}}"
java_pid="${2:-}"

: "${VIRTUAL_MEDIA_START_DELAY:=1}"
: "${VIRTUAL_MEDIA_WINDOW_TIMEOUT:=30}"
: "${VIRTUAL_MEDIA_FILE_DIALOG_TIMEOUT:=15}"
: "${VIRTUAL_MEDIA_WINDOW_NAME:=Virtual Media}"
: "${VIRTUAL_MEDIA_FILE_DIALOG_NAME:=Open}"
: "${VIRTUAL_MEDIA_MENU_RIGHT_STEPS:=6}"
: "${VIRTUAL_MEDIA_ADD_IMAGE_X_PCT:=860}"
: "${VIRTUAL_MEDIA_ADD_IMAGE_Y_PCT:=265}"
: "${VIRTUAL_MEDIA_FILE_NAME_X_PCT:=420}"
: "${VIRTUAL_MEDIA_FILE_NAME_Y_PCT:=890}"
: "${VIRTUAL_MEDIA_OPEN_BUTTON_X_PCT:=855}"
: "${VIRTUAL_MEDIA_OPEN_BUTTON_Y_PCT:=945}"
: "${VIRTUAL_MEDIA_LOCK_DIR:=/tmp/idrac-virtual-media.lock}"

cleanup() {
    rm -rf "$VIRTUAL_MEDIA_LOCK_DIR"
}

if ! mkdir "$VIRTUAL_MEDIA_LOCK_DIR" 2>/dev/null; then
    echo "Another virtual media operation is already running"
    exit 1
fi

trap cleanup EXIT INT TERM

wait_for_pid_window() {
    target_pid="$1"
    timeout="$2"
    end_ts=$(( $(date +%s) + timeout ))

    while [ "$(date +%s)" -lt "$end_ts" ]; do
        window_id="$(xdotool search --onlyvisible --pid "$target_pid" 2>/dev/null | head -n 1 || true)"
        if [ -n "$window_id" ]; then
            printf '%s\n' "$window_id"
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
        if [ -n "$window_id" ]; then
            printf '%s\n' "$window_id"
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

click_pct_in_window() {
    window_id="$1"
    x_pct="$2"
    y_pct="$3"

    eval "$(xdotool getwindowgeometry --shell "$window_id")"
    x=$(( WIDTH * x_pct / 1000 ))
    y=$(( HEIGHT * y_pct / 1000 ))

    click_in_window "$window_id" "$x" "$y"
}

open_virtual_media_window() {
    main_window="$1"

    existing_window="$(xdotool search --onlyvisible --name "$VIRTUAL_MEDIA_WINDOW_NAME" 2>/dev/null | head -n 1 || true)"
    if [ -n "$existing_window" ]; then
        printf '%s\n' "$existing_window"
        return 0
    fi

    echo "Opening the Dell Virtual Media window"
    xdotool windowactivate --sync "$main_window"
    sleep 1
    xdotool key --window "$main_window" F10
    sleep 0.8

    step=0
    while [ "$step" -lt "$VIRTUAL_MEDIA_MENU_RIGHT_STEPS" ]; do
        xdotool key --window "$main_window" Right
        step=$((step + 1))
        sleep 0.2
    done

    xdotool key --window "$main_window" Down
    sleep 0.3
    xdotool key --window "$main_window" Return

    wait_for_named_window "$VIRTUAL_MEDIA_WINDOW_NAME" "$VIRTUAL_MEDIA_WINDOW_TIMEOUT"
}

focus_dialog_and_type_path() {
    file_dialog="$1"
    media_path="$2"

    xdotool windowactivate --sync "$file_dialog"
    sleep 0.5

    xdotool key --window "$file_dialog" ctrl+l >/dev/null 2>&1 || true
    sleep 0.3
    xdotool key --window "$file_dialog" ctrl+a >/dev/null 2>&1 || true
    xdotool type --window "$file_dialog" --delay 1 "$media_path"
    sleep 0.5
    xdotool key --window "$file_dialog" Return >/dev/null 2>&1 || true
    sleep 1

    if xdotool search --onlyvisible --name "$VIRTUAL_MEDIA_FILE_DIALOG_NAME" >/dev/null 2>&1; then
        click_pct_in_window "$file_dialog" "$VIRTUAL_MEDIA_FILE_NAME_X_PCT" "$VIRTUAL_MEDIA_FILE_NAME_Y_PCT"
        sleep 0.3
        xdotool key --window "$file_dialog" ctrl+a >/dev/null 2>&1 || true
        xdotool key --window "$file_dialog" BackSpace >/dev/null 2>&1 || true
        xdotool type --window "$file_dialog" --delay 1 "$media_path"
        sleep 0.5
        click_pct_in_window "$file_dialog" "$VIRTUAL_MEDIA_OPEN_BUTTON_X_PCT" "$VIRTUAL_MEDIA_OPEN_BUTTON_Y_PCT"
    fi
}

if [ -z "$media_file" ]; then
    exit 0
fi

media_path="/vmedia/$media_file"
if [ ! -f "$media_path" ]; then
    echo "Virtual media file $media_path does not exist"
    exit 1
fi

echo "Preparing to map $media_path into Dell Virtual Media"
sleep "$VIRTUAL_MEDIA_START_DELAY"

if [ -n "$java_pid" ]; then
    main_window="$(wait_for_pid_window "$java_pid" "$VIRTUAL_MEDIA_WINDOW_TIMEOUT" || true)"
else
    main_window="$(xdotool search --onlyvisible --class java 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${main_window:-}" ]; then
    echo "Unable to find the Java KVM window for virtual media mapping"
    exit 1
fi

vm_window="$(open_virtual_media_window "$main_window" || true)"
if [ -z "${vm_window:-}" ]; then
    echo "Unable to find the Virtual Media window"
    exit 1
fi

echo "Opening Dell Add Image for $media_path"
click_pct_in_window "$vm_window" "$VIRTUAL_MEDIA_ADD_IMAGE_X_PCT" "$VIRTUAL_MEDIA_ADD_IMAGE_Y_PCT"

file_dialog="$(wait_for_named_window "$VIRTUAL_MEDIA_FILE_DIALOG_NAME" "$VIRTUAL_MEDIA_FILE_DIALOG_TIMEOUT" || true)"
if [ -n "${file_dialog:-}" ]; then
    focus_dialog_and_type_path "$file_dialog" "$media_path"
else
    echo "Unable to find the file chooser dialog for Dell Virtual Media"
    exit 1
fi

sleep 1
xdotool windowactivate --sync "$vm_window" >/dev/null 2>&1 || true
echo "Virtual media mapping submitted for $media_path"
