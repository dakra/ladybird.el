#!/bin/bash
# Runs every acceptance check of the server work package against a built Ladybird.
# Usage: tools/checks/run.sh [CHECK...]   (default: all; names are t4 reattach t5 t6 t7 t8 t9 bands hints views popups background activation mock)
set -u
. "$(dirname "$0")/common.sh"

FAILED=()

script_check() {
    local name="$1" page_name="$2"
    shift 2
    echo "== $name"
    if "${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page "$page_name")" \
        --script "$CHECKS_DIR/$name.txt" "$@"; then
        echo "$name: ok"
    else
        FAILED+=("$name")
    fi
}

shell_check() {
    echo "== $1"
    bash "$CHECKS_DIR/$1.sh" || FAILED+=("$1")
}

mock_check() {
    echo "== mock"
    local mock="$TOOLS_DIR/mock-server.py"
    [ -f "$mock" ] || { echo "mock: skipped, no $mock"; return; }
    for options in "" "--zstd" "--shm"; do
        local client_options=()
        [ "$options" = "--shm" ] && client_options=(--shm)
        if ! "${CLIENT[@]}" --server "python3 -I $mock --stdio --fps 0 $options" --strict \
            --url mock://page --viewport 320x240@1 --verify-formula 0 ${client_options[@]+"${client_options[@]}"}; then
            FAILED+=("mock $options")
            return
        fi
    done
    echo "mock: ok"
}

[ $# -eq 0 ] && set -- t4 reattach t5 t6 t7 t8 t9 bands hints views popups background activation mock
for check in "$@"; do
    case "$check" in
        t4) shell_check t4-handshake ;;
        reattach) shell_check t4-reattach ;;
        t5) script_check t5-frames animate.html --strict ;;
        t6) script_check t6-input input.html --strict ;;
        t7) shell_check t7-encodings ;;
        t8) script_check t8-dialogs dialogs.html ;;
        t9) shell_check t9-hardening ;;
        bands)
            script_check bands tall.html --strict --viewport 4200x4100@1 --encodings raw
            script_check bands tall.html --strict --viewport 4200x4100@1 --encodings zstd,raw
            ;;
        hints) shell_check hints ;;
        views) shell_check views ;;
        popups) shell_check popups ;;
        background) shell_check background ;;
        activation) shell_check activation ;;
        mock) mock_check ;;
        *) echo "unknown check $check" >&2; exit 2 ;;
    esac
done

if [ ${#FAILED[@]} -ne 0 ]; then
    echo "FAILED: ${FAILED[*]}" >&2
    exit 1
fi
echo "all checks passed"
