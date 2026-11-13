# Shared by the check scripts: paths, a scratch directory and cleanup.

CHECKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "$CHECKS_DIR")"
LADYBIRD="${LADYBIRD:-/Users/daniel/src/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird}"
CLIENT=(python3 -I "$TOOLS_DIR/ladybird-client.py")
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ladybird-check.XXXXXX")"
SERVER="$LADYBIRD --headless=emacs --emacs-log=$WORK/stdio-server.log"
SERVER_PIDS=()

cleanup() {
    for pid in ${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# page NAME: the file:// URL of a test page.
page() {
    echo "file://$CHECKS_DIR/pages/$1"
}

# start_socket_server PATH [ARGS...]: starts a server on a Unix socket and waits for it to listen.
start_socket_server() {
    local path="$1"
    shift
    "$LADYBIRD" --headless=emacs --emacs-socket="$path" --emacs-log="$WORK/server.log" "$@" 2>"$WORK/server.stderr" &
    SERVER_PIDS+=($!)
    for _ in $(seq 100); do
        [ -S "$path" ] && return 0
        sleep 0.1
    done
    fail "the server did not create $path"
}

# server_pid PATH: connects to the socket at once, without waiting for it, and prints the pid of the process that
# listens there.
server_pid() {
    python3 -I - "$1" <<'PY'
import socket, struct, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
if sys.platform == "darwin":
    pid = struct.unpack("i", s.getsockopt(0, 2, 4))[0]  # SOL_LOCAL, LOCAL_PEERPID
else:
    pid = struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
print(pid)
PY
}
