#!/bin/bash
# A view outlives its client: the next client on the socket finds it as it was left.
set -u
. "$(dirname "$0")/common.sh"

SOCKET="$WORK/l.sock"
start_socket_server "$SOCKET"

"${CLIENT[@]}" --socket "$SOCKET" --url "$(page dialogs.html)" --script "$CHECKS_DIR/reattach-first.txt" \
    || fail "first client"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$CHECKS_DIR/reattach-second.txt" \
    || fail "second client"

# Shared memory over the socket, and a new segment for the next client.
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --shm --script "$CHECKS_DIR/t7-shm.txt" || fail "shm over the socket"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --shm --script "$CHECKS_DIR/t7-shm.txt" || fail "shm for the next client"

kill -INT "${SERVER_PIDS[0]}"
wait "${SERVER_PIDS[0]}"
SERVER_PIDS=()
[ -e "$SOCKET" ] && fail "the socket outlived the server"

echo "t4-reattach: ok"
