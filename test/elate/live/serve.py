#!/usr/bin/env python3
"""HTTP server for the pages of the live scenarios.

Usage: python3 -I test/elate/live/serve.py [--port PORT] [--dir DIRECTORY]
                                           [--exit-on-eof] [--label WORD]

Serves the files of DIRECTORY (by default pages/ next to this file) on
127.0.0.1 and prints "ready PORT" once it listens; PORT 0 picks a free
port.  With --exit-on-eof it exits when its standard input ends, which
is how it ends with the ssh that started it.  Besides the files:

  /favicon.png     a 16x16 PNG of one colour
  /slow?ms=N       an HTML page sent after N milliseconds
  /download        a file sent as an attachment
"""

import argparse
import functools
import http.server
import os
import struct
import sys
import threading
import time
import urllib.parse
import zlib


def png(width, height, rgba):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data)))
    row = b"\0" + bytes(rgba) * width
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height))
            + chunk(b"IEND", b""))


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_body(self, content_type, body, headers=()):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/favicon.png":
            self.send_body("image/png", png(16, 16, (0x20, 0x80, 0xE0, 0xFF)))
        elif url.path == "/slow":
            time.sleep(int(query.get("ms", ["3000"])[0]) / 1000)
            self.send_body("text/html", b"<!doctype html><title>page=slow</title>slow")
        elif url.path == "/download":
            self.send_body("application/octet-stream", b"downloaded\n",
                           [("Content-Disposition",
                             'attachment; filename="live-download.bin"')])
        else:
            super().do_GET()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--dir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "pages"))
    parser.add_argument("--exit-on-eof", action="store_true")
    parser.add_argument("--label", help="a word to find this process by")
    args = parser.parse_args()
    handler = functools.partial(Handler, directory=args.dir)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    server.daemon_threads = True
    print("ready", server.server_address[1], flush=True)
    if args.exit_on_eof:
        def watch():
            while sys.stdin.buffer.read(4096):
                pass
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
