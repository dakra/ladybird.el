#!/bin/bash
# T7: raw, zstd and shared memory frames all give the same pixels; shm_failed falls back to the stream.
set -u
. "$(dirname "$0")/common.sh"

URL="$(page text.html)"

run() {
    local name="$1"
    shift
    "${CLIENT[@]}" --server "$SERVER" --strict --url "$URL" --png "$WORK/$name.png" --dump "$@" 2>"$WORK/$name.out" \
        || { cat "$WORK/$name.out" >&2; fail "$name"; }
    tail -1 "$WORK/$name.out"
}

run raw --encodings raw
grep -q "frames: [0-9]* (raw [0-9]*)," "$WORK/raw.out" || fail "raw run used another encoding"

run zstd --encodings zstd,raw
grep -q "zstd [0-9]" "$WORK/zstd.out" || fail "zstd run sent no zstd frame"
cmp "$WORK/raw.png" "$WORK/zstd.png" || fail "zstd pixels differ from raw"

run shm --encodings zstd,raw --shm --script "$CHECKS_DIR/t7-shm.txt"
grep -q "frames: [0-9]* (shm [0-9]*)," "$WORK/shm.out" || fail "shm run used a stream encoding"
cmp "$WORK/raw.png" "$WORK/shm.png" || fail "shm pixels differ from raw"

# The server removes its segments when the client is gone.
for name in $(grep '^< {"type": "shm"' "$WORK/shm.out" | sed 's/.*"name": "\([^"]*\)".*/\1/'); do
    python3 -I -c 'import _posixshmem, os, sys
try:
    os.close(_posixshmem.shm_open(sys.argv[1], os.O_RDONLY, mode=0))
except FileNotFoundError:
    sys.exit(0)
sys.exit(1)' "$name" || fail "segment $name outlived the server"
done
[ "$(grep -c '^< {"type": "shm"' "$WORK/shm.out")" -ge 2 ] || fail "no second segment after the resize"

run shm-failed --encodings zstd,raw --shm --fail-shm
grep -q "shm failures: 1;" "$WORK/shm-failed.out" || fail "expected one shm failure"
grep -q "zstd [0-9]" "$WORK/shm-failed.out" || fail "no stream frame after shm_failed"
cmp "$WORK/raw.png" "$WORK/shm-failed.png" || fail "pixels after shm_failed differ from raw"

echo "t7-encodings: ok"
