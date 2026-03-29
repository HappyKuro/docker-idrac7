#!/bin/sh

set -eu

java_pid="${1:-}"

: "${VIRTUAL_MEDIA_GUI_TITLE:=Virtual Media}"
: "${VIRTUAL_MEDIA_GUI_WIDTH:=420}"
: "${VIRTUAL_MEDIA_GUI_HEIGHT:=320}"
: "${VIRTUAL_MEDIA_GUI_DELAY:=3}"
: "${VIRTUAL_MEDIA_GUI_LOCK_DIR:=/tmp/idrac-virtual-media-ui.lock}"
: "${VIRTUAL_MEDIA_GUI_MOUNT_DELAY:=0}"

YAD_BIN="${YAD_BIN:-/opt/base/bin/yad}"

list_media_files() {
    if [ ! -d /vmedia ]; then
        return 0
    fi

    find /vmedia -type f \( -iname '*.iso' -o -iname '*.img' -o -iname '*.ima' \) -printf '%P\n' 2>/dev/null | sort
}

cleanup() {
    rm -rf "${VIRTUAL_MEDIA_GUI_LOCK_DIR}"
}

show_no_media_dialog() {
    "${YAD_BIN}" \
        --title="${VIRTUAL_MEDIA_GUI_TITLE}" \
        --text="No files were found in /vmedia.\n\nAdd an ISO or IMG file to the mounted /vmedia directory and click Refresh." \
        --width=420 \
        --center \
        --on-top \
        --sticky \
        --button="Refresh:2" \
        --button="Close:1"
}

show_media_picker() {
    printf '%s\n' "$1" | "${YAD_BIN}" \
        --list \
        --title="${VIRTUAL_MEDIA_GUI_TITLE}" \
        --text="Select a virtual media image to map into the active iDRAC session." \
        --column="Image" \
        --width="${VIRTUAL_MEDIA_GUI_WIDTH}" \
        --height="${VIRTUAL_MEDIA_GUI_HEIGHT}" \
        --center \
        --on-top \
        --sticky \
        --button="Mount:0" \
        --button="Refresh:2" \
        --button="Close:1"
}

notify_result() {
    text="$1"
    kind="${2:-info}"

    case "${kind}" in
        info)
            "${YAD_BIN}" --info --title="${VIRTUAL_MEDIA_GUI_TITLE}" --text="${text}" --timeout=4 --center --on-top &
            ;;
        error)
            "${YAD_BIN}" --error --title="${VIRTUAL_MEDIA_GUI_TITLE}" --text="${text}" --center --on-top &
            ;;
    esac
}

if [ ! -x "${YAD_BIN}" ]; then
    echo "Unable to find yad at ${YAD_BIN}"
    exit 1
fi

if ! mkdir "${VIRTUAL_MEDIA_GUI_LOCK_DIR}" 2>/dev/null; then
    exit 0
fi

trap cleanup EXIT INT TERM

sleep "${VIRTUAL_MEDIA_GUI_DELAY}"

while :; do
    media_files="$(list_media_files)"

    if [ -z "${media_files}" ]; then
        set +e
        show_no_media_dialog >/dev/null
        status="$?"
        set -e
        if [ "${status}" -eq 2 ]; then
            continue
        fi
        exit 0
    fi

    set +e
    selected_file="$(show_media_picker "${media_files}")"
    status="$?"
    set -e

    case "${status}" in
        0)
            if [ -z "${selected_file}" ]; then
                notify_result "Select a media file before clicking Mount." error
                continue
            fi

            if VIRTUAL_MEDIA_START_DELAY="${VIRTUAL_MEDIA_GUI_MOUNT_DELAY}" /mountiso.sh "${selected_file}" "${java_pid}"; then
                notify_result "Queued ${selected_file} for mapping."
            else
                notify_result "Failed to map ${selected_file}. Check the container logs for details." error
            fi
            ;;
        2)
            continue
            ;;
        *)
            exit 0
            ;;
    esac
done
