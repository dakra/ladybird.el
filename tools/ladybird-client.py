#!/usr/bin/env python3
"""Test client for the Ladybird Emacs server (plans/01-protocol.md).

Speaks the handshake, keeps a BGRA frame store per view, acknowledges frames,
and runs check scripts.  Standard library only.

Without --script the client says hello, creates a view (or loads --url into
the one the server already has), waits for the page to finish loading, sends
every --send message, applies --resize, waits for the frames to settle and
writes --png.

Script lines (--script FILE, one command per line, `#` starts a comment):

  {"type": ...}             send a control message, after forgetting the control
                            messages received so far; "view" is filled in when
                            missing; "$view", "$id" and "$last.KEY" stand for
                            the view id and (dotted) fields of the last matched
                            message,
                            $pages for the URL of the script's pages directory
                            $dir for the path of the script's directory and
                            $tmp for a directory that is removed at exit
  sleep N                   keep reading for N seconds
  settle [N]                wait until no frame arrived for N seconds (1.0)
  expect TYPE [K=V ...]     wait for a control message of TYPE whose fields
                            equal the JSON values V (K may be dotted;
                            K~=TEXT matches a substring, K#=N a string or
                            list of length N); timeout=N overrides the default
  expect-frame [K=V ...]    wait for a frame; K is one of view, full, more,
                            width, height, dpr, encoding (raw, zstd, shm)
  expect-no-frame N [view=V]
                            fail when a frame (of view V) arrives within N
                            seconds
  welcome [K=V ...]         fail unless the welcome message has those fields
  use VIEW                  make VIEW the view that messages without a "view"
                            and the pixel, png and frame commands are about
  expect-eof [N]            wait for the server to close the stream
  expect-no TYPE N [K=V ...]
                            fail when a control message of TYPE (with those
                            fields) arrives within N seconds
  expect-order TYPE...      wait for control messages of these types and
                            fail unless they arrived in this order
  ack on|off [view=V] [bands]
                            start or stop acknowledging frames (of view V;
                            with bands, only those with more bands to follow);
                            `on` also acknowledges what is outstanding
  frames MIN [MAX] [view=V] fail unless MIN..MAX frames (of view V) arrived
                            since the last `frames` (of that view) or `ack`
                            command
  pixel X Y RRGGBB [TOL]    fail unless the store's pixel has that colour
  png PATH                  write the frame store as a PNG
  png-size PATH W H         fail unless the PNG file has that size
  file-mode PATH MODE       fail unless the file has that octal mode
  remove PATH               delete a file
  stall N                   neither read nor write for N seconds
  echo TEXT                 print TEXT to stderr
  keep NAME                 remember the last matched message as NAME;
                            "$kept.NAME.KEY" then stands for its fields
  distinct WORD...          fail unless the words differ from each other
  frame-save NAME           remember the frame store as NAME
  frame-same NAME           fail unless the frame store equals NAME
  frame-differs NAME        fail if the frame store equals NAME
  color-in X Y W H RRGGBB [TOL]
                            fail unless some pixel of the rectangle has that
                            colour; no-color-in fails if one does
  hints-valid ALPHABET      check the last hints_list: indices in order,
                            distinct labels over ALPHABET of the shortest
                            common length, kinds, text length, urls only on
                            links, rectangles that intersect the viewport
  hint TEXT [K=V ...]       pick the first item of the last hints_list with
                            that text whose fields match; "$hint.KEY" then
                            stands for its fields
  no-hint TEXT              fail if the last hints_list has an item with
                            that text
  hint-label-shown TEXT     fail unless the frame store shows a hint label
                            at the item with that text; hint-label-hidden
                            fails if it does

The "$..." and $... placeholders of control messages work in every line.
"""

import argparse
import json
import math
import mmap
import os
import select
import shlex
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ladybird_protocol as proto  # noqa: E402

DEFAULT_SERVER = ("/Users/daniel/src/ladybird/Build/release/bin/"
                  "Ladybird.app/Contents/MacOS/Ladybird --headless=emacs")
ENCODING_NAMES = {proto.ENCODING_RAW: "raw", proto.ENCODING_ZSTD: "zstd",
                  proto.ENCODING_SHM: "shm"}
GLOBAL_TYPES = {"hello", "ping", "pong", "create_view"}
# The background of the server's hint labels.
HINT_LABEL_COLOR = "fff3a3"
HINT_KINDS = {"link", "button", "input", "other"}


class CheckFailed(Exception):
    pass


def parse_viewport(text):
    size, _, dpr = text.partition("@")
    width, _, height = size.partition("x")
    return int(width), int(height), float(dpr or 1)


class Segment:
    """A POSIX shared memory object of the server, mapped read-only."""

    def __init__(self, name, size):
        import _posixshmem
        fd = _posixshmem.shm_open(name, os.O_RDONLY, mode=0)
        try:
            actual = os.fstat(fd).st_size
            if actual < size:
                raise OSError(f"segment {name} holds {actual} bytes, not {size}")
            self.map = mmap.mmap(fd, size, prot=mmap.PROT_READ)
        finally:
            os.close(fd)
        self.name = name
        self.size = size

    def close(self):
        self.map.close()


class View:
    def __init__(self, view_id):
        self.id = view_id
        self.width = 0
        self.height = 0
        self.dpr = 1.0
        self.store = bytearray()
        self.segment = None
        self.next_seq = None
        self.state = {}
        # Whether this client last asked for the view to be hidden.
        self.hidden = False
        # Whether the next frame must be a whole one, as the view's page crashed.
        self.needs_full = False


class Client:
    def __init__(self, args):
        self.args = args
        self.process = None
        self.sock = None
        self.reader = proto.RecordReader()
        self.eof = False
        self.inbox = []
        self.frames = []
        self.frame_cursor = 0
        self.views = {}
        self.view_id = None
        self.welcome = None
        self.acking = not args.no_ack
        self.views_not_acked = set()
        self.views_bands_not_acked = set()
        self.unacked = []
        self.kept = {}
        self.last = {}
        self.last_frame_time = time.monotonic()
        self.frame_count = 0
        self.frame_mark = 0
        self.frame_counts = {}
        self.frame_marks = {}
        # The view whose frame is under way in bands, which no other view's frame may come between.
        self.banding_view = None
        self.wire_bytes = 0
        self.decoded_bytes = 0
        self.encoding_counts = {}
        self.errors = []
        self.rejected = None
        self.shm_failures = 0
        self.stderr_data = b""
        self.scratch = None
        self.hints = None
        self.hint = {}
        self.saved_frames = {}

    # -- transport ---------------------------------------------------------

    def connect(self):
        if self.args.socket:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(self.args.socket)
            self.read_fd = self.write_fd = self.sock.fileno()
        else:
            command = shlex.split(self.args.server or DEFAULT_SERVER)
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE)
            self.read_fd = self.process.stdout.fileno()
            self.write_fd = self.process.stdin.fileno()
            os.set_blocking(self.process.stderr.fileno(), False)
        os.set_blocking(self.read_fd, False)

    def close(self):
        if self.sock:
            self.sock.close()
        if self.process:
            for stream in (self.process.stdin, self.process.stdout):
                try:
                    stream.close()
                except OSError:
                    pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.drain_stderr()
            self.process.stderr.close()
        for view in self.views.values():
            if view.segment:
                view.segment.close()
        if self.scratch:
            shutil.rmtree(self.scratch, ignore_errors=True)

    def drain_stderr(self):
        if not self.process:
            return
        try:
            while True:
                data = os.read(self.process.stderr.fileno(), 65536)
                if not data:
                    break
                self.stderr_data += data
        except (BlockingIOError, OSError):
            pass

    def write(self, data):
        view = memoryview(data)
        while view:
            try:
                written = os.write(self.write_fd, view)
                view = view[written:]
            except BlockingIOError:
                select.select([], [self.write_fd], [], 1.0)

    def send(self, message):
        if self.args.dump:
            print("> " + json.dumps(message, ensure_ascii=False), file=sys.stderr)
        self.write(proto.encode_control(message))
        if message.get("type") == "set_visibility" and isinstance(message.get("view"), int):
            # Hiding a view ends a frame it was sending in bands; bands of it already on their way may still come.
            view = self.view(message["view"])
            view.hidden = message.get("visible") is False
            if view.hidden and self.banding_view == view.id:
                self.banding_view = None

    def pump(self, timeout):
        """Read what arrives within TIMEOUT seconds; return whether anything did."""
        if self.eof:
            time.sleep(min(timeout, 0.05))
            return False
        readable, _, _ = select.select([self.read_fd], [], [], max(timeout, 0))
        self.drain_stderr()
        if not readable:
            return False
        try:
            data = os.read(self.read_fd, 1 << 20)
        except BlockingIOError:
            return False
        except ConnectionResetError:
            data = b""
        if not data:
            self.eof = True
            return True
        for kind, payload in self.reader.feed(data):
            if kind == proto.KIND_CONTROL:
                try:
                    message = json.loads(payload.decode("utf-8"))
                except ValueError as error:
                    raise CheckFailed(f"control record is not UTF-8 JSON: {error}: {payload[:60]!r}") from None
                self.handle_control(message)
            else:
                self.handle_frame(payload)
        return True

    def pump_for(self, seconds):
        deadline = time.monotonic() + seconds
        while (remaining := deadline - time.monotonic()) > 0:
            self.pump(remaining)

    # -- incoming ----------------------------------------------------------

    def view(self, view_id):
        if view_id not in self.views:
            self.views[view_id] = View(view_id)
        return self.views[view_id]

    def handle_control(self, message):
        if self.args.dump:
            shown = message
            if message.get("type") == "favicon" and message.get("png"):
                shown = dict(message, png=f"<{len(message['png'])} base64 chars>")
            print("< " + json.dumps(shown, ensure_ascii=False), file=sys.stderr)
        kind = message.get("type")
        if kind == "welcome":
            self.welcome = message
            for description in message.get("views", []):
                self.view(description["view"]).state = description
        elif kind == "view_created":
            self.view_id = message["view"]
            self.view(message["view"]).state = dict(message)
        elif kind == "state":
            self.view(message["view"]).state = message
        elif kind == "shm":
            view = self.view(message["view"])
            if view.segment:
                view.segment.close()
                view.segment = None
            try:
                if self.args.fail_shm:
                    raise OSError("--fail-shm")
                view.segment = Segment(message["name"], message["size"])
            except (OSError, ImportError, ValueError) as error:
                print(f"cannot map {message['name']}: {error}", file=sys.stderr)
                self.shm_failures += 1
                self.send({"type": "shm_failed", "view": view.id})
        elif kind in ("view_closed", "crashed"):
            # Either ends a frame the view was sending in bands.
            if self.banding_view == message.get("view"):
                self.banding_view = None
            if kind == "crashed":
                self.view(message["view"]).needs_full = True
        elif kind == "error":
            self.errors.append(message)
        elif kind == "reject":
            self.rejected = message
        elif kind == "ping":
            self.send({"type": "pong", "id": message.get("id")})
        elif kind == "hints_list":
            self.hints = message
        self.inbox.append(message)

    def handle_frame(self, payload):
        header, body = proto.FrameHeader.parse(payload)
        header.validate(len(body))
        if header.reserved != 0:
            raise CheckFailed("frame header has a non-zero reserved field")
        view = self.view(header.view)
        if self.banding_view is not None and header.view != self.banding_view:
            raise CheckFailed(f"a frame of view {header.view} came between the bands of a frame of view {self.banding_view}")
        if not view.hidden:
            self.banding_view = header.view if header.more else None
        if view.needs_full and not header.full:
            raise CheckFailed(f"the first frame of view {header.view} after its page crashed is not whole")
        view.needs_full = False
        if view.next_seq is not None and header.seq != view.next_seq:
            raise CheckFailed(f"frame seq {header.seq}, expected {view.next_seq}")
        welcomed = {description.get("view") for description in self.welcome.get("views", [])}
        if view.next_seq is None and header.seq != 1 and header.view not in welcomed:
            raise CheckFailed(f"first frame of view {header.view} has seq {header.seq}")
        view.next_seq = header.seq + 1

        fw, fh = header.frame_width, header.frame_height
        resized = (fw, fh) != (view.width, view.height)
        if resized and not header.full:
            raise CheckFailed("frame size changed without the full flag")
        if header.full and not header.more and (
                header.damage_x, header.damage_y) != (0, 0):
            raise CheckFailed("full frame whose damage does not start at 0,0")
        if resized:
            view.width, view.height = fw, fh
            view.store = bytearray(fw * fh * 4)
        view.dpr = header.dpr

        applied = True
        if header.encoding == proto.ENCODING_RAW:
            pixels = body
        elif header.encoding == proto.ENCODING_ZSTD:
            pixels = proto.zstd_decompress(body, header.raw_size)
        else:
            (offset,) = proto.struct.unpack("<Q", body)
            pixels = None
            if view.segment is None:
                applied = False
            elif offset + fw * fh * 4 > view.segment.size:
                raise CheckFailed("shm frame does not fit its segment")
            else:
                stride = fw * 4
                dx, dw = header.damage_x * 4, header.damage_width * 4
                for row in range(header.damage_y, header.damage_y + header.damage_height):
                    start = row * stride + dx
                    view.store[start:start + dw] = view.segment.map[offset + start:offset + start + dw]
        if pixels is not None:
            proto.compose(view.store, fw, fh, header, pixels)

        self.frame_count += 1
        self.frame_counts[header.view] = self.frame_counts.get(header.view, 0) + 1
        self.wire_bytes += len(payload) + proto.RECORD_HEADER.size
        self.decoded_bytes += header.raw_size
        name = ENCODING_NAMES[header.encoding]
        self.encoding_counts[name] = self.encoding_counts.get(name, 0) + 1
        self.last_frame_time = time.monotonic()
        self.frames.append(header)
        if self.args.dump:
            flags = "".join(text for bit, text in ((proto.FLAG_FULL, " full"), (proto.FLAG_MORE, " more"))
                            if header.flags & bit)
            print(f"< frame seq={header.seq} view={header.view} {fw}x{fh}@{header.dpr:g} "
                  f"damage={header.damage_x},{header.damage_y} {header.damage_width}x{header.damage_height} "
                  f"{name}{flags} bytes={len(body)}{'' if applied else ' (not applied)'}", file=sys.stderr)
        withheld = header.view in self.views_not_acked or (header.more and header.view in self.views_bands_not_acked)
        if self.acking and not withheld:
            self.send_ack(header.view, header.seq)
        else:
            self.unacked.append((header.view, header.seq))

    def send_ack(self, view_id, seq):
        self.write(proto.encode_control({"type": "frame_ack", "view": view_id, "seq": seq}))

    # -- waiting -----------------------------------------------------------

    def wait_until(self, predicate, timeout, what):
        deadline = time.monotonic() + timeout
        while True:
            result = predicate()
            if result:
                return result
            if self.rejected and what != "reject":
                raise CheckFailed(f"server rejected the client: {self.rejected.get('reason')}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CheckFailed(f"timed out after {timeout:g}s waiting for {what}")
            if self.eof:
                raise CheckFailed(f"server closed the stream while waiting for {what}")
            self.pump(min(remaining, 0.25))

    def expect(self, kind, conditions, timeout):
        def find():
            for index, message in enumerate(self.inbox):
                if message.get("type") == kind and all(match(message) for match in conditions):
                    del self.inbox[index]
                    return message
            return None

        what = kind
        self.last = self.wait_until(find, timeout, what)
        return self.last

    def expect_frame(self, conditions, timeout):
        def find():
            while self.frame_cursor < len(self.frames):
                header = self.frames[self.frame_cursor]
                self.frame_cursor += 1
                if all(match(header) for match in conditions):
                    return header
            return None

        return self.wait_until(find, timeout, "a frame")

    def settle(self, seconds):
        deadline = time.monotonic() + self.args.timeout
        self.last_frame_time = max(self.last_frame_time, time.monotonic() - seconds / 2)
        while time.monotonic() - self.last_frame_time < seconds:
            if time.monotonic() > deadline:
                raise CheckFailed("frames never settled")
            if self.eof:
                raise CheckFailed("server closed the stream while frames settled")
            self.pump(max(0.01, seconds - (time.monotonic() - self.last_frame_time)))

    def current_view(self):
        if self.view_id is None or self.view_id not in self.views:
            raise CheckFailed("there is no view")
        return self.views[self.view_id]

    def write_png(self, path):
        view = self.current_view()
        if not view.width:
            raise CheckFailed("no frame arrived, nothing to write")
        proto.write_png(path, view.width, view.height, bytes(view.store))
        print(f"wrote {path} ({view.width}x{view.height}@{view.dpr:g})", file=sys.stderr)

    # -- session -----------------------------------------------------------

    def handshake(self):
        width, height, dpr = self.args.viewport
        self.send({"type": "hello", "protocol": self.args.protocol, "client": "ladybird-client 0.1",
                   "viewport": {"width": width, "height": height, "dpr": dpr},
                   "encodings": self.args.encodings, "shm": self.args.shm, "token": None})
        self.wait_until(lambda: self.welcome, self.args.timeout, "welcome")
        if self.welcome.get("protocol") != proto.PROTOCOL_VERSION:
            raise CheckFailed(f"welcome has protocol {self.welcome.get('protocol')}")
        if self.welcome.get("encoding") not in self.args.encodings:
            raise CheckFailed(f"server chose encoding {self.welcome.get('encoding')}")
        views = self.welcome.get("views", [])
        if views:
            self.view_id = views[0]["view"]

    def open_view(self):
        width, height, dpr = self.args.viewport
        url = self.args.url
        if self.view_id is None:
            message = {"type": "create_view", "width": width, "height": height, "dpr": dpr}
            if url:
                message["url"] = url
            self.send(message)
            self.expect("view_created", [], self.args.timeout)
        else:
            self.send({"type": "set_viewport", "view": self.view_id,
                       "width": width, "height": height, "dpr": dpr})
            if url:
                self.send({"type": "load", "view": self.view_id, "url": url})
        if url:
            self.wait_loaded()

    def wait_loaded(self):
        started = [False]

        def loaded():
            state = self.current_view().state
            if state.get("loading"):
                started[0] = True
            return (not state.get("loading", True)
                    and (started[0] or state.get("url") not in (None, "", "about:blank")))

        self.wait_until(loaded, self.args.timeout, "state with loading false")

    def fill_in(self, message):
        if "view" not in message and message.get("type") not in GLOBAL_TYPES and self.view_id is not None:
            message["view"] = self.view_id
        return message

    def substitute(self, text, base=None):
        if base is not None:
            text = text.replace("$pages", "file://" + os.path.join(base, "pages"))
            text = text.replace("$dir", base)
        if "$tmp" in text:
            if self.scratch is None:
                self.scratch = tempfile.mkdtemp(prefix="ladybird-client.")
            text = text.replace("$tmp", self.scratch)
        if self.view_id is not None:
            text = text.replace('"$view"', str(self.view_id))
        text = text.replace('"$id"', json.dumps(self.last.get("id")))
        for prefix, source in (('"$last.', self.last), ('"$hint.', self.hint), ('"$kept.', self.kept)):
            while prefix in text:
                start = text.index(prefix)
                end = text.index('"', start + 1)
                text = text[:start] + json.dumps(lookup(source, text[start + len(prefix):end])) + text[end + 1:]
        return text

    def run_script(self, path):
        base = os.path.dirname(os.path.abspath(path))
        with open(path, encoding="utf-8") as script:
            for number, line in enumerate(script, 1):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    self.run_line(line, base)
                except CheckFailed as error:
                    raise CheckFailed(f"{os.path.basename(path)}:{number}: {line}\n  {error}") from None

    def run_line(self, line, base):
        if line.startswith("{"):
            # What arrived before a message was sent is not an answer to it.
            self.inbox.clear()
            self.send(self.fill_in(json.loads(self.substitute(line, base))))
            return
        command, _, rest = self.substitute(line, base).partition(" ")
        words = shlex.split(rest)
        timeout = self.args.timeout
        for word in list(words):
            if word.startswith("timeout="):
                timeout = float(word[8:])
                words.remove(word)
        if command == "sleep":
            self.pump_for(float(words[0]))
        elif command == "settle":
            self.settle(float(words[0]) if words else 1.0)
        elif command == "expect":
            self.expect(words[0], [control_condition(word) for word in words[1:]], timeout)
        elif command == "expect-frame":
            self.expect_frame([frame_condition(word) for word in words], timeout)
        elif command == "expect-no-frame":
            only = next((int(word[5:]) for word in words[1:] if word.startswith("view=")), None)
            count = lambda: self.frame_count if only is None else self.frame_counts.get(only, 0)
            before = count()
            self.pump_for(float(words[0]))
            if count() != before:
                raise CheckFailed(f"{count() - before} frame(s) arrived")
        elif command == "welcome":
            for condition, word in ((control_condition(word), word) for word in words):
                if not condition(self.welcome):
                    raise CheckFailed(f"welcome does not have {word}: {json.dumps(self.welcome)[:300]}")
        elif command == "use":
            self.view_id = int(words[0])
        elif command == "expect-no":
            conditions = [control_condition(word) for word in words[2:]]
            def matching():
                return next((message for message in self.inbox if message.get("type") == words[0]
                             and all(match(message) for match in conditions)), None)
            deadline = time.monotonic() + float(words[1])
            while not matching() and time.monotonic() < deadline:
                self.pump(min(0.1, max(0, deadline - time.monotonic())))
            if matching():
                raise CheckFailed(f"unexpected {json.dumps(matching())[:300]}")
        elif command == "expect-order":
            def positions():
                types = [message.get("type") for message in self.inbox]
                return [types.index(kind) for kind in words] if all(kind in types for kind in words) else None
            found = self.wait_until(positions, timeout, " and ".join(words))
            if found != sorted(found):
                raise CheckFailed(f"arrived in the order {[words[i] for i in sorted(range(len(words)), key=found.__getitem__)]}")
        elif command == "expect-eof":
            deadline = time.monotonic() + (float(words[0]) if words else timeout)
            while not self.eof:
                if time.monotonic() > deadline:
                    raise CheckFailed("the server kept the stream open")
                self.pump(0.1)
        elif command == "ack":
            only = next((int(word[5:]) for word in words[1:] if word.startswith("view=")), None)
            if only is None:
                self.acking = words[0] == "on"
                self.frame_mark = self.frame_count
                self.views_not_acked.clear()
                self.views_bands_not_acked.clear()
            elif words[0] == "on":
                self.views_not_acked.discard(only)
                self.views_bands_not_acked.discard(only)
            elif "bands" in words:
                self.views_bands_not_acked.add(only)
            else:
                self.views_not_acked.add(only)
            outstanding = [(view_id, seq) for view_id, seq in self.unacked
                           if self.acking and view_id not in self.views_not_acked]
            for view_id, seq in outstanding:
                self.send_ack(view_id, seq)
            self.unacked = [entry for entry in self.unacked if entry not in outstanding]
        elif command == "keep":
            self.kept[words[0]] = self.last
        elif command == "distinct":
            if len(set(words)) != len(words):
                raise CheckFailed(f"the same value more than once in {words}")
        elif command == "frames":
            only = next((int(word[5:]) for word in words if word.startswith("view=")), None)
            words = [word for word in words if not word.startswith("view=")]
            low = int(words[0])
            high = int(words[1]) if len(words) > 1 else low
            if only is None:
                count = self.frame_count - self.frame_mark
                self.frame_mark = self.frame_count
            else:
                count = self.frame_counts.get(only, 0) - self.frame_marks.get(only, 0)
                self.frame_marks[only] = self.frame_counts.get(only, 0)
            if not low <= count <= high:
                raise CheckFailed(f"{count} frame(s) arrived, expected {low}..{high}")
        elif command == "pixel":
            view = self.current_view()
            x, y = int(words[0]), int(words[1])
            tolerance = int(words[3]) if len(words) > 3 else 0
            if not (0 <= x < view.width and 0 <= y < view.height):
                raise CheckFailed(f"pixel {x},{y} is outside the {view.width}x{view.height} frame")
            b, g, r, _ = view.store[(y * view.width + x) * 4:(y * view.width + x) * 4 + 4]
            want = bytes.fromhex(words[2].lstrip("#"))
            if any(abs(have - wanted) > tolerance for have, wanted in zip((r, g, b), want)):
                raise CheckFailed(f"pixel {x},{y} is #{r:02x}{g:02x}{b:02x}")
        elif command == "frame-save":
            self.saved_frames[words[0]] = bytes(self.current_view().store)
        elif command in ("frame-same", "frame-differs"):
            saved = self.saved_frames[words[0]]
            store = bytes(self.current_view().store)
            if command == "frame-same" and store != saved:
                differing = sum(1 for offset in range(0, min(len(store), len(saved)), 4)
                                if store[offset:offset + 4] != saved[offset:offset + 4])
                raise CheckFailed(f"{differing} pixel(s) differ from {words[0]}")
            if command == "frame-differs" and store == saved:
                raise CheckFailed(f"the frame store still equals {words[0]}")
        elif command in ("color-in", "no-color-in"):
            x, y, width, height = (int(float(word)) for word in words[:4])
            tolerance = int(words[5]) if len(words) > 5 else 0
            found = self.color_in(x, y, width, height, words[4], tolerance)
            if command == "color-in" and not found:
                raise CheckFailed(f"no pixel of #{words[4]} in {width}x{height} at {x},{y}")
            if command == "no-color-in" and found:
                raise CheckFailed(f"a pixel of #{words[4]} in {width}x{height} at {x},{y}")
        elif command == "hints-valid":
            self.check_hints(words[0])
        elif command == "hint":
            conditions = [control_condition(word) for word in words[1:]]
            items = self.hint_items()
            self.hint = next((item for item in items if item.get("text") == words[0]
                              and all(match(item) for match in conditions)), None)
            if self.hint is None:
                raise CheckFailed(f"no matching item with text {words[0]!r} in "
                                  + json.dumps([item.get("text") for item in items]))
        elif command == "no-hint":
            if any(item.get("text") == words[0] for item in self.hint_items()):
                raise CheckFailed(f"an item has text {words[0]!r}")
        elif command in ("hint-label-shown", "hint-label-hidden"):
            item = next((item for item in self.hint_items() if item.get("text") == words[0]), None)
            if item is None:
                raise CheckFailed(f"no item with text {words[0]!r}")
            view = self.current_view()
            scale = view.dpr * view.state.get("zoom", 1)
            # A label sits at the top-left corner of its element, moved into the viewport.
            x = max(0, math.floor(item["x"] * scale) - 2)
            y = max(0, math.floor(item["y"] * scale) - 2)
            found = self.color_in(x, y, round(16 * scale), round(12 * scale), HINT_LABEL_COLOR, 6)
            if command == "hint-label-shown" and not found:
                raise CheckFailed(f"no label at {words[0]!r}")
            if command == "hint-label-hidden" and found:
                raise CheckFailed(f"a label at {words[0]!r}")
        elif command == "png":
            self.write_png(os.path.join(base, words[0]) if not os.path.isabs(words[0]) else words[0])
        elif command == "png-size":
            with open(words[0], "rb") as image:
                header = image.read(24)
            size = struct.unpack(">II", header[16:24]) if header[:8] == b"\x89PNG\r\n\x1a\n" else None
            if size != (int(words[1]), int(words[2])):
                raise CheckFailed(f"{words[0]} is a PNG of size {size}")
        elif command == "file-mode":
            mode = stat.S_IMODE(os.lstat(words[0]).st_mode)
            if mode != int(words[1], 8):
                raise CheckFailed(f"{words[0]} has mode {mode:o}")
        elif command == "remove":
            os.unlink(words[0])
        elif command == "stall":
            time.sleep(float(words[0]))
        elif command == "echo":
            print(rest, file=sys.stderr)
        else:
            raise CheckFailed(f"unknown script command {command}")

    def color_in(self, x, y, width, height, color, tolerance):
        view = self.current_view()
        want = bytes.fromhex(color.lstrip("#"))
        for row in range(max(0, y), min(view.height, y + height)):
            for column in range(max(0, x), min(view.width, x + width)):
                offset = (row * view.width + column) * 4
                b, g, r = view.store[offset:offset + 3]
                if all(abs(have - wanted) <= tolerance for have, wanted in zip((r, g, b), want)):
                    return True
        return False

    def hint_items(self):
        if self.hints is None:
            raise CheckFailed("no hints_list arrived")
        return self.hints.get("items", [])

    def check_hints(self, alphabet):
        """Check the structure of the last hints_list against protocol section 6.1."""
        items = self.hint_items()
        view = self.current_view()
        scale = view.dpr * view.state.get("zoom", 1)
        css_width, css_height = view.width / scale, view.height / scale
        if not isinstance(self.hints.get("truncated"), bool):
            raise CheckFailed("truncated is not a boolean")
        labels = [item.get("label") for item in items]
        length = 1
        while len(alphabet) ** length < len(items):
            length += 1
        for position, item in enumerate(items):
            where = f"item {position} {json.dumps(item)[:200]}"
            if item.get("index") != position:
                raise CheckFailed(f"{where}: index is not {position}")
            label = item.get("label")
            if not isinstance(label, str) or len(label) != length or any(c not in alphabet for c in label):
                raise CheckFailed(f"{where}: label is not {length} characters of {alphabet}")
            if item.get("kind") not in HINT_KINDS:
                raise CheckFailed(f"{where}: bad kind")
            if not isinstance(item.get("text"), str) or len(item["text"]) > 200:
                raise CheckFailed(f"{where}: bad text")
            url = item.get("url")
            if (item["kind"] != "link" and url is not None) or (url is not None and ":" not in url):
                raise CheckFailed(f"{where}: bad url")
            x, y, width, height = (item.get(key) for key in ("x", "y", "width", "height"))
            if not all(isinstance(value, (int, float)) for value in (x, y, width, height)):
                raise CheckFailed(f"{where}: rectangle is not numbers")
            if width < 1 or height < 1 or x >= css_width or y >= css_height or x + width <= 0 or y + height <= 0:
                raise CheckFailed(f"{where}: rectangle is outside the {css_width:g}x{css_height:g} viewport")
        if len(set(labels)) != len(labels):
            raise CheckFailed("labels are not distinct")

    def run(self):
        self.connect()
        self.handshake()
        if not self.args.no_view:
            self.open_view()
        for text in self.args.send:
            self.send(self.fill_in(json.loads(self.substitute(text))))
        if self.args.resize:
            width, height, dpr = self.args.resize
            self.send(self.fill_in({"type": "set_viewport", "width": width, "height": height, "dpr": dpr}))
            self.expect_frame([lambda h: h.full and (h.frame_width, h.frame_height) == (width, height)
                               and h.dpr == dpr], self.args.timeout)
        for path in self.args.script:
            self.run_script(path)
        if self.args.no_ack:
            self.pump_for(self.args.settle)
        elif self.args.png or not self.args.script:
            if self.view_id is not None and self.args.png:
                self.wait_until(lambda: self.frame_count, self.args.timeout, "a frame")
            self.settle(self.args.settle)
        if self.args.png:
            self.write_png(self.args.png)
        if self.args.verify_formula is not None:
            self.verify_formula(self.args.verify_formula)

    def verify_formula(self, tolerance_percent):
        """Check the store against the synthetic frame formula of plans/05 section 2."""
        view = self.current_view()
        fw, fh = view.width, view.height
        if not fw:
            raise CheckFailed("no frame arrived, nothing to verify")
        store = bytes(view.store)
        # The blue channel of the last pixel gives the seed, modulo 256.
        x, y = fw - 1, fh - 1
        seed = ((store[(y * fw + x) * 4] - (x ^ y)) * pow(37, -1, 256)) & 0xFF
        expected = proto.formula_rect(seed, fw, fh)
        differing = 0
        stride = fw * 4
        for row in range(fh):
            have = store[row * stride:(row + 1) * stride]
            want = expected[row * stride:(row + 1) * stride]
            if have != want:
                differing += sum(1 for offset in range(0, stride, 4)
                                 if have[offset:offset + 4] != want[offset:offset + 4])
        percent = 100.0 * differing / (fw * fh)
        print(f"formula: seed {seed}, {differing} of {fw * fh} pixels differ ({percent:.2f}%)", file=sys.stderr)
        if percent > tolerance_percent:
            raise CheckFailed(f"{percent:.2f}% of the pixels differ from the formula")

    def summary(self):
        encodings = ", ".join(f"{name} {count}" for name, count in sorted(self.encoding_counts.items()))
        print(f"frames: {self.frame_count} ({encodings or 'none'}), "
              f"{self.wire_bytes} bytes on the wire, {self.decoded_bytes} bytes of pixels; "
              f"errors: {len(self.errors)}; shm failures: {self.shm_failures}; "
              f"server stderr: {len(self.stderr_data)} bytes", file=sys.stderr)


def lookup(message, key):
    value = message
    for part in key.split("."):
        if isinstance(value, dict):
            value = value.get(part)
        elif isinstance(value, list) and part.isdigit() and int(part) < len(value):
            value = value[int(part)]
        else:
            return None
    return value


def parse_value(text):
    try:
        return json.loads(text)
    except ValueError:
        return text


def control_condition(word):
    if "#=" in word:
        key, _, text = word.partition("#=")
        return lambda message: isinstance(lookup(message, key), (str, list)) and len(lookup(message, key)) == int(text)
    if "~=" in word:
        key, _, text = word.partition("~=")
        return lambda message: isinstance(lookup(message, key), str) and text in lookup(message, key)
    key, _, text = word.partition("=")
    value = parse_value(text)
    return lambda message: lookup(message, key) == value


def frame_condition(word):
    key, _, text = word.partition("=")
    value = parse_value(text) if text else True
    getters = {
        "view": lambda h: h.view, "full": lambda h: h.full, "more": lambda h: h.more,
        "width": lambda h: h.frame_width, "height": lambda h: h.frame_height,
        "dpr": lambda h: h.dpr, "encoding": lambda h: ENCODING_NAMES[h.encoding],
        "damage_width": lambda h: h.damage_width, "damage_height": lambda h: h.damage_height,
    }
    if key not in getters:
        raise CheckFailed(f"unknown frame field {key}")
    return lambda header: getters[key](header) == value


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--server", help="command that starts the server on stdio")
    parser.add_argument("--socket", help="Unix socket of a running server")
    parser.add_argument("--viewport", type=parse_viewport, default=(800, 600, 1.0), metavar="WxH@DPR")
    parser.add_argument("--encodings", default=None, help="comma-separated, in preference order")
    parser.add_argument("--shm", action="store_true", help="offer shared memory")
    parser.add_argument("--fail-shm", action="store_true", help="answer every shm message with shm_failed")
    parser.add_argument("--protocol", type=int, default=proto.PROTOCOL_VERSION)
    parser.add_argument("--url")
    parser.add_argument("--png")
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("--send", action="append", default=[], metavar="JSON")
    parser.add_argument("--resize", type=parse_viewport, metavar="WxH@DPR")
    parser.add_argument("--script", action="append", default=[], metavar="FILE")
    parser.add_argument("--dump", action="store_true", help="print every message to stderr")
    parser.add_argument("--no-ack", action="store_true", help="never acknowledge frames")
    parser.add_argument("--no-view", action="store_true", help="do not create a view")
    parser.add_argument("--strict", action="store_true",
                        help="fail on reject, on any error message and on server stderr output")
    parser.add_argument("--verify-formula", type=float, metavar="PERCENT", nargs="?", const=0.0,
                        help="fail when more than PERCENT of the pixels differ from the synthetic formula")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if args.encodings is None:
        args.encodings = ["zstd", "raw"] if proto.zstd_available() else ["raw"]
    else:
        args.encodings = [name for name in args.encodings.split(",") if name]

    client = Client(args)
    status = 0
    try:
        client.run()
    except (CheckFailed, proto.BadFrame, proto.Desync) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        status = 1
    except BrokenPipeError:
        print("FAIL: the server closed the stream", file=sys.stderr)
        status = 1
    finally:
        client.close()
    client.summary()
    if args.strict and status == 0:
        if client.rejected or client.errors:
            print(f"FAIL: {client.rejected or client.errors[0]}", file=sys.stderr)
            status = 1
        elif client.stderr_data:
            print("FAIL: the server wrote to stderr:\n" + client.stderr_data.decode("utf-8", "replace"),
                  file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
