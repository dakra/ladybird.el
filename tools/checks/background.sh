#!/bin/bash
# A server started in the background: the start returns once the socket accepts connections, the server outlives the
# process that started it, one server per socket, stale sockets, socket paths that do not fit, and the default socket.
set -u
. "$(dirname "$0")/common.sh"

cat > "$WORK/ping.txt" <<'SCRIPT'
{"type":"ping","id":7}
expect pong id=7
SCRIPT

# run NAME SECONDS ARGS...: runs Ladybird with ARGS in a process group of its own, with its standard streams on pipes,
# and writes its exit status, stdout and stderr to $WORK/NAME.status, .out and .err. The status is "timeout" when it has
# not ended with its streams closed after SECONDS, as when a server holds on to them; its group is then sent SIGTERM.
run() {
    local name="$1" seconds="$2"
    shift 2
    python3 -I - "$WORK/$name" "$seconds" "$LADYBIRD" "$@" <<'PY'
import os, signal, subprocess, sys
prefix, seconds = sys.argv[1], float(sys.argv[2])
process = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           process_group=0)
try:
    stdout, stderr = process.communicate(timeout=seconds)
    status = str(process.returncode)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    stdout, stderr = process.communicate()
    status = "timeout"
open(prefix + ".status", "w").write(status)
open(prefix + ".out", "wb").write(stdout)
open(prefix + ".err", "wb").write(stderr)
PY
    [ $? -eq 0 ] || fail "$name: could not run Ladybird"
}

# start NAME ARGS...: a background start, which must end within the minute it waits for the server and a bit.
start() {
    local name="$1"
    shift
    run "$name" 75 --headless=emacs --emacs-background "$@"
}

# hold_lock PATH SECONDS: holds an exclusive flock on PATH, which it creates, for SECONDS, in the background. Returns
# once the lock is held.
hold_lock() {
    rm -f "$WORK/lock-held"
    python3 -I - "$1" "$2" "$WORK/lock-held" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[3], "w").close()
time.sleep(float(sys.argv[2]))
PY
    LOCK_HOLDER=$!
    for _ in $(seq 100); do
        [ -e "$WORK/lock-held" ] && return 0
        sleep 0.1
    done
    fail "could not take the lock $1"
}

status() {
    cat "$WORK/$1.status"
}

# stop PID PATH: ends the server and waits until it has removed its socket.
stop() {
    kill -TERM "$1" || fail "server $1 is not running"
    for _ in $(seq 100); do
        kill -0 "$1" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$1" 2>/dev/null && fail "server $1 did not end"
    [ -e "$2" ] && fail "the socket $2 outlived the server"
    [ -e "$2.lock" ] && fail "the lock file $2.lock was left behind"
    return 0
}

# Started servers are not children of this shell, so cleanup() does not see them. A server that started where it
# should not have is found by its socket.
BACKGROUND_PIDS=()
stop_all() {
    local path pid
    for path in "${SOCKET:-}" "$WORK/run/ladybird-emacs.sock" "${DEFAULT_SOCKET:-}"; do
        [ -S "$path" ] && pid="$(server_pid "$path" 2>/dev/null)" && BACKGROUND_PIDS+=("$pid")
    done
    for pid in ${BACKGROUND_PIDS[@]+"${BACKGROUND_PIDS[@]}"}; do
        kill -TERM "$pid" 2>/dev/null
    done
    [ -n "${TEMPORARY:-}" ] && rm -rf "$TEMPORARY"
    [ -n "${TEMPORARY_LOG_PID:-}" ] && rm -f /tmp/ladybird-emacs-"$TEMPORARY_LOG_PID"-??????.log
    cleanup
}
trap stop_all EXIT

SOCKET="$WORK/bg.sock"

# The start returns once the socket accepts connections, and says where the server logs to.
start first --emacs-socket="$SOCKET" --emacs-log="$WORK/first.log"
[ "$(status first)" = 0 ] || fail "the background start failed: $(cat "$WORK/first.err")"
PID="$(server_pid "$SOCKET")" || fail "the socket did not accept a connection when the start returned"
BACKGROUND_PIDS+=("$PID")
grep -qx "Ladybird logs to $WORK/first.log" "$WORK/first.err" || fail "the start did not name the log: $(cat "$WORK/first.err")"
[ -s "$WORK/first.out" ] && fail "the start wrote to stdout: $(cat "$WORK/first.out")"

# The server runs in a session of its own, so it outlives whoever started it and gets no signal sent to their group.
python3 -I -c 'import os, sys; pid = int(sys.argv[1]); sys.exit(os.getsid(pid) != pid or os.getsid(pid) == os.getsid(0))' "$PID" \
    || fail "the server does not lead a session of its own"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" || fail "ping after the start"
[ -e "$SOCKET.lock" ] && fail "the lock file is left next to a running server"

# A second start on a socket that a server answers on fails, in the background and in the foreground, and leaves the
# server its socket and its log, even when it names the same log.
[ -s "$WORK/first.log" ] || fail "the server logged nothing for a connection"
LOG_SIZE="$(wc -c < "$WORK/first.log")"
head -c "$LOG_SIZE" "$WORK/first.log" > "$WORK/first.log.before"
start second --emacs-socket="$SOCKET" --emacs-log="$WORK/first.log"
[ "$(status second)" != 0 ] || fail "a second server started on the same socket"
grep -q "already listens" "$WORK/second.err" || fail "no clear error from the second start: $(cat "$WORK/second.err")"
run second-foreground 20 --headless=emacs --emacs-socket="$SOCKET" --emacs-log="$WORK/first.log"
[ "$(status second-foreground)" != 0 ] || fail "a second foreground server started on the same socket"
grep -q "already listens" "$WORK/second-foreground.err" || fail "no clear error from the second foreground server"
head -c "$LOG_SIZE" "$WORK/first.log" | cmp -s - "$WORK/first.log.before" || fail "a refused start changed the server's log"
[ "$(server_pid "$SOCKET")" = "$PID" ] || fail "the first server lost its socket"
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" || fail "ping after the second start"

stop "$PID" "$SOCKET"

# A socket file that nobody listens on is replaced.
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCKET"
[ -S "$SOCKET" ] || fail "could not leave a stale socket"
start stale --emacs-socket="$SOCKET" --emacs-log="$WORK/stale.log"
[ "$(status stale)" = 0 ] || fail "the start on a stale socket failed: $(cat "$WORK/stale.err")"
PID="$(server_pid "$SOCKET")" || fail "the stale socket was not replaced"
BACKGROUND_PIDS+=("$PID")
"${CLIENT[@]}" --socket "$SOCKET" --no-view --strict --script "$WORK/ping.txt" || fail "ping on the replaced socket"
stop "$PID" "$SOCKET"

# A start waits while another holds the lock next to the socket, and goes on once it is released.
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCKET"
hold_lock "$SOCKET.lock" 3
start locked --emacs-socket="$SOCKET" --emacs-log="$WORK/locked.log" &
LOCKED=$!
sleep 1.5
[ -e "$WORK/locked.status" ] && fail "a start went on while the lock was held: $(cat "$WORK/locked.err")"
[ -S "$SOCKET" ] && python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])' "$SOCKET" 2>/dev/null \
    && fail "a server listened while the lock was held"
wait $LOCKED
wait $LOCK_HOLDER
[ "$(status locked)" = 0 ] || fail "the start failed after the lock was released: $(cat "$WORK/locked.err")"
PID="$(server_pid "$SOCKET")" || fail "no server after the lock was released"
BACKGROUND_PIDS+=("$PID")
stop "$PID" "$SOCKET"

# A start gives up when the lock is held for longer than another server takes to start.
hold_lock "$SOCKET.lock" 13
start lock-timeout --emacs-socket="$SOCKET" --emacs-log="$WORK/lock-timeout.log"
wait $LOCK_HOLDER
rm -f "$SOCKET.lock"
[ "$(status lock-timeout)" = 1 ] || fail "a start did not give up on a lock that stays held: $(status lock-timeout)"
grep -q "Another server is still starting on the Emacs socket path" "$WORK/lock-timeout.err" \
    || fail "no clear error for a lock that stays held: $(cat "$WORK/lock-timeout.err")"
[ -e "$SOCKET" ] && fail "a start that gave up made a socket"
[ -e "$WORK/lock-timeout.log" ] && fail "a start that gave up opened its log"

# A "--" ends the options, and the server it starts serves the URL after it rather than starting another server.
start dashes --emacs-socket="$SOCKET" --emacs-log="$WORK/dashes.log" -- about:blank
[ "$(status dashes)" = 0 ] || fail "the start with -- failed: $(cat "$WORK/dashes.err")"
PID="$(server_pid "$SOCKET")" || fail "no server after the start with --"
BACKGROUND_PIDS+=("$PID")
sleep 1
COUNT="$(pgrep -f -- "--emacs-socket=$SOCKET" | wc -l | tr -d ' ')"
[ "$COUNT" = 1 ] || fail "the start with -- left $COUNT processes on the socket"
stop "$PID" "$SOCKET"

# Without --emacs-log and XDG_RUNTIME_DIR the server logs to a file of its own in /tmp, with a name nobody can tell
# beforehand, which the start names.
XDG_RUNTIME_DIR= start default-log --emacs-socket="$SOCKET"
[ "$(status default-log)" = 0 ] || fail "the start without a log failed: $(cat "$WORK/default-log.err")"
PID="$(server_pid "$SOCKET")" || fail "no server after the start without a log"
BACKGROUND_PIDS+=("$PID")
TEMPORARY_LOG_PID="$PID"
DEFAULT_LOG="$(sed -n "s|^Ladybird logs to \(/tmp/ladybird-emacs-$PID-[A-Za-z0-9]\{6\}\.log\)\$|\1|p" "$WORK/default-log.err")"
[ -n "$DEFAULT_LOG" ] || fail "the start did not name the server's own log: $(cat "$WORK/default-log.err")"
python3 -I -c 'import os, stat, sys; s = os.lstat(sys.argv[1]); sys.exit(not stat.S_ISREG(s.st_mode) or s.st_mode & 0o777 != 0o600)' "$DEFAULT_LOG" \
    || fail "no log of mode 0600 at $DEFAULT_LOG"
stop "$PID" "$SOCKET"
rm -f "$DEFAULT_LOG"

# file_mode_is PATH MODE: whether PATH is a regular file of MODE (octal), not a link.
file_mode_is() {
    python3 -I -c 'import os, stat, sys; s = os.lstat(sys.argv[1]); sys.exit(not stat.S_ISREG(s.st_mode) or stat.S_IMODE(s.st_mode) != int(sys.argv[2], 8))' "$1" "$2"
}

# With XDG_RUNTIME_DIR the log is there, for a server on a socket and for one over stdio.
mkdir -m 700 "$WORK/xdg-log" "$WORK/xdg-stdio"
XDG_RUNTIME_DIR="$WORK/xdg-log" start xdg-log --emacs-socket="$SOCKET"
[ "$(status xdg-log)" = 0 ] || fail "the start without a log with XDG_RUNTIME_DIR failed: $(cat "$WORK/xdg-log.err")"
PID="$(server_pid "$SOCKET")" || fail "no server after the start without a log with XDG_RUNTIME_DIR"
BACKGROUND_PIDS+=("$PID")
grep -qx "Ladybird logs to $WORK/xdg-log/ladybird-emacs-$PID.log" "$WORK/xdg-log.err" \
    || fail "the server did not log in XDG_RUNTIME_DIR: $(cat "$WORK/xdg-log.err")"
file_mode_is "$WORK/xdg-log/ladybird-emacs-$PID.log" 600 || fail "no log of mode 0600 in XDG_RUNTIME_DIR"
stop "$PID" "$SOCKET"
"${CLIENT[@]}" --server "env XDG_RUNTIME_DIR=$WORK/xdg-stdio $LADYBIRD --headless=emacs" --no-view --strict --script "$WORK/ping.txt" \
    || fail "ping over stdio with XDG_RUNTIME_DIR"
STDIO_LOGS=("$WORK"/xdg-stdio/ladybird-emacs-*.log)
[ ${#STDIO_LOGS[@]} = 1 ] && file_mode_is "${STDIO_LOGS[0]}" 600 \
    || fail "the server over stdio did not log in XDG_RUNTIME_DIR: $(ls -A "$WORK/xdg-stdio")"

# So it does when the log cannot be made in XDG_RUNTIME_DIR, here one that is missing.
XDG_RUNTIME_DIR="$WORK/missing-run" start default-log-fallback --emacs-socket="$SOCKET"
[ "$(status default-log-fallback)" = 0 ] || fail "the start without a log in XDG_RUNTIME_DIR failed: $(cat "$WORK/default-log-fallback.err")"
PID="$(server_pid "$SOCKET")" || fail "no server after the start without a log in XDG_RUNTIME_DIR"
BACKGROUND_PIDS+=("$PID")
TEMPORARY_LOG_PID="$PID"
grep -qx "Ladybird logs to /tmp/ladybird-emacs-$PID-[A-Za-z0-9]\{6\}\.log" "$WORK/default-log-fallback.err" \
    || fail "the server did not log in /tmp: $(cat "$WORK/default-log-fallback.err")"
stop "$PID" "$SOCKET"
rm -f /tmp/ladybird-emacs-"$PID"-??????.log

# A path that does not fit a Unix socket address is refused up front, in the background and in the foreground.
LONG="$WORK/$(printf 'x%.0s' $(seq 120)).sock"
start long --emacs-socket="$LONG" --emacs-log="$WORK/long.log"
[ "$(status long)" = 1 ] || fail "a server started on a path that is too long"
grep -q "longer than a Unix socket address can hold" "$WORK/long.err" || fail "no clear error for a long path: $(cat "$WORK/long.err")"
run long-foreground 20 --headless=emacs --emacs-socket="$LONG" --emacs-log="$WORK/long-foreground.log"
[ "$(status long-foreground)" = 1 ] || fail "a foreground server started on a path that is too long"
grep -q "longer than a Unix socket address can hold" "$WORK/long-foreground.err" || fail "no clear error for a long path in the foreground"
[ -e "$LONG" ] && fail "a socket was made at the long path"

# The reason a server could not open its log reaches the start.
start no-log-directory --emacs-socket="$SOCKET" --emacs-log="$WORK/missing/server.log"
[ "$(status no-log-directory)" = 1 ] || fail "the start succeeded with a log that cannot be written"
grep -qF "Unable to start the Emacs server: Unable to open the log $WORK/missing/server.log: " "$WORK/no-log-directory.err" \
    || fail "the error for a log that cannot be opened does not name it: $(cat "$WORK/no-log-directory.err")"
grep -q "Unable to start the Emacs server: .*No such file or directory" "$WORK/no-log-directory.err" \
    || fail "no clear error for a log that cannot be opened: $(cat "$WORK/no-log-directory.err")"
[ -e "$SOCKET" ] && fail "a server that could not open its log left its socket"

# The background start needs a socket and the Emacs mode.
start no-socket --emacs-log="$WORK/no-socket.log"
[ "$(status no-socket)" = 1 ] || fail "a background start without a socket succeeded"
grep -q "needs --emacs-socket or --emacs-default-socket" "$WORK/no-socket.err" || fail "no clear error without a socket"
run not-emacs 20 --headless=text --emacs-background --emacs-socket="$SOCKET" --emacs-log="$WORK/not-emacs.log" about:blank
[ "$(status not-emacs)" = 1 ] || fail "--emacs-background was taken without --headless=emacs: $(status not-emacs)"
grep -q "needs --headless=emacs" "$WORK/not-emacs.err" || fail "no clear error for --emacs-background in another mode"
mkdir -m 700 "$WORK/text"
XDG_RUNTIME_DIR= TMPDIR="$WORK/text" run default-not-emacs 20 --headless=text --emacs-default-socket about:blank
[ "$(status default-not-emacs)" = 1 ] || fail "--emacs-default-socket was taken without --headless=emacs: $(status default-not-emacs)"
grep -q "\-\-emacs-default-socket needs --headless=emacs" "$WORK/default-not-emacs.err" \
    || fail "no clear error for --emacs-default-socket in another mode: $(cat "$WORK/default-not-emacs.err")"
[ -z "$(ls -A "$WORK/text")" ] || fail "--emacs-default-socket in another mode made $(ls -A "$WORK/text")"

# The default socket is in XDG_RUNTIME_DIR, and without it, or with a relative one, in a directory of the user's own in
# TMPDIR. A trailing slash on the directory makes no difference. Without --emacs-log the server logs next to the default
# socket. The fallback to /tmp is left alone, since a server of the user's own may be listening there.
mkdir -m 700 "$WORK/run"
XDG_RUNTIME_DIR="$WORK/run/" start default-xdg --emacs-default-socket
[ "$(status default-xdg)" = 0 ] || fail "the start on the default socket failed: $(cat "$WORK/default-xdg.err")"
PID="$(server_pid "$WORK/run/ladybird-emacs.sock")" || fail "no server on \$XDG_RUNTIME_DIR/ladybird-emacs.sock"
BACKGROUND_PIDS+=("$PID")
grep -qx "Ladybird logs to $WORK/run/ladybird-emacs-$PID.log" "$WORK/default-xdg.err" \
    || fail "the server on the default socket does not log in XDG_RUNTIME_DIR: $(cat "$WORK/default-xdg.err")"
"${CLIENT[@]}" --socket "$WORK/run/ladybird-emacs.sock" --no-view --strict --script "$WORK/ping.txt" || fail "ping on the default socket"
stop "$PID" "$WORK/run/ladybird-emacs.sock"

# The socket path in $WORK, which is in TMPDIR, may not fit a Unix socket address, so this TMPDIR is in /tmp.
TEMPORARY="$(mktemp -d /tmp/ladybird-check.XXXXXX)"
PRIVATE="$TEMPORARY/ladybird-emacs-$(id -ru)"
DEFAULT_SOCKET="$PRIVATE/ladybird-emacs.sock"

# mode_is PATH MODE: whether PATH is a directory of MODE (octal), not a link.
mode_is() {
    python3 -I -c 'import os, stat, sys; s = os.lstat(sys.argv[1]); sys.exit(not stat.S_ISDIR(s.st_mode) or stat.S_IMODE(s.st_mode) != int(sys.argv[2], 8))' "$1" "$2"
}

XDG_RUNTIME_DIR= TMPDIR="$TEMPORARY/" start default-tmp --emacs-default-socket
[ "$(status default-tmp)" = 0 ] || fail "the start on the default socket in TMPDIR failed: $(cat "$WORK/default-tmp.err")"
PID="$(server_pid "$DEFAULT_SOCKET")" || fail "no server on \$TMPDIR/ladybird-emacs-<uid>/ladybird-emacs.sock"
BACKGROUND_PIDS+=("$PID")
mode_is "$PRIVATE" 700 || fail "the directory of the default socket is not one of mode 0700"
grep -qx "Ladybird logs to $PRIVATE/ladybird-emacs-$PID.log" "$WORK/default-tmp.err" \
    || fail "the server on the default socket does not log in its directory: $(cat "$WORK/default-tmp.err")"
file_mode_is "$PRIVATE/ladybird-emacs-$PID.log" 600 || fail "no log of mode 0600 in the directory of the default socket"
stop "$PID" "$DEFAULT_SOCKET"

# A directory that is there already is taken when only the user may enter it, and a relative XDG_RUNTIME_DIR is
# taken as unset. Ladybird keeps other files in XDG_RUNTIME_DIR, so the relative one is in $WORK.
mkdir "$WORK/cwd"
(cd "$WORK/cwd" && XDG_RUNTIME_DIR=run TMPDIR="$TEMPORARY" start default-tmp-again --emacs-default-socket --emacs-log="$WORK/default-tmp-again.log")
[ "$(status default-tmp-again)" = 0 ] || fail "the start in the existing directory failed: $(cat "$WORK/default-tmp-again.err")"
PID="$(server_pid "$DEFAULT_SOCKET")" || fail "no server in the existing directory"
BACKGROUND_PIDS+=("$PID")
stop "$PID" "$DEFAULT_SOCKET"

# refused NAME MESSAGE: a start on the default socket in TMPDIR fails with MESSAGE, naming the directory, in the
# background and in the foreground, and makes no socket.
refused() {
    local name
    for name in "$1" "$1-foreground"; do
        if [ "$name" = "$1" ]; then
            XDG_RUNTIME_DIR= TMPDIR="$TEMPORARY" start "$name" --emacs-default-socket --emacs-log="$WORK/$name.log"
        else
            XDG_RUNTIME_DIR= TMPDIR="$TEMPORARY" run "$name" 20 --headless=emacs --emacs-default-socket --emacs-log="$WORK/$name.log"
        fi
        [ "$(status "$name")" = 1 ] || fail "$name: a server started: $(cat "$WORK/$name.err")"
        grep -q "$2" "$WORK/$name.err" || fail "$name: no clear error: $(cat "$WORK/$name.err")"
        grep -qF "Unable to use $PRIVATE for the default Emacs socket: The directory of the default Emacs socket $2" "$WORK/$name.err" \
            || fail "$name: the error does not name the directory: $(cat "$WORK/$name.err")"
        [ -e "$WORK/$name.log" ] && fail "$name: the refused start opened its log"
    done
    [ -e "$DEFAULT_SOCKET" ] && fail "$1: a socket was made"
    return 0
}

chmod 750 "$PRIVATE"
refused default-group "grants permissions to its group or others"
chmod 701 "$PRIVATE"
refused default-other "grants permissions to its group or others"
rm -r "$PRIVATE"
mkdir -m 700 "$TEMPORARY/elsewhere"
ln -s "$TEMPORARY/elsewhere" "$PRIVATE"
refused default-link "is a symbolic link"
[ -e "$TEMPORARY/elsewhere/ladybird-emacs.sock.lock" ] && fail "a start took the lock in the directory a link names"
rm "$PRIVATE"
touch "$PRIVATE"
refused default-file "exists and is not a directory"
rm -f "$PRIVATE"
chmod 777 "$TEMPORARY"
refused default-parent "is in a directory that others can write to"
[ -e "$PRIVATE" ] && fail "a start made the directory in a directory that others can write to"
chmod 770 "$TEMPORARY"
refused default-parent-group "is in a directory that others can write to"
[ -e "$PRIVATE" ] && fail "a start made the directory in a directory that its group can write to"
XDG_RUNTIME_DIR= TMPDIR="$TEMPORARY/missing" run default-missing 20 --headless=emacs --emacs-default-socket --emacs-log="$WORK/default-missing.log"
[ "$(status default-missing)" = 1 ] || fail "a server started in a TMPDIR that is missing"
grep -qF "Unable to use $TEMPORARY/missing/ladybird-emacs-$(id -ru) for the default Emacs socket: " "$WORK/default-missing.err" \
    || fail "the error for a missing TMPDIR does not name the directory: $(cat "$WORK/default-missing.err")"

# A default socket path that does not fit a Unix socket address is named, in XDG_RUNTIME_DIR and in TMPDIR.
LONG_DIRECTORY="$WORK/$(printf 'y%.0s' $(seq 100))"
for variables in "XDG_RUNTIME_DIR=$LONG_DIRECTORY" "XDG_RUNTIME_DIR= TMPDIR=$LONG_DIRECTORY"; do
    case "$variables" in
        XDG_RUNTIME_DIR=/*) LONG_DEFAULT="$LONG_DIRECTORY/ladybird-emacs.sock" ;;
        *) LONG_DEFAULT="$LONG_DIRECTORY/ladybird-emacs-$(id -ru)/ladybird-emacs.sock" ;;
    esac
    env $variables "$LADYBIRD" --headless=emacs --emacs-background --emacs-default-socket >/dev/null 2>"$WORK/default-long.err" \
        && fail "a server started on a default socket path that is too long"
    grep -qF "Unable to use $LONG_DEFAULT as the default Emacs socket: The Emacs socket path is longer" "$WORK/default-long.err" \
        || fail "the error for a long default socket path does not name it: $(cat "$WORK/default-long.err")"
done
[ -e "$LONG_DIRECTORY" ] && fail "a start on a default socket path that is too long made $LONG_DIRECTORY"

# In a sticky TMPDIR that anyone may write to, the directory is made with mode 0700 whatever the umask.
chmod 1777 "$TEMPORARY"
(umask 277 && XDG_RUNTIME_DIR= TMPDIR="$TEMPORARY" start default-sticky --emacs-default-socket --emacs-log="$WORK/default-sticky.log")
[ "$(status default-sticky)" = 0 ] || fail "the start in a sticky TMPDIR failed: $(cat "$WORK/default-sticky.err")"
PID="$(server_pid "$DEFAULT_SOCKET")" || fail "no server in a sticky TMPDIR"
BACKGROUND_PIDS+=("$PID")
mode_is "$PRIVATE" 700 || fail "with umask 277 the directory of the default socket is not one of mode 0700"
stop "$PID" "$DEFAULT_SOCKET"
chmod 700 "$TEMPORARY"

XDG_RUNTIME_DIR="$WORK/run" run both 20 --headless=emacs --emacs-default-socket --emacs-socket="$SOCKET" --emacs-log="$WORK/both.log"
[ "$(status both)" = 1 ] || fail "a server started with both --emacs-socket and --emacs-default-socket: $(status both)"
grep -q "cannot be given together" "$WORK/both.err" || fail "no clear error for both socket options"

echo "background: ok"
