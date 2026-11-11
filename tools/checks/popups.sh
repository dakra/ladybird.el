#!/bin/bash
# Views opened by pages (protocol section 3.1), over HTTP: the page on 127.0.0.1 and its frame on localhost, which are
# different sites.
set -u
. "$(dirname "$0")/common.sh"

PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$CHECKS_DIR/pages" >"$WORK/http.log" 2>&1 &
SERVER_PIDS+=($!)
for _ in $(seq 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/popups.html" && break
    sleep 0.1
done
URL="http://127.0.0.1:$PORT/popups.html"

"${CLIENT[@]}" --server "$SERVER" --popups --timeout 15 --viewport 800x600@1 --url "$URL" \
    --script "$CHECKS_DIR/popups.txt" || fail "popups script"
"${CLIENT[@]}" --server "$SERVER --emacs-max-views=2" --popups --timeout 15 --url "$URL" \
    --script "$CHECKS_DIR/popups-limit.txt" || fail "popups-limit script"
"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "$URL" --script "$CHECKS_DIR/popups-off.txt" \
    || fail "popups-off script"

# A client without popups comes back to views a page opened, one of them of another site and so in a WebContent
# process of its own. Once the views are closed, no WebContent process of theirs is left beyond the one Ladybird keeps
# for the next page.
SOCKET="$WORK/p.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[${#SERVER_PIDS[@]} - 1]}"
sleep 1
BEFORE="$(pgrep -P "$SERVER_PID" WebContent | wc -l)"
"${CLIENT[@]}" --socket "$SOCKET" --popups --shm --timeout 15 --url "http://127.0.0.1:$PORT/popups-cross.html" \
    --script "$CHECKS_DIR/popups-detach.txt" || fail "popups-detach script"
DURING="$(pgrep -P "$SERVER_PID" WebContent | wc -l)"
[ "$DURING" -ge 2 ] || fail "the page and the window of another site it opened share a WebContent process"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --timeout 15 --script "$CHECKS_DIR/popups-reattach.txt" \
    || fail "popups-reattach script"
sleep 2
AFTER="$(pgrep -P "$SERVER_PID" WebContent | wc -l)"
[ "$AFTER" -le "$((BEFORE + 1))" ] || fail "WebContent processes: $BEFORE before the popups, $AFTER after closing them"
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
echo "popups: ok"
