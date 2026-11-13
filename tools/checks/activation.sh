#!/bin/bash
# A server started by socket activation as systemd does it: LISTEN_PID and LISTEN_FDS=1 with the listening socket as
# descriptor 3. The server serves the socket it is handed without binding one, leaves the socket file to whoever made
# it, keeps the socket and the variables from its helpers, and refuses a descriptor it cannot serve.
set -u
. "$(dirname "$0")/common.sh"

cat > "$WORK/ping.txt" <<'SCRIPT'
{"type":"ping","id":7}
expect pong id=7
SCRIPT

# The launcher makes what MODE says, puts it at descriptor 3, sets the variables as MODE says and runs the command after
# "--" in its place, so that LISTEN_PID names the server. It writes the inode of a socket it binds to PATH.inode.
cat > "$WORK/activate.py" <<'PY'
import os, socket, sys
mode, path = sys.argv[1], sys.argv[2]
command = sys.argv[sys.argv.index("--") + 1:]
listen_pid, listen_fds = str(os.getpid()), "1"
fd = None
if mode in ("unix", "wrong-pid", "two", "no-pid", "bound"):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    if mode != "bound":
        s.listen()
    open(path + ".inode", "w").write(str(os.lstat(path).st_ino))
    fd = s.detach()
    listen_pid = {"wrong-pid": str(os.getppid())}.get(mode, listen_pid)
    listen_fds = {"two": "2"}.get(mode, listen_fds)
elif mode == "unbound":
    fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).detach()
elif mode == "datagram":
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.bind(path)
    fd = s.detach()
elif mode == "tcp":
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen()
    fd = s.detach()
elif mode == "connected":
    a, b = socket.socketpair()
    fd = a.detach()
    # The other end stays open in the server, at descriptor 4, so that the socket stays connected.
    os.dup2(b.detach(), 4)
elif mode == "file":
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
elif mode == "pipe":
    fd, _ = os.pipe()
elif mode != "closed" and mode != "none":
    sys.exit("unknown mode " + mode)
if fd is not None and fd != 3:
    os.dup2(fd, 3)
    os.close(fd)
if fd is not None:
    os.set_inheritable(3, True)
else:
    try:
        os.close(3)
    except OSError:
        pass
if mode == "none":
    os.environ.pop("LISTEN_PID", None)
    os.environ.pop("LISTEN_FDS", None)
else:
    os.environ["LISTEN_FDS"] = listen_fds
    if mode != "no-pid":
        os.environ["LISTEN_PID"] = listen_pid
os.execv(command[0], command)
PY

# run NAME SECONDS MODE PATH ARGS...: runs Ladybird with ARGS under the launcher, with its standard streams on pipes, and
# writes its exit status and stderr to $WORK/NAME.status and .err; "timeout" when it has not ended after SECONDS.
run() {
    local name="$1" seconds="$2" mode="$3" path="$4"
    shift 4
    python3 -I - "$WORK/$name" "$seconds" python3 -I "$WORK/activate.py" "$mode" "$path" -- "$LADYBIRD" "$@" <<'PY'
import os, signal, subprocess, sys
prefix, seconds = sys.argv[1], float(sys.argv[2])
process = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                           process_group=0)
try:
    _, stderr = process.communicate(timeout=seconds)
    status = str(process.returncode)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    _, stderr = process.communicate()
    status = "timeout"
open(prefix + ".status", "w").write(status)
open(prefix + ".err", "wb").write(stderr)
PY
    [ $? -eq 0 ] || fail "$name: could not run Ladybird"
}

status() {
    cat "$WORK/$1.status"
}

inode() {
    python3 -I -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' "$1"
}

refuses_connections() {
    python3 -I -c '
import socket, sys
try:
    socket.socket(socket.AF_UNIX).connect(sys.argv[1])
except ConnectionRefusedError:
    sys.exit(0)
sys.exit(1)' "$1"
}

SOCKET="$WORK/activated.sock"
mkdir -m 700 "$WORK/run"

# The server serves the socket it is handed. A client may connect before the server has started, as with systemd.
XDG_RUNTIME_DIR="$WORK/run" python3 -I "$WORK/activate.py" unix "$SOCKET" -- \
    "$LADYBIRD" --headless=emacs --emacs-socket-activation </dev/null 2>"$WORK/activated.err" &
PID=$!
SERVER_PIDS+=("$PID")
for _ in $(seq 100); do
    [ -e "$SOCKET.inode" ] && break
    sleep 0.1
done
[ -e "$SOCKET.inode" ] || fail "the launcher did not bind $SOCKET"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" || fail "ping on the handed socket"
if command -v lsof >/dev/null; then
    # Linux's lsof adds " type=STREAM" to the name.
    lsof -a -p "$PID" -d 3 -U -F n 2>/dev/null \
        | awk -v name="n$SOCKET" '$0 == name || substr($0, 1, length(name) + 6) == name " type=" { found = 1 } END { exit !found }' \
        || fail "the server does not hold the handed socket at descriptor 3"
fi

# It does not bind a socket of its own: the socket file is the launcher's, and there is no lock file next to it.
[ "$(inode "$SOCKET")" = "$(cat "$SOCKET.inode")" ] || fail "the server replaced the socket it was handed"
[ -e "$SOCKET.lock" ] && fail "the server took the lock of a socket path"

# Without --emacs-log it logs in XDG_RUNTIME_DIR, and says so on stderr.
grep -qx "Ladybird logs to $WORK/run/ladybird-emacs-$PID.log" "$WORK/activated.err" \
    || fail "the server did not name its log in XDG_RUNTIME_DIR: $(cat "$WORK/activated.err")"
python3 -I -c 'import os, stat, sys; s = os.lstat(sys.argv[1]); sys.exit(not stat.S_ISREG(s.st_mode) or stat.S_IMODE(s.st_mode) != 0o600)' \
    "$WORK/run/ladybird-emacs-$PID.log" || fail "no log of mode 0600 in XDG_RUNTIME_DIR"

# Its helpers get neither the variables nor the socket.
ps eww -o command= -p "$PID" | grep -q LISTEN_FDS= || fail "ps does not show the environment the server was started with"
HELPERS="$(pgrep -P "$PID")"
[ -n "$HELPERS" ] || fail "the server started no helper process"
for helper in $HELPERS; do
    ps eww -o command= -p "$helper" | grep -q LISTEN_ && fail "helper $helper got the LISTEN_ variables"
    if command -v lsof >/dev/null; then
        lsof -a -p "$helper" -U 2>/dev/null | grep -qF "$SOCKET" && fail "helper $helper got the socket"
    fi
done

# Stopped, it leaves the socket file to whoever made it, and nothing listens on it any more.
kill -TERM "$PID"
wait "$PID"
[ -S "$SOCKET" ] || fail "the server removed the socket it was handed"
[ "$(inode "$SOCKET")" = "$(cat "$SOCKET.inode")" ] || fail "the socket changed when the server stopped"
refuses_connections "$SOCKET" || fail "the handed socket still accepts connections after the server stopped"
rm -f "$SOCKET" "$SOCKET.inode"

# refused NAME MODE MESSAGE: the server under the launcher in MODE fails with MESSAGE, opens no log and makes no socket.
refused() {
    local name="$1" mode="$2" message="$3"
    rm -f "$SOCKET" "$SOCKET.inode"
    XDG_RUNTIME_DIR="$WORK/run" run "$name" 30 "$mode" "$SOCKET" --headless=emacs --emacs-socket-activation \
        --emacs-log="$WORK/$name.log"
    [ "$(status "$name")" = 1 ] || fail "$name: the server did not refuse: $(status "$name"): $(cat "$WORK/$name.err")"
    grep -qE "^Unable to take the socket handed to the Emacs server: ($message)\$" "$WORK/$name.err" \
        || fail "$name: no clear error: $(cat "$WORK/$name.err")"
    [ -e "$WORK/$name.log" ] && fail "$name: the refused server opened its log"
    [ -e "$SOCKET.lock" ] && fail "$name: the refused server took a lock"
    if [ -e "$SOCKET.inode" ]; then
        [ "$(inode "$SOCKET")" = "$(cat "$SOCKET.inode")" ] || fail "$name: the socket was replaced"
    fi
    return 0
}

if [ "$(uname)" = Darwin ]; then
    # Without the variables, the server asks launchd, which did not start it.
    refused none none "Neither LISTEN_FDS nor a launchd job hands this process a socket|The launchd job of this process has no socket named Listeners"
else
    refused none none "Neither LISTEN_PID nor LISTEN_FDS is set"
fi
refused wrong-pid wrong-pid "LISTEN_PID does not name this process"
refused no-pid no-pid "LISTEN_PID does not name this process"
refused two two "LISTEN_FDS does not count exactly one socket"
refused closed closed "There is no open descriptor 3"
refused file file "It is not a socket"
refused pipe pipe "It is not a socket"
refused datagram datagram "It is not a stream socket"
refused tcp tcp "It is not a Unix socket"
if [ "$(uname)" = Darwin ]; then
    # macOS cannot be asked whether a socket listens, so a socket that is not connected is made to listen.
    refused connected connected "It is or was connected"
    refused unbound unbound "It is not bound to an address and cannot listen"
    rm -f "$SOCKET" "$SOCKET.inode"
    XDG_RUNTIME_DIR="$WORK/run" python3 -I "$WORK/activate.py" bound "$SOCKET" -- \
        "$LADYBIRD" --headless=emacs --emacs-socket-activation --emacs-log="$WORK/bound.log" </dev/null 2>"$WORK/bound.err" &
    PID=$!
    SERVER_PIDS+=("$PID")
    for _ in $(seq 300); do
        grep -q "^Ladybird logs to " "$WORK/bound.err" 2>/dev/null && break
        sleep 0.1
    done
    "${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" \
        || fail "ping on a bound socket that was handed over before it listened"
    kill -TERM "$PID"
    wait "$PID"
else
    refused connected connected "It does not listen"
    refused unbound unbound "It does not listen"
    refused bound bound "It does not listen"
fi

# The option is for the Emacs mode only, and goes with neither another socket nor a background start.
rm -f "$SOCKET" "$SOCKET.inode"
for args in "--headless=text --emacs-socket-activation about:blank" \
    "--headless=emacs --emacs-socket-activation --emacs-socket=$WORK/other.sock" \
    "--headless=emacs --emacs-socket-activation --emacs-default-socket" \
    "--headless=emacs --emacs-socket-activation --emacs-background"; do
    mkdir -m 700 "$WORK/options"
    # shellcheck disable=SC2086
    XDG_RUNTIME_DIR= TMPDIR="$WORK/options" run options 30 unix "$SOCKET" $args --emacs-log="$WORK/options.log"
    [ "$(status options)" = 1 ] || fail "$args: the server did not refuse: $(status options)"
    grep -qE "\-\-emacs-socket-activation (needs --headless=emacs|cannot be given with --emacs-socket or --emacs-default-socket|and --emacs-background cannot be given together)" \
        "$WORK/options.err" || fail "$args: no clear error: $(cat "$WORK/options.err")"
    [ -z "$(ls -A "$WORK/options")" ] || fail "$args: made $(ls -A "$WORK/options")"
    [ -e "$WORK/options.log" ] && fail "$args: opened its log"
    [ -e "$WORK/other.sock" ] && fail "$args: made a socket"
    rmdir "$WORK/options"
    rm -f "$SOCKET" "$SOCKET.inode"
done

echo "activation: ok"
