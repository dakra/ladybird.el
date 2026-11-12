# 05 — Shared tooling, fixtures and integration checkpoints

The three component plans each specify test tools. This file makes them share one
protocol implementation and one pixel formula, names the files, and lists the
integration checkpoints with the commands that prove them. It wins over 02–04 on tool
names and fixture formats.

## 1. Shared Python protocol module — `tools/ladybird_protocol.py` (task T-1, ½ day)

Stdlib only (Python ≥ 3.11; zstd via `compression.zstd` on ≥ 3.14, else the `zstd` CLI
through `subprocess`, else disabled). Written first, imported by every other Python tool.

```python
FRAME_HEADER = struct.Struct("<IIIIdIIIIBBH")   # 44 bytes, 01-protocol §4.1
def encode_record(kind: int, payload: bytes) -> bytes   # length field = 1 + len(payload)
def encode_control(obj: dict) -> bytes           # kind 1, json.dumps(separators=(",",":"))
def encode_frame(seq, view, fw, fh, dpr, dx, dy, dw, dh, encoding, flags, payload) -> bytes
class RecordReader:                              # feed(bytes) -> list[(kind, payload)], raises Desync
class FrameHeader:                               # parse(payload) -> header + body offset, validate()
def bgra_formula(x, y, seed, fw, fh) -> int      # §2, the one pixel formula
def formula_rect(seed, fw, fh, dx=0, dy=0, dw=None, dh=None) -> bytes   # BGRA bytes of a rect
def compose(store: bytearray, fw, fh, header, body)  # apply a decoded damage rect to a BGRA store
def write_png(path, fw, fh, bgra: bytes)         # zlib + struct, no PIL
def write_ppm(path, fw, fh, bgra: bytes)
def zstd_available() -> bool; def zstd_compress(b, level=1); def zstd_decompress(b, size)
```

Self-test: `python3 -I tools/ladybird_protocol.py --selftest` round-trips 100 random records
through `RecordReader` in chunk sizes 1..97, 4096, 65536, and checks `FrameHeader`
validation on the bad cases of 03 §2.2 step 1. The Zig parser tests (03 T2) and the fake
Elisp module (04 A3) implement the same cases, so a discrepancy shows up in whichever
component is wrong.

## 2. One pixel formula

Every synthetic frame in every tool uses, for pixel `(x, y)` of a frame generated with
integer `seed`:

```
r = (x * 255 // max(fw-1, 1))            # horizontal gradient
g = (y * 255 // max(fh-1, 1))            # vertical gradient
b = (seed * 37 + (x ^ y)) & 0xFF         # seed-dependent texture
argb = 0xFF000000 | (r << 16) | (g << 8) | b
```

`gen_stream.py` (03 T3) writes the sidecar JSON with `seed`, `fw`, `fh` and the list of
applied damage rects; ERT and Zig tests recompute expected pixels from the formula
instead of storing images. The mock server (04 A4) draws its moving gradient with the
same formula and `seed = frame number`, and overlays input feedback (24-px square at
click position, key names in a 5×7 bitmap font) on top, so an elate screenshot of an
Emacs buffer can be checked against the formula outside the overlays.

## 3. Tools and who writes them

| File | Written in | Used by | Spec |
| --- | --- | --- | --- |
| `tools/ladybird_protocol.py` | T-1 (first, anyone) | all Python tools | §1 |
| `test/fixtures/gen_stream.py` + `test/fixtures/*.ladybird` | T-2 (right after T-1, before M and E start; spec is 03 T3) | M (Zig + ERT), E-A3 fake module tests | 03 T3; files: `basic-raw-full`, `damage-mix`, `zstd`, `resize`, `shm`, `bad`, `control-utf8`, each with sidecar JSON |
| `tools/mock-server.py` | E-A4 | E (ERT, elate), also a smoke test for M | 04 A4 (flags `--stdio --socket --tcp --views --fps --log --no-pong --exit-after --reject --zstd`, `mock://` URLs) |
| `tools/ladybird-client.py` + `tools/checks/*.txt` | S-T9 | S acceptance checks, I1 | 02 T9 (`--server/--socket`, `--url`, `--png`, `--script`, `--dump`, `--no-ack`, `--strict`) |
| `test/ladybird-fake-module.el` | E-A3 | E tests before the module exists | 04 A3, implements 03 §2 names |
| `test/elate/` (`run.sh`, `lib/ladybird-setup.el`, `matrix/*.json`) | E-E1 | I2–I5 | 04 E1, layout as `/Users/daniel/.emacs.d/lib/rexel/test/elate/` |

`mock-server.py` and `ladybird-client.py` are each other's conformance test: the client
run against the mock (`--server "python3 -I tools/mock-server.py --stdio"`) must reach
`state.loading false` and write a PNG whose non-overlay pixels match the formula; that
check runs in CI without Ladybird or Emacs.

## 4. Integration checkpoints

Each checkpoint names the tasks it needs and the command that proves it. Record results
(date, machine, pass/fail, notes) in `plans/INTEGRATION-LOG.md`.

### I1 — real page to PNG, no Emacs (S-T1…T5, T9)

```sh
cd /Users/daniel/src/ladybird && ./Meta/ladybird.py build Hub   # first build: hours, tens of GiB
python3 -I /Users/daniel/src/dakra/ladybird/tools/ladybird-client.py \
  --server ./Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird \
  --url https://ladybird.dev --viewport 1600x1000@2 --png /tmp/i1.png --dump
```

Pass: PNG shows the page at 1600×1000; `--dump` shows `welcome`, `view_created`, `state`
with `loading false`, frames with `full` first then damage rects; `--no-ack` shows exactly
one frame and then nothing (flow control); stderr of Ladybird is empty and the log file
has the output.

### I2 — mock frames in an Emacs buffer, no Ladybird (M-T1…T4, E-A1…A4, B1, C1)

```sh
cd /Users/daniel/src/dakra/ladybird && make build test   # module + ERT with fixtures and fake module
uvx elate start --name i2 --ui gui --eval-file test/elate/lib/ladybird-setup.el
# in the sandbox: (ladybird-elate-start 'stdio)  → buffer *ladybird: Mock* shows the gradient
```

Pass: the gradient is visible and animates at `--fps 10`; resizing the window sends
`set_viewport` (mock log) and the canvas is replaced without a blank flash; a mock
screenshot's pixels match the formula; `M-x ladybird-module-stats` shows no dropped frames.
With dpr 2 (if M-T0 passed) the gradient is crisp at 1:1 device pixels.

### I3 — real page in Emacs, local (S-T6/T7, M-T5/T6, E-C2/C3)

```elisp
(setq ladybird-program "/Users/daniel/src/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird")
M-x ladybird-browse-url RET https://ladybird.dev RET
```

Pass: page renders; `welcome.shm true` and `ladybird-module-stats` shows `:shm-size` > 0;
clicking a link navigates; wheel scrolls; `i` then typing into a form field inserts text;
`C-y` pastes; `M-w` after a drag selection yields the text; `g` loads another URL; `b`/`f`
work; resizing works. Measure with `benchmark-run` around `feed` (03 §6): a full frame
should cost under 5 ms in the module.

### I4 — detach, reconnect, remote (S-T3 socket, E-D3)

```sh
# detachable local session
Ladybird --headless=emacs --emacs-socket=/tmp/ladybird.sock
# remote over ssh, stdio
(setq ladybird-hosts '(("devbox" . "ssh://devbox")))        ; make-process "ssh -T devbox Ladybird --headless=emacs"
# remote socket forwarded
ssh -N -o StreamLocalBindUnlink=yes -L /tmp/devbox.sock:/tmp/ladybird.sock devbox
(setq ladybird-hosts '(("devbox" . "/tmp/devbox.sock")))
```

Pass: kill the Emacs buffer, reconnect, the page and its state (logged-in session,
scroll position) are still there; a second client gets the view and the first sees
`replaced`; over ssh a full 1600×1000 zstd frame arrives in well under a second on a LAN
and scrolling stays usable; a dropped connection redials with backoff and re-attaches
by view id.

### I5 — polish (S-T8/T10, E-C4, D1, D2, E1, E2)

Pass: `mock://alert|confirm|prompt|select|file|permission|external|context` all round-trip
against the mock and the real server (test pages under `tools/checks/pages/`); find
highlights and steps; zoom; favicon and title in the header line; the elate matrix
(`test/elate/run.sh` with `stdio`, `unix`, `tcp`) is green; README quick start works
on a fresh machine.

## 5. CI (E-E1, small)

GitHub Actions on the Emacs repo, macOS and Ubuntu runners: `zig build test`, `make
test-native` under `emacs --batch` (canvas works in batch, 03 §1), `python3 -I
tools/ladybird_protocol.py --selftest`, mock↔client conformance (§3), byte-compile with
warnings as errors, checkdoc, package-lint. Ladybird is not built in CI (hours); S is
checked by its own `TestEmacsProtocol` in the Ladybird tree and by I1 locally.
