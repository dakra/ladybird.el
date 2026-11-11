#!/bin/bash
# Hints (protocol section 6.1): the hints.txt script on stdio, then what ends a session from outside.
set -u
. "$(dirname "$0")/common.sh"

"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page hints.html)" --script "$CHECKS_DIR/hints.txt" \
    || fail "hints script"

SOCKET="$WORK/h.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[0]}"

# wait_for_line FILE TEXT: waits until a background client printed TEXT.
wait_for_line() {
    for _ in $(seq 200); do
        grep -q "$2" "$1" && return 0
        sleep 0.1
    done
    cat "$1" >&2
    fail "no '$2' in $1"
}

# A client that disconnects ends its session silently, and the labels leave the page.
"${CLIENT[@]}" --socket "$SOCKET" --url "$(page hints.html)" --script "$CHECKS_DIR/hints-left.txt" || fail "hints-left"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --script "$CHECKS_DIR/hints-gone.txt" \
    || fail "labels or the session outlived a disconnected client"

# So does a client that is replaced.
"${CLIENT[@]}" --socket "$SOCKET" --url "$(page hints.html)" --script "$CHECKS_DIR/hints-replaced.txt" 2>"$WORK/replaced.out" &
REPLACED=$!
wait_for_line "$WORK/replaced.out" "labels are shown"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --script "$CHECKS_DIR/hints-gone.txt" \
    || fail "labels or the session outlived a replaced client"
wait $REPLACED || { cat "$WORK/replaced.out" >&2; fail "the replaced client was not told"; }

# The page's process dying ends the session with hints_cancelled.
"${CLIENT[@]}" --socket "$SOCKET" --no-view --script "$CHECKS_DIR/hints-crash.txt" 2>"$WORK/crash.out" &
CRASHING=$!
wait_for_line "$WORK/crash.out" "labels are shown"
pkill -KILL -P "$SERVER_PID" WebContent
wait $CRASHING || { cat "$WORK/crash.out" >&2; fail "no hints_cancelled after the crash"; }

kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
SERVER_PIDS=()
echo "hints: ok"
