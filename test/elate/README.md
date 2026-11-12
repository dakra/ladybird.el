# ladybird end-to-end scenarios (elate)

[`elate`](https://github.com/dakra/elate) scenarios that drive ladybird in a sandboxed
Emacs against `tools/mock-server.py`: the commands, their prompts and the keys a user
types, with the mock server's log as the oracle for what arrived.

```sh
test/elate/run.sh                                   # every scenario, every variant
test/elate/run.sh test/elate/matrix/ui.json         # one scenario
test/elate/run.sh -v unix,tcp test/elate/matrix/reconnect.json
uvx elate run --keep-going --variant tcp test/elate/matrix/connect.json
```

`run.sh` runs each scenario once per variant and exits non-zero when a group failed.
It needs `uvx` (or `ELATE` naming the elate command, 0.16 or later) and `python3`;
`LADYBIRD_ELATE_PYTHON` names the Python that runs the mock server.  The sessions load the
native module from the checkout and fall back to `test/ladybird-fake-module.el`.

| Scenario | Variants | Covers |
|---|---|---|
| `connect` | stdio, unix, tcp | opening a page, the `C-c` navigation commands, zoom, a second buffer, closing from command mode |
| `input` | stdio, unix | page mode: typed and function keys, the editing and motion keys per platform, a prefix argument, text, paste, selection, `C-c C-q` (also `ESC x` on the terminal); command mode and its scroll commands |
| `size` | stdio, tcp | viewport after window and frame changes, visibility, focus |
| `ui` | stdio, unix | dialogs, pickers, permissions, withdrawn requests, a prompt that waits for the minibuffer, page events, find |
| `reconnect` | unix, tcp | a lost connection, another server process, a second client, server exit |
| `limit` | stdio | a server whose welcome names no `max_views` holds one page: a second page (`c` in command mode) loads in the first |
| `pages` | unix | several pages on one server: a second buffer and view, the shared cookie, a hidden page without frames and a full frame when shown again, `C-c C-s`, a page opened in the background, the limit, killing one page, connecting again to the pages the server kept |
| `popups` | stdio, unix | pages that pages open: a page in the background, told it is hidden, with a message; `C-c C-s` naming its opener; a page that closes its window, the window going back to the opener; one that closes itself at once; a burst stopped by the limit with `popup_blocked`, taking no window; a kept page brought back with its state |
| `hints` | stdio | following links by their labels (`C-c C-o`, `o` in command mode): narrowing, refusal, `DEL`, buttons, links, `C-u`, fields, `C-g`, `<escape>`, `ESC x` on the terminal, wheel and mouse movement, a session the server ends, before or after its labels, a page's question and an alert that waits for a key during the hints, no labels |
| `mouse` | (graphical frame) | clicks, wheel and movement at canvas positions |

A variant is how the mock server is reached: started by the connection on standard
input and output, or started first and listening on a Unix socket or a TCP port.
`lib/ladybird-setup.el` has the helpers, also for a session started by hand:

```sh
uvx elate start --name lady --ui gui --eval-file "$PWD/test/elate/lib/ladybird-setup.el"
uvx elate -s lady eval "(ladybird-elate-start 'stdio)"
```

# ladybird live scenarios

`test/elate/live/scenarios` drives the package against a real Ladybird server, with
pages that the test serves itself.  `test/elate/run-live.sh` (or `make live`) runs
them:

```sh
test/elate/run-live.sh                                   # every scenario, every variant
test/elate/run-live.sh -v stdio test/elate/live/scenarios/live-dialogs.json
LADYBIRD_LIVE_SSH_HOST=devbox LADYBIRD_LIVE_REMOTE_PROGRAM=/opt/ladybird/bin/Ladybird \
    test/elate/run-live.sh -v ssh,forward
```

It prints one line per scenario and variant, `PASS` or `FAIL` with the steps that
failed, and exits non-zero when one failed.  Every scenario runs in a graphical elate
session, because the page has the size of its window in pixels and the mouse acts on
positions of the canvas; the sessions need no screenshot, so a locked screen is fine.
Afterwards the runner stops the sessions, servers and ssh processes of its run and
removes their sockets and temporary files, here and on the remote machine.

A variant says where the server is:

| Variant | Server | Frames |
|---|---|---|
| `stdio` | local, started by the connection | shared memory |
| `socket` | local, listening on a Unix socket (`--emacs-socket`) | shared memory |
| `ssh` | on another machine, started by `ssh HOST PROGRAM --headless=emacs` | in the stream |
| `forward` | on another machine, on a Unix socket that `ssh -L` forwards | in the stream, after the fallback from shared memory |

The local variants are skipped when the local server is missing, the remote ones when
the variables below are unset or the server is not there.

| Variable | Meaning | Default |
|---|---|---|
| `LADYBIRD_LIVE_PROGRAM` | the local server | the build in `/Users/daniel/src/ladybird` |
| `LADYBIRD_LIVE_SSH_HOST` | ssh destination of the remote machine; it must take no password | unset: `ssh` and `forward` are skipped |
| `LADYBIRD_LIVE_REMOTE_PROGRAM` | the server on that machine | unset |
| `LADYBIRD_LIVE_REMOTE_PYTHON` | Python 3 on that machine | `python3` |
| `LADYBIRD_LIVE_PYTHON` | Python 3 here | the first of the usual places |
| `LADYBIRD_LIVE_HOME` | home directory for ssh, whose configuration the sandbox hides | `$HOME` |
| `LADYBIRD_LIVE_LOGS` | where the output of each run goes | a directory under `$TMPDIR` |
| `ELATE` | the elate command | `uvx elate` |

## Pages

The pages are in `live/pages`.  `live/serve.py` serves them over HTTP on the machine
the server runs on, so every server loads `http://127.0.0.1:PORT/PAGE`: for the remote
variants the pages and `serve.py` are copied to a temporary directory there and run
with that machine's Python.  Besides the files it has a page that is slow to arrive, a
download and an icon.

A page reports what it knows in its title as `key=value;key=value` (`live.js`), which
arrives in the buffer's state; the steps read it with `ladybird-live-field`.  What is
drawn is checked on the canvas itself: the pages have blocks of one colour at known
places, and `ladybird-live-color` reads a pixel through the module's test accessor
(`make live` builds that module).

## Scenarios

| Scenario | Covers |
|---|---|
| `live-connect` | first frame's pixels, sizes, buffer name, header line, icon, shared memory or not |
| `live-navigation` | link click, `C-c C-l`, back and forward, reload with and without the cache, zoom with `C-x C-+` and its repeat keys, stop |
| `live-scroll` | the page's own scrolling on the cursor keys, `SPC`, the page keys and the Emacs motion keys; the scroll commands of command mode; wheel; position and pixels |
| `live-keyboard` | page mode: letters, shift, text without a key, function keys, the Emacs editing keys, paste, the motion keys in a textarea, `C-c C-q`; command mode round trip; a field focused by a click, `TAB`, a script after a click and autofocus leaves command mode, with `activation` as expected |
| `live-mouse` | click, double click, drag selection and `M-w`, hover, context menu |
| `live-dialogs` | alert, confirm, prompt, beforeunload, select, file, colour, date, a granted permission |
| `live-permission` | a stray key, dismissal and refusal of a permission; geolocation |
| `live-crash` | a prompt withdrawn by a crash, the crash message, the page coming back |
| `live-find` | counting, stepping, case, the selection left by `C-g` |
| `live-hints` | the list and its labels in the frames, cancelling, a button, a text field from command mode with user activation, a checkbox that takes the focus from it and brings command mode back, a link |
| `live-viewport` | split, frame resize, a growing minibuffer, visibility, focus |
| `live-pages` | two pages on one server painting their own canvases, a cookie set in one and read in the other, `C-c C-s`, a hidden animated page sending no frames and a full frame when shown again, `ladybird-new-page-display` (`selected-window`, `other-window`, `background`), killing a page while it animates, the limit (the server started with `--emacs-max-views=3`), and the pages coming back with `ladybird-connect` (`socket`, `forward`) |
| `live-popups` | pages that pages open (the server started with `--emacs-max-views=3`): a link with `target=_blank` opening a page in the background that sees itself hidden, `C-c C-s`, the page closing its window, `window.open` with `window.opener` reaching the opener, a page closing itself at once, the limit giving `popup_blocked`, a hinted click opening a page |
| `live-events` | console, a popup blocked on a server that holds one page, refused download, clipboard, screenshot |
| `live-socket` | a kept page found again, a second client, a server restart (`socket`, `forward`) |

Every scenario ends with a check that each frame was acknowledged and none dropped.

`live/lib/ladybird-live.el` has the helpers, also for a session started by hand:

```sh
uvx elate start --name live --ui gui --eval-file "$PWD/test/elate/live/lib/ladybird-live.el"
uvx elate -s live eval '(ladybird-live-start "stdio" "form.html")'
```
