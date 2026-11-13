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
  --emacs-default-socket
                      listen on the default socket of plans/01-protocol.md
                      section 1, making its directory outside
                      XDG_RUNTIME_DIR with mode 0700 but checking nothing
  --emacs-background  with a socket: run the server in a session of its own
                      with its standard streams on /dev/null and exit once it
                      listens, printing "Ladybird logs to FILE" with --log; or
                      exit 1 with the reason on stderr, also when a server
                      accepts connections on the socket already
  --headless MODE     ignored, so that the mock takes Ladybird's command line
  --tcp HOST:PORT     listen on a TCP port
  --views N           views that exist before the first client (default 0)
  --fps F             animation ticks per second (default 10; 0 = none)
  --log FILE          JSON lines: every received control message, plus
                      {"type":"_frame_sent",...}, {"type":"_connected"} when
                      a connection becomes the client and
                      {"type":"_disconnected"} when the client goes
  --no-pong           never answer a ping
  --exit-after S      exit after S seconds
  --exit-code N       exit status of --exit-after (default 0)
  --reject            answer every hello with a reject
  --zstd              use zstd when the client offers it
  --shm               use shared memory when the client offers it
  --platform NAME     platform named in the welcome: macos, linux or unknown
                      (default: this machine's)
  --hostname NAME     host name in the welcome (default: this machine's)
  --max-views N       hold at most N views (default 16), the welcome's
                      max_views; a create_view beyond them gets an error
  --no-max-views      leave max_views out of the welcome and hold one view
  --band-rows N       send a stream frame taller than N rows in bands of N
                      rows, one after the other's acknowledgement; while one
                      view's frame is in bands the others wait
  --band-pause S      wait S seconds before each band after the first
  --max-area PIXELS   refuse a create_view or set_viewport that would make
                      the views cover more pixels with an error
  --no-hints          leave "hints" out of the welcome's features (there are
                      none then) and answer hints with an error
  --selftest          run an in-process client against the server

A connection becomes the client with a valid hello (protocol section
8).  A connection that closes before its hello leaves the client alone,
as does one whose first message is no valid hello or whose framing is
broken, which gets a reject.  A client that is replaced gets the rest
of the record being written to it, "replaced" and the end of the
stream; a client whose framing is broken gets the same with a reject.
What such a connection still sends is dropped until it closes, for at
most 3 seconds.
At most 8 connections wait for their hello; a ninth closes the oldest.
A second hello of the client is answered with an error.

Loading a mock:// URL makes the server emit a request or event:
mock://alert, confirm, prompt, beforeunload, select, file, files, color,
date, permission, permission-cancel, external, context, popup, crash,
hover, favicon, console, clipboard, background, error, close.
mock://close-later closes its view half a second after it loads.

mock://popup opens a view at mock://popped, as a page that opens a
window does (protocol section 3.1): when the client's hello had "popups":
true and there is room (--max-views, --max-area), with view_created
naming the opener, the opener's size, a state and a frame; otherwise with
popup_blocked.  mock://popup-close opens one at mock://close-later, and
mock://popups-N opens N in a row, as N clicks would.

mock://cancel-NAME emits the request of mock://NAME and withdraws it
half a second later with request_cancelled; mock://disconnect drops the
client and keeps the views.

The views share a cookie: loading mock://cookie/set/VALUE sets it, and a
page at mock://cookie has the title "Mock: cookie=VALUE".  A hidden view
sends no frames and sends a full one when it is shown again.  Hiding or
closing a view whose frame is in bands drops the bands not sent
(logged as {"type":"_bands_dropped","view","bands","why"}).  One
shm_failed turns every view to stream frames, each sending a whole
frame next.  The server keeps running with no view.

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
import subprocess
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
MAX_PENDING = 8
DRAIN_TIMEOUT = 3
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
        self.bands = []  # (x, y, w, h, flags) of the frame's bands not sent
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
        # Bytes of the record at the head of out that are still to be written.
        self.record_left = 0
        self.ready = False
        self.encoding = "raw"
        self.shm = False
        self.viewport = (800, 600, 1.0)
        self.popups = False
        self.writing = False


class Server:
    def __init__(self, args):
        self.args = args
        self.selector = selectors.DefaultSelector()
        self.views = {}
        self.next_view = 1
        self.cookie = ""
        self.next_id = 1
        self.shm_generation = 0
        self.client = None
        self.pending = []
        self.retiring = []
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

    def connect(self, client):
        """Take the connection CLIENT, which becomes the client with its hello."""
        os.set_blocking(client.read_fd, False)
        os.set_blocking(client.write_fd, False)
        self.selector.register(client.read_fd, selectors.EVENT_READ, client)
        if len(self.pending) >= MAX_PENDING:
            self.close(self.pending.pop(0))
        self.pending.append(client)

    def attach(self, client):
        """Make the pending connection CLIENT the client, replacing the one before."""
        self.pending.remove(client)
        self.drop_client({"type": "replaced"})
        self.client = client
        self.log({"type": "_connected"})

    def close(self, client):
        self.unregister(client)
        if client.sock:
            client.sock.close()

    def close_pending(self, client):
        self.pending.remove(client)
        self.close(client)
        self.check_stop()

    def reject(self, client, reason):
        self.pending.remove(client)
        self.retire(client, {"type": "reject", "reason": reason})

    def retire(self, client, message):
        """Send CLIENT the rest of the record being written and MESSAGE, then close.

        What it sends meanwhile is dropped; it is closed when it closes
        or after DRAIN_TIMEOUT seconds."""
        del client.out[client.record_left:]
        client.out += lp.encode_control(message)
        self.retiring.append(client)
        self.after(DRAIN_TIMEOUT, lambda: self.discard(client))
        self.flush(client)

    def discard(self, client):
        if client in self.retiring:
            self.retiring.remove(client)
            self.close(client)
            self.check_stop()

    def finish_writing(self, client):
        """End the stream of the retiring CLIENT, whose queue is written."""
        if not client.sock:
            self.discard(client)
            return
        try:
            client.sock.shutdown(socket.SHUT_WR)
        except OSError:
            self.discard(client)

    def check_stop(self):
        """Without a listener the server ends with its last connection."""
        if not (self.listener or self.client or self.pending or self.retiring):
            self.running = False

    def hello_refusal(self, m):
        """Return why the first message M of a connection is refused, or None."""
        if m.get("type") != "hello":
            return "the first message must be hello"
        if self.args.reject:
            return "rejected by --reject"
        if m.get("protocol") != lp.PROTOCOL_VERSION:
            return "unsupported protocol version"
        return None

    def unregister(self, client):
        for fd in {client.read_fd, client.write_fd}:
            try:
                self.selector.unregister(fd)
            except (KeyError, ValueError):
                pass

    def drop_client(self, message=None):
        """Drop the client; with MESSAGE, retire its connection with it."""
        client, self.client = self.client, None
        if not client:
            return
        if message:
            self.retire(client, message)
        else:
            self.close(client)
        for view in self.views.values():
            view.in_flight = None
            view.shm_announced = False
            # A client that goes away ends its hint sessions.
            if view.hints:
                view.hints = None
                view.dirty = True
                view.damage_all()
        self.log({"type": "_disconnected"})

    def hang_up(self, message=None):
        """Drop the client; without a listener that ends the server."""
        self.drop_client(message)
        self.check_stop()

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
                    client = key.data
                    if client == "listener":
                        self.accept()
                    elif not self.connected(client):
                        continue
                    elif events & selectors.EVENT_WRITE:
                        self.flush(client)
                    elif events & selectors.EVENT_READ:
                        self.read(client)
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
        self.connect(Client(sock.fileno(), sock.fileno(), sock))

    def connected(self, client):
        return (client is self.client or client in self.pending
                or client in self.retiring)

    def framing_error(self, client):
        if client in self.pending:
            self.reject(client, "framing error")
        else:
            self.hang_up({"type": "reject", "reason": "framing error"})

    def read(self, client):
        """Read from CLIENT, the client or a connection that has not said hello."""
        try:
            data = os.read(client.read_fd, 1 << 16)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if client in self.retiring:
            if not data:
                self.discard(client)
            return
        if not data:
            if client in self.pending:
                self.close_pending(client)
            else:
                self.hang_up()
            return
        try:
            records = client.reader.feed(data)
        except lp.Desync:
            self.framing_error(client)
            return
        for kind, payload in records:
            if kind != lp.KIND_CONTROL:
                continue
            try:
                message = json.loads(payload)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            if client in self.pending:
                refusal = self.hello_refusal(message)
                if refusal:
                    self.log(message)
                    self.reject(client, refusal)
                    return
                self.attach(client)
            elif client is not self.client:
                return
            self.log(message)
            handler = getattr(self, "on_" + str(message.get("type")), None)
            if handler:
                handler(client, message)
        # A framing error behind the records shows on the next feed.
        if client is self.client or client in self.pending:
            try:
                client.reader.feed(b"")
            except lp.Desync:
                self.framing_error(client)

    def send(self, client, obj):
        client.out += lp.encode_control(obj)
        self.flush(client)

    def wrote(self, client, sent):
        """Remove the SENT bytes written from CLIENT's queue."""
        position, left = 0, client.record_left
        while position < sent:
            if not left:
                left = 4 + struct.unpack_from("<I", client.out, position)[0]
            step = min(left, sent - position)
            position += step
            left -= step
        client.record_left = left
        del client.out[:sent]

    def flush(self, client):
        try:
            while client.out:
                self.wrote(client, os.write(client.write_fd, client.out[:1 << 18]))
        except BlockingIOError:
            pass
        except OSError:
            del client.out[:]
            client.record_left = 0
            if client in self.retiring:
                self.discard(client)
                return
        if not self.connected(client):
            return
        want = bool(client.out)
        if want != client.writing:
            client.writing = want
            if client.read_fd == client.write_fd:
                self.selector.modify(client.read_fd, selectors.EVENT_READ
                                     | (selectors.EVENT_WRITE if want else 0),
                                     client)
            elif want:
                self.selector.register(client.write_fd, selectors.EVENT_WRITE,
                                       client)
            else:
                self.selector.unregister(client.write_fd)
        if not want and client in self.retiring:
            self.finish_writing(client)

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

    def banding(self):
        """Return the view whose frame is in bands, or None."""
        return next((v for v in self.views.values() if v.bands), None)

    def drop_bands(self, view, why):
        """Drop the bands of VIEW's frame not sent; the others go on."""
        if view.bands:
            self.log({"type": "_bands_dropped", "view": view.id,
                      "bands": len(view.bands), "why": why})
            view.bands = []
            view.damage_all()
            for other in list(self.views.values()):
                self.pump(other)

    def send_band(self, view):
        """Send the next band of VIEW's frame once its last is acknowledged."""
        client = self.client
        if (not client or not client.ready or not view.bands
                or view.in_flight is not None or not view.visible
                or self.views.get(view.id) is not view):
            return
        x, y, w, h, flags = view.bands.pop(0)
        view.seq += 1
        if view.bands:
            flags |= lp.FLAG_MORE
        client.out += lp.encode_frame(view.seq, view.id, view.width, view.height,
                                      view.dpr, x, y, w, h, lp.ENCODING_RAW, flags,
                                      view.rect_bytes(x, y, w, h))
        view.in_flight = view.seq
        self.log({"type": "_frame_sent", "view": view.id, "seq": view.seq,
                  "frame_width": view.width, "frame_height": view.height,
                  "x": x, "y": y, "width": w, "height": h,
                  "full": bool(flags & lp.FLAG_FULL), "more": bool(view.bands),
                  "encoding": "raw", "seed": view.seed, "scroll": view.scroll})
        self.flush(client)
        if not view.bands:
            for other in list(self.views.values()):
                if other is not view:
                    self.pump(other)

    def pump(self, view):
        """Send VIEW's pending damage unless a frame is in flight.
        With --band-rows a frame taller than that goes in bands; while
        one view's frame is in bands the others wait."""
        client = self.client
        if (not client or not client.ready or view.in_flight is not None
                or view.damage is None or not view.visible or view.bands):
            return
        banding = self.banding()
        if banding is not None and banding is not view:
            return
        if view.dirty:
            view.render()
        x, y, w, h = view.damage
        rows = self.args.band_rows
        if rows and not client.shm and h > rows:
            view.damage = None
            full = (x, y, w, h) == (0, 0, view.width, view.height)
            view.bands = [(x, top, w, min(rows, y + h - top),
                           lp.FLAG_FULL if full and top == y else 0)
                          for top in range(y, y + h, rows)]
            self.send_band(view)
            return
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

    def title_for(self, url):
        """Return the title of the page at URL; mock://cookie shows the cookie."""
        if url.startswith("mock://cookie/set/"):
            self.cookie = url[len("mock://cookie/set/"):]
        if url == "mock://cookie":
            return "Mock: cookie=" + self.cookie
        return "Mock: " + url

    def max_views(self):
        return 1 if self.args.no_max_views else self.args.max_views

    def navigate(self, view, url):
        self.cancel_hints(view)
        view.url = url
        view.title = self.title_for(url)
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
            self.open_popup(view, "mock://popped")
        elif name == "popup-close":
            self.open_popup(view, "mock://close-later")
        elif name.startswith("popups-") and name[len("popups-"):].isdigit():
            for _ in range(int(name[len("popups-"):])):
                self.open_popup(view, "mock://popped")
        elif name == "close-later":
            def close_later():
                if self.views.get(v) is view:
                    self.close_by_page(view)
            self.after(0.5, close_later)
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
            self.close_by_page(view)

    def close_by_page(self, view):
        """Close VIEW as a page does with window.close()."""
        self.cancel_hints(view)
        del self.views[view.id]
        self.drop_bands(view, "closed")
        for segment in (view.shm, view.old_shm):
            self.release(segment)
        self.tell({"type": "view_closed", "view": view.id, "reason": "closed"})

    def open_popup(self, opener, url):
        """Open a view at URL as a page of OPENER opens a window."""
        area = (opener.width * opener.height
                + sum(v.width * v.height for v in self.views.values()))
        if (not (self.client and self.client.ready and self.client.popups)
                or len(self.views) >= self.max_views()
                or (self.args.max_area and area > self.args.max_area)):
            self.tell({"type": "popup_blocked", "view": opener.id, "url": url})
            return
        view = self.add_view("about:blank", opener.width, opener.height, opener.dpr)
        view.title = ""
        self.tell({"type": "view_created", "view": view.id, "opener": opener.id,
                   "url": view.url, "title": view.title, "width": view.width,
                   "height": view.height, "dpr": view.dpr})
        self.navigate(view, url)
        self.pump(view)

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
        if client.ready:
            self.send(client, {"type": "error", "message": "hello was already sent"})
            return
        viewport = m.get("viewport") or {}
        client.viewport = (viewport.get("width", 800), viewport.get("height", 600),
                           viewport.get("dpr", 1.0))
        if (self.args.zstd and "zstd" in (m.get("encodings") or [])
                and lp.zstd_available()):
            client.encoding = "zstd"
        client.shm = bool(self.args.shm and m.get("shm"))
        client.popups = m.get("popups") is True
        client.ready = True
        features = {} if self.args.no_hints else {"features": ["hints"]}
        if not self.args.no_max_views:
            features["max_views"] = self.args.max_views
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
        width, height, _ = client.viewport
        area = (int(m.get("width", width)) * int(m.get("height", height))
                + sum(v.width * v.height for v in self.views.values()))
        if self.args.max_area and area > self.args.max_area:
            self.tell({"type": "error", **request,
                       "message": f"the views would cover {area} pixels, "
                                  f"more than {self.args.max_area}"})
            return
        if len(self.views) >= self.max_views():
            one = self.max_views() == 1
            self.tell({"type": "error", **request,
                       "message": "only one view is supported" if one
                       else f"only {self.max_views()} views are supported"})
            return
        width, height, dpr = client.viewport
        url = m.get("url") or "about:blank"
        view = self.add_view(url, m.get("width", width), m.get("height", height),
                             m.get("dpr", dpr))
        view.title = self.title_for(url)
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
            if view.bands:
                self.log({"type": "_bands_dropped", "view": view.id,
                          "bands": len(view.bands), "why": "closed"})
                view.bands = []
                for other in list(self.views.values()):
                    self.pump(other)
            for segment in (view.shm, view.old_shm):
                self.release(segment)
            self.tell({"type": "view_closed", "view": view.id, "reason": "client"})

    def on_set_viewport(self, _client, m):
        view = self.view_of(m)
        if view and self.args.max_area:
            area = (int(m.get("width", view.width)) * int(m.get("height", view.height))
                    + sum(v.width * v.height for v in self.views.values() if v is not view))
            if area > self.args.max_area:
                self.tell({"type": "error", "view": view.id,
                           "message": f"the views would cover {area} pixels, "
                                      f"more than {self.args.max_area}"})
                return
        if view:
            view.resize(m.get("width", view.width), m.get("height", view.height),
                        m.get("dpr", view.dpr))
            self.pump(view)

    def on_set_visibility(self, _client, m):
        view = self.view_of(m)
        if view:
            shown = bool(m.get("visible")) and not view.visible
            view.visible = bool(m.get("visible"))
            if not view.visible:
                self.drop_bands(view, "hidden")
            # A view shown again starts with a full frame.
            if shown:
                view.dirty = True
                view.damage_all()
            self.pump(view)

    def on_frame_ack(self, _client, m):
        view = self.views.get(m.get("view"))
        if view and m.get("seq") == view.in_flight:
            view.in_flight = None
            self.release(view.old_shm)
            view.old_shm = None
            if view.bands:
                if self.args.band_pause:
                    self.after(self.args.band_pause, lambda: self.send_band(view))
                else:
                    self.send_band(view)
            else:
                self.pump(view)

    def on_shm_failed(self, client, m):
        # Every view of the connection goes over to stream frames, each
        # with a whole frame next.
        client.shm = False
        failed = self.views.get(m.get("view"))
        if failed:
            failed.in_flight = None
        for view in list(self.views.values()):
            view.dirty = True
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

    def eof(self, timeout=2):
        """Read until the end of the stream, which comes within TIMEOUT."""
        try:
            while True:
                self.receive(timeout)
        except EOFError:
            pass

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
        server.connect(Client(theirs.fileno(), theirs.fileno(), theirs))
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
    assert client.expect("reject")["reason"] == "rejected by --reject"
    client.eof()
    client.sock.close()
    thread.join(5)
    assert not thread.is_alive()

    # Without a listener the server ends once a client with a framing
    # error has read what was queued for it and the reject.
    client, thread = serve("--views", "1")
    client.send(hello)
    time.sleep(0.3)
    client.sock.sendall(BAD_HEADER)
    time.sleep(0.3)
    assert [client.receive()["type"] for _ in range(2)] == ["welcome", "state"]
    assert client.frame()[0].full
    assert client.expect("reject")["reason"] == "framing error"
    client.eof()
    client.sock.close()
    thread.join(5)
    assert not thread.is_alive()

    selftest_hints(serve, hello)
    selftest_views(serve, hello)
    selftest_popups(serve, hello)
    selftest_takeover(hello)
    print("ok" + "".join(f" ({note})" for note in notes))


class Listening:
    """A server on a Unix socket in a directory of its own, in a thread."""

    def __init__(self, *argv):
        self.directory = tempfile.mkdtemp()
        self.path = os.path.join(self.directory, "mock.sock")
        self.log = os.path.join(self.directory, "mock.log")
        self.server = Server(parse_arguments(["--fps", "0", "--log", self.log,
                                              *argv]))
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(self.path)
        listener.listen(16)
        self.server.listen(listener)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        self.clients = []

    def connect(self):
        sock = socket.socket(socket.AF_UNIX)
        sock.connect(self.path)
        client = SelftestClient(sock)
        self.clients.append(client)
        return client

    def logged(self, message_type):
        with open(self.log) as f:
            return [m for m in map(json.loads, f) if m["type"] == message_type]

    def stop(self):
        # The end of a stream wakes the server up to stop.
        self.server.running = False
        for client in self.clients:
            client.sock.close()
        try:
            self.connect().sock.close()
        except OSError:
            pass
        self.thread.join(5)
        assert not self.thread.is_alive()
        for file in (self.path, self.log):
            os.unlink(file)
        os.rmdir(self.directory)


BAD_HEADER = struct.pack("<IB", 0, 1)


def selftest_takeover(hello):
    """A connection takes over the client with its hello, and only then."""
    mock = Listening()
    first = mock.connect()
    first.send(hello)
    first.expect("welcome")
    # A probe, a first message that is no hello, one of another protocol
    # and a framing error, also behind a record, leave the client alone.
    mock.connect().sock.close()
    frame = lp.encode_record(lp.KIND_FRAME, b"xx")
    for data, reason in ((lp.encode_control({"type": "ping", "id": 1}),
                          "the first message must be hello"),
                         (lp.encode_control({**hello, "protocol": 2}),
                          "unsupported protocol version"),
                         (BAD_HEADER, "framing error"),
                         (frame + BAD_HEADER, "framing error")):
        other = mock.connect()
        other.sock.sendall(data)
        assert other.expect("reject")["reason"] == reason, data
        other.eof()
    # The ninth connection waiting for its hello closes the first.
    waiting = [mock.connect() for _ in range(MAX_PENDING + 1)]
    waiting[0].eof()
    waiting[1].send({"type": "ping", "id": 2})
    assert waiting[1].expect("reject")["reason"] == "the first message must be hello"
    # The client's second hello is refused.
    first.send(hello)
    assert first.expect("error")["message"] == "hello was already sent"
    first.send({"type": "ping", "id": 3})
    assert first.expect("pong")["id"] == 3
    assert len(mock.logged("_connected")) == 1 and not mock.logged("_disconnected")
    # A hello takes over.
    second = mock.connect()
    second.send(hello)
    second.expect("welcome")
    first.expect("replaced")
    # What the replaced client still sends is not read.
    first.sock.sendall(BAD_HEADER)
    first.eof()
    time.sleep(0.2)
    second.send({"type": "ping", "id": 4})
    assert second.expect("pong")["id"] == 4
    # The client's framing error ends it with a reject.
    second.sock.sendall(BAD_HEADER)
    assert second.expect("reject")["reason"] == "framing error"
    second.eof()
    assert len(mock.logged("_connected")) == 2
    assert len(mock.logged("_disconnected")) == 2
    mock.stop()

    # A client that does not read is replaced without the server waiting
    # for it: it reads the record that was being written to it, replaced
    # and the end of the stream, not the pong queued behind the record,
    # while what it writes is dropped.
    mock = Listening("--views", "1")
    first = mock.connect()
    first.send(hello)
    first.send({"type": "ping", "id": 5})
    time.sleep(0.3)
    second = mock.connect()
    started = time.monotonic()
    second.send(hello)
    second.expect("welcome")
    assert time.monotonic() - started < 1
    records = []
    try:
        while True:
            record = first.receive(2)
            if isinstance(record, tuple):
                first.ack(record[0])
            records.append(record if isinstance(record, tuple) else record["type"])
    except EOFError:
        pass
    assert records[:2] == ["welcome", "state"] and records[-1] == "replaced", records
    assert len(records) == 4 and records[2][0].full, records
    # Hello and a framing error in one write: welcome, then a reject.
    third = mock.connect()
    third.sock.sendall(lp.encode_control(hello) + BAD_HEADER)
    records = []
    try:
        while True:
            record = third.receive(2)
            records.append(record if isinstance(record, tuple) else record["type"])
    except EOFError:
        pass
    assert records[0] == "welcome" and records[-1] == "reject", records
    second.control("state")
    second.control("replaced")
    second.eof()
    mock.stop()


def selftest_views(serve, hello):
    client, thread = serve("--max-views", "2")
    client.send(hello)
    welcome = client.expect("welcome")
    assert welcome["max_views"] == 2 and welcome["views"] == []

    def create(request, url):
        client.send({"type": "create_view", "request": request, "url": url,
                     "width": 64, "height": 48, "dpr": 1.0})

    def frame_of(view):
        header, _ = client.frame()
        assert header.view == view, (header.view, view)
        client.ack(header)
        return header

    create(1, "mock://a")
    a = client.expect("view_created")["view"]
    client.expect("state")
    assert frame_of(a).full
    create(2, "mock://b")
    b = client.expect("view_created")["view"]
    assert a != b
    client.expect("state")
    assert frame_of(b).full
    # The limit is the welcome's max_views.
    create(3, "mock://c")
    assert client.expect("error") == {"type": "error", "request": 3,
                                      "message": "only 2 views are supported"}
    # A hidden view sends nothing; a shown one goes on.
    client.send({"type": "set_visibility", "view": b, "visible": False})
    for view in (b, a):
        client.send({"type": "mouse", "view": view, "kind": "down", "x": 5, "y": 5,
                     "button": "left", "buttons": ["left"], "modifiers": 0,
                     "clicks": 1})
    assert not frame_of(a).full
    client.quiet()
    # Shown again, it starts with a full frame.
    client.send({"type": "set_visibility", "view": b, "visible": True})
    assert frame_of(b).full
    # The views share the cookie.
    client.send({"type": "load", "view": a, "url": "mock://cookie/set/abc"})
    client.expect("state")
    client.send({"type": "load", "view": b, "url": "mock://cookie"})
    state = client.expect("state")
    assert state["view"] == b and state["title"] == "Mock: cookie=abc", state
    client.expect("state")
    client.expect("state")
    # The server keeps running with no view.
    for view in (a, b):
        client.send({"type": "close_view", "view": view})
        assert client.expect("view_closed")["view"] == view
    client.send({"type": "ping", "id": 9})
    assert client.expect("pong")["id"] == 9
    create(4, "mock://d")
    assert client.expect("view_created")["view"] > b, "view ids are not reused"
    client.sock.close()
    thread.join(5)

    # A banded frame interrupted by hiding or closing its view: the rest
    # is dropped, another view's frame may come next, and the view shown
    # again starts with a full frame.
    client, thread = serve("--band-rows", "16")
    client.send(hello)
    client.expect("welcome")
    create(1, "mock://a")
    a = client.expect("view_created")["view"]
    client.expect("state")
    first, _ = client.frame()
    assert first.view == a and first.full and first.more and first.damage_height == 16
    create(2, "mock://b")
    b = client.expect("view_created")["view"]
    client.expect("state")
    client.send({"type": "set_visibility", "view": a, "visible": False})
    client.ack(first)
    header, _ = client.frame()
    assert header.view == b and header.full and header.more, "b goes once a's bands end"
    client.ack(header)
    header, _ = client.frame()
    assert header.view == b and not header.full and header.more
    client.ack(header)
    header, _ = client.frame()
    assert header.view == b and not header.more
    client.ack(header)
    client.send({"type": "set_visibility", "view": a, "visible": True})
    header, _ = client.frame()
    assert header.view == a and header.full and header.more
    client.send({"type": "close_view", "view": a})
    client.ack(header)
    assert client.expect("view_closed")["view"] == a
    client.send({"type": "mouse", "view": b, "kind": "down", "x": 5, "y": 5,
                 "button": "left", "buttons": ["left"], "modifiers": 0, "clicks": 1})
    header, _ = client.frame()
    assert header.view == b, "b is not held up by the bands of the closed view"
    client.sock.close()
    thread.join(5)

    # One shm_failed turns every view to stream frames, each whole.
    client, thread = serve("--shm")
    client.send({**hello, "shm": True})
    client.expect("welcome")
    create(1, "mock://a")
    a = client.expect("view_created")["view"]
    client.expect("state")
    client.expect("shm")
    first, _ = client.frame()
    create(2, "mock://b")
    b = client.expect("view_created")["view"]
    client.expect("state")
    client.expect("shm")
    second, _ = client.frame()
    assert first.encoding == second.encoding == lp.ENCODING_SHM
    client.send({"type": "shm_failed", "view": a})
    client.ack(second)
    seen = {}
    while len(seen) < 2:
        header, _ = client.frame()
        client.ack(header)
        seen.setdefault(header.view, header)
    for header in seen.values():
        assert header.encoding == lp.ENCODING_RAW and header.full, header
    client.sock.close()
    thread.join(5)

    # The area of all views is capped.
    client, thread = serve("--max-area", "5000")
    client.send(hello)
    client.expect("welcome")
    create(1, "mock://a")
    a = client.expect("view_created")["view"]
    client.expect("state")
    client.frame()
    create(2, "mock://b")
    assert "more than 5000" in client.expect("error")["message"]
    client.send({"type": "set_viewport", "view": a, "width": 100, "height": 100,
                 "dpr": 1.0})
    error = client.expect("error")
    assert error["view"] == a and "more than 5000" in error["message"]
    client.sock.close()
    thread.join(5)

    client, thread = serve("--no-max-views")
    client.send(hello)
    assert "max_views" not in client.expect("welcome")
    create(1, "mock://a")
    client.expect("view_created")
    client.expect("state")
    client.frame()
    create(2, "mock://b")
    assert client.expect("error")["message"] == "only one view is supported"
    client.sock.close()
    thread.join(5)


def selftest_popups(serve, hello):
    def collect(client, done):
        """Read records, acknowledging frames, until DONE(records) holds."""
        records = []
        while not done(records):
            record = client.receive()
            if isinstance(record, tuple):
                client.ack(record[0])
            records.append(record)
        return records

    def messages(records, message_type, **fields):
        return [r for r in records if isinstance(r, dict) and r["type"] == message_type
                and all(r.get(k) == v for k, v in fields.items())]

    def opened(client, opener, url):
        client.send({"type": "load", "view": opener, "url": url})
        records = collect(client, lambda rs: messages(rs, "view_created")
                          and any(isinstance(r, tuple)
                                  and r[0].view == messages(rs, "view_created")[0]["view"]
                                  for r in rs))
        return records, messages(records, "view_created")[0]

    # A client that did not say "popups" gets popup_blocked.
    client, thread = serve()
    client.send(hello)
    client.expect("welcome")
    client.send({"type": "create_view", "url": "mock://a", "width": 40,
                 "height": 30, "dpr": 2.0})
    a = client.expect("view_created")["view"]
    client.send({"type": "load", "view": a, "url": "mock://popup"})
    records = collect(client, lambda rs: messages(rs, "popup_blocked"))
    assert messages(records, "popup_blocked") == [
        {"type": "popup_blocked", "view": a, "url": "mock://popped"}]
    assert not messages(records, "view_created")
    client.sock.close()
    thread.join(5)

    # One that did gets a view with the opener's size, state and frame,
    # until the limit.
    client, thread = serve("--max-views", "3")
    client.send({**hello, "popups": True})
    client.expect("welcome")
    client.send({"type": "create_view", "url": "mock://a", "width": 40,
                 "height": 30, "dpr": 2.0})
    a = client.expect("view_created")["view"]
    records, created = opened(client, a, "mock://popup")
    popped = created["view"]
    assert created["opener"] == a and "request" not in created, created
    assert (created["width"], created["height"], created["dpr"]) == (40, 30, 2.0)
    assert messages(records, "state", view=popped)[0]["url"] == "mock://popped"
    frame = next(r for r in records if isinstance(r, tuple) and r[0].view == popped)
    assert frame[0].full and (frame[0].frame_width, frame[0].frame_height) == (40, 30)
    # A burst opens what fits; the rest is blocked.
    client.send({"type": "load", "view": a, "url": "mock://popups-3"})
    records = collect(client, lambda rs: len(messages(rs, "popup_blocked")) == 2)
    assert len(messages(records, "view_created", opener=a)) == 1
    # A page that closes its window.
    for view in (popped, messages(records, "view_created")[0]["view"]):
        client.send({"type": "close_view", "view": view})
        collect(client, lambda rs, view=view: messages(rs, "view_closed", view=view))
    records, created = opened(client, a, "mock://popup-close")
    records = collect(client, lambda rs: messages(rs, "view_closed"))
    assert messages(records, "view_closed") == [
        {"type": "view_closed", "view": created["view"], "reason": "closed"}]
    client.sock.close()
    thread.join(5)


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
    parser.add_argument("--max-views", type=int, default=16, metavar="N")
    parser.add_argument("--no-max-views", action="store_true")
    parser.add_argument("--band-rows", type=int, metavar="N")
    parser.add_argument("--band-pause", type=float, default=0, metavar="S")
    parser.add_argument("--max-area", type=int, metavar="PIXELS")
    parser.add_argument("--hostname", metavar="NAME")
    parser.add_argument("--no-hints", action="store_true")
    parser.add_argument("--platform", default=(
        "macos" if sys.platform == "darwin" else
        "linux" if sys.platform.startswith("linux") else "unknown"))
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--emacs-default-socket", action="store_true")
    parser.add_argument("--emacs-background", action="store_true")
    parser.add_argument("--headless", metavar="MODE")
    return parser.parse_args(argv)


STARTER_FD = "LADYBIRD_MOCK_STARTER_FD"


def default_socket():
    """Return the default socket, making its directory outside XDG_RUNTIME_DIR."""
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime.startswith("/"):
        return runtime.rstrip("/") + "/ladybird-emacs.sock"
    temporary = os.environ.get("TMPDIR", "")
    temporary = temporary.rstrip("/") if temporary.startswith("/") else "/tmp"
    directory = f"{temporary}/ladybird-emacs-{os.getuid()}"
    os.makedirs(directory, mode=0o700, exist_ok=True)
    return directory + "/ladybird-emacs.sock"


def accepts(path):
    """Return whether something accepts connections on the Unix socket PATH."""
    probe = socket.socket(socket.AF_UNIX)
    try:
        probe.connect(path)
        return True
    except OSError:
        return False
    finally:
        probe.close()


def start_background(args):
    """Start the server in a session of its own and return the exit status."""
    if not args.socket:
        print("--emacs-background needs a socket", file=sys.stderr)
        return 1
    if accepts(args.socket):
        print("Unable to start the Emacs server: Another server already "
              f"listens on {args.socket}", file=sys.stderr)
        return 1
    read_end, write_end = os.pipe()
    subprocess.Popen(
        [sys.executable, "-I", os.path.abspath(__file__), *sys.argv[1:]],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(write_end,),
        env={**os.environ, STARTER_FD: str(write_end)})
    os.close(write_end)
    said = b""
    while chunk := os.read(read_end, 4096):
        said += chunk
    os.close(read_end)
    if said == b"ready":
        if args.log:
            print(f"Ladybird logs to {args.log}", file=sys.stderr)
        return 0
    print(said.decode(errors="replace")
          or "The Emacs server ended before it accepted connections",
          file=sys.stderr)
    return 1


def tell_starter(starter, text):
    """Write TEXT to the starter's pipe STARTER and close it.

    A starter that is gone already is no reason to stop."""
    try:
        os.write(int(starter), text.encode())
    except BrokenPipeError:
        pass
    os.close(int(starter))


def main():
    args = parse_arguments(sys.argv[1:])
    if args.selftest:
        selftest()
        return 0
    if args.emacs_default_socket:
        args.socket = default_socket()
    starter = os.environ.pop(STARTER_FD, None)
    if args.emacs_background and starter is None:
        return start_background(args)
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
        except OSError as error:
            if starter is not None:
                tell_starter(starter, f"Unable to start the Emacs server: {error}")
            raise
        finally:
            os.umask(old)
        listener.listen(4)
        server.listen(listener)
        if starter is not None:
            tell_starter(starter, "ready")
    elif args.tcp:
        host, _, port = args.tcp.rpartition(":")
        host = host.strip("[]")
        listener = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, int(port)))
        listener.listen(4)
        server.listen(listener)
    else:
        server.connect(Client(0, 1))
    try:
        return server.run()
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
