#!/bin/sh
# Run the live scenarios against a real Ladybird server.
#
#   test/elate/run-live.sh [-v VARIANT[,VARIANT...]] [SCENARIO.json...]
#
# Without scenarios, every one in live/scenarios runs; without -v, every
# variant a scenario declares and this machine can serve:
#
#   stdio, socket   need the local server, LADYBIRD_LIVE_PROGRAM
#   ssh, forward    need LADYBIRD_LIVE_SSH_HOST, an ssh destination that
#                   takes no password, and LADYBIRD_LIVE_REMOTE_PROGRAM,
#                   the server's program there
#
# Every scenario runs in a graphical elate session.  One line per
# scenario and variant says PASS or FAIL; the output of each run is kept
# under LADYBIRD_LIVE_LOGS.  ELATE names the elate command.

here=$(cd "$(dirname "$0")" && pwd)
live=$here/live
elate=${ELATE:-uvx elate}
only=

while getopts v: opt; do
    case $opt in
        v) only=$OPTARG ;;
        *) echo "usage: $0 [-v VARIANTS] [SCENARIO.json...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || set -- "$live"/scenarios/*.json

: "${LADYBIRD_LIVE_PROGRAM:=/Users/daniel/src/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird}"
: "${LADYBIRD_LIVE_HOME:=$HOME}"
LADYBIRD_LIVE_RUN=run$$
logs=${LADYBIRD_LIVE_LOGS:-${TMPDIR:-/tmp}/ladybird-live-$LADYBIRD_LIVE_RUN}
export LADYBIRD_LIVE_PROGRAM LADYBIRD_LIVE_HOME LADYBIRD_LIVE_RUN
mkdir -p "$logs"

local_ok=
remote_ok=
if [ -x "$LADYBIRD_LIVE_PROGRAM" ]; then
    local_ok=1
else
    echo "SKIP stdio, socket: no server at $LADYBIRD_LIVE_PROGRAM (LADYBIRD_LIVE_PROGRAM)"
fi
if [ -z "$LADYBIRD_LIVE_SSH_HOST" ]; then
    echo "SKIP ssh, forward: LADYBIRD_LIVE_SSH_HOST is not set"
elif [ -z "$LADYBIRD_LIVE_REMOTE_PROGRAM" ]; then
    echo "SKIP ssh, forward: LADYBIRD_LIVE_REMOTE_PROGRAM is not set"
elif ! "$live/ssh" -o ConnectTimeout=10 "$LADYBIRD_LIVE_SSH_HOST" \
        test -x "$LADYBIRD_LIVE_REMOTE_PROGRAM"; then
    echo "SKIP ssh, forward: no server at $LADYBIRD_LIVE_SSH_HOST:$LADYBIRD_LIVE_REMOTE_PROGRAM"
else
    remote_ok=1
fi

# The scenarios clean up after themselves; this catches what a run that
# failed or was cut short left behind: elate sessions, servers, the ssh
# processes and the sockets and files named after this run.
sweep() {
    $elate list 2>/dev/null | python3 -c '
import json, sys
for session in json.load(sys.stdin).get("sessions", []):
    if session["name"].startswith("run-live-") and session["status"] != "stopped":
        print(session["name"])' 2>/dev/null |
        while read -r name; do $elate stop "$name" >/dev/null 2>&1; done
    $elate purge --glob 'run-live-*' >/dev/null 2>&1
    pkill -f "ladybird-live-$LADYBIRD_LIVE_RUN-" 2>/dev/null
    rm -f /tmp/ladybird-live-"$LADYBIRD_LIVE_RUN"-*
    if [ -n "$remote_ok" ]; then
        "$live/ssh" -o ConnectTimeout=10 "$LADYBIRD_LIVE_SSH_HOST" \
            "pkill -f ladybird-live-$LADYBIRD_LIVE_RUN-; rm -rf /tmp/ladybird-live-$LADYBIRD_LIVE_RUN-*" \
            >/dev/null 2>&1
    fi
}
trap sweep EXIT
trap 'exit 130' INT TERM

variants() {
    python3 -c '
import json, sys
names = list(json.load(open(sys.argv[1])).get("variants", {}))
only = [v for v in sys.argv[2].split(",") if v]
print(" ".join(v for v in names if (v in only if only else True)))
' "$1" "$only"
}

ui() {
    python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("session", {}).get("ui", "tty"))' "$1"
}

status=0
passed=0
failed=0
started=$(date +%s)
for scenario; do
    name=$(basename "$scenario" .json)
    name=${name#live-}
    for variant in $(variants "$scenario"); do
        case $variant in
            stdio|socket) [ -n "$local_ok" ] || continue ;;
            ssh|forward) [ -n "$remote_ok" ] || continue ;;
        esac
        log=$logs/$name-$variant.log
        begun=$(date +%s)
        if $elate run --keep-going --format human --variant "$variant" \
                "$scenario" >"$log" 2>&1; then
            verdict=PASS
            passed=$((passed + 1))
        else
            verdict=FAIL
            failed=$((failed + 1))
            status=1
        fi
        echo "$verdict $name [$variant] ($(ui "$scenario"), $(($(date +%s) - begun)) s)"
        if [ $verdict = FAIL ]; then
            grep -E -A1 '\.\.\. (FAIL|XPASS)|^(setup|.*: (PASS|FAIL|XFAIL))' "$log" |
                grep -v '^--$' | grep -v 'sandbox kept' | sed 's/^/    /'
            echo "    log: $log"
        fi
        sweep
    done
done
echo "$passed passed, $failed failed in $(($(date +%s) - started)) s; logs in $logs"
exit $status
