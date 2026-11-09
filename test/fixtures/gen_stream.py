#!/usr/bin/env python3
"""Generate the stream fixtures of plans/03-emacs-module.md T3.

Usage: python3 -I test/fixtures/gen_stream.py [OUTPUT-DIRECTORY]

Each NAME.ladybird is a byte stream as a server would send it.  NAME.json
describes it:

  records   one entry per record, in stream order: {"kind": "control"} or
            {"kind": "frame", "seq", "view", "frame_width", "frame_height",
             "x", "y", "width", "height", "encoding", "full", "seed",
             "status"}.  "status" is what a client reports whose canvas has
            the size of the first frame and never changes.  A frame with
            "seed" null carries no formula pixels.
  desync    null, or {"reason", "offset"} of the framing error that ends
            the stream.
  final     {"frame_width", "frame_height"} of the client's backing store
            after the stream, or null without frames.

The expected value of a store pixel is the formula of
plans/05-tooling-and-integration.md section 2 with the seed of the last
frame record that has a status of "painted", "stored" or "size-mismatch",
the final frame size, and a rectangle containing the pixel.
"""

import json
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "tools"))
import ladybird_protocol as lp  # noqa: E402

ENCODING_NAMES = {lp.ENCODING_RAW: "raw", lp.ENCODING_ZSTD: "zstd",
                  lp.ENCODING_SHM: "shm"}
SHM_OFFSET = 4096


class Stream:
    def __init__(self):
        self.data = bytearray()
        self.records = []
        self.desync = None
        self.final = None
        self.seq = 0

    def control(self, obj):
        self.data += lp.encode_control(obj)
        self.records.append({"kind": "control"})

    def frame(self, fw, fh, rect=None, seed=0, encoding=lp.ENCODING_RAW,
              full=False, status="painted", view=1, dpr=1.0):
        x, y, w, h = rect or (0, 0, fw, fh)
        self.seq += 1
        if encoding == lp.ENCODING_SHM:
            payload = struct.pack("<Q", SHM_OFFSET)
        else:
            payload = lp.formula_rect(seed, fw, fh, x, y, w, h)
            if encoding == lp.ENCODING_ZSTD:
                payload = lp.zstd_compress(payload)
        self.data += lp.encode_frame(self.seq, view, fw, fh, dpr, x, y, w, h,
                                     encoding, lp.FLAG_FULL if full else 0, payload)
        self._describe(fw, fh, (x, y, w, h), seed, encoding, full, status, view)
        if status in ("painted", "stored", "size-mismatch"):
            self.final = {"frame_width": fw, "frame_height": fh}

    def bad_frame(self, header_fields, payload, status="bad-frame"):
        """Append a frame record from raw header fields, without validation."""
        self.seq += 1
        fw, fh, x, y, w, h, encoding = header_fields
        header = lp.FRAME_HEADER.pack(self.seq, 1, fw, fh, 1.0, x, y, w, h,
                                      encoding, 0, 0)
        self.data += lp.encode_record(lp.KIND_FRAME, header + payload)
        self._describe(fw, fh, (x, y, w, h), None, encoding, False, status, 1)

    def raw(self, data, reason):
        self.desync = {"reason": reason, "offset": len(self.data)}
        self.data += data

    def _describe(self, fw, fh, rect, seed, encoding, full, status, view):
        x, y, w, h = rect
        self.records.append({
            "kind": "frame", "seq": self.seq, "view": view,
            "frame_width": fw, "frame_height": fh,
            "x": x, "y": y, "width": w, "height": h,
            "encoding": ENCODING_NAMES.get(encoding, encoding),
            "full": full, "seed": seed, "status": status})

    def write(self, directory, name):
        with open(os.path.join(directory, name + ".ladybird"), "wb") as f:
            f.write(self.data)
        with open(os.path.join(directory, name + ".json"), "w") as f:
            json.dump({"records": self.records, "desync": self.desync,
                       "final": self.final}, f, indent=1)
            f.write("\n")


def welcome(width, height):
    return {"type": "welcome", "protocol": 1, "server": "fixture",
            "encoding": "zstd", "shm": False, "log": "/dev/null",
            "host": {"hostname": "fixture", "platform": "test"},
            "views": [{"view": 1, "url": "about:blank", "title": "", "loading": False,
                       "can_go_back": False, "can_go_forward": False, "zoom": 1.0,
                       "width": width, "height": height, "dpr": 1.0}]}


def state(title):
    return {"type": "state", "view": 1, "url": "about:blank", "title": title,
            "loading": False, "can_go_back": False, "can_go_forward": False,
            "zoom": 1.0}


def basic_raw_full():
    s = Stream()
    s.control(welcome(64, 48))
    s.frame(64, 48, seed=1, full=True)
    s.control(state("basic"))
    return s


def zstd_full():
    s = Stream()
    s.frame(1600, 1000, seed=7, encoding=lp.ENCODING_ZSTD, full=True)
    return s


def damage_mix():
    s = Stream()
    s.frame(320, 200, seed=1, full=True)
    rects = [((0, 10, 320, 20), lp.ENCODING_RAW),      # full width
             ((40, 50, 100, 60), lp.ENCODING_ZSTD),    # interior
             ((0, 150, 320, 50), lp.ENCODING_ZSTD),    # full width, to the bottom
             ((319, 0, 1, 200), lp.ENCODING_RAW),      # right column
             ((60, 70, 30, 30), lp.ENCODING_RAW),      # inside an earlier rect
             ((0, 0, 1, 1), lp.ENCODING_ZSTD)]         # one pixel
    for seed, (rect, encoding) in enumerate(rects, start=2):
        s.frame(320, 200, rect, seed=seed, encoding=encoding)
    return s


def resize():
    s = Stream()
    s.frame(320, 200, seed=1, full=True)
    s.frame(320, 200, (10, 10, 100, 50), seed=2)
    s.frame(400, 300, seed=3, full=True, status="size-mismatch")
    s.frame(320, 200, (0, 0, 50, 50), seed=4, status="stale")
    return s


def shm():
    s = Stream()
    s.control({"type": "shm", "view": 1, "name": "/ladybird-fixture",
               "size": SHM_OFFSET + 64 * 48 * 4})
    s.frame(64, 48, seed=5, encoding=lp.ENCODING_SHM, full=True)
    return s


def bad():
    s = Stream()
    pixel = b"\0\0\0\xff"
    s.bad_frame((64, 48, 60, 0, 8, 1, lp.ENCODING_RAW), pixel * 8)   # dx+dw > width
    s.bad_frame((64, 48, 0, 47, 1, 2, lp.ENCODING_RAW), pixel * 2)   # dy+dh > height
    s.bad_frame((64, 48, 0, 0, 0, 1, lp.ENCODING_RAW), b"")          # empty damage
    s.bad_frame((64, 48, 0, 0, 2, 2, lp.ENCODING_RAW), pixel * 3)    # payload size
    s.bad_frame((64, 48, 0, 0, 1, 1, 3), pixel)                      # encoding
    s.bad_frame((64, 48, 0, 0, 1, 1, lp.ENCODING_SHM), b"\0" * 4)    # shm payload size
    s.bad_frame((20000, 48, 0, 0, 1, 1, lp.ENCODING_RAW), pixel)     # frame too wide
    s.seq += 1                                                       # short header
    s.data += lp.encode_record(lp.KIND_FRAME, b"\0" * 20)
    s.records.append({"kind": "frame", "seq": None, "view": None,
                      "frame_width": None, "frame_height": None,
                      "x": None, "y": None, "width": None, "height": None,
                      "encoding": None, "full": False, "seed": None,
                      "status": "bad-frame"})
    s.bad_frame((64, 48, 0, 0, 4, 4, lp.ENCODING_ZSTD), b"not zstd",
                status="decode-error")
    s.control(state("after bad frames"))
    s.raw(struct.pack("<IB", lp.MAX_RECORD + 1, lp.KIND_CONTROL) + b"{}", "oversize")
    return s


def control_utf8():
    s = Stream()
    s.control(state("héllo wörld ✓ 日本語 🦋"))
    s.control({"type": "console", "view": 1, "level": "log", "text": "é" * (512 * 1024)})
    s.control({"type": "pong", "id": 1})
    return s


FIXTURES = {
    "basic-raw-full": (basic_raw_full, False),
    "zstd": (zstd_full, True),
    "damage-mix": (damage_mix, True),
    "resize": (resize, False),
    "shm": (shm, False),
    "bad": (bad, False),
    "control-utf8": (control_utf8, False),
}


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
        os.path.abspath(__file__))
    os.makedirs(directory, exist_ok=True)
    for name, (build, needs_zstd) in FIXTURES.items():
        if needs_zstd and not lp.zstd_available():
            print(f"skipping {name}: no zstd", file=sys.stderr)
            continue
        stream = build()
        stream.write(directory, name)
        print(f"{name}.ladybird {len(stream.data)} bytes")


if __name__ == "__main__":
    main()
