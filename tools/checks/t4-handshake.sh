#!/bin/bash
# T4: handshake, ping, replacement of a client, socket mode and removal.
set -u
. "$(dirname "$0")/common.sh"

cat > "$WORK/ping.txt" <<'SCRIPT'
{"type":"ping","id":7}
expect pong id=7
SCRIPT

"${CLIENT[@]}" --server "$SERVER" --no-view --strict --script "$WORK/ping.txt" || fail "stdio handshake"
[ -s "$WORK/stdio-server.log" ] || fail "the log file is empty"

# The server answers a wrong protocol version with reject.
"${CLIENT[@]}" --server "$SERVER" --no-view --protocol 2 2>"$WORK/reject.out"
grep -q "rejected the client: unsupported protocol version" "$WORK/reject.out" || fail "no reject for protocol 2"

SOCKET="$WORK/l.sock"
start_socket_server "$SOCKET"
[ "$(stat -c %a "$SOCKET" 2>/dev/null || stat -f %Lp "$SOCKET")" = 600 ] || fail "socket mode is not 0600"

"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" || fail "socket handshake"

# A second client replaces the first, which reads `replaced` and then the end of the stream.
cat > "$WORK/first.txt" <<'SCRIPT'
expect replaced timeout=20
expect-eof 5
SCRIPT
"${CLIENT[@]}" --socket "$SOCKET" --no-view --script "$WORK/first.txt" &
FIRST=$!
sleep 1
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" || fail "second client"
wait $FIRST || fail "the first client was not replaced"

kill -TERM "${SERVER_PIDS[0]}"
wait "${SERVER_PIDS[0]}"
SERVER_PIDS=()
[ -e "$SOCKET" ] && fail "the socket outlived the server"
[ -s "$WORK/server.stderr" ] && grep -v "^Ladybird logs to" "$WORK/server.stderr" | grep -q . && fail "the server wrote to stderr"

echo "t4-handshake: ok"
