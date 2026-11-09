#!/bin/sh
# Run the elate scenarios against tools/mock-server.py.
#
#   test/elate/run.sh [-v VARIANT[,VARIANT...]] [SCENARIO.json...]
#
# Without scenarios, every one in matrix/ runs; without -v, every variant a
# scenario declares.  ELATE names the elate command and ELATE_FORMAT its
# output format.

here=$(cd "$(dirname "$0")" && pwd)
elate=${ELATE:-uvx elate}
format=${ELATE_FORMAT:-human}
only=

while getopts v: opt; do
    case $opt in
        v) only=$OPTARG ;;
        *) echo "usage: $0 [-v VARIANTS] [SCENARIO.json...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || set -- "$here"/matrix/*.json

variants() {
    python3 -c '
import json, sys
names = list(json.load(open(sys.argv[1])).get("variants", {}))
only = [v for v in sys.argv[2].split(",") if v]
print(" ".join(v for v in names if (v in only if only else True)) or ("-" if not names else ""))
' "$1" "$only"
}

status=0
for scenario; do
    for variant in $(variants "$scenario"); do
        if [ "$variant" = - ]; then
            echo "== $(basename "$scenario" .json)"
            $elate run --keep-going --format "$format" "$scenario" || status=1
        else
            echo "== $(basename "$scenario" .json) [$variant]"
            $elate run --keep-going --format "$format" --variant "$variant" "$scenario" || status=1
        fi
    done
done
exit $status
