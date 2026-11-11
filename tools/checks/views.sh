#!/bin/bash
# Several views: the views.txt script, their turns on the connection, shared cookies and storage, shared memory per
# view, a flood of create_view and what is left after closing views, reattaching to several views, and clients that
# take frames differently from the one before.
set -u
. "$(dirname "$0")/common.sh"

"${CLIENT[@]}" --server "$LADYBIRD --headless=emacs --emacs-log=$WORK/views.log --emacs-max-views=3 --expose-internals-object" \
    --timeout 15 --viewport 400x300@1 --url "$(page text.html)" --script "$CHECKS_DIR/views.txt" || fail "views script"
"${CLIENT[@]}" --server "$LADYBIRD --headless=emacs --emacs-log=$WORK/views-turns.log --expose-internals-object" \
    --timeout 30 --viewport 400x300@1 --url "$(page text.html)" --script "$CHECKS_DIR/views-turns.txt" \
    || fail "views-turns script"

"${CLIENT[@]}" --server "$SERVER" --timeout 15 --viewport 320x240@1 --shm --url "$(page text.html)" \
    --script "$CHECKS_DIR/views-shm.txt" || fail "views-shm script"
"${CLIENT[@]}" --server "$SERVER" --timeout 15 --viewport 320x240@1 --shm --fail-shm --url "$(page text.html)" \
    --script "$CHECKS_DIR/views-shm-failed.txt" || fail "views-shm-failed script"

# A server is not started with a number of views it cannot serve.
for count in 0 65 many; do
    if "$LADYBIRD" --headless=emacs --emacs-log="$WORK/max-views.log" --emacs-max-views="$count" </dev/null >/dev/null 2>"$WORK/max-views.err"; then
        fail "a server started with --emacs-max-views=$count"
    fi
done

# Cookies and storage are the server's, so a second view reads what the first one set.
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$CHECKS_DIR/pages" >"$WORK/http.log" 2>&1 &
SERVER_PIDS+=($!)
for _ in $(seq 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/views-cookie-set.html" && break
    sleep 0.1
done
# NB: The profile keeps cookies and storage from earlier runs, so the value is new each time.
VALUE="value$$$RANDOM"
sed "s|\$http|http://127.0.0.1:$PORT|; s|\$value|$VALUE|g" "$CHECKS_DIR/views-shared.txt" >"$WORK/views-shared.txt"
"${CLIENT[@]}" --server "$SERVER" --timeout 15 --url "http://127.0.0.1:$PORT/views-cookie-set.html?v=$VALUE" \
    --script "$WORK/views-shared.txt" || fail "views-shared script"

# A flood of create_view gets as many views as the server can have and errors for the rest. Closing them all leaves no
# WebContent process or shared memory segment of theirs behind.
SOCKET="$WORK/v.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[${#SERVER_PIDS[@]} - 1]}"
sleep 1
BEFORE="$(pgrep -P "$SERVER_PID" WebContent | wc -l)"
cat >"$WORK/flood.py" <<'PY'
import _posixshmem, json, os, socket, sys, time
sys.path.insert(0, sys.argv[2])
import ladybird_protocol as proto

connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.connect(sys.argv[1])
reader = proto.RecordReader()
messages = []
segments = set()

def send(message):
    connection.sendall(proto.encode_control(message))

def pump(seconds, until=lambda: False):
    deadline = time.monotonic() + seconds
    connection.settimeout(0.1)
    while time.monotonic() < deadline and not until():
        try:
            data = connection.recv(1 << 20)
        except socket.timeout:
            continue
        if not data:
            sys.exit("the server closed the connection")
        for kind, payload in reader.feed(data):
            if kind == proto.KIND_CONTROL:
                message = json.loads(payload)
                messages.append(message)
                if message.get("type") == "shm":
                    segments.add(message["name"])
            else:
                header, _ = proto.FrameHeader.parse(payload)
                send({"type": "frame_ack", "view": header.view, "seq": header.seq})

send({"type": "hello", "protocol": 1, "client": "flood", "viewport": {"width": 200, "height": 150, "dpr": 1},
      "encodings": ["raw"], "shm": True, "token": None})
pump(10, lambda: any(m.get("type") == "welcome" for m in messages))
maximum = next(m for m in messages if m.get("type") == "welcome")["max_views"]
for request in range(maximum + 20):
    send({"type": "create_view", "width": 200, "height": 150, "dpr": 1, "url": "about:blank", "request": request})
answered = lambda: {m.get("request") for m in messages if m.get("type") in ("view_created", "error") and "request" in m}
pump(60, lambda: len(answered()) == maximum + 20)
created = [m["view"] for m in messages if m.get("type") == "view_created"]
refused = [m for m in messages if m.get("type") == "error" and "request" in m]
if len(created) != maximum or len(refused) != 20:
    sys.exit(f"{len(created)} views created and {len(refused)} refused, of {maximum} and 20")
pump(3)
if not segments:
    sys.exit("no view announced a shared memory segment")
for view in created:
    send({"type": "close_view", "view": view})
pump(30, lambda: len([m for m in messages if m.get("type") == "view_closed"]) == len(created))
pump(1)
for name in segments:
    try:
        os.close(_posixshmem.shm_open(name, os.O_RDONLY, mode=0))
        sys.exit(f"the segment {name} outlived its view")
    except FileNotFoundError:
        pass
print(f"{len(created)} views created, {len(refused)} refused, {len(segments)} segments gone")
PY
flood() {
    python3 -I "$WORK/flood.py" "$SOCKET" "$TOOLS_DIR" >&2 || fail "flood of create_view"
    sleep 2
    pgrep -P "$SERVER_PID" WebContent | wc -l
}
# NB: Ladybird keeps a spare WebContent process for the next page; there is no more of them after the second flood
#     than after the first.
FIRST="$(flood)"
SECOND="$(flood)"
[ "$FIRST" -le "$((BEFORE + 1))" ] && [ "$SECOND" -le "$FIRST" ] \
    || fail "WebContent processes: $BEFORE before, $FIRST and $SECOND after closing the views of two floods"

kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
SERVER_PIDS=("${SERVER_PIDS[@]:0:${#SERVER_PIDS[@]}-1}")

# A client that comes back finds every view, the alert it left open, and the views it hid still hidden.
SOCKET="$WORK/r.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[${#SERVER_PIDS[@]} - 1]}"
"${CLIENT[@]}" --socket "$SOCKET" --url "$(page text.html)" --script "$CHECKS_DIR/views-detach.txt" || fail "views-detach script"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --script "$CHECKS_DIR/views-reattach.txt" || fail "views-reattach script"
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
SERVER_PIDS=("${SERVER_PIDS[@]:0:${#SERVER_PIDS[@]}-1}")

# Each client gets the frames of the views it finds as it asked for them, and segments of its own.
SOCKET="$WORK/e.sock"
start_socket_server "$SOCKET"
SERVER_PID="${SERVER_PIDS[${#SERVER_PIDS[@]} - 1]}"
"${CLIENT[@]}" --socket "$SOCKET" --shm --url "$(page text.html)" --script "$CHECKS_DIR/views-encodings-a.txt" \
    || fail "views-encodings-a script"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --encodings raw --script "$CHECKS_DIR/views-encodings-b.txt" \
    || fail "views-encodings-b script"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --shm --script "$CHECKS_DIR/views-encodings-c.txt" \
    || fail "views-encodings-c script"
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
echo "views: ok"
