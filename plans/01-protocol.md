# 01 — Wire protocol between the Ladybird Emacs server and the Emacs client

Status: **v1**, the integration contract for every other work package. Change it only
by editing this file; every plan refers to it by message name. Where a plan's body
conflicts with this file, this file wins. §11 lists what changed from the draft so the
plans written against the draft can be read correctly.

Working names: the Ladybird side is the **server** (`Ladybird --headless=emacs`), the
Emacs side is the **client** (Elisp package `ladybird` with native module
`ladybird-module`).

## 1. Transport

One bidirectional byte stream per client. The server offers it as:

| Option | Stream | Use |
| --- | --- | --- |
| `--emacs-stdio` (default when no other is given) | stdin/stdout of the server process | local `make-process`, or `ssh host Ladybird --headless=emacs` |
| `--emacs-socket=PATH` | Unix listener, mode 0600, unlinked on exit | detachable local session, `ssh -L` forwarding |
| `--emacs-default-socket` | the same on the default socket (below); not with `--emacs-socket` | detachable local session that clients find without configuration |
| `--emacs-socket-activation` | a listening Unix socket that systemd (`LISTEN_FDS`) or launchd made for the server; not with the other socket options | the same, with the server started on the first connection |
| `--emacs-tcp=HOST:PORT` | TCP listener, no authentication | only for trusted networks such as a tailnet; v2 |

A stdio server lives exactly as long as its client (or its ssh session). Detaching and
reattaching needs `--emacs-socket`, `--emacs-default-socket`, `--emacs-socket-activation` or
`--emacs-tcp`.
`--emacs-background`, with `--emacs-socket` or `--emacs-default-socket`, runs the server
in a session of its own; the command returns once the socket accepts connections, and
fails with the reason on stderr when the server cannot start.

The **default socket** of a user's local server is `$XDG_RUNTIME_DIR/ladybird-emacs.sock`
when `XDG_RUNTIME_DIR` is an absolute path, else
`$TMPDIR/ladybird-emacs-UID/ladybird-emacs.sock` with UID the real user id in decimal and
`/tmp` for a `TMPDIR` that is not an absolute path. An unset, empty or relative value
counts as unset. Trailing slashes of `XDG_RUNTIME_DIR` and `TMPDIR` are dropped.

Outside `XDG_RUNTIME_DIR` the directory `ladybird-emacs-UID` must be **private**: a
directory, not a symbolic link, owned by the user and granting its group and others no
permission, in a directory that is owned by root or the user and is either sticky or
writable by its owner only. The server creates it with mode 0700 when it is missing, and
refuses to start, naming the directory on stderr, when it or its parent fails. A client
never creates it, and ignores a socket there unless the directory is private.

A client asked for the local server connects to the default socket when a socket of its
user accepts connections on it, and otherwise starts a server over stdio. It may find
that out by connecting and closing again without a `hello`, which leaves the server's
current client in place (§8).

On macOS a Unix socket delivers at most 8 KiB per read to Emacs, while a pipe delivers
64 KiB, so locally prefer stdio (or shm, §4) over a Unix socket.

The stream carries **records**. Every record is:

```
u32 LE  length      bytes that follow this field: 1 for `kind` plus the payload;
                    at least 1, at most 64 MiB
u8      kind        1 = control (UTF-8 JSON object), 2 = frame (binary, §4)
bytes   payload
```

Control records are JSON objects with a `type` string and, where a view is involved,
`view` (integer id). Unknown `type` values are ignored by both sides. Unknown JSON keys
are ignored. Integers are JSON numbers; booleans are `true`/`false`; absent means null.

The server serves one client at a time. A second connection gets a `welcome`, and the
previous client gets `{"type":"replaced"}` and a close. A client that disconnects leaves
every view running; the next client sees them in its `welcome`. The server keeps
running with zero views; `welcome.views` is then `[]`.

All stderr/debug output of the server and its helpers goes to a log file, never to the
stream (`TerminalWebView::take_over_terminal()` shows how to redirect it).

A length-prefixed stream has no resynchronisation marker. A client that detects a
framing error (bad kind, zero or oversize length) must close and reconnect.

## 2. Handshake

Client sends first:

```json
{"type":"hello","protocol":1,"client":"ladybird 0.1",
 "viewport":{"width":1600,"height":1000,"dpr":2.0},
 "encodings":["zstd","raw"],
 "shm":true,
 "popups":true,
 "token":null}
```

`viewport` is in device pixels; `dpr` is the device pixel ratio the client renders
at. `encodings` lists what the client can decode, in preference order. `shm` says the
client can map POSIX shared memory of the server's machine (only true when the client
connected over stdio to a local process or over a Unix socket; the client decides from
how it connected. A Unix socket may be an `ssh -L` forward of a remote one, which the
client cannot see; `shm_failed`, §4.3, covers that case). `token` is reserved for TCP authentication (v2); the server
ignores it in v1.

Server answers:

```json
{"type":"welcome","protocol":1,"server":"Ladybird 0.x (abcdef)",
 "encoding":"zstd","shm":true,
 "log":"/run/user/1000/ladybird-emacs-12345.log",
 "host":{"hostname":"devbox","platform":"linux"},
 "features":["hints"],"max_views":16,
 "views":[{"view":1,"url":"https://…","title":"…","loading":false,
           "can_go_back":true,"can_go_forward":false,"zoom":1.0,
           "width":1600,"height":1000,"dpr":2.0}]}
```

`encoding` is the one the server will use; `shm` is `true` when both sides agreed to
use shared memory (the segment itself is announced with `shm` messages, §4.3). `log` is
the server's log file on its machine. `features` names the optional parts of the
protocol the server implements (`"hints"`, §6.1); a server without any may leave it
out. `max_views` is the number of views the server can have at a time (§3). `popups` in
`hello` says the client takes views that pages open (§3.1); it is false when left out. If `views` is empty the client sends `create_view`. On a protocol mismatch the server sends `{"type":"reject","reason":"…"}`
and closes.

After `welcome` the server sends, for every view, a `state` and, for every view that
is visible (§3), as soon as the Compositor has presented one, a full frame (flag
`full`, §4), so a reconnecting client has something to show.

Keepalive: either side may send `{"type":"ping","id":n}`; the peer answers
`{"type":"pong","id":n}`. The client treats a missing pong within 10 s as a dropped
connection (rexel does the same).

## 3. Views

A view is one Ladybird `HeadlessWebView` (one page, with a WebContent process of its
own). A server has up to `welcome.max_views` views at a time (an integer; a server that
leaves it out has one). They share the server's cookies and storage. View ids are never
reused within a server process: a view created after `close_view` gets the next id.

Every view has its own frame sequence, flow control (§4.2) and shared memory segment
(§4.3). Frames of several views share the connection; the bands of one frame (§4.4)
follow each other with no other view's frame between them. A view the client has hidden
with `set_visibility` sends no frames; when it becomes visible again its next frame is
a full one. A new view is visible. While no client is connected no view renders; a
view has the visibility its last client gave it when a client connects again, and
`welcome` does not say which, so a client sends `set_visibility` for every view after
`welcome`. `welcome.views` is in the order of the view ids.

A view sends a frame when it is its turn: while one view's frame is in bands, or the
server has 64 MiB or more that the client has not read from the connection, the others
wait, the one that has waited longest going first. A client that stops acknowledging
one view's bands so stalls the frames of all; one that stops acknowledging a frame
that has no bands stalls that view alone. Hiding or closing a view, and a crash of its
WebContent, end its frame early: the bands still to come are not sent, another view's
frame can follow, and the view's next frame is a full one.

When the connection is busy the server keeps only the latest `state`, `cursor`,
`link_hover`, `tooltip`, `favicon`, `background_color` and `ime` of a view, so a page
that changes them in a loop does not fill it.

All viewports of a server together have at most 256 000 000 device pixels. A
`set_viewport` or `create_view` that would exceed that gets a smaller size (the height
is reduced, as for the limit of one view); a `create_view` when nothing is left is
answered with `error`. `max_views` is at least 1. The ids the server puts on its
requests (dialogs, pickers, permissions) are unique across its views.

A server keeps running without views: on a socket until it is stopped, on standard
input and output until the client disconnects.

| Client → server | Fields | Effect |
| --- | --- | --- |
| `create_view` | `url` (optional), `width`, `height`, `dpr`, `request` (optional integer) | Server creates a view and answers with `view_created` followed by `state` and a frame, or with an `error` when it cannot (the server has `max_views` views already). Both answers echo `request` |
| `close_view` | `view` | Closes it; server answers `view_closed`. A `close_view` for a view that is closed already gets no answer, one for an id that never existed an `error` |
| `set_viewport` | `view`, `width`, `height`, `dpr` | Device pixels. Server resizes the view; the next frame has the new size and the `full` flag. The server clamps each dimension to 16000 and the area to 64 000 000 pixels (reducing the height); a `dpr` outside 0.25–8 is answered with `error` and changes nothing |
| `set_visibility` | `view`, `visible` | Maps to `set_system_visibility_state`; a hidden view stops presenting frames |
| `set_focus` | `view`, `focused` | Maps to `set_has_system_focus` |

| Server → client | Fields | Meaning |
| --- | --- | --- |
| `view_created` | `view`, `url`, `title`, `width`, `height`, `dpr`, `request` or `opener` | Answer to `create_view` (with its `request`); `url` is `about:blank`, the `state` that follows a `create_view` has the requested URL with `loading` true. With `opener`, the id of another view, it announces a view a page of that view opened (§3.1) |
| `popup_blocked` | `view`, `url` (null when unknown) | A page tried to open a window with user activation (also middle click and "open in new tab") and the server made no view for it (§3.1); the client may offer to `create_view` with that URL. Ladybird drops popups without user activation silently |
| `view_closed` | `view`, `reason` (`"closed"`, `"crashed"`, `"client"`) | |
| `state` | `view`, `url`, `title`, `loading`, `can_go_back`, `can_go_forward`, `zoom` | Whole state, sent whenever any of it changes. Sending the whole thing keeps the client stateless |
| `crashed` | `view`, `reason` | WebContent died; the view shows Ladybird's crash page and keeps working |

### 3.1 Views opened by pages

A page opens a window with `window.open`, a link with a `target` or a middle click.
Ladybird lets it only after a user's action in the page, unless it was started with
`--allow-popups`. The server then makes a view for the window when the client's
`hello` had `"popups": true`, there are fewer than `max_views` views and the limit on
all viewports leaves room for one of the opener's size, and sends `view_created` with
`opener`, followed by `state` and a frame as for any new view. Otherwise the server
makes no view and sends `popup_blocked`.

The view has the size and `dpr` of its opener until the client sends `set_viewport`.
Its `url` is `about:blank` until the page's URL is known. A client that does not want
it sends `close_view`. One action of the user lets the page open one window; a link
the user clicks with the middle button or with Ctrl opens one more.

A window whose first navigation turns out to be a download is closed again: the client
gets the `error` for the download with the new view's id, then `view_closed` with
reason `"closed"`.

`opener` is the view the window was opened from, also when the new page cannot reach
that view's page (`noopener`, a middle click). Where the page can, the two hold
references to each other (`window.opener`, the value `window.open` returned), as in a
browser. When a page closes its window (`window.close()`), the server sends
`view_closed` with reason `"closed"`. Closing a view leaves the views it opened.

A view a page opened is a view like any other after that: `welcome.views` lists it
without `opener`, and the `popups` of a later `hello` decides only about windows opened
from then on.

## 4. Frames

### 4.1 Record layout

A frame record (kind 2) has this **44-byte header**, all little-endian, then a payload:

```
u32  seq            starts at 1 per view, increases per frame record; the client acks it
u32  view
u32  frame_width    device pixels of the whole presented frame
u32  frame_height
f64  dpr            device pixel ratio the frame was rendered at
u32  damage_x       rectangle of changed pixels within the frame
u32  damage_y
u32  damage_width
u32  damage_height
u8   encoding       0 = raw, 1 = zstd, 2 = shm
u8   flags          bit 0 = full: the whole frame changed or its size changed; damage equals
                    the frame rectangle and the client must repaint everything
                    bit 1 = more: another record for the same presented frame follows
                    (banding, §4.4); the client may defer refresh until a record without it
u16  reserved       0
```

Pixels are **BGRA8888**, i.e. each pixel read as a little-endian `u32` is `0xAARRGGBB`,
which is exactly the Emacs canvas's ARGB32. Alpha is 0xFF for page content.

| encoding | payload |
| --- | --- |
| 0 raw | `damage_width * damage_height * 4` bytes: the damage rectangle, rows tightly packed |
| 1 zstd | one zstd frame, with its content size pledged in the frame header, that decompresses to the raw payload above |
| 2 shm | `u64 offset`: the whole frame lives in the current shared memory segment (§4.3) at `offset`, row stride `frame_width * 4`. The damage rectangle says what changed since the last acked frame |

The server chooses raw over zstd for small damage rectangles (under 16 KiB) and when
the client did not offer zstd. Compression level is zstd 1 (fast).

### 4.2 Flow control

The server keeps **one frame in flight per view**. It sends a frame and waits for
`{"type":"frame_ack","view":v,"seq":n}` before sending the next. While waiting it
coalesces: it remembers the union of damage rectangles and, when the ack arrives, sends
the latest displayed frame with that union as damage.

The client acks **every** frame record it receives, including ones it could not decode,
ones for unknown views and ones it dropped as stale; otherwise the server stalls. It acks
after it has copied the pixels (or decided to drop them), not after Emacs redisplayed.
The server ignores acks whose `seq` is not the one in flight.

### 4.3 Shared memory

When `welcome.shm` is true the server announces each segment before the first frame
that uses it:

```json
{"type":"shm","view":1,"name":"/ladybird-12345-2","size":6400000}
```

`size` is the number of bytes the server uses; the mapped object may be larger (macOS
rounds it up to whole pages).

`name` is a POSIX `shm_open` name, at most 31 bytes including the slash (macOS limit).
A frame record with encoding 2 refers to the most recent `shm` message for its view.
Segments are never resized: a viewport change allocates a new segment (new generation
number in the name) and announces it; the server unlinks the previous segment after the
client acks the first frame in the new one. With shm the server writes the segment only
between an ack and the next frame record, so the client reads it only between receiving
a frame record and sending its ack. The client needs no reply to `shm`.

A client that cannot use an announced segment (the name does not open, or the object is
smaller than `size`; `fstat` reports a page-rounded size, so larger is normal: the socket was forwarded from another machine, or a sandbox
hides the segment) sends `{"type":"shm_failed","view":v}`. The server then stops using
shm for this connection, for every view, clears its one-in-flight state for that view
(the client still acks any shm frame record it received, with status irrelevant to the
server) and every view sends its next frame as a `full` frame with a stream encoding.
One `shm_failed` is enough for a connection.

The `shm` of a new view comes after its `view_created`. A view that was hidden has no
segment; it announces one before the frame it sends when it is shown. A reconnecting
client gets every segment announced again.

### 4.4 Large frames

A record holds at most 64 MiB. A raw frame larger than that (above about 4K at dpr 2)
is sent as horizontal bands: several frame records with consecutive `seq`, the same
`frame_*`/`dpr`, adjacent damage rectangles, and the `more` flag set on all but the
last. Each band is acked like any frame; the one-in-flight rule applies per band. Of the
bands of a `full` frame only the first carries the `full` flag. Zstd frames are banded
the same way, so no record decodes to more than 64 MiB.

## 5. Input

Coordinates are device pixels of the frame (the same space as the frame header). The
client converts from canvas coordinates.

Modifier bitmask, shared by mouse and key messages:

| bit | value | meaning | Ladybird |
| --- | --- | --- | --- |
| 0 | 1 | shift | `Mod_Shift` |
| 1 | 2 | ctrl | `Mod_Ctrl` |
| 2 | 4 | alt / option / meta | `Mod_Alt` |
| 3 | 8 | super / command | `Mod_Super` |
| 4 | 16 | keypad: the key is on the numeric keypad | `Mod_Keypad` |

Buttons: `"left"`, `"middle"`, `"right"`, `"back"`, `"forward"`.

```json
{"type":"mouse","view":1,"kind":"down","x":120,"y":340,"button":"left",
 "buttons":["left"],"modifiers":0,"clicks":1}
{"type":"mouse","view":1,"kind":"up","x":120,"y":340,"button":"left","buttons":[],
 "modifiers":0,"clicks":1}
{"type":"mouse","view":1,"kind":"move","x":121,"y":342,"buttons":[],"modifiers":0}
{"type":"mouse","view":1,"kind":"wheel","x":121,"y":342,"dx":0,"dy":80,"modifiers":0,
 "precise":true}
{"type":"mouse","view":1,"kind":"leave"}
```

`clicks` (1, 2 or 3) is sent on `down` and repeated on the matching `up`; the server
puts it in `MouseEvent::click_count`, as the Qt and terminal frontends do (Ladybird has
no separate double-click event). `buttons` is the set held after the event. Wheel
`dx`/`dy` are device pixels; positive `dy` scrolls the content down (the page moves up),
positive `dx` scrolls right. `precise` is true for touchpad pixel deltas
(`WheelDeltaPrecision::Precise`), absent or false for wheel notches. `kind:"leave"`
tells the page the pointer left the view (hover state clears).

```json
{"type":"key","view":1,"kind":"down","key":"Return","code_point":10,"modifiers":0,"repeat":false}
{"type":"key","view":1,"kind":"up","key":"Return","code_point":10,"modifiers":0}
{"type":"text","view":1,"text":"héllo"}
```

`key` is the **enumerator name** of Ladybird's `Web::UIEvents::KeyCode` without the
`Key_` prefix (`"A"`, `"Return"`, `"Escape"`, `"Left"`, `"F5"`, `"Backspace"`,
`"ExclamationPoint"`, `"Space"`…), not the UI name that `key_code_from_string` parses.
The server maps the string with a table generated from `ENUMERATE_KEY_CODES`; an unknown
name maps to `Key_Invalid`, and `Key_Invalid` with a non-zero `code_point` still types
that character. `code_point` is the Unicode scalar the key produces, 0 if none; the
special keys use what Ladybird's terminal frontend sends: Return 10, Tab 9, Backspace 8,
Escape 27, Delete 127. Emacs has no key-release events, so the client sends `up`
immediately after `down` for every key, except that a held modifier sends nothing on its
own.

`text` inserts a string as typed text through the input-method commit path, for
characters Emacs received that have no key code (non-ASCII, IME composition). `paste`
(§6) is the clipboard paste operation and fires paste events on the page.

The server answers input it has dispatched with nothing; the client does not wait.
Commands are not ordered after input events still on their way to the page: a
`request_selection` sent straight after a double click may answer with the old selection.

## 6. Navigation and page commands

| Client → server | Fields | Maps to |
| --- | --- | --- |
| `load` | `view`, `url` | `load()`; the server also accepts non-URL text and treats it as a search or hostname the way `load_from_user_input` does |
| `load_html` | `view`, `html` | `load_html()` |
| `reload` | `view`, `bypass_cache` | `reload()` |
| `stop` | `view` | `stop_loading()` |
| `history` | `view`, `delta` | `traverse_the_history_by_delta()`; −1 back, +1 forward |
| `zoom` | `view`, `op`: `"in"`, `"out"`, `"reset"` | |
| `find` | `view`, `query`, `case_sensitive`, `highlight_all` | `find_in_page()`; `query` empty ends the search |
| `find_step` | `view`, `direction`: `"next"`, `"previous"` | |
| `edit` | `view`, `op`: `"select_all"`, `"cut"`, `"undo"`, `"redo"` | `cut` makes the server send `clipboard` with the cut text |
| `paste` | `view`, `text` | Paste `text` at the caret (Emacs owns the clipboard) |
| `request_selection` | `view`, `request` | Server answers `selection` `{view, request, text}` |
| `screenshot` | `view`, `request`, `kind`: `"visible"`, `"full"`, `path` (optional, server-side) | Server saves a PNG on its machine and answers `screenshot_saved` `{view, request, path}`; `path` in the answer is authoritative (without `path`: `ladybird-emacs-<pid>-screenshot-<n>.png` in the directory of the default socket when the server listens there, else in `$XDG_RUNTIME_DIR`, and where there is neither or the file cannot be made there, `/tmp/ladybird-emacs-<pid>-screenshot-<n>-XXXXXX.png` with `XXXXXX` chosen at random; mode 0600, `<n>` counting the screenshots of the server) |
| `set_console` | `view`, `enabled` | Turns `console` messages on or off |

| Server → client | Fields | Meaning |
| --- | --- | --- |
| `cursor` | `view`, `cursor` | CSS cursor name (`"pointer"`, `"text"`, …) |
| `link_hover` | `view`, `url` (null when unhovered) | |
| `tooltip` | `view`, `text` (null when left) | |
| `favicon` | `view`, `png` (base64) | |
| `background_color` | `view`, `rgb` (`"#rrggbb"`) | For the canvas margin |
| `find_result` | `view`, `query`, `index`, `total` | `index` is the current match counted from 1, 0 without a match; `total` is null when unknown. `query` lets the client drop stale results |
| `ime` | `view`, `enabled`, `activation`, `caret`: `{x,y,width,height}` or null | `enabled` is true while a mutable textarea, a mutable input of a type with a text field (text, search, tel, url, email, password, number), or an editable element or document has the focus; `activation` is true while the focused document has transient user activation (a key or button pressed in it or in a related frame, a hint chosen or a paste, in the last few seconds), so false for a focus moved by autofocus or a script alone. Sent after input events, paste, IME edits, a focus move, a change of whether the focused element takes text and a new active document, and not when it would repeat the last `ime` sent; to a new client and on `set_focus` true it is sent even then, with the `activation` of the last state. A focus that a key in one document moves into a cross-origin frame has no `activation` there. `caret` places the Emacs cursor / IME candidate window |
| `clipboard` | `view`, `text` | The page put text on the clipboard (cut, copy, `navigator.clipboard`); the client adds it to the kill ring |
| `console` | `view`, `level`, `text` | Page console output, when enabled |
| `error` | `view`, `message` | A command failed (bad URL, unknown view, unsupported in v1). Informational |

`request_source` is **v2**: Ladybird's `get_source()` opens a view-source tab, which a
headless view cannot show. v2 will define it as serialized DOM or page text.

### 6.1 Hints

Hints let the user activate an element of the page from the keyboard: the server puts a
short label on every element in the viewport that can be activated, the user types a
label, and the server activates that element. A server that implements them lists
`"hints"` in `welcome.features` (§2).

| Client → server | Fields | Meaning |
| --- | --- | --- |
| `hints` | `view`, `id`, `alphabet` | Label the elements and answer `hints_list`. `id` is a non-negative integer below 2^53 chosen by the client; it names this hint session. `alphabet` is 2 to 36 distinct characters of `a`–`z` and `0`–`9`; labels are made of them. A view has one hint session; a new `hints` ends the one before it without a message |
| `hints_narrow` | `view`, `id`, `prefix` | Show only the labels that start with `prefix` (the empty string shows all). `prefix` is a string of characters of the session's alphabet, no longer than its labels |
| `hints_end` | `view`, `id`, `activate` (an item's `index`, or null) | Remove the labels. With `activate` the server then moves the focus to the element and, unless it is a text field, clicks it |

| Server → client | Fields | Meaning |
| --- | --- | --- |
| `hints_list` | `view`, `id`, `items`, `truncated` | `items` is an array of `{index, label, kind, text, url, x, y, width, height}` in document order. `kind` is `"link"`, `"button"`, `"input"` (what takes typed text: a mutable `textarea`, an element with `contenteditable`, a mutable `input` of a type with a text field; a read-only or disabled one is `"other"`) or `"other"`. `text` is the element's visible text or its accessible name, at most 200 characters. `url` is the absolute link target of a `"link"`, else null; it is also null for a target longer than 16 KiB. `x`, `y`, `width`, `height` are the element's rectangle relative to the viewport of the top-level document, also for an element in a frame, cut to what shows of it, in CSS pixels, which the page's zoom and the device pixel ratio scale to canvas pixels. `truncated` is true when elements were left out because there are more than 1000; they have no label |
| `hints_cancelled` | `view`, `id` | The hint session ended without `hints_end`: another document became active, WebContent crashed, the page closed its view (`hints_cancelled` comes before that `view_closed`), or the process of the top-level document did not answer in time. The labels are gone. It can arrive in place of `hints_list`. A `close_view` from the client ends the session with `view_closed` alone |

Rules:

- A candidate is an element that can be activated: `a[href]` (also an SVG `a` with
  `xlink:href`), `button`, `input` other
  than `type=hidden`, `select`, `textarea`, `summary`, `label`, an element with
  `contenteditable`, an `onclick` attribute, a `tabindex` of 0 or more, or a `role` of
  `button`, `link`, `tab`, `menuitem`, `checkbox`, `radio`, `switch` or `option`.
  Candidates come from the top-level document, from the document of every frame,
  whatever its origin, and from open and closed shadow roots. An `area` is not a
  candidate (Ladybird gives it no box), and an SVG document gets no labels.
- A candidate is listed when a click of the mouse could reach it: it is not disabled,
  neither it nor an ancestor has an opacity of 0, its box is at least 3×3 CSS pixels,
  and at one of up to 34 points sampled over it that lies in the viewport and in the
  visible part of every frame around it, the page's hit test lands on it or on
  something inside it. That leaves out what is clipped, covered, moved out of view or
  made unhittable with `pointer-events`.
- Of two listed candidates for one thing, one is dropped: a `label` whose control is
  listed, and a candidate that is one only by `label`, `onclick`, `tabindex` or `role`
  and contains another listed candidate.
- A frame that another process hosts (a frame of another site) counts as visible when
  the hit test of the document around it, at the centre of the frame's visible part,
  lands on the frame. What covers only a part of such a frame is not noticed: an
  element under it is listed, and its label is covered with it.
- A label straddles the top left corner of the first piece of the element that shows,
  a few pixels up and left of it, inside what shows of its document.
- The documents of a page can live in several processes. Once the process of the
  top-level document has answered, the others have half a second; the frames of a
  process that takes longer are left out.
- Labels all have the same length, the shortest that gives every item its own label, so
  no label is the prefix of another.
- The labels are part of the page's frames: the client draws nothing. They stay where
  they are in the document while the page scrolls, and elements that scroll into view
  get no label.
- `hints` with a bad `alphabet` or `id`, `hints_narrow` with a bad `prefix`, and
  `hints_narrow` or `hints_end` with an `id` that is not the view's hint session, are
  answered with `error` and change nothing. That `error` carries the `id` of the
  message it answers, and no other `error` has an `id`, so the client can end a session
  whose `hints` was refused. A `hints_narrow` or `hints_end` can cross a
  `hints_cancelled` or an empty `hints_list`; the client ignores an `error` with the
  `id` of a session it knows to be over. A `hints_end` whose `activate` is no item's index
  removes the labels and activates nothing.
- Before `hints_list` has been sent, a `hints_narrow` takes effect when the labels are
  drawn, and a `hints_end` ends the session and activates nothing.
- Activation is a mouse click at a point of the element, sent the way a click of the
  user is, so the page takes it for one. The press and the release are delivered only
  if the hit test still lands on the element when each is dispatched, in every
  document the click passes on its way into a frame. An element that moved is clicked
  where it is. One that went away or got covered since `hints_list` is not activated,
  and the server answers the `hints_end` with an `error` that carries its `id`.
- A page with nothing to label gets `hints_list` with empty `items`; the hint session
  is over then and needs no `hints_end`.
- A disconnecting or replaced client ends the hint session; a reconnecting client is
  not told about it.
- The server finds the elements, makes the list and delivers the click outside the
  reach of the page's script, so a page cannot falsify the list or move the click to
  another element. The labels are elements in the page, inside a shadow root its
  script cannot open: a page can notice their host element and remove, hide or move
  it. The server checks the chosen label at activation and activates nothing when it
  is not where it was put (an `error` with the `id`). `text` and `url` are the
  page's content; the client treats them like any other strings from a page, and
  loads a `url` the user chose under the rules it has for a link the user clicked.

## 7. Dialogs and pickers

Every request has an `id` the client echoes. The server leaves the page blocked until
the answer, as Ladybird's dialogs do. Device pixels for `x`, `y`.

| Server → client | Fields | Client → server |
| --- | --- | --- |
| `dialog` | `view`, `id`, `kind`: `"alert"`, `"confirm"`, `"prompt"`, `"beforeunload"`, `message`, `default`, `origin` | `dialog_closed` `{view, id, accepted, text}` |
| `dialog_update` | `view`, `id`, `default` | The default text of an open prompt changed; the client may ignore it |
| `select` | `view`, `id`, `x`, `y`, `min_width` (device px), `items`: `[{id,label,selected,disabled,group}]` or `{separator:true}` | `select_closed` `{view, id, item}` (item id or null) |
| `file_picker` | `view`, `id`, `multiple`, `accept`, `directory` (hint, may be null) | `file_picker_closed` `{view, id, paths}` with paths on the server's machine; `[]` cancels. Uploading a local file first is v2 |
| `color_picker` | `view`, `id`, `current` | `color_picker_closed` `{view, id, color}` or null |
| `date_picker` | `view`, `id`, `input_type`, `value`, `min`, `max` | `date_picker_closed` `{view, id, value}` or null |
| `permission` | `view`, `id`, `name` (`geolocation`, `microphone`, `notifications`), `origin`, `is_file` | `permission_closed` `{view, id, outcome}`: `"allow_once"`, `"allow_always"`, `"deny"`, `"dismiss"` |
| `permission_cancelled` | `view`, `id` | The page withdrew the request (navigated away); the client closes its prompt |
| `request_cancelled` | `view`, `id` | The server withdrew an open `dialog`, `select`, `file_picker`, `color_picker` or `date_picker` (WebContent crashed, another document became active, a newer request of the same kind replaced it, the view closed); the client closes its prompt and sends no answer. A withdrawn request is not sent again to a reconnecting client. An alert that blocks a pending `load` stays open: withdrawal happens when the new document is active |
| `context_menu` | `view`, `x`, `y`, `kind`, `link_url`, `image_url`, `image_mime_type`, `media_url`, `media`: `{playing, muted, loop, controls}` or null, `selection`, `editable` | nothing; the client builds its own menu from these and sends ordinary commands. v2 adds `context_menu_action` for Ladybird-side actions such as inspect element |
| `external_url` | `view`, `id`, `url`, `application` | `external_url_closed` `{view, id, open}`; `open` false denies |

## 8. Errors and logging

`error` (§6) reports a failed command; the connection stays up. Framing errors (§1)
end the connection.

Limits the server enforces: every string that comes from a page (title, URL, dialog and
console text, tooltip, selection, clipboard, select labels) is cut to 1 MiB of UTF-8 and
is always valid UTF-8 (a lone surrogate becomes U+FFFD); a favicon whose PNG is larger is
sent with `png` null. Wheel deltas beyond ±1e6 or not finite, a `code_point` that is not a
Unicode scalar value, and a history `delta` beyond ±10000 are answered with `error` and
not forwarded. Downloads are refused with `error` "download blocked: NAME". A `create_view`
with an unusable URL or `dpr` fails with `error` and creates no view. `reject` reasons are
"the first message must be hello", "unsupported protocol version" and "framing error".
A connection replaces the current client only once its `hello` is accepted; the old client
then receives `replaced` followed by end of stream. A connection that negotiated zstd
still receives raw frames when zstd cannot shrink the pixels.

## 9. Versioning

`protocol` is a single integer, bumped on any incompatible change. Additive changes
(new message types, new optional fields) do not bump it.

## 10. Reserved for v2

Multiple clients on one view,
uploads for the file picker, `context_menu_action`, `request_source`/`source`,
`request_history`/`history_list` (full session history with titles), video-codec frame
encodings (`encoding` 3+), per-view `set_user_agent`, downloads (`download_*` events
mirroring Ladybird's `DownloadState`), devtools port forwarding, TCP listener
authentication via `hello.token`.

## 11. Changes from the draft

Made after the three component plans reviewed the draft. Plans 02, 03 and 04 were
written against the draft; read their bodies with these corrections.

1. Modifier bit 16 is `keypad` (`Mod_Keypad`), not altgr.
2. `clicks` on `down` and `up` sets `click_count`; there is no double-click event. Wheel
   has optional `precise`. The `leave` example is fixed.
3. Special-key code points fixed: Return **10** (not 13), Tab 9, Backspace 8, Escape 27,
   Delete 127. `Key_Invalid` with a code point still types.
4. `key` names are enumerator names; stated explicitly.
5. `text` vs `paste` defined; `edit cut` yields a `clipboard` message; new `clipboard`
   message for page-initiated clipboard writes.
6. `screenshot.path` optional, answer authoritative. `request_source` moved to v2.
7. `select` gains separators and device-pixel `min_width`; `dialog` gains `origin`;
   `dialog_update` added; `file_picker` gains `directory`; `permission` outcomes are
   `allow_once`/`allow_always`/`deny`/`dismiss`, plus `permission_cancelled`;
   `context_menu` gains `image_mime_type` and `media`.
8. Popups: `popup_blocked` in v1; `view_created` is only the answer to `create_view` and
   carries `title`, `width`, `height`, `dpr`.
9. `welcome` gains `log`, per-view `width`/`height`/`dpr`; `welcome.shm` is a boolean,
   segments are announced by the new `shm` message (§4.3), never resized.
10. Frame header size stated (44 bytes); `seq` starts at 1 per view; zstd pledges the
    content size; `more` flag and banding for frames above 64 MiB (§4.4); clients ack
    every record; stale acks ignored; full frame after `welcome` only once available.
11. `find_result` carries `query`. `hello` gains reserved `token`. `set_console` listed.
12. Transport notes: stdio dies with its ssh session; macOS Unix sockets read in 8 KiB
    chunks; framing errors require a reconnect.
13. `shm_failed` (§4.3): fallback to stream encodings when the client cannot map the
    announced segment, e.g. over a forwarded Unix socket.
14. `length` counts the `kind` byte (§1); plans 02 and 03 had read it as the payload
    length.
15. From the server implementation: view ids are not reused; `view_created.url` is
    `about:blank`; `popup_blocked` needs user activation and may have a null `url`; only
    the first band of a full frame has `full`, zstd frames are banded too; commands are
    not ordered after input; `shm.size` is the used size, the mapping may be larger.
    The server re-sends open dialogs, pickers and permission requests to a reconnecting
    client. `external_url` never fires in headless Ladybird.
16. From the code reviews: `create_view.request`, echoed by `view_created` and `error`;
    `request_cancelled`; the server truncates over-long page strings, sends valid UTF-8
    only, answers out-of-range input numbers with `error`, refuses downloads with an
    `error`, and replaces a client only after the new connection's `hello`.
17. Hints (§6.1): `hints`, `hints_narrow`, `hints_end`, `hints_list`, `hints_cancelled`,
    `welcome.features`, and `id` in an `error` that answers a hints message.
18. Several views per server (§3): `welcome.max_views`, one frame flow and shared
    memory segment per view, turns for frames, the limit on all viewports together.
    Views opened by pages (§3.1): `hello.popups` and `view_created.opener`.
19. The default socket (§1): `--emacs-default-socket` listens on `ladybird-emacs.sock`
    in an absolute `XDG_RUNTIME_DIR`, else in the private directory `ladybird-emacs-UID`
    of an absolute `TMPDIR` or `/tmp`, which the server creates with mode 0700 and
    refuses when it or its parent is not private; a client asked for the local server
    tries it before stdio, outside `XDG_RUNTIME_DIR` only in a private directory.
