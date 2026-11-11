#!/bin/bash
# Hints (protocol section 6.1): the scripts on stdio, frames of other sites over HTTP, then what ends a session from
# outside.
set -u
. "$(dirname "$0")/common.sh"

"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page hints.html)" --script "$CHECKS_DIR/hints.txt" \
    || fail "hints script"
"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page hints-hidden.html)" --script "$CHECKS_DIR/hints-hidden.txt" \
    || fail "hints-hidden script"
"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page hints-hostile.html)" --script "$CHECKS_DIR/hints-hostile.txt" \
    || fail "hints-hostile script"

# The pages are served on 127.0.0.1 and on localhost, which are different sites, so the frames of the other one are in
# processes of their own unless site isolation is limited to top-level documents.
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$CHECKS_DIR/pages" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
SERVER_PIDS+=("$HTTP_PID")
for _ in $(seq 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/hints-frames.html" && break
    sleep 0.1
done
# With site isolation, the frames of the other site are in processes of their own: the frames check runs on a server
# whose processes are then counted.
FRAMES_SOCKET="$WORK/f.sock"
start_socket_server "$FRAMES_SOCKET"
FRAMES_SERVER_PID="${SERVER_PIDS[${#SERVER_PIDS[@]} - 1]}"
for name in frames jack hung; do
    "${CLIENT[@]}" --socket "$FRAMES_SOCKET" --timeout 15 --url "http://127.0.0.1:$PORT/hints-$name.html" \
        --script "$CHECKS_DIR/hints-$name.txt" || fail "hints-$name script"
    if [ "$name" = frames ]; then
        [ "$(pgrep -P "$FRAMES_SERVER_PID" WebContent | wc -l)" -ge 2 ] || fail "the frames of another site share the page's process"
    fi
done
kill -TERM "$FRAMES_SERVER_PID"
wait "$FRAMES_SERVER_PID"
SERVER_PIDS=("$HTTP_PID")

# With site isolation limited to top-level documents, every frame is in the page's process.
"${CLIENT[@]}" --server "$SERVER --site-isolation=top-level" --timeout 15 --url "http://127.0.0.1:$PORT/hints-frames.html" \
    --script "$CHECKS_DIR/hints-frames.txt" || fail "hints-frames script with site isolation for top-level documents"
"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page hints-shift.html)" --script "$CHECKS_DIR/hints-refused.txt" \
    || fail "hints-refused script"

SOCKET="$WORK/h.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[${#SERVER_PIDS[@]} - 1]}"

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
SERVER_PIDS=("$HTTP_PID")
echo "hints: ok"
