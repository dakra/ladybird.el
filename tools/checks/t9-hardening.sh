#!/bin/bash
# Limits on what pages and clients can make the server do, and the transport's handling of its socket and connections.
set -u
. "$(dirname "$0")/common.sh"

# Text limits, input ranges, screenshots, blocked downloads, withdrawn requests.
mkdir "$WORK/downloads"
XDG_DOWNLOAD_DIR="$WORK/downloads" "${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$(page dialogs.html)" \
    --script "$CHECKS_DIR/t9-hardening.txt" || fail "hardening script"
[ -z "$(ls -A "$WORK/downloads")" ] || fail "a page saved a file: $(ls "$WORK/downloads")"

SOCKET="$WORK/l.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[0]}"
[ "$(stat -c %a "$WORK/server.log" 2>/dev/null || stat -f %Lp "$WORK/server.log")" = 600 ] || fail "log mode is not 0600"

# A second server does not take the socket of one that answers, and a path that is not a socket is left alone.
"$LADYBIRD" --headless=emacs --emacs-socket="$SOCKET" --emacs-log="$WORK/second.log" 2>/dev/null
[ $? -ne 0 ] || fail "a second server started on the same socket"
grep -q "already listens" "$WORK/second.log" || fail "no clear error from the second server"
echo "user data" > "$WORK/precious.txt"
"$LADYBIRD" --headless=emacs --emacs-socket="$WORK/precious.txt" --emacs-log="$WORK/third.log" 2>/dev/null
[ $? -ne 0 ] || fail "a server started on a regular file"
[ "$(cat "$WORK/precious.txt")" = "user data" ] || fail "the regular file was replaced"
[ -S "$SOCKET" ] || fail "the first server's socket is gone"

# Connections that say no valid hello leave the client alone.
"${CLIENT[@]}" --socket "$SOCKET" --url "$(page text.html)" --script "$CHECKS_DIR/stays-connected.txt" --strict &
ACTIVE=$!
sleep 1.5
python3 -I - "$SOCKET" <<'PY'
import socket, struct, sys, time
connections = []
for _ in range(20):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sys.argv[1])
    connections.append(s)
    time.sleep(0.01)
bad = b'{"type":"hello","protocol":99}'
connections[-1].sendall(struct.pack("<IB", len(bad) + 1, 1) + bad)
connections[-2].sendall(struct.pack("<IB", 5, 1) + b"ping")
time.sleep(0.5)
PY
[ $? -eq 0 ] || fail "could not open the extra connections"
wait $ACTIVE || fail "connections without a hello disturbed the client"

# A client that is replaced while it is behind on reading is still told so.
"${CLIENT[@]}" --socket "$SOCKET" --no-view --encodings raw --script "$CHECKS_DIR/replaced-while-stalled.txt" &
STALLED=$!
sleep 1.5
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$CHECKS_DIR/stays-connected.txt" || fail "replacing client"
wait $STALLED || fail "the stalled client was not told it was replaced"

# A request is withdrawn when the page crashes.
"${CLIENT[@]}" --socket "$SOCKET" --no-view --send '{"type":"load","url":"'"$(page dialogs.html)"'"}' --settle 1 || fail "load"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --script "$CHECKS_DIR/crash-withdraws.txt" 2>"$WORK/crash.out" &
CRASHING=$!
for _ in $(seq 100); do
    grep -q "select is open" "$WORK/crash.out" && break
    sleep 0.1
done
pkill -KILL -P "$SERVER_PID" WebContent
wait $CRASHING || { cat "$WORK/crash.out" >&2; fail "no request_cancelled after the crash"; }

kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
SERVER_PIDS=()
[ -e "$SOCKET" ] && fail "the socket outlived the server"

# A server started with SIGHUP ignored, as under nohup, survives SIGHUP.
(trap '' HUP; exec "$LADYBIRD" --headless=emacs --emacs-socket="$SOCKET" --emacs-log="$WORK/nohup.log" 2>/dev/null) &
SERVER_PIDS=($!)
for _ in $(seq 100); do [ -S "$SOCKET" ] && break; sleep 0.1; done
kill -HUP "${SERVER_PIDS[0]}"
sleep 1
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$CHECKS_DIR/stays-connected.txt" || fail "the server did not survive SIGHUP"
kill -TERM "${SERVER_PIDS[0]}"
wait "${SERVER_PIDS[0]}"
SERVER_PIDS=()

echo "t9-hardening: ok"
