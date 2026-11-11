"""Wire protocol helpers shared by the ladybird Python tools.

Implements the record framing and frame header of plans/01-protocol.md and the
synthetic pixel formula of plans/05-tooling-and-integration.md.  Standard
library only.
"""

import json
import random
import shutil
import struct
import subprocess
import sys
import zlib

PROTOCOL_VERSION = 1

KIND_CONTROL = 1
KIND_FRAME = 2

MAX_RECORD = 64 * 1024 * 1024
MAX_FRAME_DIMENSION = 16384
MAX_FRAME_BYTES = 256 * 1024 * 1024

ENCODING_RAW = 0
ENCODING_ZSTD = 1
ENCODING_SHM = 2

FLAG_FULL = 1
FLAG_MORE = 2

RECORD_HEADER = struct.Struct("<IB")
FRAME_HEADER = struct.Struct("<IIIIdIIIIBBH")
assert FRAME_HEADER.size == 44

try:
    from compression import zstd as _zstd
except ImportError:
    _zstd = None


class Desync(Exception):
    """The stream cannot be parsed any further."""

    def __init__(self, reason, offset):
        super().__init__(f"{reason} at byte {offset}")
        self.reason = reason
        self.offset = offset


class BadFrame(Exception):
    """A frame record failed validation."""


def encode_record(kind, payload):
    # LENGTH counts the kind byte and the payload.
    return RECORD_HEADER.pack(len(payload) + 1, kind) + payload


def encode_control(obj):
    text = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    return encode_record(KIND_CONTROL, text.encode("utf-8"))


def encode_frame(seq, view, fw, fh, dpr, dx, dy, dw, dh, encoding, flags, payload):
    header = FRAME_HEADER.pack(seq, view, fw, fh, dpr, dx, dy, dw, dh, encoding, flags, 0)
    return encode_record(KIND_FRAME, header + payload)


class RecordReader:
    """Incremental record parser.

    `feed` returns the complete records as (kind, payload) pairs.  A framing
    error raises `Desync`, from the same call when no record precedes the error
    and from the next call otherwise; the reader then stays unusable.
    """

    def __init__(self):
        self._buffer = bytearray()
        self._offset = 0
        self._desync = None

    def feed(self, data):
        if self._desync:
            raise self._desync
        self._buffer += data
        records = []
        position = 0
        while len(self._buffer) - position >= RECORD_HEADER.size:
            length, kind = RECORD_HEADER.unpack_from(self._buffer, position)
            reason = None
            if length < 1:
                reason = "bad-length"
            elif length > MAX_RECORD:
                reason = "oversize"
            elif kind not in (KIND_CONTROL, KIND_FRAME):
                reason = "bad-kind"
            if reason:
                self._desync = Desync(reason, self._offset + position)
                del self._buffer[:]
                if records:
                    return records
                raise self._desync
            end = position + 4 + length
            if len(self._buffer) < end:
                break
            records.append((kind, bytes(self._buffer[position + RECORD_HEADER.size:end])))
            position = end
        del self._buffer[:position]
        self._offset += position
        return records

    @property
    def buffered(self):
        return len(self._buffer)


class FrameHeader:
    __slots__ = ("seq", "view", "frame_width", "frame_height", "dpr",
                 "damage_x", "damage_y", "damage_width", "damage_height",
                 "encoding", "flags", "reserved")

    def __init__(self, *fields):
        for name, value in zip(self.__slots__, fields):
            setattr(self, name, value)

    @classmethod
    def parse(cls, payload):
        """Return (header, body) for a frame record payload."""
        if len(payload) < FRAME_HEADER.size:
            raise BadFrame("short-frame-header")
        header = cls(*FRAME_HEADER.unpack_from(payload))
        return header, payload[FRAME_HEADER.size:]

    @property
    def full(self):
        return bool(self.flags & FLAG_FULL)

    @property
    def more(self):
        return bool(self.flags & FLAG_MORE)

    @property
    def raw_size(self):
        return self.damage_width * self.damage_height * 4

    def validate(self, body_length):
        fw, fh = self.frame_width, self.frame_height
        if not (1 <= fw <= MAX_FRAME_DIMENSION and 1 <= fh <= MAX_FRAME_DIMENSION):
            raise BadFrame("frame-size")
        if fw * fh * 4 > MAX_FRAME_BYTES:
            raise BadFrame("frame-size")
        if self.damage_width < 1 or self.damage_height < 1:
            raise BadFrame("empty-damage")
        if (self.damage_x + self.damage_width > fw
                or self.damage_y + self.damage_height > fh):
            raise BadFrame("damage-outside-frame")
        if self.encoding == ENCODING_RAW:
            if body_length != self.raw_size:
                raise BadFrame("payload-size")
        elif self.encoding == ENCODING_SHM:
            if body_length != 8:
                raise BadFrame("payload-size")
        elif self.encoding != ENCODING_ZSTD:
            raise BadFrame("encoding")

    def as_dict(self):
        return {name: getattr(self, name) for name in self.__slots__}


def bgra_formula(x, y, seed, fw, fh):
    """The ARGB value of pixel (X, Y) in a synthetic FW x FH frame."""
    r = x * 255 // max(fw - 1, 1)
    g = y * 255 // max(fh - 1, 1)
    b = (seed * 37 + (x ^ y)) & 0xFF
    return 0xFF000000 | (r << 16) | (g << 8) | b


def formula_rect(seed, fw, fh, dx=0, dy=0, dw=None, dh=None):
    """BGRA bytes of a rectangle of the synthetic frame, rows tightly packed."""
    dw = fw - dx if dw is None else dw
    dh = fh - dy if dh is None else dh
    out = bytearray(dw * dh * 4)
    xden = max(fw - 1, 1)
    yden = max(fh - 1, 1)
    base = seed * 37
    reds = [x * 255 // xden for x in range(dx, dx + dw)]
    position = 0
    for y in range(dy, dy + dh):
        g = y * 255 // yden
        row = bytearray(dw * 4)
        row[0::4] = bytes((base + (x ^ y)) & 0xFF for x in range(dx, dx + dw))
        row[1::4] = bytes([g]) * dw
        row[2::4] = bytes(reds)
        row[3::4] = b"\xff" * dw
        out[position:position + dw * 4] = row
        position += dw * 4
    return bytes(out)


def compose(store, fw, fh, header, pixels):
    """Copy the raw PIXELS of HEADER's damage rectangle into the BGRA STORE."""
    dx, dy, dw, dh = (header.damage_x, header.damage_y,
                      header.damage_width, header.damage_height)
    if header.frame_width != fw or header.frame_height != fh:
        raise BadFrame("store-size")
    if len(pixels) != dw * dh * 4:
        raise BadFrame("payload-size")
    for row in range(dh):
        start = ((dy + row) * fw + dx) * 4
        store[start:start + dw * 4] = pixels[row * dw * 4:(row + 1) * dw * 4]


def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data)))


def write_png(path, fw, fh, bgra):
    rgba = bytearray(bgra)
    rgba[0::4], rgba[2::4] = bgra[2::4], bgra[0::4]
    stride = fw * 4
    raw = b"".join(b"\0" + rgba[y * stride:(y + 1) * stride] for y in range(fh))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(b"IHDR", struct.pack(">IIBBBBB", fw, fh, 8, 6, 0, 0, 0)))
        f.write(_png_chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(_png_chunk(b"IEND", b""))


def write_ppm(path, fw, fh, bgra):
    rgb = bytearray(fw * fh * 3)
    rgb[0::3], rgb[1::3], rgb[2::3] = bgra[2::4], bgra[1::4], bgra[0::4]
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (fw, fh))
        f.write(rgb)


def zstd_available():
    return _zstd is not None or shutil.which("zstd") is not None


def zstd_compress(data, level=1):
    """Compress DATA into one zstd frame that states its content size."""
    if _zstd is not None:
        return _zstd.compress(data, level=level)
    # Reading a pipe, zstd writes the content size only when told it.
    return subprocess.run(["zstd", f"-{level}", "-q", "-c", "--no-check",
                           f"--stream-size={len(data)}"],
                          input=data, stdout=subprocess.PIPE, check=True).stdout


def zstd_decompress(data, size):
    if _zstd is not None:
        out = _zstd.decompress(data)
    else:
        out = subprocess.run(["zstd", "-d", "-q", "-c"], input=data,
                             stdout=subprocess.PIPE, check=True).stdout
    if len(out) != size:
        raise BadFrame("decoded-size")
    return out


def _chunks(data, size):
    return [data[i:i + size] for i in range(0, len(data), size)]


def _selftest():
    rng = random.Random(1)
    records = []
    for i in range(100):
        if i % 3 == 0:
            dw, dh = rng.randint(1, 16), rng.randint(1, 16)
            body = rng.randbytes(dw * dh * 4)
            header = FRAME_HEADER.pack(i + 1, 1, 64, 48, 2.0, 3, 4, dw, dh,
                                       ENCODING_RAW, 0, 0)
            records.append((KIND_FRAME, header + body))
        else:
            obj = {"type": "state", "n": i, "title": "héllo " * rng.randint(0, 40)}
            text = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
            records.append((KIND_CONTROL, text.encode("utf-8")))
    stream = b"".join(encode_record(kind, payload) for kind, payload in records)
    for size in list(range(1, 98)) + [4096, 65536]:
        reader = RecordReader()
        got = []
        for chunk in _chunks(stream, size):
            got += reader.feed(chunk)
        assert got == records, f"round trip failed at chunk size {size}"
        assert reader.buffered == 0

    assert encode_control({"type": "ping", "id": 1}) == \
        b'\x17\x00\x00\x00\x01{"type":"ping","id":1}'

    for bad, reason in ((struct.pack("<IB", MAX_RECORD + 1, 1), "oversize"),
                        (struct.pack("<IB", 4, 3) + b"abc", "bad-kind"),
                        (struct.pack("<IB", 0, 1), "bad-length")):
        good = encode_control({"type": "ping"})
        for prefix in (b"", good):
            reader = RecordReader()
            try:
                if prefix:
                    assert len(reader.feed(prefix + bad)) == 1
                    reader.feed(b"")
                else:
                    reader.feed(bad)
            except Desync as e:
                assert e.reason == reason, (e.reason, reason)
                assert e.offset == len(prefix)
            else:
                raise AssertionError(f"no desync for {reason}")
            try:
                reader.feed(good)
            except Desync:
                pass
            else:
                raise AssertionError("reader usable after desync")

    def header(fw=64, fh=48, dx=0, dy=0, dw=64, dh=48, encoding=ENCODING_RAW):
        return FrameHeader(1, 1, fw, fh, 1.0, dx, dy, dw, dh, encoding, 0, 0)

    header().validate(64 * 48 * 4)
    header(encoding=ENCODING_SHM).validate(8)
    header(encoding=ENCODING_ZSTD).validate(17)
    bad_cases = [
        (header(dw=0), 0),
        (header(dh=0), 0),
        (header(dx=1), 64 * 48 * 4),
        (header(dy=1), 64 * 48 * 4),
        (header(fw=MAX_FRAME_DIMENSION + 1, dw=1, dh=1), 4),
        (header(fw=0, dw=1, dh=1), 4),
        (header(fw=8192, fh=8193, dw=1, dh=1), 4),
        (header(encoding=3), 4),
        (header(), 64 * 48 * 4 - 1),
        (header(encoding=ENCODING_SHM), 4),
    ]
    for case, length in bad_cases:
        try:
            case.validate(length)
        except BadFrame:
            pass
        else:
            raise AssertionError(f"accepted bad frame {case.as_dict()}")
    try:
        FrameHeader.parse(b"\0" * 43)
    except BadFrame:
        pass
    else:
        raise AssertionError("accepted a short frame header")

    fw, fh = 37, 23
    full = formula_rect(5, fw, fh)
    for x, y in ((0, 0), (36, 22), (17, 9), (1, 22)):
        (pixel,) = struct.unpack_from("<I", full, (y * fw + x) * 4)
        assert pixel == bgra_formula(x, y, 5, fw, fh)
    store = bytearray(fw * fh * 4)
    compose(store, fw, fh, header(fw, fh, 0, 0, fw, fh), full)
    patch = formula_rect(9, fw, fh, 4, 5, 10, 6)
    compose(store, fw, fh, header(fw, fh, 4, 5, 10, 6), patch)
    for x, y, seed in ((4, 5, 9), (13, 10, 9), (3, 5, 5), (14, 10, 5), (4, 11, 5)):
        (pixel,) = struct.unpack_from("<I", store, (y * fw + x) * 4)
        assert pixel == bgra_formula(x, y, seed, fw, fh), (x, y)

    if zstd_available():
        packed = zstd_compress(full)
        assert zstd_decompress(packed, len(full)) == full
        # The frame header states the content size (protocol 4.1).
        assert packed[:4] == b"\x28\xb5\x2f\xfd" and (packed[4] >> 6 or packed[4] & 0x20)
    print("ok" + ("" if zstd_available() else " (zstd unavailable, skipped)"))


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        _selftest()
    else:
        sys.exit("usage: ladybird_protocol.py --selftest")
