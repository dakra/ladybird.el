#!/usr/bin/env python3
"""Mock of the Ladybird Emacs server (plans/01-protocol.md).

Serves the wire protocol with synthetic frames: the gradient of
plans/05-tooling-and-integration.md section 2 with the seed counting the
animation ticks, shifted vertically by the wheel, with a white 24-pixel
square at every mouse press and the names of the pressed keys in a 5x7
font at the top left.

Usage: python3 -I tools/mock-server.py [OPTIONS]

  --stdio             serve stdin/stdout (default)
  --socket PATH       listen on a Unix socket
  --tcp HOST:PORT     listen on a TCP port
  --views N           views that exist before the first client (default 0)
  --fps F             animation ticks per second (default 10; 0 = none)
  --log FILE          JSON lines: every received control message, plus
                      {"type":"_frame_sent",...}, {"type":"_connected"} and
                      {"type":"_disconnected"}
  --no-pong           never answer a ping
  --exit-after S      exit after S seconds
  --exit-code N       exit status of --exit-after (default 0)
  --reject            answer every hello with a reject
  --zstd              use zstd when the client offers it
  --shm               use shared memory when the client offers it
  --platform NAME     platform named in the welcome: macos, linux or unknown
                      (default: this machine's)
  --hostname NAME     host name in the welcome (default: this machine's)
  --max-views N       answer a create_view beyond N views with an error
  --no-hints          leave "hints" out of the welcome's features (there are
                      none then) and answer hints with an error
  --selftest          run an in-process client against the server

Loading a mock:// URL makes the server emit a request or event:
mock://alert, confirm, prompt, beforeunload, select, file, files, color,
date, permission, permission-cancel, external, context, popup, crash,
hover, favicon, console, clipboard, background, error, close.
mock://cancel-NAME emits the request of mock://NAME and withdraws it
half a second later with request_cancelled; mock://disconnect drops the
client and keeps the views.

Hints (protocol section 6.1): a page has 12 items, kinds link, button,
input and other in turn, with the texts "Link 1", "Button 2", "Field 3",
"Other 4", "Link 5"...; a link's URL is https://mock.invalid/link/N.  The labels are
drawn into the frames at the items' rectangles.  mock://hints-N has N
items (mock://hints-0 none), mock://hints-truncated 1000 items and
truncated true.  The first hints_narrow of a session makes
mock://hints-expire end it with hints_cancelled, mock://hints-confirm
open a confirm dialog and mock://hints-alert open an alert and end the
session 0.3 seconds later.  mock://hints-timeout answers hints with
hints_cancelled 3 seconds later instead of hints_list.  Loading another
page or the page closing its view ends a session with hints_cancelled; a
close_view ends it without one.  An error that answers a hints message
carries its id.  An activated item is logged as
{"type":"_hint_activated","view","id","index","kind","label"}, and an
activated link loads its URL.
"""

import argparse
import base64
import heapq
import json
import os
import selectors
import socket
import struct
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ladybird_protocol as lp  # noqa: E402

SQUARE = 24
TEXT_SCALE = 2
TEXT_MARGIN = 8
TEXT_HEIGHT = 2 * TEXT_MARGIN + 7 * TEXT_SCALE
RAW_THRESHOLD = 16 * 1024
WHITE = b"\xff\xff\xff\xff"
BLACK = b"\x00\x00\x00\xff"

# 5x7 glyphs, one two-digit hex number per row, most significant bit left.
FONT = {
    "A": "0E11111F111111", "B": "1E11111E11111E", "C": "0E11101010110E",
    "D": "1E11111111111E", "E": "1F10101E10101F", "F": "1F10101E101010",
    "G": "0E11101711110F", "H": "1111111F111111", "I": "0E04040404040E",
    "J": "0702020202120C", "K": "11121418141211", "L": "1010101010101F",
    "M": "111B1515111111", "N": "11191513111111", "O": "0E11111111110E",
    "P": "1E11111E101010", "Q": "0E11111115120D", "R": "1E11111E141211",
    "S": "0F10100E01011E", "T": "1F040404040404", "U": "1111111111110E",
    "V": "11111111110A04", "W": "1111111515150A", "X": "11110A040A1111",
    "Y": "1111110A040404", "Z": "1F01020408101F",
    "0": "0E11131519110E", "1": "040C040404040E", "2": "0E11010204081F",
    "3": "1F02040201110E", "4": "02060A121F0202", "5": "1F101E0101110E",
    "6": "0608101E11110E", "7": "1F010204080808", "8": "0E11110E11110E",
    "9": "0E11110F01020C", " ": "00000000000000", "-": "0000001F000000",
    ".": "00000000000C0C", ":": "000C0C000C0C00", "/": "01010204081010",
}
BOX = "1F11111111111F"


def glyph_rows(char):
    code = FONT.get(char.upper(), BOX)
    return [int(code[i:i + 2], 16) for i in range(0, 14, 2)]


HINT_KINDS = ("link", "button", "input", "other")
HINT_TEXTS = {"link": "Link", "button": "Button", "input": "Field",
              "other": "Other"}
HINT_COLUMNS = 4


def hint_alphabet_ok(alphabet):
    """Whether ALPHABET is 2 to 36 distinct characters of a-z and 0-9."""
    return (isinstance(alphabet, str) and 2 <= len(alphabet) <= 36
            and len(set(alphabet)) == len(alphabet)
            and all(c in "abcdefghijklmnopqrstuvwxyz0123456789" for c in alphabet))


def hint_labels(count, alphabet):
    """Return COUNT labels of one length, the shortest that tells them apart."""
    base, length = len(alphabet), 1
    while base ** length < count:
        length += 1
    labels = []
    for n in range(count):
        digits = []
        for _ in range(length):
            n, digit = divmod(n, base)
            digits.append(alphabet[digit])
        labels.append("".join(reversed(digits)))
    return labels


def hint_items(url, alphabet):
    """Return the hint items of the page at URL and whether they were cut."""
    name = url[len("mock://hints-"):] if url.startswith("mock://hints-") else ""
    count, truncated = 12, False
    if name == "truncated":
        count, truncated = 1000, True
    elif name.isdigit():
        count = int(name)
    items = []
    for index, label in enumerate(hint_labels(count, alphabet)):
        kind = HINT_KINDS[index % len(HINT_KINDS)]
        items.append({
            "index": index, "label": label, "kind": kind,
            "text": f"{HINT_TEXTS[kind]} {index + 1}",
            "url": f"https://mock.invalid/link/{index + 1}" if kind == "link" else None,
            "x": 2 + (index % HINT_COLUMNS) * 96,
            "y": 2 + (index // HINT_COLUMNS) * 24,
            "width": 80, "height": 18})
    return items, truncated


class Gradient:
    """Rows of the synthetic frame of one size."""

    def __init__(self, fw, fh):
        self.fw, self.fh = fw, fh
        self.reds = bytes(x * 255 // max(fw - 1, 1) for x in range(fw))
        self.alpha = b"\xff" * fw
        low = bytes(x & 0xFF for x in range(fw))
        self.xor = [low.translate(bytes(i ^ y for i in range(256)))
                    for y in range(256)]
        self.seed = None
        self.add = None

    def row(self, y, seed):
        if seed != self.seed:
            self.seed = seed
            self.add = bytes((i + seed * 37) & 0xFF for i in range(256))
        row = bytearray(self.fw * 4)
        row[0::4] = self.xor[y & 0xFF].translate(self.add)
        row[1::4] = bytes([y * 255 // max(self.fh - 1, 1)]) * self.fw
        row[2::4] = self.reds
        row[3::4] = self.alpha
        return row


class View:
    def __init__(self, view_id, url, width, height, dpr):
        self.id = view_id
        self.url = url
        self.title = "Mock: " + url
        self.loading = False
        self.can_go_back = False
        self.can_go_forward = False
        self.zoom = 1.0
        self.dpr = dpr
        self.visible = True
        self.seq = 0
        self.in_flight = None
        self.seed = 0
        self.scroll = 0
        self.squares = []
        self.text = ""
        self.find_query = ""
        self.find_index = 0
        self.find_total = 0
        self.shm = None
        self.old_shm = None
        self.shm_announced = False
        self.hints = None  # {"id", "items", "prefix"} of the hint session
        self.resize(width, height, dpr)

    def resize(self, width, height, dpr):
        self.width = max(1, min(int(width), lp.MAX_FRAME_DIMENSION))
        self.height = max(1, min(int(height), lp.MAX_FRAME_DIMENSION))
        self.dpr = float(dpr)
        self.gradient = Gradient(self.width, self.height)
        self.framebuffer = bytearray(self.width * self.height * 4)
        self.dirty = True
        self.damage_all()

    def damage_all(self):
        self.damage = (0, 0, self.width, self.height)

    def add_damage(self, x, y, w, h):
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.width, x + w), min(self.height, y + h)
        if x1 <= x0 or y1 <= y0:
            return
        if self.damage:
            dx, dy, dw, dh = self.damage
            x0, y0 = min(x0, dx), min(y0, dy)
            x1, y1 = max(x1, dx + dw), max(y1, dy + dh)
        self.damage = (x0, y0, x1 - x0, y1 - y0)

    def fill(self, x, y, w, h, pixel):
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.width, x + w), min(self.height, y + h)
        if x1 <= x0 or y1 <= y0:
            return
        row = pixel * (x1 - x0)
        for line in range(y0, y1):
            start = (line * self.width + x0) * 4
            self.framebuffer[start:start + len(row)] = row

    def text_rect(self):
        return (0, 0, self.width, min(self.height, TEXT_HEIGHT))

    def render(self):
        stride = self.width * 4
        for y in range(self.height):
            source = (y + self.scroll) % self.height
            self.framebuffer[y * stride:(y + 1) * stride] = \
                self.gradient.row(source, self.seed)
        for x, y in self.squares:
            self.fill(x - SQUARE // 2, y - SQUARE // 2, SQUARE, SQUARE, WHITE)
        if self.text:
            cell = 6 * TEXT_SCALE
            columns = max(1, (self.width - 2 * TEXT_MARGIN) // cell)
            self.draw_text(TEXT_MARGIN, TEXT_MARGIN, self.text[-columns:])
        if self.hints:
            prefix = self.hints["prefix"]
            for item in self.hints["items"]:
                x, y = int(item["x"] * self.dpr), int(item["y"] * self.dpr)
                if (item["label"].startswith(prefix)
                        and x < self.width and y < self.height):
                    self.draw_text(x + 2, y + 2, item["label"])
        self.dirty = False

    def draw_text(self, x, y, text):
        """Draw TEXT in black on white with its top left glyph at X, Y."""
        cell = 6 * TEXT_SCALE
        self.fill(x - 2, y - 2, len(text) * cell + 4, 7 * TEXT_SCALE + 4, WHITE)
        for column, char in enumerate(text):
            for line, bits in enumerate(glyph_rows(char)):
                for bit in range(5):
                    if bits & (0x10 >> bit):
                        self.fill(x + column * cell + bit * TEXT_SCALE,
                                  y + line * TEXT_SCALE,
                                  TEXT_SCALE, TEXT_SCALE, BLACK)

    def rect_bytes(self, x, y, w, h):
        if (x, y, w, h) == (0, 0, self.width, self.height):
            return bytes(self.framebuffer)
        stride = self.width * 4
        return b"".join(self.framebuffer[(y + row) * stride + x * 4:
                                         (y + row) * stride + (x + w) * 4]
                        for row in range(h))

    def state(self):
        return {"type": "state", "view": self.id, "url": self.url,
                "title": self.title, "loading": self.loading,
                "can_go_back": self.can_go_back,
                "can_go_forward": self.can_go_forward, "zoom": self.zoom}

    def describe(self):
        return {"view": self.id, "url": self.url, "title": self.title,
                "loading": self.loading, "can_go_back": self.can_go_back,
                "can_go_forward": self.can_go_forward, "zoom": self.zoom,
                "width": self.width, "height": self.height, "dpr": self.dpr}


class Client:
    def __init__(self, read_fd, write_fd, sock=None):
        self.read_fd = read_fd
        self.write_fd = write_fd
        self.sock = sock
        self.reader = lp.RecordReader()
        self.out = bytearray()
        self.ready = False
        self.encoding = "raw"
        self.shm = False
        self.viewport = (800, 600, 1.0)
        self.writing = False


class Server:
    def __init__(self, args):
        self.args = args
        self.selector = selectors.DefaultSelector()
        self.views = {}
        self.next_view = 1
        self.next_id = 1
        self.shm_generation = 0
        self.client = None
        self.listener = None
        self.timers = []
        self.timer_serial = 0
        self.running = True
        self.exit_code = 0
        self.log_file = open(args.log, "a", buffering=1) if args.log else None
        for index in range(args.views):
            self.add_view(f"mock://view/{index + 1}", 800, 600, 1.0)

    # Event loop

    def log(self, obj):
        if self.log_file:
            self.log_file.write(json.dumps(obj, ensure_ascii=False) + "\n")

    def after(self, delay, function):
        self.timer_serial += 1
        heapq.heappush(self.timers, (time.monotonic() + delay, self.timer_serial,
                                     function))

    def listen(self, sock):
        self.listener = sock
        sock.setblocking(False)
        self.selector.register(sock, selectors.EVENT_READ, "listener")

    def attach(self, client):
        if self.client:
            self.send(self.client, {"type": "replaced"})
            self.flush(self.client, blocking=True)
            self.drop_client()
        self.client = client
        os.set_blocking(client.read_fd, False)
        os.set_blocking(client.write_fd, False)
        self.selector.register(client.read_fd, selectors.EVENT_READ, "client")
        self.log({"type": "_connected"})

    def drop_client(self):
        client, self.client = self.client, None
        if not client:
            return
        for fd in {client.read_fd, client.write_fd}:
            try:
                self.selector.unregister(fd)
            except (KeyError, ValueError):
                pass
        if client.sock:
            client.sock.close()
        for view in self.views.values():
            view.in_flight = None
            view.shm_announced = False
            # A client that goes away ends its hint sessions.
            if view.hints:
                view.hints = None
                view.dirty = True
                view.damage_all()
        self.log({"type": "_disconnected"})

    def hang_up(self):
        """Drop the client; without a listener that ends the server."""
        self.drop_client()
        if not self.listener:
            self.running = False

    def run(self):
        if self.args.exit_after is not None:
            self.after(self.args.exit_after, self.exit_now)
        if self.args.fps > 0:
            self.after(1 / self.args.fps, self.tick)
        try:
            while self.running:
                timeout = None
                if self.timers:
                    timeout = max(0, self.timers[0][0] - time.monotonic())
                for key, events in self.selector.select(timeout):
                    if key.data == "listener":
                        self.accept()
                    elif self.client and events & selectors.EVENT_WRITE:
                        self.flush(self.client)
                    elif self.client and events & selectors.EVENT_READ:
                        self.read()
                while self.timers and self.timers[0][0] <= time.monotonic():
                    heapq.heappop(self.timers)[2]()
        finally:
            self.cleanup()
        return self.exit_code

    def exit_now(self):
        self.exit_code = self.args.exit_code
        self.running = False

    def cleanup(self):
        for view in self.views.values():
            for segment in (view.shm, view.old_shm):
                self.release(segment)
        if self.listener:
            self.listener.close()
            if self.args.socket:
                try:
                    os.unlink(self.args.socket)
                except OSError:
                    pass
        if self.log_file:
            self.log_file.close()

    def accept(self):
        sock, _ = self.listener.accept()
        self.attach(Client(sock.fileno(), sock.fileno(), sock))

    def read(self):
        client = self.client
        try:
            data = os.read(client.read_fd, 1 << 16)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.drop_client()
            if not self.listener:
                self.running = False
            return
        try:
            records = client.reader.feed(data)
        except lp.Desync:
            self.drop_client()
            if not self.listener:
                self.running = False
            return
        for kind, payload in records:
            if kind != lp.KIND_CONTROL or client is not self.client:
                continue
            try:
                message = json.loads(payload)
            except ValueError:
                continue
            self.log(message)
            handler = getattr(self, "on_" + str(message.get("type")), None)
            if handler:
                handler(client, message)

    def send(self, client, obj):
        client.out += lp.encode_control(obj)
        self.flush(client)

    def flush(self, client, blocking=False):
        if blocking:
            os.set_blocking(client.write_fd, True)
        try:
            while client.out:
                sent = os.write(client.write_fd, client.out[:1 << 18])
                del client.out[:sent]
        except BlockingIOError:
            pass
        except OSError:
            del client.out[:]
        want = bool(client.out)
        if want == client.writing or client is not self.client:
            return
        client.writing = want
        if client.read_fd == client.write_fd:
            self.selector.modify(client.read_fd, selectors.EVENT_READ
                                 | (selectors.EVENT_WRITE if want else 0),
                                 "client")
        elif want:
            self.selector.register(client.write_fd, selectors.EVENT_WRITE,
                                   "client")
        else:
            self.selector.unregister(client.write_fd)

    def tell(self, obj):
        if self.client and self.client.ready:
            self.send(self.client, obj)

    # Views and frames

    def add_view(self, url, width, height, dpr):
        view = View(self.next_view, url, width, height, dpr)
        self.next_view += 1
        self.views[view.id] = view
        return view

    def view_of(self, message):
        view = self.views.get(message.get("view"))
        if not view:
            self.tell({"type": "error", "view": message.get("view"),
                       "message": "unknown view"})
        return view

    def release(self, segment):
        if segment:
            segment.close()
            try:
                segment.unlink()
            except OSError:
                pass

    def segment(self, view):
        """Return VIEW's shared memory segment, announcing a new one."""
        size = view.width * view.height * 4
        if view.shm and view.shm.size < size:
            self.release(view.old_shm)
            view.old_shm, view.shm = view.shm, None
        if not view.shm:
            from multiprocessing import shared_memory
            self.shm_generation += 1
            view.shm = shared_memory.SharedMemory(
                name=f"ladybird-{os.getpid()}-{self.shm_generation}",
                create=True, size=size)
            view.shm_announced = False
        if not view.shm_announced:
            view.shm_announced = True
            # Left unflushed: it goes out in one write with its frame.
            self.client.out += lp.encode_control(
                {"type": "shm", "view": view.id,
                 "name": "/" + view.shm.name.lstrip("/"),
                 "size": view.shm.size})
        return view.shm

    def pump(self, view):
        """Send VIEW's pending damage unless a frame is in flight."""
        client = self.client
        if (not client or not client.ready or view.in_flight is not None
                or view.damage is None or not view.visible):
            return
        if view.dirty:
            view.render()
        x, y, w, h = view.damage
        view.damage = None
        full = (x, y, w, h) == (0, 0, view.width, view.height)
        view.seq += 1
        if client.shm:
            segment = self.segment(view)
            segment.buf[:len(view.framebuffer)] = view.framebuffer
            encoding, payload = lp.ENCODING_SHM, struct.pack("<Q", 0)
        else:
            payload = view.rect_bytes(x, y, w, h)
            encoding = lp.ENCODING_RAW
            if client.encoding == "zstd" and len(payload) >= RAW_THRESHOLD:
                encoding, payload = lp.ENCODING_ZSTD, lp.zstd_compress(payload)
        client.out += lp.encode_frame(view.seq, view.id, view.width, view.height,
                                      view.dpr, x, y, w, h, encoding,
                                      lp.FLAG_FULL if full else 0, payload)
        view.in_flight = view.seq
        self.log({"type": "_frame_sent", "view": view.id, "seq": view.seq,
                  "frame_width": view.width, "frame_height": view.height,
                  "x": x, "y": y, "width": w, "height": h, "full": full,
                  "encoding": ("raw", "zstd", "shm")[encoding],
                  "seed": view.seed, "scroll": view.scroll})
        self.flush(client)

    def tick(self):
        for view in self.views.values():
            view.seed += 1
            view.dirty = True
            view.damage_all()
            self.pump(view)
        self.after(1 / self.args.fps, self.tick)

    def send_state(self, view):
        self.tell(view.state())

    def request_id(self):
        self.next_id += 1
        return self.next_id - 1

    def navigate(self, view, url):
        self.cancel_hints(view)
        view.url = url
        view.title = "Mock: " + url
        view.loading = True
        view.can_go_back = True
        view.can_go_forward = False
        self.send_state(view)

        def loaded():
            if self.views.get(view.id) is view:
                view.loading = False
                self.send_state(view)
        self.after(0.2, loaded)
        if url.startswith("mock://"):
            self.emit(view, url[len("mock://"):])

    def emit(self, view, name):
        v = view.id
        if name.startswith("cancel-"):
            # Open the request and withdraw it half a second later.
            request = self.next_id
            self.emit(view, name[len("cancel-"):])
            if self.next_id > request:
                self.after(0.5, lambda: self.tell(
                    {"type": "request_cancelled", "view": v, "id": request}))
            return
        if name == "disconnect":
            # Drop the client; the views stay.
            self.after(0.1, self.hang_up)
            return
        dialog = {"type": "dialog", "view": v, "message": "Mock " + name,
                  "default": "", "origin": "mock://" + name}
        if name in ("alert", "confirm", "beforeunload"):
            self.tell({**dialog, "id": self.request_id(), "kind": name})
        elif name == "prompt":
            self.tell({**dialog, "id": self.request_id(), "kind": name,
                       "default": "mock default"})
        elif name == "select":
            self.tell({"type": "select", "view": v, "id": self.request_id(),
                       "x": 10, "y": 10, "min_width": 120, "items": [
                           {"id": 1, "label": "One", "selected": False,
                            "disabled": False, "group": None},
                           {"id": 2, "label": "Two", "selected": True,
                            "disabled": False, "group": None},
                           {"separator": True},
                           {"id": 3, "label": "Three", "selected": False,
                            "disabled": True, "group": None},
                           {"id": 4, "label": "Four", "selected": False,
                            "disabled": False, "group": "More"}]})
        elif name in ("file", "files"):
            self.tell({"type": "file_picker", "view": v, "id": self.request_id(),
                       "multiple": name == "files", "accept": "*/*",
                       "directory": None})
        elif name == "color":
            self.tell({"type": "color_picker", "view": v,
                       "id": self.request_id(), "current": "#ff0000"})
        elif name == "date":
            self.tell({"type": "date_picker", "view": v, "id": self.request_id(),
                       "input_type": "date", "value": "2026-01-02",
                       "min": None, "max": None})
        elif name in ("permission", "permission-cancel"):
            request = self.request_id()
            self.tell({"type": "permission", "view": v, "id": request,
                       "name": "geolocation", "origin": "mock://" + name,
                       "is_file": False})
            if name == "permission-cancel":
                self.after(0.5, lambda: self.tell(
                    {"type": "permission_cancelled", "view": v, "id": request}))
        elif name == "external":
            self.tell({"type": "external_url", "view": v, "id": self.request_id(),
                       "url": "mailto:someone@example.com", "application": "Mail"})
        elif name == "context":
            self.context_menu(view, 10, 10)
        elif name == "popup":
            self.tell({"type": "popup_blocked", "view": v, "url": "mock://popped"})
        elif name == "crash":
            self.tell({"type": "crashed", "view": v, "reason": "mock crash"})
        elif name == "hover":
            self.tell({"type": "cursor", "view": v, "cursor": "pointer"})
            self.tell({"type": "link_hover", "view": v, "url": "mock://hovered"})
            self.tell({"type": "tooltip", "view": v, "text": "mock tooltip"})
        elif name == "favicon":
            self.tell({"type": "favicon", "view": v, "png": self.favicon()})
        elif name == "console":
            self.tell({"type": "console", "view": v, "level": "log",
                       "text": "mock console"})
        elif name == "clipboard":
            self.tell({"type": "clipboard", "view": v, "text": "mock clipboard"})
        elif name == "background":
            self.tell({"type": "background_color", "view": v, "rgb": "#102030"})
        elif name == "error":
            self.tell({"type": "error", "view": v, "message": "mock error"})
        elif name == "close":
            self.cancel_hints(view)
            del self.views[v]
            self.tell({"type": "view_closed", "view": v, "reason": "closed"})

    def context_menu(self, view, x, y):
        self.tell({"type": "context_menu", "view": view.id, "x": x, "y": y,
                   "kind": "link", "link_url": "https://mock.invalid/linked", "image_url": None,
                   "image_mime_type": None, "media_url": None, "media": None,
                   "selection": "mock selection", "editable": True})

    def favicon(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "favicon.png")
            lp.write_png(path, 16, 16, lp.formula_rect(3, 16, 16))
            with open(path, "rb") as f:
                return base64.b64encode(f.read()).decode("ascii")

    # Messages

    def on_hello(self, client, m):
        if self.args.reject or m.get("protocol") != lp.PROTOCOL_VERSION:
            self.send(client, {"type": "reject",
                               "reason": "rejected by --reject" if self.args.reject
                               else "unsupported protocol"})
            self.flush(client, blocking=True)
            self.drop_client()
            if not self.listener:
                self.running = False
            return
        viewport = m.get("viewport") or {}
        client.viewport = (viewport.get("width", 800), viewport.get("height", 600),
                           viewport.get("dpr", 1.0))
        if (self.args.zstd and "zstd" in (m.get("encodings") or [])
                and lp.zstd_available()):
            client.encoding = "zstd"
        client.shm = bool(self.args.shm and m.get("shm"))
        client.ready = True
        features = {} if self.args.no_hints else {"features": ["hints"]}
        self.send(client, {
            "type": "welcome", "protocol": lp.PROTOCOL_VERSION,
            "server": f"ladybird mock server ({os.getpid()})",
            "encoding": client.encoding,
            "shm": client.shm, "log": self.args.log,
            "host": {"hostname": self.args.hostname or socket.gethostname(),
                     "platform": self.args.platform},
            **features,
            "views": [view.describe() for view in self.views.values()]})
        for view in list(self.views.values()):
            self.send_state(view)
            view.damage_all()
            self.pump(view)

    def on_ping(self, client, m):
        if not self.args.no_pong:
            self.send(client, {"type": "pong", "id": m.get("id")})

    def on_create_view(self, client, m):
        # The answer names the request when the client numbered it.
        request = {} if m.get("request") is None else {"request": m["request"]}
        if (self.args.max_views is not None
                and len(self.views) >= self.args.max_views):
            one = self.args.max_views == 1
            self.tell({"type": "error", **request,
                       "message": "only one view is supported" if one
                       else f"only {self.args.max_views} views are supported"})
            return
        width, height, dpr = client.viewport
        url = m.get("url") or "about:blank"
        view = self.add_view(url, m.get("width", width), m.get("height", height),
                             m.get("dpr", dpr))
        self.tell({"type": "view_created", "view": view.id, **request,
                   "url": view.url, "title": view.title, "width": view.width,
                   "height": view.height, "dpr": view.dpr})
        self.send_state(view)
        self.pump(view)
        if url.startswith("mock://"):
            self.emit(view, url[len("mock://"):])

    def on_close_view(self, _client, m):
        view = self.view_of(m)
        if view:
            view.hints = None
            del self.views[view.id]
            for segment in (view.shm, view.old_shm):
                self.release(segment)
            self.tell({"type": "view_closed", "view": view.id, "reason": "client"})

    def on_set_viewport(self, _client, m):
        view = self.view_of(m)
        if view:
            view.resize(m.get("width", view.width), m.get("height", view.height),
                        m.get("dpr", view.dpr))
            self.pump(view)

    def on_set_visibility(self, _client, m):
        view = self.view_of(m)
        if view:
            view.visible = bool(m.get("visible"))
            self.pump(view)

    def on_frame_ack(self, _client, m):
        view = self.views.get(m.get("view"))
        if view and m.get("seq") == view.in_flight:
            view.in_flight = None
            self.release(view.old_shm)
            view.old_shm = None
            self.pump(view)

    def on_shm_failed(self, client, m):
        client.shm = False
        view = self.views.get(m.get("view"))
        if view:
            view.in_flight = None
            view.damage_all()
            self.pump(view)

    def on_mouse(self, _client, m):
        view = self.view_of(m)
        if not view:
            return
        kind = m.get("kind")
        if kind == "down":
            x, y = int(m.get("x", 0)), int(m.get("y", 0))
            view.squares = (view.squares + [(x, y)])[-32:]
            view.dirty = True
            view.add_damage(x - SQUARE // 2, y - SQUARE // 2, SQUARE, SQUARE)
            if m.get("button") == "right":
                self.context_menu(view, x, y)
        elif kind == "wheel":
            view.scroll = (view.scroll + int(m.get("dy", 0))) % view.height
            view.dirty = True
            view.damage_all()
        self.pump(view)

    def type_text(self, view, text):
        view.text += text
        view.dirty = True
        view.add_damage(*view.text_rect())
        self.pump(view)

    def on_key(self, _client, m):
        view = self.view_of(m)
        if view and m.get("kind") == "down":
            self.type_text(view, str(m.get("key")) + " ")

    def on_text(self, _client, m):
        view = self.view_of(m)
        if view:
            self.type_text(view, str(m.get("text")))

    def on_paste(self, _client, m):
        self.on_text(_client, m)

    def on_load(self, _client, m):
        view = self.view_of(m)
        if view:
            self.navigate(view, str(m.get("url")))

    def on_load_html(self, _client, m):
        view = self.view_of(m)
        if view:
            self.navigate(view, "about:srcdoc")

    def on_reload(self, _client, m):
        view = self.view_of(m)
        if view:
            self.navigate(view, view.url)

    def on_stop(self, _client, m):
        view = self.view_of(m)
        if view:
            view.loading = False
            self.send_state(view)

    def on_history(self, _client, m):
        view = self.view_of(m)
        if view:
            back = m.get("delta", 0) < 0
            view.can_go_back = not back
            view.can_go_forward = back
            self.send_state(view)

    def on_zoom(self, _client, m):
        view = self.view_of(m)
        if view:
            op = m.get("op")
            view.zoom = (1.0 if op == "reset" else
                         round(view.zoom * (1.1 if op == "in" else 1 / 1.1), 3))
            self.send_state(view)

    def find_result(self, view):
        self.tell({"type": "find_result", "view": view.id,
                   "query": view.find_query, "index": view.find_index,
                   "total": view.find_total})

    def on_find(self, _client, m):
        view = self.view_of(m)
        if view:
            query, url = str(m.get("query") or ""), view.url
            if not m.get("case_sensitive"):
                query, url = query.lower(), url.lower()
            view.find_query = str(m.get("query") or "")
            view.find_total = url.count(query) if query else 0
            view.find_index = 1 if view.find_total else 0
            self.find_result(view)

    def on_find_step(self, _client, m):
        view = self.view_of(m)
        if view and view.find_total:
            step = -1 if m.get("direction") == "previous" else 1
            view.find_index = (view.find_index - 1 + step) % view.find_total + 1
            self.find_result(view)

    def on_edit(self, _client, m):
        view = self.view_of(m)
        if view and m.get("op") == "cut":
            self.tell({"type": "clipboard", "view": view.id, "text": "mock cut"})

    def on_request_selection(self, _client, m):
        view = self.view_of(m)
        if view:
            self.tell({"type": "selection", "view": view.id,
                       "request": m.get("request"), "text": "mock selection"})

    def on_screenshot(self, _client, m):
        view = self.view_of(m)
        if view:
            path = m.get("path") or os.path.join(
                tempfile.gettempdir(), f"ladybird-mock-{os.getpid()}-{view.id}.png")
            if view.dirty:
                view.render()
            try:
                lp.write_png(path, view.width, view.height, bytes(view.framebuffer))
            except OSError as e:
                self.tell({"type": "error", "view": view.id, "message": str(e)})
                return
            self.tell({"type": "screenshot_saved", "view": view.id,
                       "request": m.get("request"), "path": path})

    def on_set_console(self, _client, m):
        view = self.view_of(m)
        if view and m.get("enabled"):
            self.tell({"type": "console", "view": view.id, "level": "log",
                       "text": "console enabled"})

    # Hints

    def redraw_hints(self, view):
        view.dirty = True
        view.damage_all()
        self.pump(view)

    def cancel_hints(self, view):
        """End VIEW's hint session, if it has one, with hints_cancelled."""
        if view.hints:
            session, view.hints = view.hints, None
            self.tell({"type": "hints_cancelled", "view": view.id,
                       "id": session["id"]})
            self.redraw_hints(view)

    def hint_error(self, view, m, message):
        self.tell({"type": "error", "view": view.id, "id": m.get("id"),
                   "message": message})

    def hint_session(self, m):
        """Return the view of M if M names its hint session, else None."""
        view = self.view_of(m)
        if not view:
            return None
        if not view.hints or view.hints["id"] != m.get("id"):
            self.hint_error(view, m, "not the view's hint session")
            return None
        return view

    def on_hints(self, _client, m):
        view = self.view_of(m)
        if not view:
            return
        if self.args.no_hints:
            self.hint_error(view, m, "hints are not supported")
            return
        session = m.get("id")
        if (not isinstance(session, int) or isinstance(session, bool)
                or not 0 <= session < 2 ** 53):
            self.hint_error(view, m, f"bad hint id {session!r}")
            return
        alphabet = m.get("alphabet")
        if not hint_alphabet_ok(alphabet):
            self.hint_error(view, m, f"bad hint alphabet {alphabet!r}")
            return
        items, truncated = hint_items(view.url, alphabet)
        # A new session ends the one before it without a message.
        view.hints = None
        if view.url == "mock://hints-timeout":
            view.hints = {"id": session, "items": [], "prefix": "",
                          "alphabet": alphabet, "narrowed": False}
            pending = view.hints

            def timeout():
                if self.views.get(view.id) is view and view.hints is pending:
                    self.cancel_hints(view)
            self.after(3, timeout)
            return
        if items:
            view.hints = {"id": session, "items": items, "prefix": "",
                          "alphabet": alphabet, "narrowed": False}
        self.tell({"type": "hints_list", "view": view.id, "id": session,
                   "items": items, "truncated": truncated})
        self.redraw_hints(view)

    def on_hints_narrow(self, _client, m):
        view = self.hint_session(m)
        if not view:
            return
        session = view.hints
        prefix = m.get("prefix")
        longest = max((len(item["label"]) for item in session["items"]),
                      default=None)
        if (not isinstance(prefix, str)
                or any(c not in session["alphabet"] for c in prefix)
                or (longest is not None and len(prefix) > longest)):
            self.hint_error(view, m, f"bad hint prefix {prefix!r}")
            return
        session["prefix"] = prefix
        self.redraw_hints(view)
        if session["narrowed"]:
            return
        session["narrowed"] = True
        if view.url == "mock://hints-expire":
            self.cancel_hints(view)
        elif view.url == "mock://hints-confirm":
            self.emit(view, "confirm")
        elif view.url == "mock://hints-alert":
            self.emit(view, "alert")

            def later():
                if view.hints is session:
                    self.cancel_hints(view)
            self.after(0.3, later)

    def on_hints_end(self, _client, m):
        view = self.hint_session(m)
        if not view:
            return
        session, view.hints = view.hints, None
        self.redraw_hints(view)
        index = m.get("activate")
        item = next((item for item in session["items"]
                     if index is not None and item["index"] == index), None)
        if item:
            self.log({"type": "_hint_activated", "view": view.id,
                      "id": session["id"], "index": index, "kind": item["kind"],
                      "label": item["label"]})
            if item["kind"] == "link":
                self.navigate(view, item["url"])


class SelftestClient:
    def __init__(self, sock):
        self.sock = sock
        self.reader = lp.RecordReader()
        self.queue = []
        sock.settimeout(5)

    def send(self, obj):
        self.sock.sendall(lp.encode_control(obj))

    def receive(self, timeout=5):
        """Return the next record: a dict, or (FrameHeader, body)."""
        self.sock.settimeout(timeout)
        while not self.queue:
            data = self.sock.recv(1 << 16)
            if not data:
                raise EOFError
            self.queue += self.reader.feed(data)
        kind, payload = self.queue.pop(0)
        if kind == lp.KIND_CONTROL:
            return json.loads(payload)
        header, body = lp.FrameHeader.parse(payload)
        header.validate(len(body))
        return header, body

    def expect(self, message_type):
        record = self.receive()
        assert isinstance(record, dict) and record["type"] == message_type, record
        return record

    def frame(self):
        record = self.receive()
        assert isinstance(record, tuple), record
        return record

    def quiet(self):
        try:
            record = self.receive(0.2)
        except TimeoutError:
            return
        raise AssertionError(f"unexpected record {record}")

    def ack(self, header):
        self.send({"type": "frame_ack", "view": header.view, "seq": header.seq})

    def control(self, message_type, timeout=5):
        """Return the next control message of MESSAGE_TYPE.
        Frames on the way are acknowledged; another control message is an
        error."""
        while True:
            record = self.receive(timeout)
            if isinstance(record, tuple):
                self.ack(record[0])
                continue
            assert record["type"] == message_type, record
            return record

    def settle(self):
        """Acknowledge frames until the server is quiet; return the last."""
        last = None
        try:
            while True:
                record = self.receive(0.3)
                assert isinstance(record, tuple), record
                self.ack(record[0])
                last = record
        except TimeoutError:
            return last


def selftest():
    for fw, fh, seed in ((1, 1, 0), (37, 23, 5), (300, 260, 9)):
        gradient = Gradient(fw, fh)
        rows = b"".join(bytes(gradient.row(y, seed)) for y in range(fh))
        assert rows == lp.formula_rect(seed, fw, fh), (fw, fh, seed)

    def serve(*argv):
        ours, theirs = socket.socketpair()
        server = Server(parse_arguments(["--fps", "0", *argv]))
        server.attach(Client(theirs.fileno(), theirs.fileno(), theirs))
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        return SelftestClient(ours), thread

    hello = {"type": "hello", "protocol": 1, "client": "selftest",
             "viewport": {"width": 64, "height": 48, "dpr": 1.0},
             "encodings": ["zstd", "raw"], "shm": False, "token": None}

    client, thread = serve()
    client.send(hello)
    welcome = client.expect("welcome")
    assert welcome["views"] == [] and welcome["encoding"] == "raw"
    assert welcome["shm"] is False
    client.send({"type": "create_view", "url": "mock://one", "width": 64,
                 "height": 48, "dpr": 1.0})
    created = client.expect("view_created")
    view = created["view"]
    assert (created["width"], created["height"]) == (64, 48)
    state = client.expect("state")
    assert state["title"] == "Mock: mock://one" and state["loading"] is False
    header, body = client.frame()
    assert (header.seq, header.view, header.full) == (1, view, True)
    assert body == lp.formula_rect(0, 64, 48)
    store = bytearray(body)

    # One frame in flight: damage made before the ack is sent as one union.
    client.send({"type": "mouse", "view": view, "kind": "down", "x": 20, "y": 30,
                 "button": "left", "buttons": ["left"], "modifiers": 0,
                 "clicks": 1})
    client.send({"type": "mouse", "view": view, "kind": "down", "x": 50, "y": 20,
                 "button": "left", "buttons": ["left"], "modifiers": 0,
                 "clicks": 1})
    client.quiet()
    client.ack(header)
    header, body = client.frame()
    assert header.seq == 2 and not header.full
    rect = (header.damage_x, header.damage_y, header.damage_width,
            header.damage_height)
    assert rect == (8, 8, 54, 34), rect
    lp.compose(store, 64, 48, header, body)
    for x, y, white in ((20, 30, True), (50, 20, True), (31, 41, True),
                        (32, 42, False), (7, 17, False), (40, 40, False)):
        (pixel,) = struct.unpack_from("<I", store, (y * 64 + x) * 4)
        expected = 0xFFFFFFFF if white else lp.bgra_formula(x, y, 0, 64, 48)
        assert pixel == expected, (x, y, hex(pixel))
    client.ack(header)

    client.send({"type": "set_viewport", "view": view, "width": 80, "height": 40,
                 "dpr": 2.0})
    header, body = client.frame()
    assert (header.seq, header.full, header.frame_width, header.frame_height,
            header.dpr) == (3, True, 80, 40, 2.0)
    client.ack(header)

    client.send({"type": "key", "view": view, "kind": "down", "key": "A",
                 "code_point": 97, "modifiers": 0, "repeat": False})
    header, body = client.frame()
    assert (header.damage_x, header.damage_y, header.damage_width,
            header.damage_height) == (0, 0, 80, TEXT_HEIGHT)
    client.ack(header)

    client.send({"type": "ping", "id": 7})
    assert client.expect("pong")["id"] == 7
    client.send({"type": "load", "view": view, "url": "mock://confirm"})
    assert client.expect("state")["loading"] is True
    dialog = client.expect("dialog")
    assert dialog["kind"] == "confirm"
    assert client.expect("state")["loading"] is False
    client.send({"type": "find", "view": view, "query": "O",
                 "case_sensitive": False, "highlight_all": True})
    result = client.expect("find_result")
    assert (result["index"], result["total"]) == (1, 2), result
    client.send({"type": "request_selection", "view": view, "request": 3})
    assert client.expect("selection")["request"] == 3
    client.send({"type": "close_view", "view": view})
    assert client.expect("view_closed")["reason"] == "client"
    client.sock.close()
    thread.join(5)
    assert not thread.is_alive()

    notes = []
    if lp.zstd_available():
        client, thread = serve("--zstd", "--views", "1")
        client.send(hello)
        welcome = client.expect("welcome")
        assert welcome["encoding"] == "zstd" and len(welcome["views"]) == 1
        client.expect("state")
        header, body = client.frame()
        assert header.encoding == lp.ENCODING_ZSTD
        assert (lp.zstd_decompress(body, header.raw_size)
                == lp.formula_rect(0, 800, 600))
        client.sock.close()
        thread.join(5)
    else:
        notes.append("zstd unavailable, skipped")

    client, thread = serve("--shm", "--views", "1")
    client.send({**hello, "shm": True})
    assert client.expect("welcome")["shm"] is True
    client.expect("state")
    announced = client.expect("shm")
    header, body = client.frame()
    assert header.encoding == lp.ENCODING_SHM and body == struct.pack("<Q", 0)
    from multiprocessing import shared_memory
    segment = shared_memory.SharedMemory(name=announced["name"].lstrip("/"))
    assert segment.size == announced["size"]
    assert bytes(segment.buf[:800 * 600 * 4]) == lp.formula_rect(0, 800, 600)
    segment.close()
    client.send({"type": "shm_failed", "view": header.view})
    client.ack(header)
    header, body = client.frame()
    assert header.encoding == lp.ENCODING_RAW and header.full
    client.sock.close()
    thread.join(5)

    client, thread = serve("--max-views", "1", "--hostname", "elsewhere")
    client.send(hello)
    welcome = client.expect("welcome")
    assert welcome["host"]["hostname"] == "elsewhere"
    assert str(os.getpid()) in welcome["server"]
    client.send({"type": "create_view", "request": 7, "url": "mock://cancel-confirm",
                 "width": 64, "height": 48, "dpr": 1.0})
    created = client.expect("view_created")
    assert created["request"] == 7
    client.expect("state")
    header, _ = client.frame()
    client.ack(header)
    dialog = client.expect("dialog")
    client.send({"type": "create_view", "request": 8, "url": "mock://two"})
    refused = client.expect("error")
    assert refused == {"type": "error", "request": 8,
                       "message": "only one view is supported"}, refused
    client.send({"type": "create_view", "url": "mock://three"})
    assert "request" not in client.expect("error")
    cancelled = client.expect("request_cancelled")
    assert (cancelled["view"], cancelled["id"]) == (created["view"], dialog["id"])
    client.send({"type": "load", "view": created["view"], "url": "mock://disconnect"})
    assert client.expect("state")["loading"] is True
    try:
        while True:
            client.receive(2)
    except EOFError:
        pass
    client.sock.close()
    server_exit = thread.join(5)
    assert server_exit is None and not thread.is_alive()

    client, thread = serve("--reject")
    client.send(hello)
    assert client.expect("reject")["reason"]
    thread.join(5)

    selftest_hints(serve, hello)
    print("ok" + "".join(f" ({note})" for note in notes))


def selftest_hints(serve, hello):
    assert hint_labels(3, "ab") == ["aa", "ab", "ba"]
    assert hint_labels(2, "ab") == ["a", "b"]
    assert hint_labels(1, "ab") == ["a"]
    for bad in ("a", "aa", "aB", "a-", "abcdefghijklmnopqrstuvwxyz0123456789x", 7):
        assert not hint_alphabet_ok(bad), bad

    client, thread = serve("--views", "1")
    client.send({**hello, "viewport": {"width": 400, "height": 200, "dpr": 1.0}})
    welcome = client.expect("welcome")
    assert welcome["features"] == ["hints"]
    view = welcome["views"][0]["view"]
    client.expect("state")
    client.send({"type": "set_viewport", "view": view, "width": 400,
                 "height": 200, "dpr": 1.0})
    before = client.settle()

    def hints(session, alphabet="asdfghjkl"):
        client.send({"type": "hints", "view": view, "id": session,
                     "alphabet": alphabet})

    def refused(session):
        error = client.control("error")
        assert error["id"] == session, error
        return error["message"]

    # A bad alphabet or id is refused and changes nothing; the error has
    # the id of what it answers.
    hints(1, "aa")
    assert "alphabet" in refused(1)
    for bad in (-1, 2 ** 53, 1.5, "1", None, True):
        hints(bad)
        assert "bad hint id" in refused(bad)
    client.send({"type": "hints_narrow", "view": view, "id": 1, "prefix": ""})
    assert refused(1) == "not the view's hint session"

    hints(2)
    listed = client.control("hints_list")
    assert listed["id"] == 2 and listed["truncated"] is False
    items = listed["items"]
    assert len(items) == 12 and [i["index"] for i in items] == list(range(12))
    assert {i["kind"] for i in items} == set(HINT_KINDS)
    assert {len(i["label"]) for i in items} == {2}
    assert items[0]["label"] == "aa" and items[11]["label"] == "sd"
    assert items[0]["url"] == "https://mock.invalid/link/1" and items[1]["url"] is None
    # The labels are drawn into the frames.
    labelled = client.settle()
    assert labelled and labelled[1] != before[1]
    client.send({"type": "hints_narrow", "view": view, "id": 2, "prefix": "s"})
    narrowed = client.settle()
    assert narrowed and narrowed[1] != labelled[1]
    # Another id is refused; an index that is no item's activates nothing.
    client.send({"type": "hints_end", "view": view, "id": 3, "activate": 0})
    assert refused(3) == "not the view's hint session"
    client.send({"type": "hints_end", "view": view, "id": 2, "activate": 99})
    client.settle()
    client.send({"type": "hints_end", "view": view, "id": 2, "activate": None})
    assert refused(2) == "not the view's hint session"

    # A new session ends the one before it without a message; activating a
    # link loads it.
    hints(4)
    client.control("hints_list")
    hints(5)
    assert client.control("hints_list")["id"] == 5
    client.send({"type": "hints_end", "view": view, "id": 4, "activate": 0})
    assert refused(4) == "not the view's hint session"
    client.send({"type": "hints_end", "view": view, "id": 5, "activate": 4})
    state = client.control("state")
    assert state["url"] == "https://mock.invalid/link/5" and state["loading"] is True
    assert client.control("state")["loading"] is False

    # Loading another page ends the session.
    hints(6)
    client.control("hints_list")
    client.send({"type": "load", "view": view, "url": "mock://hints-0"})
    assert client.control("hints_cancelled") == {
        "type": "hints_cancelled", "view": view, "id": 6}
    client.control("state")
    client.control("state")
    # No items: the session is over at once.
    hints(7)
    listed = client.control("hints_list")
    assert listed["items"] == [] and listed["truncated"] is False
    client.send({"type": "hints_end", "view": view, "id": 7, "activate": None})
    assert refused(7) == "not the view's hint session"

    client.send({"type": "load", "view": view, "url": "mock://hints-truncated"})
    client.control("state")
    client.control("state")
    hints(8)
    listed = client.control("hints_list")
    assert len(listed["items"]) == 1000 and listed["truncated"] is True
    assert {len(i["label"]) for i in listed["items"]} == {4}
    hints(9, "ab")
    listed = client.control("hints_list")
    assert {len(i["label"]) for i in listed["items"]} == {10}

    client.send({"type": "load", "view": view, "url": "mock://hints-expire"})
    assert client.control("hints_cancelled")["id"] == 9
    client.control("state")
    client.control("state")
    hints(10)
    client.control("hints_list")
    # A prefix must be of the alphabet and no longer than the labels.
    for bad in ("x", "aaa", 3, None):
        client.send({"type": "hints_narrow", "view": view, "id": 10, "prefix": bad})
        assert "bad hint prefix" in refused(10)
    client.send({"type": "hints_narrow", "view": view, "id": 10, "prefix": "a"})
    assert client.control("hints_cancelled") == {
        "type": "hints_cancelled", "view": view, "id": 10}
    # A narrowing that crosses it is refused with the old id.
    client.send({"type": "hints_narrow", "view": view, "id": 10, "prefix": ""})
    assert refused(10) == "not the view's hint session"
    client.send({"type": "load", "view": view, "url": "mock://hints-confirm"})
    client.control("state")
    client.control("state")
    hints(12)
    client.control("hints_list")
    client.send({"type": "hints_narrow", "view": view, "id": 12, "prefix": "s"})
    assert client.control("dialog")["kind"] == "confirm"
    client.send({"type": "hints_narrow", "view": view, "id": 12, "prefix": ""})
    client.send({"type": "load", "view": view, "url": "mock://hints-alert"})
    client.control("hints_cancelled")
    client.control("state")
    client.control("state")
    hints(13)
    client.control("hints_list")
    client.send({"type": "hints_narrow", "view": view, "id": 13, "prefix": "s"})
    assert client.control("dialog")["kind"] == "alert"
    assert client.control("hints_cancelled", 2)["id"] == 13
    # A page that does not answer in time: hints_cancelled, no hints_list.
    client.send({"type": "load", "view": view, "url": "mock://hints-timeout"})
    client.control("state")
    client.control("state")
    hints(11)
    assert client.control("hints_cancelled", 5) == {
        "type": "hints_cancelled", "view": view, "id": 11}
    # A close_view ends a session with view_closed alone.
    client.send({"type": "load", "view": view, "url": "mock://one"})
    client.control("state")
    client.control("state")
    hints(14)
    client.control("hints_list")
    client.send({"type": "close_view", "view": view})
    assert client.control("view_closed")["reason"] == "client"
    client.sock.close()
    thread.join(5)

    client, thread = serve("--no-hints", "--views", "1")
    client.send(hello)
    welcome = client.expect("welcome")
    assert "features" not in welcome
    view = welcome["views"][0]["view"]
    client.control("state")
    client.send({"type": "hints", "view": view, "id": 1, "alphabet": "ab"})
    error = client.control("error")
    assert error == {"type": "error", "view": view, "id": 1,
                     "message": "hints are not supported"}, error
    client.sock.close()
    thread.join(5)


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description="Mock ladybird server")
    parser.add_argument("--stdio", action="store_true")
    parser.add_argument("--socket", metavar="PATH")
    parser.add_argument("--tcp", metavar="HOST:PORT")
    parser.add_argument("--views", type=int, default=0)
    parser.add_argument("--fps", type=float, default=10)
    parser.add_argument("--log", metavar="FILE")
    parser.add_argument("--no-pong", action="store_true")
    parser.add_argument("--exit-after", type=float, metavar="SECONDS")
    parser.add_argument("--exit-code", type=int, default=0)
    parser.add_argument("--reject", action="store_true")
    parser.add_argument("--zstd", action="store_true")
    parser.add_argument("--shm", action="store_true")
    parser.add_argument("--max-views", type=int, metavar="N")
    parser.add_argument("--hostname", metavar="NAME")
    parser.add_argument("--no-hints", action="store_true")
    parser.add_argument("--platform", default=(
        "macos" if sys.platform == "darwin" else
        "linux" if sys.platform.startswith("linux") else "unknown"))
    parser.add_argument("--selftest", action="store_true")
    return parser.parse_args(argv)


def main():
    args = parse_arguments(sys.argv[1:])
    if args.selftest:
        selftest()
        return 0
    server = Server(args)
    if args.socket:
        try:
            os.unlink(args.socket)
        except OSError:
            pass
        listener = socket.socket(socket.AF_UNIX)
        old = os.umask(0o177)
        try:
            listener.bind(args.socket)
        finally:
            os.umask(old)
        listener.listen(4)
        server.listen(listener)
    elif args.tcp:
        host, _, port = args.tcp.rpartition(":")
        host = host.strip("[]")
        listener = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, int(port)))
        listener.listen(4)
        server.listen(listener)
    else:
        server.attach(Client(0, 1))
    try:
        return server.run()
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
