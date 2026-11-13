# 04 — The Elisp package `ladybird`

Status: implementation plan v1. The wire protocol in `plans/01-protocol.md` is binding;
message names below are its names. The native module
(`ladybird-module`, planned in `plans/03-*.md`) decodes records and writes pixels; section 3.4
states the module interface this plan assumes, and the module plan wins on conflict.

Reference implementations to copy patterns from, all read-only:

- `/Users/daniel/.emacs.d/lib/rexel/rexel.el` (Rex client): host configuration, dialling,
  redial with backoff, keepalive, prompting from timers, blocking-write lessons.
- `/Users/daniel/.emacs.d/lib/ghostel/lisp/ghostel.el` (terminal): key event decoding
  (`ghostel--event-key-spec`, line 1668), mouse handling (`ghostel--mouse-press`,
  `ghostel--mouse-begin-drag-tracking`, `ghostel--forward-scroll-event`, lines 2140–2280),
  mode-line tag (`ghostel--mode-line-refresh`, line 2442), `ghostel-xterm-paste` (line 1953).
- `/Users/daniel/src/emacs/lisp/xwidget.el`: the browser UX to mirror (`xwidget-webkit-mode-map`
  line 197, `xwidget-webkit-edit-mode` line 994, `xwidget-webkit-isearch-mode` line 1145).
- `/Users/daniel/src/emacs/doc/lispref/display.texi` node "Canvas Images" (line 7484) and
  `/Users/daniel/src/emacs/doc/lispref/internals.texi` "Module Canvas API" (line 2028).

## 1. Scope and non-goals

v1 delivers: connecting to a server over the four transports, one view per buffer (several
buffers = several views, each its own `create_view`), a major mode that sends keys to the
page and a command minor mode, mouse/wheel/keyboard/paste input, viewport tracking, title/favicon/
cursor/link hover, the dialogs and pickers of protocol section 7, find-in-page, history,
zoom, screenshot, console, `browse-url` integration, reconnection with
re-attachment to surviving views, ERT tests, a Python mock server, elate scenarios.

Non-goals for v1: a tabs UI, view source (`request_source` is protocol v2), file
uploads (the file picker returns server-side paths), downloads UI, IME caret placement,
bookmarks, cookies/profile management, `context_menu_action`, TRAMP path translation,
Windows.

## 2. Package layout, options, commands, keymaps

Repo `/Users/daniel/src/dakra/ladybird`, Elisp under `lisp/`:

| File | Contents |
| --- | --- |
| `lisp/ladybird.el` | header (`Package-Requires: ((emacs "32.1"))`, Version 0.1.0), customization, module loading, `ladybird-mode`, `ladybird-command-mode`, buffers/views, rendering, input commands, page UI, `browse-url`. Requires the two files below. |
| `lisp/ladybird-conn.el` | hosts/endpoints, record framing, connection struct and state machine, send/dispatch, keepalive, redial. No buffer knowledge beyond a view-id → buffer table and a handler table. |
| `lisp/ladybird-keys.el` | pure functions: Emacs event → protocol key/mouse/wheel message fields, CSS cursor → pointer symbol. No process or buffer state; fully ERT-testable. |
| `tools/mock-server.py` | protocol mock (section 7). |
| `test/ladybird-keys-test.el`, `test/ladybird-conn-test.el`, `test/ladybird-render-test.el`, `test/ladybird-fake-module.el` | ERT. |
| `test/elate/lib/ladybird-setup.el`, `test/elate/matrix/*.json`, `test/elate/run.sh` | elate scenarios, same layout as `/Users/daniel/.emacs.d/lib/rexel/test/elate/`. |
| `Makefile` | `byte-compile` (warnings are errors), `test`, `checkdoc`, `package-lint`, `mock` (runs the mock server), as `/Users/daniel/.emacs.d/lib/rexel/Makefile`. |

Module loading: `(defcustom ladybird-module-directory ...)` default = directory of
`ladybird.el` (`load-file-name`), `ladybird--load-module` does
`(module-load (expand-file-name "ladybird-module" dir))` trying the extensions in
`module-file-suffix`, is called at load time like `ghostel--load-module`
(`ghostel.el` line 847), failure is a message, and every module call goes through a
`ladybird--module-*` wrapper with `declare-function` so the package byte-compiles without
the module. Without the module a buffer shows the text "ladybird-module not loaded" instead
of a canvas, and tests substitute the fake module.

### 2.1 User options (`defgroup ladybird`)

| Option | Default | Meaning |
| --- | --- | --- |
| `ladybird-program` | `"Ladybird"` | Binary for the local server (`executable-find`), run as `PROGRAM --headless=emacs` (stdio), or by `ladybird-start-server` with `--emacs-default-socket --emacs-background`. |
| `ladybird-program-arguments` | `nil` | Extra arguments for the local and ssh servers. |
| `ladybird-hosts` | `nil` | Alist `(LABEL . ENDPOINT)` or `(LABEL ENDPOINT...)` tried in order; see 3.1 for the endpoint syntax. The local server has label `nil` and is always offered. |
| `ladybird-default-host` | `nil` | Label used without prompting; `nil` = local; `ask` = prompt when several hosts exist. |
| `ladybird-autostart-server` | `ask` | When the local server would be `ladybird-program` over stdio because nothing accepts connections on the default socket and no connection to the local server is open: `t` runs `ladybird-start-server`, `ask` asks with `y-or-n-p`, `nil` (or no, or `ask` in batch Emacs) keeps stdio and says once per connection that its pages end with Emacs. Not consulted for hosts of `ladybird-hosts` or for a redial. |
| `ladybird-ssh-program` | `"ssh"` | with `-T` added. |
| `ladybird-home-url` | `"about:blank"` | URL of `ladybird` without argument. |
| `ladybird-device-pixel-ratio` | `1.0` on NS, else `nil` | `nil` = `(frame-scale-factor)`; a number overrides (1.0 renders in logical pixels, no `:scale` in the spec). On NS `nil` needs an Emacs with the canvas transform patch (03 §7). |
| `ladybird-resize-delay` | `0.05` | Seconds the viewport resize is debounced. |
| `ladybird-hover-interval` | `0.016` | Minimum seconds between `mouse move` messages. |
| `ladybird-track-hover` | `t` | Send mouse moves without a button held (needs `track-mouse`). |
| `ladybird-show-link-hover` | `t` | Hovered link URL in the echo area. |
| `ladybird-header-line` | `t` | Header line with favicon, title and URL. |
| `ladybird-buffer-name-format` | `"*ladybird: %t*"` | `%t` title, `%u` URL, `%h` host label. |
| `ladybird-alert-style` | `echo` | `echo`: alerts are messages and accepted at once; `prompt`: wait for a key. |
| `ladybird-keepalive-interval` | `30` | Idle seconds before a `ping`. |
| `ladybird-ping-timeout` | `10` | Seconds to wait for `pong` (protocol section 2). |
| `ladybird-connect-timeout` | `10` | Seconds a dial or hello may take. |
| `ladybird-reconnect` | `t` | Redial a lost connection with backoff 1, 2, 4 … 30 s. |
| `ladybird-translated-keys` | see 5.3 | Emacs editing and motion keys translated for the server's platform and sent to the page. |
| `ladybird-emacs-keys` | `<f1> <f3> <f4> <f10> <f11>` | Keys the page map leaves to Emacs (help, keyboard macros, menu bar, full screen); they win over `ladybird-translated-keys`. Rebuilds the page map like it. |
| `ladybird-new-page-display` | `selected-window` | Where a page a command opens in a new buffer appears: `selected-window`, `other-window` or `background`; through `display-buffer` (4.6). |
| `ladybird-initial-mode` | `command` | `command`: a new buffer starts in `ladybird-command-mode`; `page`: it sends its keys to the page. |
| `ladybird-field-focus-functions` | `(ladybird-follow-field-focus)` | Hook run with FOCUSED and ACTIVATION when `ladybird--field-focused` changes; the default leaves command mode while a field has the focus. |
| `ladybird-scroll-step` | `nil` | Pixels for `n`/`p`; `nil` = `(frame-char-height)` × 3. |
| `ladybird-console-buffer` | `"*ladybird-console*"` | |
| `ladybird-hint-alphabet` | `"asdfghjkl"` | Characters the server makes hint labels of (protocol §6.1): 2 to 36 different characters of `a`–`z`, `0`–`9`; `ladybird-follow-hint` refuses another value with a `user-error`. |

### 2.2 Commands

| Command | Interactive behavior |
| --- | --- |
| `ladybird` (autoload) | `(ladybird &optional URL HOST)`; prompts URL with `browse-url-interactive-arg` style default; opens a new buffer (new view) on HOST. |
| `ladybird-browse-url` (autoload) | `(url &optional new-session)`; `browse-url` handler (section 6.9). Reuses the most recently used ladybird buffer unless NEW-SESSION. |
| `ladybird-connect` | Dial a host without opening a view (shows existing views as buffers). |
| `ladybird-reconnect` | Redial this buffer's connection now (also after `replaced`). |
| `ladybird-goto-url` (`C-c C-l`; `g` in command mode) | `read-string` with current URL as default → `load`; with a prefix argument the URL opens in a new buffer on the same host. |
| `ladybird-reload` (`C-c C-r`; `r`), `ladybird-reload-bypass-cache` (`R`), `ladybird-stop` (`C-c C-k`; `k`) | `ladybird-reload` bypasses the cache with a prefix argument. |
| `ladybird-back` (`C-c C-b`; `b`), `ladybird-forward` (`C-c C-f`; `f`) | `history` −1/+1; disabled when `can_go_back`/`can_go_forward` is false (`user-error`). |
| `ladybird-scroll-down-line`, `-up-line`, `-down-page`, `-up-page`, `-left`, `-right`, `-top`, `-bottom` (command mode: `n`/`p`, `C-n`/`C-p`, `<down>`/`<up>`, `SPC`/`DEL`/`S-SPC`, `C-v`/`M-v`, `<next>`/`<prior>`, `<left>`/`<right>`, `C-b`/`C-f`, `<`/`>`, `M-<`/`M->`) | Send `mouse wheel` at the canvas center with `dy`/`dx` in device pixels; a page is `(window-body-height win t)` − one line; top/bottom send ±10⁶. Command mode also remaps `scroll-up-command` and the like to them. |
| `ladybird-zoom-adjust` (`[remap text-scale-adjust]`: `C-x C-+`, `C-x C-=`, `C-x C--`, `C-x C-0`) | `zoom` in, out or reset by the last key's base character; a transient map lets `+ = - 0` repeat, as `text-scale-adjust` does. `ladybird-zoom-in` (`+`, `=`), `-out` (`-`), `-reset` (`0`) in command mode. |
| `ladybird-find` (`C-s`), `ladybird-find-backward` (`C-r`) | Section 6.6. |
| `ladybird-switch-to-page` (`C-c C-s`; `s`) | `completing-read` over every page buffer by title and URL, the buffer used last first and the current one last; with several connections an annotation names the host (4.6). |
| `ladybird-follow-hint` (`C-c C-o`; `o` in command mode) | Section 6, item 13. With a prefix argument a chosen link opens in a new buffer. |
| `ladybird-command-mode` (`C-c C-e`, the mode-line tag), `ladybird-page-mode` (`C-c C-j`; `i`, `RET` in command mode) | Single keys are commands, or keys go to the page. |
| `ladybird-send-next-key` (`C-c C-q`, `[remap quoted-insert]`) | Reads one key and sends it untranslated (`read-event` in a graphical frame, `read-key` in a terminal, where an `ESC` read with a key is that key with Meta); a mouse event is put back on `unread-command-events`. |
| `ladybird-focus-next` (`C-c C-n`), `ladybird-focus-previous` (`C-c C-p`) | Send `Tab` / `Shift+Tab`. |
| `ladybird-copy-url` (`C-c C-w`; `w`) | `kill-new` the URL, message it. |
| `ladybird-copy-selection` (`M-w`) | `request_selection` → `kill-new`. |
| `ladybird-yank` (`C-y`, `C-c C-y`) | `paste` with `(current-kill 0)`. |
| `ladybird-select-all` (`C-x h` via `[remap mark-whole-buffer]`) | `edit select_all`. |
| `ladybird-view-source` | v2 (section 6.10); not defined in v1. |
| `ladybird-screenshot` (`S`) | `read-string` server path, `read-multiple-choice` visible/full. |
| `ladybird-toggle-console` (`C-c C-t`) | `set_console`, pops the console buffer. |
| `ladybird-new-buffer` (`c`) | New view on the same host with the current URL (like `xwidget-webkit-clone-and-split-*` without the split). |
| `ladybird-quit` (`q`) | `quit-window`; `Q` = `ladybird-close` (sends `close_view`, kills buffer). |
| `ladybird-detach` (`C-c C-d`; `d`) | Only for a server on a socket (`user-error` for stdio, local or over ssh): `ladybird--disconnect`, then kills the connection's page buffers, which sends no `close_view`; the next `welcome` lists the views. Interactively asks with `y-or-n-p` when more than one buffer would go; refused while the connection is down with views in `closing`. With a prefix argument kills only the current buffer as with `ladybird-keep-view-on-kill`, unless it is the connection's last. `ladybird--disconnect` ends the prompts of the connection's requests. |
| `ladybird-attach` (`C-c C-a`; `a`) | `completing-read` (category `ladybird-page`) over the connection's `kept`, by view id, look-alikes numbered as in `ladybird-switch-to-page`, with a last entry `All N pages` when there are several; `ladybird--restore-kept` for the choice, `ladybird--display-new-page` for the first buffer. The connection is the current page buffer's, else that of `ladybird--host` (with a prefix argument `ladybird--read-host`), both with `ladybird-autostart-server` nil; a host that is not connected and has no socket endpoint is a `user-error` "No server on …". A connection that is not ready is dialled with `ladybird--attach-offer` in `on-ready` (once; a second attach while it waits only says so), trying only its `unix`, `tcp` and `tls` endpoints (`ladybird--connect`'s ONLY); the offer reads the page from `ladybird--later` with the key `(CONN attach)`, so a close for good or a takeover drops it. Such a welcome does not linger. Nothing in `kept` is a `user-error`, after a connect a message. A connection without page buffers before the read and after it, however the read ends, lingers (socket) or is disconnected, as after its last buffer; a lingering timer is cancelled while the page is read. A page that got a buffer meanwhile shows that buffer. |
| `ladybird-kill-buffer-hook` | `kill-buffer-hook`: sends `close_view` unless `ladybird-keep-view-on-kill` (`defcustom`, default `nil`; `t` leaves the view on the server to reappear in the next `welcome`). |

### 2.3 Keymaps

`ladybird-mode` derives from no mode (it is read-only and has the `special` mode class) so
that no inherited single-key binding shadows the page. Three maps, from the highest
priority down:

- `ladybird-command-mode-map`, the keymap of the minor mode `ladybird-command-mode`: the
  single keys and motion keys of command mode, `[remap self-insert-command]` →
  `ladybird-command-mode-self-insert` (a `user-error` saying that `i` sends keys to the page
  again), `i`, `RET`, `<return>` and `<kp-enter>` → `ladybird-page-mode`, `<backspace>` as
  `DEL`. The page map binds the function keys `<return>` and `<backspace>`, and Emacs
  translates a function key to its ASCII key (`RET`, `DEL`) only when nothing binds it,
  so a map that means the ASCII key binds the function key too: the hint map binds
  `<backspace>` and the keypad digits, the zoom repeat map the keypad's `+ - = 0`.
- `ladybird-mode-map`: the commands only — the `C-c` keys of 2.2, `C-y`, `C-s`, `C-r`,
  `M-s n`, `M-s p`, `M-w`, `[remap mark-whole-buffer]`, `[remap text-scale-adjust]`.
- its parent `ladybird--page-map`, built by `ladybird--build-page-map` and rebuilt when
  `ladybird-translated-keys` changes: `[remap self-insert-command]` → `ladybird-send-key`;
  `RET`, `TAB`, `DEL`, `<backtab>` and `S-SPC` (which Emacs would otherwise shift-translate
  to `SPC`); the function keys of 5.3 and every mouse button, click count, drag and wheel
  event in all `C- M- S- s-` combinations; `[mouse-movement]`; `[xterm-paste]`; and
  `ladybird-translated-keys` → `ladybird-send-edit-key`; the keys of `ladybird-emacs-keys`
  are unbound last.

`C-g`, `C-x`, `C-h`, `M-x`, `M-:` and `C-u` are bound by none of them. `C-h m` stays short
because nothing lists the generated bindings: the major mode's docstring is hand-written
with `\\[command]` references (`define-derived-mode` appends `\\{map}` only to a docstring
without `\\[` or `\\{`, and `\\{map}` would list the parent's bindings too), and the minor
mode's docstring ends in `\\{ladybird-command-mode-map}`, which holds only its few keys.
The map-only commands of hints and command mode are declared `(completion ignore)`, so they
appear neither in `M-x` nor among describe-mode's unbound mode commands. The mode line
tag `:Page`/`:Command` toggles the mode when clicked, in the window of the click
(`ladybird-mode-line-toggle` selects `(posn-window (event-start EVENT))`).

`ladybird-hint-map` is in force only while `ladybird-follow-hint` reads a label (section 6,
item 13): every character from `SPC` up → `ladybird-hint-add-char`, `DEL` and
`<backspace>` → `ladybird-hint-delete-char`, `C-g` and `<escape>` → `ladybird-hint-quit`.
`ESC` is not bound, so Meta keys typed on a terminal stay intact.

## 3. Connection layer (`ladybird-conn.el`)

### 3.1 Hosts and endpoints

`ladybird--parse-endpoint STRING` returns a plist `(:kind K ...)` or nil:

| Syntax | Kind | Dial |
| --- | --- | --- |
| `local` or `nil` host | `local` | `make-process :command (list program "--headless=emacs" args…) :connection-type 'pipe :coding 'binary :noquery t :stderr (get-buffer-create " *ladybird-stderr*")`. The server logs to a file (protocol section 1), stderr stays empty but is captured for diagnostics. |
| `ssh:HOST` or `ssh://USER@HOST` | `ssh` | `make-process :command (list ssh "-T" host "exec" program "--headless=emacs" …)`, same options; `ladybird-hosts` may give `(:ssh HOST :program PATH :args LIST)` as the plist form. |
| absolute path, `unix:///path` | `unix` | `make-network-process :family 'local :service PATH :coding 'binary :noquery t`. |
| `tcp://HOST:PORT` | `tcp` | `open-network-stream NAME nil HOST PORT :type 'plain :nowait t :coding 'binary` |
| `tls://HOST:PORT` | `tls` | same with `:type 'tls` (as `rexel--open-network`, `rexel.el` line 262; strip `[]` from IPv6 hosts; a status of `failed` right after the call is an error). |

`ladybird--hosts` returns `((nil ENDPOINT...) (LABEL ENDPOINT...) ...)`; the local entry
has the endpoints of an open (or redialing) connection to the local server over a socket,
else the default socket when a server of this user listens there, else those of an open
connection over stdio, else `local` when `(executable-find ladybird-program)` succeeds,
and is left out otherwise. So the pages that `ladybird`, `ladybird-browse-url` and
`ladybird-connect` open go to a server that appeared on the default socket, while pages
open on a stdio server stay there, and so do the pages opened from them (a new buffer,
a link in a new buffer, a blocked popup, windows the page opens), which use the host of
their buffer. When `ladybird--host` or `ladybird--read-host` picks
that `local` entry and no connection to it is open (neither to the local server nor one
of a configured host with the same endpoints), `ladybird--local-host` applies
`ladybird-autostart-server`: a server
started by `ladybird-start-server` (an async process waited on with
`accept-process-output`, so `C-g` stops only the waiting: the start goes on, and its
sentinel deletes the stderr pipe and reports the outcome; an exit status other than 0 is
an error with the last line of the stderr this start wrote, collected by its own filter,
unless a server accepts connections on the socket afterwards) replaces it with the default
socket. Without the native module it signals an error before asking or starting anything;
in batch Emacs `ask` counts as `nil`. `shm` in `hello` is `t`
only for kind `local` and `unix`; `ssh`, `tcp`, `tls` send `false`. A `unix` endpoint may
be an `ssh -L` forward, so a failing `ladybird-module-set-shm` (or a mapped size below the
`shm` message's `size`) is answered with `shm_failed` (protocol §4.3), not treated as an
error; an endpoint plist with `:shm nil` skips the attempt. Note in the README: over `ssh` stdio the server dies with the ssh session, so
sessions that must survive Emacs need `--emacs-socket` on the remote host and
`ssh -N -o StreamLocalBindUnlink=yes -L /tmp/devbox.sock:/run/user/1000/ladybird.sock devbox`
(the pattern of rexel's README "ssh" section) or the TCP listener on a tailnet.

### 3.2 Data structures

```elisp
(cl-defstruct (ladybird--conn (:constructor ladybird--make-conn))
  host            ; label or nil
  endpoints       ; list of plists from ladybird--parse-endpoint
  endpoint        ; the one that last answered
  untried         ; endpoints left in this dial
  process state   ; state: dialing hello ready redialing closed replaced
  decoder         ; module session (or fake module object)
  encoding shm server-info   ; from welcome
  (views (make-hash-table))  ; view id -> buffer
  (pending (make-hash-table :test #'equal)) ; request id -> callback (selection, source, screenshot)
  (next-request 0)
  on-ready        ; callbacks (lambda (conn)) waiting for ready
  timer delay     ; redial timer and current backoff delay
  hello-timer ping-id ping-timer last-read
  stderr-buffer)
```

Buffer-locals in a view buffer: `ladybird--conn`, `ladybird--view` (integer), `ladybird--canvas`
(image spec), `ladybird--canvas-size` (`(W . H)` device px), `ladybird--requested-size`,
`ladybird--dpr`, `ladybird--state` (last `state` alist), `ladybird--favicon` (image or nil),
`ladybird--cursor` (pointer symbol), `ladybird--hover-url`, `ladybird--buttons` (held buttons
list), `ladybird--last-move` (float-time), `ladybird--resize-timer`, `ladybird--find-string`,
`ladybird--find-result`, `ladybird--pending-frame` (seq awaiting ack), `ladybird--url-at-create`
(for re-creation after server loss).

Global: `ladybird--conns` (list), `ladybird--handlers` (hash `type` string → `(lambda (conn msg))`,
filled with `ladybird--defhandler`), `ladybird--last-buffer` (for `ladybird-browse-url`).

### 3.3 State machine

```
closed --dial--> dialing --process open--> hello (hello sent, hello-timer armed)
hello --welcome--> ready        hello --reject/timeout/close--> try next endpoint, else failed
ready --close/ping timeout--> redialing --timer--> dialing      (if ladybird-reconnect and views exist)
ready --replaced--> replaced    (no redial; ladybird-reconnect command dials again)
any   --ladybird-disconnect--> closed
```

- `ladybird--connect HOST CALLBACK`: find or make the conn (equal endpoints), call CALLBACK
  when ready, else push to `on-ready` and dial (`rexel--connect`, `rexel.el` line 399).
- `ladybird--dial CONN`: tries endpoints in order, last-answered first (`rexel--dial`). For
  `tcp`/`tls` the sentinel's `open` status sends the hello; `local`/`ssh`/`unix` send it at
  once. `hello-timer` = `ladybird-connect-timeout` → `delete-process`, next endpoint.
- `hello` fields: `protocol 1`, `client "ladybird VERSION"`, `viewport` = the selected
  window's body size × dpr (section 4.3), `encodings` = `["zstd","raw"]` always (the
  module vendors zstd), `shm` per 3.1.
- `welcome`: store encoding/shm/server, state `ready` (segments arrive later in `shm`
  messages, 3.5), then for every `views` entry: an existing buffer with that
  `ladybird--view` on this conn is kept, otherwise `ladybird--make-view-buffer` is created
  (not displayed; `(message "ladybird: %d view(s) on %s" …)`). Buffers of this conn whose
  view is not listed (server restarted) get a new `create_view` with their
  `ladybird--url-at-create`/last URL and their old `ladybird--view` is replaced on
  `view_created`. Then run `on-ready` callbacks, send `set_visibility` for every
  buffer (displayed or not), and `set_viewport` for the displayed ones.
- `reject`: message with `reason`, state `closed`, no redial.
- `replaced`: `(message "ladybird: another client took over %s" …)`, state `replaced`,
  buffers keep their last frame, header line shows `[taken over]`.
- Sentinel `ladybird--sentinel`: on `exit`/`failed`/`closed`: if state was `ready` or
  `redialing` and `ladybird-reconnect` and the conn has views → `ladybird--reconnect` (backoff
  like `rexel--reconnect`, `rexel.el` line 460); otherwise closed. ssh exit code 255 is a
  connection failure (redial); another non-zero code from a local/ssh process means the
  server itself exited: message the last lines of the stderr buffer and the exit code,
  redial only if `ladybird-reconnect` is `always` (third value of the option).
- `ladybird--reconnect` doubles `delay` to a maximum of 30 s; the header line of every
  view buffer shows `[reconnecting in Ns]`.

### 3.4 Module interface assumed

**Authoritative definition: `03-emacs-module.md` §2.** The API below is that one,
summarised; the draft of this plan assumed different names (`decoder-create`,
`set-canvas`, `present`, `WRITTEN`), which are superseded.

```elisp
(ladybird-module-create-session)                     ; => SESSION (user-ptr)
(ladybird-module-close SESSION)
(ladybird-module-feed SESSION BYTES &optional NO-REFRESH) ; => list of events, in order
;;   control record: a multibyte JSON string (already UTF-8 decoded)
;;   frame record:   (frame VIEW SEQ FRAME-W FRAME-H DPR DX DY DW DH FULL STATUS)
;;                   STATUS: painted | stored | size-mismatch | stale | bad-frame
;;                           | decode-error | shm-error
;;   framing error:  (desync REASON OFFSET) as last element; session unusable until reset
(ladybird-module-attach-canvas SESSION VIEW CANVAS)  ; replaces a previous attachment
(ladybird-module-detach SESSION VIEW)
(ladybird-module-repaint SESSION VIEW)               ; => painted | size-mismatch | no-canvas | no-frame
(ladybird-module-view-size SESSION VIEW)             ; => (W . H) of the module's backing store
(ladybird-module-set-shm SESSION NAME)               ; NAME nil unmaps
(ladybird-module-reset SESSION)
(ladybird-module-stats SESSION)                      ; plist, see 03 §2.4
```

zstd is always available (the module vendors libzstd), so `hello.encodings` is always
`["zstd","raw"]`. Unless `NO-REFRESH` is given the module itself calls `canvas-refresh`
once per canvas that received a `painted` frame during the `feed` call, so the Elisp
does **not** call `canvas-refresh` per frame; it only sends `frame_ack` for every frame
event whatever its STATUS (protocol §4.2). The module keeps a per-view backing store, so a
frame that arrives before the canvas has the new size is kept: on `size-mismatch` the
Elisp replaces the canvas spec with one of `FRAME-W × FRAME-H` (4.2), attaches it and
calls `ladybird-module-repaint`. JSON is parsed in Elisp with
`(json-parse-string (decode-coding-string s 'utf-8) :object-type 'alist :null-object nil
:false-object nil)` (as `rexel--parse-json`); JSON keys are symbols, so handlers use
`alist-get`.

### 3.5 Read path

`ladybird--filter PROCESS CHUNK` (`ladybird--open-process` let-binds `read-process-output-max`
to 1 MiB and `process-adaptive-read-buffering` to nil around `make-process` /
`make-network-process`; both are captured per process at creation): update `last-read`, then
`(dolist (item (ladybird--module-feed decoder chunk)) (ladybird--handle-item conn item))`.
Each item is handled inside `(condition-case err … (error (message "ladybird: %s: %S" type
err)))`, never `(debug error)` (it enters the debugger under `debug-on-error`, which the
elate sandboxes enable; rexel's CLAUDE.md). A control item is parsed and dispatched by
`(gethash type ladybird--handlers)`; unknown types are ignored (protocol section 1). Handlers
that prompt call `ladybird--later` (3.8). A frame event: send
`(ladybird--send conn `((type . "frame_ack") (view . ,v) (seq . ,seq)))` first, whatever
STATUS is; then on `size-mismatch` or `stored` find the buffer in `views`,
`ladybird--replace-canvas FRAME-W FRAME-H DPR` (4.2), which attaches the new spec, and call
`ladybird-module-repaint`; on `painted` nothing more (the module refreshed the canvas);
`stale`/`bad-frame`/`decode-error`/`shm-error` are counted and logged; a `desync` event
kills the process and redials (3.3). A frame for an unknown view is acked too (so the
server does not stall) and logged. A `shm` control record calls `ladybird-module-set-shm`
with the new name before the frame that uses it is decoded: `feed` stops after a control
record, and the filter keeps calling `(ladybird-module-feed session "")` until it returns nil.
The dispatch handles
`pong` (clears `ping-timer`), `ping` (answers `pong`), `error` (message), `view_created`,
`view_closed`, `state`, `crashed`, and everything in sections 6–7 of the protocol.

### 3.6 Write path

`ladybird--send CONN ALIST`: `(json-serialize alist)` → `(encode-coding-string s 'utf-8)` →
`(concat (ladybird--u32le (1+ (length bytes))) "\1" bytes)` → `process-send-string`. Arrays
must be vectors (`json-serialize`), absent fields are omitted. All messages are under
200 bytes except `paste`/`load_html`/`dialog_closed` text. `process-send-string` blocks
until the socket took everything (8 KiB send buffer on a macOS Unix socket) while running
filters and timers, so a paste never deadlocks against an incoming frame, but code must
not assume a send has returned before a filter ran: a handler may observe state changed by
nested handlers, hence `ladybird--send` is the only writer and no function holds a local
copy of mutable conn state across a send. No write watchdog is needed in v1 (rexel's
`rexel--watched-write` exists for multi-megabyte uploads); `ladybird-ping-timeout` covers a
dead peer. Sends on a conn that is not `ready` are dropped with a message, except input
(mouse/key) which is dropped silently and `frame_ack`.

### 3.7 Keepalive

One global timer `ladybird--keepalive-timer` as `rexel--keepalive` (`rexel.el` line 342):
every conn silent for `ladybird-keepalive-interval` gets `{"type":"ping","id":n}` and a
`ping-timer` of `ladybird-ping-timeout` that, if `last-read` did not advance (after one
`(accept-process-output process 0 nil 1)`), deletes the process → sentinel → redial.

### 3.8 Prompting

A handler never prompts from the filter: `ladybird--later FUNCTION ON-QUIT KEY` queues
`(KEY FUNCTION ON-QUIT)` in `ladybird--queued-prompts` and opens it from a timer, after
`rexel--prompt-later` (`rexel.el` line 848); while the minibuffer is in use without
`enable-recursive-minibuffers` it tries again every 0.2 s. KEY is `(CONN VIEW ID)` of the
request. `ladybird--call-prompt` runs FUNCTION with `use-dialog-box` nil and an
`ladybird--open-prompt` on the stack `ladybird--prompts`, and calls ON-QUIT, which sends
the cancel value (`accepted:false`, `item:null`, `paths:[]`, `outcome:"dismiss"`,
`open:false`), whenever FUNCTION ends without `ladybird--note-answer` for KEY: by `C-g`,
an error or any other exit. `ladybird--answer` notes the answer and sends it. An alert
shown in the echo area is answered at once without a prompt.

`request_cancelled` and `permission_cancelled` (`ladybird--cancel-prompt-later`), and a
connection that closes for good, is taken over or gets a `welcome` again after a redial
(`ladybird--cancel-conn-prompts`; the server sends its open requests again), drop the
prompts of their keys (`ladybird--drop-prompts`): queued ones are forgotten, open ones
send neither their answer nor their decline. The innermost dropped prompt closes from a
timer by throwing to its own entry, the catch tag; one with another prompt inside closes
when that one ends. A prompt has one such timer, and it waits while a minibuffer deeper
than the prompt's own is in use (a command the user runs inside it); an alert read with
`read-key` waits at its own depth (`ladybird--prompt-reads-keys`). Unloading `ladybird` or
`ladybird-conn` while a prompt is open is a `user-error`.

## 4. Rendering (`ladybird.el`)

### 4.1 Buffer content

A view buffer holds exactly one character, `" "`, with text properties `display` =
`ladybird--canvas`, `pointer` = `ladybird--cursor`, `keymap` nil (mouse bindings live in the
mode map), `rear-nonsticky t`, and a trailing `"\n"` with no properties (a buffer ending
in the image makes `C-e`/`end-of-buffer` jump oddly). Mode setup: `buffer-read-only t`,
`cursor-type nil`, `cursor-in-non-selected-windows nil`, `truncate-lines t`,
`line-spacing nil`, `fringe-indicator-alist` all nil, `show-trailing-whitespace nil`,
`(setq-local mode-line-format …)` kept, `header-line-format` per 4.5,
`(setq-local scroll-margin 0)`, `(add-hook 'window-size-change-functions
#'ladybird--window-size-changed nil t)`, `(add-hook 'window-buffer-change-functions
#'ladybird--window-buffer-changed nil t)`, `(add-hook 'kill-buffer-hook #'ladybird--kill nil
t)`, `(add-hook 'window-selection-change-functions #'ladybird--selection-changed nil t)`.
In a terminal frame (`(not (display-graphic-p))`) the buffer shows "ladybird needs a
graphical frame" and skips the canvas; commands still work (so tests can run in TTY).

### 4.2 Canvas spec

```elisp
(defun ladybird--make-canvas (w h dpr)   ; w h in device pixels
  (list 'image :type 'canvas
        :id (intern (format "ladybird-%d-%d" ladybird--view (cl-incf ladybird--canvas-serial)))
        :data-width w :data-height h
        :scale (/ 1.0 dpr) :ascent 100 :margin 0))   ; :scale omitted when dpr is 1
```

`:transform-smoothing nil` selects nearest-neighbour sampling so an integer dpr draws
1 canvas pixel per device pixel (03 §1.2). Whether NS keeps the transform after
`canvas-refresh` is 03's task T0; if it does not and no Emacs patch is applied, the
`ladybird-device-pixel-ratio` 1.0 fallback applies and `:scale`/`:transform-smoothing`
are omitted.

`:id`, `:data-width`, `:data-height` are mandatory and `:data` may be absent (the spec is
zero-filled; `/Users/daniel/src/emacs/src/image.c` `canvas_format` line 5476). `:scale`
is accepted as a generic image keyword (`parse_image_spec` jumps to `maybe_done` for
unknown keys, line 1535) and makes a `W×H` device-pixel canvas occupy `W/dpr × H/dpr`
logical pixels; whether NS draws it crisply at the backing scale is the module plan's
HiDPI question — if it does not, `ladybird-device-pixel-ratio` 1.0 is the fallback and the
whole sizing math below still holds with dpr 1. `:ascent 100` keeps the image line exactly
the image height. The spec object is `eq`-identified by Emacs, so the same list object is
stored in the buffer-local, handed to the module, and passed to `canvas-refresh`.

`ladybird--replace-canvas W H DPR`: build a new spec, `(ladybird-module-attach-canvas session
view spec)`, `(put-text-property 1 2 'display spec)` under `inhibit-read-only`, set
`ladybird--canvas`/`ladybird--canvas-size`, then `(ladybird-module-repaint session view)` so
the module's backing store fills the new canvas. The old spec is dropped; Emacs frees the
canvas when the spec is unreferenced (`canvas_free_unused`). Replacement happens only
when a frame of a new size arrives (3.5: STATUS `size-mismatch` or `stored`), never
speculatively, so the shown canvas always has a matching frame.

### 4.3 Viewport size

For a window `win` showing the buffer: logical size `(window-body-width win t)` ×
`(window-body-height win t)`; dpr = `ladybird-device-pixel-ratio` or
`(frame-scale-factor (window-frame win))` (`/Users/daniel/src/emacs/src/frame.c` line 5065,
NS backing scale, pgtk scale, 1 elsewhere). Device size = `(round (* logical dpr))`.
Several windows: the smallest body width and the smallest body height among them win
(like rexel's `ghostel--desired-size`), so the page fits every window and the larger
windows show margin. `ladybird--desired-size` returns `(W H DPR)` or nil when no window
shows the buffer.

`ladybird--window-size-changed WINDOW` and `ladybird--window-buffer-changed`: cancel
`ladybird--resize-timer`, start one for `ladybird-resize-delay`; it calls
`ladybird--sync-viewport`: compute desired size; if different from `ladybird--requested-size`,
store it and send `set_viewport` with `width height dpr`; also send `set_visibility`
`visible = (get-buffer-window buf 'visible)` when that changed. The next frame carries
the new size and `full` (protocol section 3), and 3.5 replaces the canvas. Until then the
old canvas stays; a window shrunk below the image shows a cropped image for ≤ one frame.
`ladybird--selection-changed` sends `set_focus` with `(eq (selected-window) win)`.

### 4.4 Background, cursor, hover, tooltip

- `background_color`: `(face-remap-set-base 'default :background rgb)` buffer-locally
  stored in `ladybird--bg-cookie`, so margin beyond the canvas matches the page.
- `cursor`: `ladybird-keys-pointer CSS` maps `default auto` → `arrow`, `pointer` → `hand`,
  `text vertical-text` → `text`, `wait progress` → `hourglass`, `ew-resize col-resize
  e-resize w-resize` → `hdrag`, `ns-resize row-resize n-resize s-resize` → `nhdrag`,
  `move all-scroll grab grabbing` → `vdrag`, else `arrow` (values from `display.texi`
  "Pointer Shape"). Applied with `put-text-property 1 2 'pointer`; Emacs updates the shape
  on the next motion.
- `link_hover`: `(message "%s" url)` unless `(active-minibuffer-window)` or `cursor-in-echo-area`;
  `null` clears only if the echo area still shows our URL (compare `(current-message)`).
- `tooltip`: `(tooltip-show text)` when `tooltip-mode`, else echo like a link.

### 4.5 Title, favicon, mode line

`state` handler: store the alist, `rename-buffer (generate-new-buffer-name (format-spec
ladybird-buffer-name-format …))` only when the formatted name changed, `force-mode-line-update`.
Header line (`ladybird-header-line`): `(:eval (ladybird--header-line))` → favicon image (if
any, `(create-image (base64-decode-string png) 'png t :height (frame-char-height)
:ascent 'center)`), title, `" — "`, URL, `[loading]`, `[taken over]`/`[reconnecting in Ns]`.
`mode-line-process` carries the `:Page`/`:Command` tag and `:Loading` as `ghostel--mode-line-refresh`.

`ime` handler: `ladybird--field-focused` is nil without a focused field, `user` once
`activation` was true while the field had the focus, `page` before. When it changes, each
function of `ladybird-field-focus-functions` gets FOCUSED and `activation` through
`run-hook-wrapped`, which reports a function's error and goes on. `ladybird-follow-field-focus`
turns command mode off for a field (`ladybird--enter-field`, which sets
`ladybird--field-page-mode` to t) and on again when no field has the focus. While a field
has the focus, the body of `ladybird-command-mode` sets the flag to `hand` when it turns the
mode on and to t when it turns it off; with no field focused it sets nil.
`ladybird--enter-field` leaves a `hand` mode alone except for a hint, the flag `hand` is
cleared when no field has the focus, and `ladybird-page-mode` acts only in command mode.
The body records a choice only when the mode changes (`ladybird--command-mode-was`). Each
hook function runs in the page buffer, and none after one that kills it; the welcome and
adopt paths go on only with live buffers. `ladybird--forget-view` reports the fields gone to
the hook, except while the buffer is killed. The server sends the current `ime` to a new
client and on `set_focus` true, so a buffer made again for a view learns it.

`favicon` arrives as base64 PNG; decode once per message.

### 4.6 Several pages

Every view is a buffer; the connection maps view ids to buffers. `ladybird--open` makes
the buffer, shows it with `ladybird--display-new-page` (`ladybird-new-page-display`:
`pop-to-buffer-same-window`, `pop-to-buffer` with `inhibit-same-window`, or
`display-buffer-no-window` with `allow-no-window`, so `display-buffer-alist` rules come
first) and sends `create_view` on the connection of the host. Every command that opens a
page in a new buffer goes through it: `ladybird`, `ladybird-new-buffer`, `ladybird-goto-url`
with a prefix argument, `ladybird--follow-link` with a new buffer (hints, context menu),
`ladybird-open-blocked-popup` and `ladybird-browse-url` without a page to reuse.

The limit is `welcome.max_views` (`ladybird--max-views`; 1 when the welcome has none).
`ladybird--view-count` counts the views of the connection's buffers, those of buffers
killed with `ladybird-keep-view-on-kill` or not given one (the connection's `kept`; the
next welcome keeps the entries it lists, unless another server process answers) and the
`create_view`s not yet answered. At the limit
`ladybird--open` asks for nothing: a server that holds one page loads the URL in it
(`ladybird--load-in-page`), any other is refused with a `user-error` that names the limit.
An `error` answering a `create_view` kills the new buffer; only on a one-page server does
it load the URL in the page there is.

Visibility is per view: `ladybird--sync-viewport` sends `set_visibility` whenever whether
a window on a visible frame shows the buffer changes, from `ladybird--update`, which
`window-size-change-functions` and `window-selection-change-functions` (buffer-local),
the global `window-buffer-change-functions` (a window that stops showing a page runs the
hooks of the buffer it shows now), `delete-frame-functions` and the special events
`iconify-frame` and `make-frame-visible` (bound in `special-event-map`, the binding they
had run after; a window system sends them, NS included; a terminal has no iconified
frames) schedule. A new view and every view after a welcome starts at `unknown`, so it
is told at once; after a welcome from the timer the welcome sets, so that
`ladybird-connect` has shown its page and every view is told once. Each buffer counts
the frames it painted and the full ones among them (`ladybird--frame-count`,
`ladybird--full-frame-count`); the module's stats count frames per session only.

A welcome gives every listed view that has neither a buffer nor a `kept` entry a new one,
with its state, and says how many pages it found; a listed view in `kept` stays there
with the welcome's state. When every function in the connection's `on-ready` is
`ladybird--attach-offer`, the new views go to `kept` instead. The welcome sends
`set_visibility` false and `set_focus` false for every view in `kept`. `ladybird-connect` shows the page buffer used last if it is one
of the connection's, else the one with the lowest view id (the welcome does not say which
view was used last), and says how many pages the server has. Closing the last page of a
socket connection says that the server keeps running, with how many pages it kept; the
protocol has no message that stops a server.

Views opened by pages (protocol §3.1): the hello says `"popups": true`. A `view_created`
with `opener` answers no request; `ladybird--page-opened` makes a buffer for the view
on the opener's connection and host (`ladybird--make-view-buffer`), records the opener's
view id in `ladybird--opener` and shows the buffer with `display-buffer`, the action
`display-buffer-no-window` with `allow-no-window` and the category `ladybird-popup`:
in no window unless a rule of `display-buffer-alist` says otherwise, and never selected,
so pages that open one on every click take no window and no focus; the server's limit
bounds how many there are, and each is one line in the echo area. The buffer is
synced at once (`ladybird--sync-viewport`, `ladybird--sync-focus`), so a page in no
window is told it is hidden before it renders more than its first frame. The message
names the opener and says that `C-c C-s` gets there; the page is named only when
`view_created` has a URL other than `about:blank`, which the protocol does not promise.
`ladybird-switch-to-page` annotates such a page with its opener's name while the opener
is open. `ladybird-new-page-display` is for pages that commands open.
`view_closed` kills the buffer of any view the server closed, with a message unless the
reason is `client` or the page was closed before it had a URL (a window whose first
navigation was a download, whose `error` the server sends first), after quitting each
window that showed it with `quit-restore-window` inside `save-selected-window`: a window
made for the page is deleted, one that showed another buffer before shows it again (the
opener, when the page was reached from there with `C-c C-s`), and the selected window
stays selected unless it was deleted. `display-buffer` runs inside `unwind-protect`, so
the view is told its visibility also when a rule's action fails.
A `popup_blocked` remembers its URL for `ladybird-open-blocked-popup`, and its message
says what that command will do: open a new page, load the URL in the page of a
one-page server, or nothing on a server that holds all its pages. One with a null `url`
is reported and remembers nothing.

A view kept for a killed buffer on a connection that stays up (`kept`, an alist of view
and its last `state`) counts against the limit, and the refusal says how many of the
pages are such. `state` messages for it update the kept state, `view_closed` drops it.
`ladybird--restore-kept` gives such views buffers again: `ladybird-connect` on the open
connection does it for all, `ladybird-switch-to-page` offers them among the pages and
does it for the one chosen, and so does `ladybird-attach` (2.2). The buffer has the kept state and gets its frame once a
window shows it (`set_visibility`, then a full frame).

Page strings shown in Emacs pass `ladybird--clean`, which turns line breaks and tabs
into spaces and drops other control characters and the bidirectional formatting
characters (U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069): buffer names, the
header line, everything cut to the echo area (`ladybird--echo-line`: hints, hovered
links, tooltips, external URLs), dialog texts and origins, select labels and the
candidates of `ladybird-switch-to-page`, whose titles are cut to 60 columns and URLs
kept whole. The console buffer shows console output as it came.

`ladybird-unload-function` (and `ladybird-conn-unload-function`) close the pages and
connections, cancel the package's timers and take back the global hooks
(`post-command-hook`, `window-buffer-change-functions`, `delete-frame-functions`,
`pre-command-hook`, `minibuffer-setup-hook`), the `after-focus-change-function` advice,
the `emulation-mode-map-alists` entry of hints, the `special-event-map` bindings and the
mouse tracking.

Tried against the Ladybird server on macOS and Linux over stdio, a socket, ssh and a
forwarded socket (`live-pages`, the server started with `--emacs-max-views=3`): two
pages painting their own canvases, a shared cookie, `C-c C-s` (a part of a URL completes,
through the completion category `ladybird-page` with the `substring` style), a hidden
animated page sending no frames while the shown one does and a full frame when shown
again, `ladybird-new-page-display` with `selected-window`, `other-window` and
`background`, closing a page while it animates, the limit, and reattaching to the pages
a socket server kept. Views that were visible before the reconnect send a full frame
right after the welcome; pages the client hid, such as those of buffers killed with
`ladybird-keep-view-on-kill`, send one when a window shows them again. Pages that pages
open are tried on the same servers and connections (`live-popups`, again with
`--emacs-max-views=3`): a link with `target=_blank`, `window.open` with `window.opener`
reaching the opener, a page closing its window or itself, the limit giving
`popup_blocked`, and a hinted click.

## 5. Input (`ladybird-keys.el` + bindings in `ladybird.el`)

### 5.1 Mouse

Bindings in `ladybird-mode-map` for N in 1 2 3 (and 8 9 → `back`/`forward` where Emacs
reports them) and every modifier prefix combination `C- M- S- s-`:
`<down-mouse-N>` → `ladybird-mouse-down`, `<mouse-N>` and `<drag-mouse-N>` →
`ladybird-mouse-up`, `<double-down-mouse-N>`/`<triple-down-mouse-N>` → `ladybird-mouse-down`
(with `(event-click-count event)` → `clicks` 2/3), `<double-mouse-N>` etc. → `ladybird-mouse-up`,
`[mouse-movement]` → `ladybird-mouse-move`. Button map: `mouse-1` left, `mouse-2` middle,
`mouse-3` right, `mouse-8` back, `mouse-9` forward (`ladybird-keys-button`).

Coordinates: `(posn-object-x-y (event-start event))` are pixels relative to the image's
top-left (`display.texi`/`commands.texi` line 3129; the canvas is one object), already in
logical pixels; device `x = (round (* dx ladybird--dpr))`. For `up` events use
`(event-end event)`. A posn whose `posn-window` is not a window showing this buffer, or
whose `posn-object` is nil (margin area), is clamped to the canvas edge for `up` and
ignored for `down`. Modifiers via `ladybird-keys-modifiers (event-modifiers event)` →
shift 1, control 2, meta/alt 4, super 8 (hyper ignored).

`ladybird-mouse-down`: `(select-window (posn-window …))`, push the button on
`ladybird--buttons`, send `mouse down` with `button`, `buttons` (vector of held), `clicks`;
then arm drag tracking like `ghostel--mouse-begin-drag-tracking` (`ghostel.el` line 2203):
`(setq track-mouse 'dragging)` and `set-transient-map` of a map binding `[mouse-movement]`
→ `ladybird-mouse-move`, kept while `this-command` is `ladybird-mouse-move`, restoring
`track-mouse` in the exit function. `ladybird-mouse-up`: remove the button, send `up` with
the end posn. `ladybird-mouse-move`: throttle by `ladybird-hover-interval` using
`ladybird--last-move` (always send the last one: a 0-delay timer when throttled), send
`move` with `buttons`; when the posn leaves the canvas send `leave` once.

Hover without a button (`ladybird-track-hover`): Emacs generates `mouse-movement` only while
`track-mouse` is non-nil and, over a single glyph, only with `mouse-fine-grained-tracking`
(`commands.texi` line 2056). `ladybird--selection-changed` sets both globally when a ladybird
window becomes selected and restores the saved values when the selected window shows
another buffer; the global map already binds `[mouse-movement]` to
`ignore-preserving-kill-region` (`bindings.el` line 1596), so motion over other buffers
is harmless. `ladybird-mouse-move` sends `leave` when the event's window shows another
buffer. Focus-out (`after-focus-change-function`) sends `leave` and clears `ladybird--buttons`.

### 5.2 Wheel

Bindings: `<wheel-up> <wheel-down> <wheel-left> <wheel-right>` with every modifier prefix,
plus `<mouse-4..7>` for X11 → `ladybird-wheel`. Event shape `(wheel-up POSN CLICKS LINES
(X . Y))` (`commands.texi` line 2600; verified in
`/Users/daniel/.claude/projects/-Users-daniel--emacs-d-lib-ghostel/memory/reference_elate_wheel_event_injection.md`).
`ladybird-keys-wheel-delta EVENT LINE-HEIGHT` returns `(DX . DY)` in logical pixels:

- with pixel delta `(nth 4 event)`: NS reports positive Y when the content should move
  down (`nsterm.m` line 7884 `scrollUp = totalDeltaY > 0`), the protocol's positive `dy`
  scrolls the content down (page moves up) → `dy = (- y)`, `dx = (- x)`. The pixel delta is
  present on NS whether or not `mwheel-coalesce-scroll-events` is set (`emacs_event->arg
  = list3 (lines, x, y)` line 7942), and under `pixel-scroll-precision-mode` every tick is
  its own event.
- without it: `lines = (or (nth 3 event) 3)`, `dy = ± lines × line-height` with the sign
  from the event type (`wheel-up`/`mouse-4` → negative), `wheel-left`/`mouse-6` → `dx`
  negative. `mouse-wheel-flip-direction` is honored for horizontal.

The command multiplies by `ladybird--dpr`, rounds, and sends `mouse wheel` at the posn
coordinates with `modifiers`. A ladybird buffer's local map wins over `pixel-scroll-precision-mode`'s
global bindings, so no `emulation-mode-map-alists` intercept is needed.

### 5.3 Keys

`ladybird-keys-event EVENT` → `(KEY CODE-POINT MODIFIERS)` or `(text STRING)` or nil, pure:

1. `base = (event-basic-type event)`, `mods = (event-modifiers event)`; drop `click`/`down`.
   As in `ghostel--event-key-spec`, `?\r ?\t ?\e` events are `Return`/`Tab`/`Escape` with
   `control` removed; 127 is `Backspace`; `backtab` is `Tab` + shift.
2. Letters: `base` `?a..?z` → KEY `"A".."Z"`; code point = the event char when the event is
   a character (so `?A` for shifted), else the base char (lowercase) for chords, which is
   what `TerminalInputParser.cpp` line 424 sends for Ctrl+letter. Digits → `"0".."9"`.
   ASCII punctuation → enumerator via the table `ladybird-keys--punctuation`:
   `) RightParen ! ExclamationPoint @ AtSign # Hashtag $ Dollar % Percent ^ Circumflex
   & Ampersand * Asterisk ( LeftParen + Plus - Minus / Slash , Comma . Period : Colon
   " DoubleQuote ' Apostrophe ; Semicolon < LessThan = Equal > GreaterThan ? QuestionMark
   [ LeftBracket ] RightBracket \ Backslash _ Underscore { LeftBrace } RightBrace
   | Pipe ~ Tilde ` Backtick SPC Space` (from `/Users/daniel/src/ladybird/Libraries/LibWebCommon/UIEvents/KeyCode.h`
   `ENUMERATE_KEY_CODES`). A shifted punctuation reaches Emacs as the final character with
   no shift modifier (`?!`), so KEY `ExclamationPoint`, code point 33, modifiers 0, as the
   Qt frontend does (`UI/Qt/WebContentView.cpp` line 680).
3. Any other character (non-ASCII, `é`, CJK, emoji) without control/meta/super → `(text
   STRING)`: sent as a `text` message, the IME-commit path.
4. Symbols: `return kp-enter → Return 10` (protocol §5: Ladybird's terminal frontend sends
   `\n`, not 13), `tab → Tab 9`, `backspace → Backspace 8`,
   `delete deletechar → Delete 127`, `escape → Escape 27`, `left right up down home end`,
   `prior → PageUp`, `next → PageDown`, `insert`, `f1..f12`, `print → PrintScreen`,
   `pause → PauseBreak`, `menu → Menu`, `capslock → CapsLock`, `scroll → ScrollLock`,
   `kp-N → "N"` with code point, `kp-add Plus`, `kp-subtract Minus`, `kp-multiply Asterisk`,
   `kp-divide Slash`, `kp-decimal Period`, `kp-left…kp-end → Left… End`, `kp-space Space`.
   Modifier-only symbols (`lshift` etc.) and media keys → nil (nothing sent; protocol
   says a held modifier sends nothing).
5. Modifiers: shift 1, control 2, meta 4 (Emacs `meta`, which is Option under the default
   `ns-alternate-modifier`), super 8 (Command), keypad 16 for every `kp-*` event (protocol
   §5, Ladybird's `Mod_Keypad`). `alt` (Emacs's own alt) → 4 too. Hyper is dropped.

`ladybird--send-key SPEC` sends `key down` (`repeat false`) immediately followed by `key up`
with the same fields (protocol section 5), or a `text` message. `ladybird-send-key` is the
command of the page keys: it repeats the key by its numeric prefix argument and uses
`last-command-event` with the
`xwidget-webkit-pass-command-event` input-method dance (`xwidget.el` line 171) so Quail
input methods yield `text`. TTY meta via `ESC x` is detected with
`this-single-command-keys`, which leaves out the keys of a prefix argument.

**Page-key rule.** A key reaches the page when its global binding is
`self-insert-command` (through the page map's remap), or it is `RET TAB DEL <backtab>
S-SPC`, or it is in the set `[return tab backspace delete escape insert left right up down
home end prior next f1…f12 kp-*]` in every `C- M- S- s-` combination (built with a loop, no
hand list), or it is in `ladybird-translated-keys` (default `C-a C-e C-k C-d M-b M-f M-d
M-DEL M-<backspace> C-<backspace> C-z C-/ C-_ C-? C-n C-p C-b C-f C-v M-v M-< M->`; set to
nil to keep them all for Emacs). These are not sent raw (Ladybird ignores Ctrl+A/E/K/D and
types the letter of an Alt chord): `ladybird-keys-editing EVENT PLATFORM` translates each
for the server's `welcome.host.platform`: `C-a`/`C-e` → Home/End, `C-d` → Delete, `C-k` →
Shift+End then Delete, `M-b`/`M-f` → Alt+Left/Right on macOS and Ctrl+Left/Right elsewhere,
`M-d` → Alt/Ctrl+Delete, `M-DEL` `M-<backspace>` `C-<backspace>` → Alt/Ctrl+Backspace,
`C-z` `C-/` `C-_` → `edit undo`, `C-?` → `edit redo`, `C-n C-p C-b C-f` → the cursor keys,
`C-v`/`M-v` → PageDown/PageUp, `M-<`/`M->` → Command+Up/Down on macOS and Ctrl+Home/End
elsewhere. A key in the option without a table entry is sent raw. Ladybird scrolls the page
itself on the cursor keys, `Space`, PageUp/PageDown and Home/End when no field has the
focus (`EventHandler::handle_keydown`), so the client needs no fallback; in a field the
same keys move the caret, Ctrl+Home/End (and Command+Up/Down on macOS) reach the field's
ends, and plain PageUp/PageDown still scroll. Tried against the macOS and the Linux server
(`live-scroll`, `live-keyboard`). Everything else, in particular `C-g C-x C-c M-x M-: C-h
C-u C-l C-s C-r` and all `C-c …` sequences, keeps its Emacs meaning; `C-y` yanks into the
page and `M-w` copies the page selection. `C-g` is never forwarded: `Escape` is the page's
cancel key and reaches it in a GUI frame via `[escape]`; `C-c C-q` sends any key as it is.
In command mode the single keys are commands; another self-inserting key signals the
`user-error` of `ladybird-command-mode-self-insert`.

Paste: `ladybird-yank` → `paste` with `(current-kill 0)`; `ladybird-xterm-paste` bound to
`<xterm-paste>` in the page map extracts `(nth 1 event)` like `ghostel-xterm-paste` and sends
`paste`. `yank-media` registers no handler in v1 (no uploads); the mode sets
`yank-media-preferred-types` untouched.

## 6. Page UI (`ladybird.el`)

All handlers below run via `ladybird--later` with an `on-quit` that cancels (3.8).

1. `dialog`: `alert` → `ladybird-alert-style` `echo`: `(message "%s: %s" title message)` and
   `dialog_closed accepted:true` at once; `prompt`: `(read-key …)` then accept. `confirm`,
   `beforeunload` → `(y-or-n-p (format "%s — OK? " message))` → `accepted`. `prompt` →
   `(read-string (concat message ": ") default)` → `accepted:true text`.
2. `select`: `completing-read` over labels; items with `disabled` are excluded; `group`
   becomes a prefix `"GROUP / LABEL"` via `completion-extra-properties`'s `:annotation-function`;
   initial input is the `selected` item's label; `select_closed item` = that id, cancel →
   `null`. `x y min_width` are ignored (minibuffer, not a popup).
3. `file_picker`: for hosts of kind `local`/`unix` → `read-file-name` (with
   `completing-read-multiple` over repeated `read-file-name` when `multiple`), paths
   expanded and sent as `paths`; for remote kinds → `read-string "Path on HOST: "` with a
   prompt noting the server's filesystem (TRAMP-based completion `/ssh:HOST:` is v2).
4. `color_picker` → `read-color` → `#rrggbb`. `date_picker` → `read-string` with `value`
   as default; no validation beyond non-empty.
5. `permission` → `ladybird--read-answer` with the choices `allow once`, `allow always`,
   `deny` → `allow_once`/`allow_always`/`deny`; empty input or quit → `dismiss`;
   `permission_cancelled` closes the prompt (protocol §7). `ladybird--read-answer` is
   `completing-read` without require-match after `discard-input`: only a choice typed or
   completed in full is taken, and any other non-empty input asks again (with
   `discard-input` again), since keys typed for the page can arrive while it is open. An
   extra time window that ignores keys after the prompt opens is not used: a full word
   followed by `RET` is needed, and a window would delay a deliberate answer without
   stopping slower stray typing.
6. `external_url` → `ladybird--read-answer` with `open on server`, `open here` (http,
   https and mailto only), `deny`: `open:true`, or `open:false` plus local `browse-url`
   with `browse-url-secondary-browser-function`, or `open:false`.
7. `context_menu`: `popup-menu` (`x-popup-menu` at the mouse position) of a keymap built per
   message: with `link_url`: Open Link, Open Link in New Buffer, Copy Link; with
   `image_url`: Open Image, Copy Image URL; with `media_url`: Copy Media URL; with
   `selection`: Copy, Search Selection (`load` with the text); with `editable`: Paste, Cut,
   Select All, Undo, Redo (`edit` ops / `paste`); always: Back, Forward, Reload. `context_menu` has no `id`, so nothing is answered.
8. `ladybird-find`: a minibuffer-driven incremental search modeled on
   `xwidget-webkit-isearch-mode` but using `read-from-minibuffer` with a local keymap:
   `C-s`/`C-r` → `find_step next/previous`, `RET` exits keeping highlights, `C-g` ends
   (`find` with `""`). A `minibuffer-setup-hook` adds an `after-change-functions` entry that
   debounces 0.1 s and sends `find query case_sensitive:(let ((case-fold-search …)))
   highlight_all:true`. `find_result` → `(minibuffer-message " [%d/%d]" index total)` when
   the minibuffer is active, else `message`. `ladybird-find-next`/`-previous` (`M-s n`/`M-s p`)
   step after exit.
9. `browse-url`: `ladybird-browse-url` with `(function-put 'ladybird-browse-url
   'browse-url-browser-kind 'internal)`; README example
   `(setq browse-url-browser-function #'ladybird-browse-url)` and
   `(add-to-list 'browse-url-handlers '("\\`https?://.*\\.internal/" . ladybird-browse-url))`.
   Host choice: `ladybird-default-host`; v2: a `browse-url` from a TRAMP buffer picks the host
   whose `ladybird-hosts` entry has `:tramp-host` equal to `(file-remote-p default-directory 'host)`.
10. `ladybird-view-source` (**v2**, `request_source` is not in protocol v1; keep the command
    unbound until then): `request_source` with a request id in `pending`; the `source`
    reply opens `*ladybird-source: URL*` in `mhtml-mode` (or `html-mode`) read-only.
11. `selection` reply → `kill-new` + message; `screenshot_saved` → message with path;
    `console` → append `[level] text` to `ladybird-console-buffer` (`special-mode`).
12. `popup_blocked`: a "Popup blocked: URL" message (see 4.6); `ladybird-open-blocked-popup`
    opens the last blocked URL in a new buffer. `clipboard` → `kill-new`.
    `view_closed`/`crashed`: `crashed` is a message (the view keeps working);
    `view_closed` with reason `closed`/`crashed` quits the windows of the buffer and kills
    it after a message (`closed`: "was closed by its page"), `client` is our own close.
13. `ladybird-follow-hint` (protocol §6.1) is not a prompt of `ladybird--later`: the page
    draws the labels into its frames, so nothing may hold up the process filter while the
    user types, and the client draws nothing.
    - It needs `"hints"` in `welcome.features` (a `user-error` otherwise, nothing sent) and
      a valid `ladybird-hint-alphabet`. It ends a session in progress (`hints_end` null),
      takes the next id of the connection's request counter (a non-negative integer, as the
      protocol requires), sends `hints` and returns. The server ends a replaced session
      silently, so the old one gets its `hints_end` null from the client first.
    - The session is the global `ladybird--hint`, a `ladybird--hint` struct (connection,
      view, buffer, id, alphabet, the prefix typed, the items once they arrive,
      `truncated`, whether a link opens in a new buffer). `ladybird-hint-map` is in force
      through `emulation-mode-map-alists`, keyed on `ladybird--hint`: exactly while a
      session exists, whatever binds `overriding-terminal-local-map` meanwhile, and above
      the command mode's and the major mode's maps. `ladybird--hint-pre-command` on
      `pre-command-hook` keeps the session for the map's own commands and for
      `mouse-movement`; any other command ends it (`hints_end` null) and then runs as
      usual, so a click, the wheel, `C-x b` or `C-c C-o` do what they do. The command
      returns at once, the filter keeps feeding frames to the module, and no recursive
      edit or minibuffer is open.
    - A command of the map that finds no session drops its key. One that finds the
      selected window showing another buffer ends the session and puts the key back on
      `unread-command-events`, with the map already out of force.
    - `hints_list` is checked: `items` an array of objects with an integer `index`, a
      `label` of characters of the session's alphabet, and a `kind`, `text` and `url`
      that are strings or null. Another list ends the session with `hints_end` null and
      "the page sent unusable hints". An empty `items` ends it with "No hints in view"
      and sends nothing. A `hints_list` whose connection, view or id is not the session's,
      or that comes a second time, is ignored.
    - Characters typed before the labels arrive are kept and taken up in order from a
      timer, so a label they complete is activated outside the process filter. Each
      character then either is refused (`ding`, nothing sent, nothing changes: no
      remaining label has the longer prefix; upper case is taken as lower case),
      completes a label (session ends, `hints_end` with the item's `index`), or narrows
      (`hints_narrow` with the whole prefix). `DEL` sends the shorter prefix, the empty
      string included.
    - The echo area shows `Hint: PREFIX  [N left]` (`, more not labelled` when
      `truncated`), the text or URL of a single remaining item, and `Hint (new buffer):`
      with a prefix argument; it is cut to one line. While a session lasts
      `ladybird--echo-free-p` is nil, so hover and find messages leave it alone.
    - A chosen `"link"` with a URL and a prefix argument: `hints_end` with null, then
      `ladybird--follow-link`, which opens http and https URLs, and file URLs from a page
      whose own URL is a file URL, in a new buffer on the buffer's host, and refuses
      others with "ladybird: not opening URL". The context menu's "Open Link" and "Open
      Link in New Buffer" go through it too. A chosen `"input"` turns
      `ladybird-command-mode` off after `hints_end`, also when it was switched on by hand
      in a field.
    - The session ends, sending nothing: on `hints_cancelled` naming its view and id,
      also while it waits for the labels ("The page ended the hint session"; dialog
      prompts are not touched, and `request_cancelled` does not end a session); on an
      `error` naming its view and id, whose message is shown; and when the connection
      leaves the `ready` state (`ladybird--on-conn-change`). It ends as well when its
      buffer is killed (`hints_end` null before `close_view`) or loses its view
      (`ladybird--forget-view`; nothing sent), and when a minibuffer opens
      (`minibuffer-setup-hook`, `hints_end` null), so a page's prompt never reads keys
      through the map.
    - The connection keeps the view and id of the 16 sessions that ended last
      (`hints-ended`); an `error` with one of them answers a `hints_narrow` or
      `hints_end` that crossed the end and is ignored. An `error` with another id or none
      is reported like any other.

## 7. Tasks in dependency order

Each task names files, functions and acceptance tests. Tasks marked ∥ can run in parallel
with the others in the same group once their dependencies are done. Sizes: S ≈ 100 lines,
M ≈ 300, L ≈ 600 of code plus tests.

**Group A (no dependencies, all ∥)**

- **A1 Framing, endpoints, hosts** (`lisp/ladybird-conn.el`, S): `ladybird--u32le`,
  `ladybird--encode-record KIND PAYLOAD`, `ladybird--parse-endpoint`, `ladybird--hosts`,
  `ladybird--shm-p ENDPOINT`. ERT `test/ladybird-conn-test.el`: round trip of a record header;
  every endpoint syntax of 3.1 incl. IPv6 `tls://[::1]:9000`, `unix:///a%20b` unhex,
  rejected forms; `ladybird--hosts` with `ladybird-program` unresolvable omits local.
- **A2 Key table** (`lisp/ladybird-keys.el`, M): `ladybird-keys-event`, `ladybird-keys-modifiers`,
  `ladybird-keys-button`, `ladybird-keys-wheel-delta`, `ladybird-keys-pointer`,
  `ladybird-keys--punctuation`. ERT `test/ladybird-keys-test.el`: `?a` → `("A" 97 0)`, `?A` →
  `("A" 65 1)`, `?\C-a` → `("A" 97 2)`, `?!` → `("ExclamationPoint" 33 0)`, `?é` →
  `(text "é")`, `'return`/`?\r` → `("Return" 10 0)`, `'C-M-left` → `("Left" 0 6)`,
  `'kp-7` → `("7" 55 16)`, `'backtab` → `("Tab" 9 1)`, `'lshift` → nil; `'s-mouse-1` → `left`
  with 8; wheel: synthetic `(wheel-up POSN 1 1 (0.0 . 24.0))` → `(0 . -24)`, `(wheel-down
  POSN 1 2 nil)` with line height 16 → `(0 . 32)`, `wheel-left` sign; pointer map
  `"pointer"` → `hand`, unknown → `arrow`.
- **A3 Fake module** (`test/ladybird-fake-module.el`, M): pure Elisp implementation of 3.4
  using `bindat` for the record and frame headers, raw encoding only, records counted in
  `ladybird-fake-module-frames`; chunk splitting across record boundaries. ERT: a control
  record split over three chunks yields one item; a frame record followed by a control
  record in one chunk yields two items in order; a frame whose size differs from the
  attached canvas yields STATUS `size-mismatch` (or `stored` with no canvas) and
  `ladybird-module-repaint` returns `painted` after attaching a matching canvas. The fake
  implements the names of 3.4 (`create-session`, `feed`, `attach-canvas`, `repaint`,
  `set-shm` as a no-op, `stats`) so `test/` can swap it for the real module.
- **A4 Mock server** (`tools/mock-server.py`, M): Python 3.11 stdlib only, built on
  `tools/ladybird_protocol.py` (framing, pixel formula, zstd, PNG; 05 §1–2). Flags: `--stdio` (default), `--socket PATH`,
  `--tcp HOST:PORT`, `--views N` (pre-existing views in `welcome`, default 0), `--fps F`
  (frames per second of a moving gradient, default 10; 0 = only on change), `--log FILE`
  (JSON lines of every received control message plus `{"type":"_frame_sent",...}`),
  `--no-pong`, `--exit-after SECONDS`, `--reject`, `--zstd`; `mock://` URLs (loading `mock://alert`,
  `mock://confirm`, `mock://prompt`, `mock://select`, `mock://file`, `mock://permission`,
  `mock://external`, `mock://context` emits the matching request; `mock://popup` opens a
  view with `opener` for a client whose hello had `"popups": true` while there is room,
  else emits `popup_blocked`; `mock://crash` emits `crashed`). Behavior: records per
  protocol; `hello` → `welcome` (`encoding` raw unless `--zstd` and offered; never `shm`),
  then per view `state` + full frame; `create_view` → `view_created`, `state`, frame;
  `set_viewport` → full frame of the new size; `mouse down` paints a 24-px square at
  `(x,y)` in the gradient (so a screenshot proves coordinate mapping), `wheel` shifts the
  gradient by `dy`; `key down` appends the key name to a text line drawn as blocks
  (fixed 5×7 bitmap font for ASCII; unknown glyphs as boxes); `load` → `state` with the URL
  and title `"Mock: URL"`, `loading` true then false after 0.2 s; `history` toggles
  `can_go_back`; `zoom` changes `zoom`; `find` → `find_result` counting occurrences of the
  query in the URL; `request_selection` answers canned text; `edit cut` answers
  `clipboard`;
  `screenshot` writes a PNG at `path`; `ping` → `pong`; one frame in flight per view with
  damage-union coalescing; a second client on the socket/tcp listener → `replaced` to the
  first. Test: `python3 -I tools/mock-server.py --selftest` runs an in-process client
  through hello, create_view, three frames and acks.

**Group B (needs A1, A3)**

- **B1 Connection state machine** (`lisp/ladybird-conn.el`, L): `ladybird--make-conn`,
  `ladybird--connect`, `ladybird--dial`, `ladybird--open-process ENDPOINT`, `ladybird--send-hello`,
  `ladybird--filter`, `ladybird--sentinel`, `ladybird--handle-item`, `ladybird--defhandler`,
  `ladybird--send`, `ladybird--request CONN TYPE FIELDS CALLBACK` (allocates `request`),
  `ladybird--keepalive`, `ladybird--probe`, `ladybird--reconnect`, `ladybird--disconnect`,
  `ladybird--later`. ERT with the fake module and `ladybird--open-process` stubbed by `cl-letf`
  to a pipe process (`make-pipe-process`) or a recording function; timers run by hand
  (`timer-event-handler`): hello is the first bytes written; `welcome` → `ready` and
  callbacks; `reject` → closed; `pong` clears the probe; a probe without pong deletes the
  process; redial backoff sequence 1 2 4 8 16 30 30; `replaced` stops redialing; a
  `frame` item acks with the right `seq` even for an unknown view; a handler error is
  messaged and the next item still dispatched; a request callback fires once and is removed.
  Mock-server test (`make test-mock`, skipped when `python3` is missing): dial
  `--stdio` via `make-process`, reach `ready`, receive a `state` and a frame with the
  fake module replaced by the real module when present.

**Group C (needs B1; C1 before C2–C4; C2–C4 ∥)**

- **C1 Buffers, mode, canvas, sizing** (`lisp/ladybird.el`, L): `ladybird-mode`,
  `ladybird--make-view-buffer CONN VIEW URL`, `ladybird--insert-canvas`, `ladybird--make-canvas`,
  `ladybird--replace-canvas`, `ladybird--desired-size`, `ladybird--sync-viewport`,
  `ladybird--window-size-changed`, `ladybird--window-buffer-changed`,
  `ladybird--selection-changed`, `ladybird--on-frame`, `ladybird--kill`, `ladybird`, `ladybird-quit`,
  `ladybird-close`, the `state`/`view_created`/`view_closed`/`crashed`/`background_color`
  handlers, header line and mode-line tag, `ladybird-connect`, `ladybird-reconnect`. ERT
  `test/ladybird-render-test.el` (batch, `noninteractive`): `ladybird--desired-size` with two
  windows of different sizes picks the smaller in each dimension and multiplies by a
  stubbed dpr; a frame item of a new size replaces the canvas and acks; the buffer rename
  follows `ladybird-buffer-name-format`; `welcome` re-creates buffers for listed views and
  sends `create_view` for a buffer whose view is gone. elate (GUI): start the mock with
  `--views 1`, `(ladybird-connect)` → a buffer exists and `(image-size ladybird--canvas t)`
  equals the window body size; `(split-window-below)` → the mock log shows one
  `set_viewport` after the debounce with the smaller height; `screenshot` shows the gradient.
- **C2 Mouse and wheel** (M): `ladybird-mouse-down`, `ladybird-mouse-up`, `ladybird-mouse-move`,
  `ladybird-wheel`, `ladybird--mouse-posn-xy`, `ladybird--send-mouse`, the scroll commands,
  `ladybird--leave`. ERT: synthetic down/up events through `ladybird--send-mouse` with a
  recording `ladybird--send` give device coordinates = posn × dpr and `buttons` sets;
  `double-down-mouse-1` → `clicks 2`. elate (GUI): `mouse click` at a canvas point → mock
  log `mouse down`/`up` at the scaled coordinates and the next screenshot shows the square
  there; wheel events pushed on `unread-command-events` (shape from the memory note) → one
  `wheel` message each with `dy` −24/+24; `n`/`SPC` → wheel messages of line/page size.
- **C3 Keys, page and command mode, paste** (M): `ladybird--build-page-map`,
  `ladybird-send-key`, `ladybird-send-edit-key`, `ladybird-send-next-key`, `ladybird--send-key`,
  `ladybird-command-mode`, `ladybird-yank`, `ladybird-xterm-paste`, `ladybird-copy-selection`,
  `ladybird-select-all`, `ladybird-zoom-adjust`. ERT: `(key-binding "a")` is
  `ladybird-send-key` and in command mode `ladybird-command-mode-self-insert`; `C-x C-f`,
  `M-x`, `C-g` resolve to their global commands; `ladybird-translated-keys` nil unbinds
  `C-a`; the translation table per platform; `C-c C-q` with `C-x`, `C-g`, a terminal's
  `ESC x` and a mouse event; `C-u 3 a`; the zoom repeat keys; the `describe-mode` text has
  no generated bindings. elate (TTY ok): `type 'Hello!'`, `keys RET` → mock log has `key
  down` `H` `E` … `ExclamationPoint` `Return` with code points; `C-y` after `(kill-new "x")`
  → `paste`; `C-c C-e` and `i` switch modes.
- **C4 Page UI handlers** (M): `dialog`, `select`, `file_picker`, `color_picker`,
  `date_picker`, `permission`, `permission_cancelled`, `external_url`, `context_menu`,
  `popup_blocked`, `clipboard`, `cursor`, `link_hover`, `tooltip`, `favicon`, `console`,
  `selection`, `screenshot_saved`, `error`.
  ERT: each handler with `read-string`/`y-or-n-p`/`completing-read` stubbed returns the
  specified reply; a `quit` from the stub sends the cancel reply. elate (TTY): load
  `mock://select` → `wait prompt`, `state` shows the candidates, `type`+`RET` → mock log
  `select_closed` with the id; `mock://confirm` + `y` → `accepted true`; `C-g` in a prompt
  → `accepted false`.

**Group D (needs C1–C4; D1–D3 ∥)**

- **D1 Navigation commands** (S): `ladybird-goto-url`, `ladybird-reload`, `ladybird-back`,
  `ladybird-forward`, `ladybird-stop`, zoom, `ladybird-copy-url`, `ladybird-new-buffer`,
  `ladybird-screenshot`, `ladybird-toggle-console`, `ladybird-browse-url`.
  elate: `g`, type URL, RET → `load` in the log and the header line shows `Mock: URL`;
  `b` with `can_go_back` false → `user-error`.
- **D2 Find** (S): `ladybird-find`, `ladybird-find-backward`, `ladybird--find-minibuffer-map`,
  `ladybird--find-update`, `find_result` handler. elate: `C-s`, type `oc` → log shows `find`
  with `"oc"` after the debounce, minibuffer shows `[1/1]`, `C-s` → `find_step next`, `RET`
  exits, `C-g` sends an empty `find`.
- **D3 Reconnection and lifecycle** (M): server exit handling with exit codes, `replaced`,
  `set_visibility` on window changes, `set_focus`, `ladybird-keep-view-on-kill`,
  `after-focus-change-function` leave. elate (`--socket` variant): kill the mock, start it
  again with `--views 1` within 10 s → `[reconnecting]` then the buffer reattaches to view 1
  with no new buffer; `--exit-after` on stdio → message with the exit code; a second Emacs
  client (a Python one-liner connecting to the socket) → `[taken over]` and `ladybird-reconnect`
  takes over.

**Group E (needs D)**

- **E1 Test harness and CI** (M): `Makefile`, `test/elate/run.sh` with variants `stdio`,
  `unix`, `tcp` (the mock is started from the sandbox via `make-process`, as
  `rexel-setup.el` starts socat relays), `lib/ladybird-setup.el` (self-locating load-path,
  `ladybird-hosts` set to the mock, helpers `ladybird-elate-start VARIANT`,
  `ladybird-elate-log-has TYPE PRED`, `ladybird-elate-ready-p`), scenarios `connect.json`,
  `input.json`, `size.json`, `ui.json`, `reconnect.json`. Byte-compile warnings as errors,
  checkdoc, package-lint green.
- **E2 README.org** (S): quick start, hosts and transports (with the ssh socket forwarding
  recipe), key bindings tables generated from the maps, requirements (Emacs 32 with
  canvas, the module, Ladybird with `--headless=emacs`), status.

## 8. Risks, open questions, protocol feedback

All protocol feedback items below were resolved in `01-protocol.md` v1 (its §11 lists the
decisions). The body of this plan was patched for the module API (3.4, 3.5, 4.2), key code
points, the keypad modifier, permissions, popups and `request_source`; where anything else
in this plan still contradicts the protocol, the protocol wins.

Risks:

- HiDPI: whether a `:scale 0.5` canvas is drawn at the backing resolution on NS is unknown;
  if not, pages render at dpr 1 until the module/Emacs side solves it. The Elisp is
  dpr-agnostic beyond 4.3, so nothing here changes.
- Image line fit: an image exactly `window-body-height` tall may still trigger a one-line
  scroll if Emacs adds a descent; C1 must verify with `(window-end)` and, if needed, subtract
  `ladybird--line-slack` (start with 0; `:ascent 100` should make it 0).
- `mouse-fine-grained-tracking` and `track-mouse` are global; setting them while a ladybird
  window is selected could surprise other packages that read `track-mouse` (`mouse.el`
  drag commands bind it themselves, so they are unaffected). `ladybird-track-hover` nil
  disables it.
- Timers vs. `process-send-string`: a `set_viewport` sent from the resize timer while a
  paste blocks is fine (nested), but handlers must re-read buffer-locals after any send.
- `window-size-change-functions` runs during redisplay; it must only start a timer, never
  send or modify the buffer (redisplay-hook restrictions).
- `process-send-string` on a closed pipe signals `file-error`; `ladybird--send` catches it and
  routes to the sentinel path.

Open questions:

- Should alerts block (`prompt`) by default like real browsers? Default `echo` chosen to
  keep Emacs responsive; revisit after use.
- Renaming the buffer on every title change confuses `switch-to-buffer` history; a fixed
  `"*ladybird:%v*"` format with the title only in the header line is the alternative.

Protocol feedback (for `plans/01-protocol.md`):

1. **Key names**: section 5 says the enumerator name without `Key_`, but Ladybird's own
   `key_code_from_string` (`KeyCode.h` line 161) matches the *UI name* (`"!"`, `"Return"`),
   which differs from the enumerator for all punctuation (`ExclamationPoint` vs `"!"`).
   The server's generated table must be explicit about which it accepts; this plan sends
   enumerator names (`ExclamationPoint`, `Space`, `RightParen`…). Please confirm or switch
   the contract to UI names (then `ladybird-keys--punctuation` becomes the identity).
2. **Modifier bitmask** differs from Ladybird's `KeyModifier` (Alt=1, Ctrl=2, Shift=4,
   Super=8, Keypad=16): fine as long as the server remaps, but the protocol's `altgr=16`
   has no Ladybird counterpart while Ladybird's `Mod_Keypad` has none in the protocol.
   Suggest replacing `altgr` by `keypad` (the client knows `kp-*` keys) or adding both.
3. **`Return` code point**: the section 5 example sends `code_point 10` for `Return`;
   Ladybird's `Key_Return` is `0x0D` and the Qt frontend sends 13. Pick one; this plan
   sends 13 unless the protocol is corrected to say 10.
4. **Key_Invalid with a code point**: state whether a `key` with an unknown name but a
   non-zero `code_point` inserts the character (Qt's behavior) or is dropped. This plan
   avoids the question by sending non-ASCII characters as `text`.
5. **`text` vs `paste`** overlap ("inserts a string as a paste or IME commit" vs "paste
   text at the caret"). Define the difference (e.g. `text` fires `input`/composition
   events, `paste` fires a `paste` event honoring the page's paste handler) or drop one.
6. **Minor fields**: the `mouse leave` example has `view` twice and no `x`/`y` (say they
   are absent); `view_created` for popups lacks `title`; `dialog` lacks the page origin
   ("page at X says"); `file_picker` lacks a `directory`/`default_path` hint.
7. **No history list**: `H` (`xwidget-webkit-browse-history`) cannot be implemented. Suggest
   v2 `request_history` → `history_list {entries:[{url,title,current}]}` and `history`
   accepting an absolute `index`.
8. **`find_result`** should also carry `query` so a late result for an old query can be
   ignored.
9. **`welcome.views`** entries should include `width height dpr` so the client can decide
    whether to send `set_viewport` immediately (now it always does).
10. **`frame_ack` before the first frame**: specify that a client must not ack a `seq` it
    has not seen and what the server does on a stale ack (ignore, presumably).
11. **Unknown-view frames**: say whether the client must ack frames for views it does not
    know (this plan does, to avoid stalling the server's one-in-flight loop).
12. **TCP option name**: `--emacs-tcp` plus "no authentication"; please reserve a `token`
    field in `hello` now so v1 clients can send it harmlessly later (unknown keys are
    ignored).
13. **ssh stdio lifetime**: document that a stdio server dies with its ssh session, so
    detach-and-resume needs the socket or TCP listener.

## 9. Size estimate

| Task | Code | Tests | Notes |
| --- | --- | --- | --- |
| A1 framing/endpoints | 120 | 80 | |
| A2 key table | 250 | 150 | the punctuation and symbol tables dominate |
| A3 fake module | 150 | 60 | `bindat` specs reused by A1 tests |
| A4 mock server | 450 py | selftest | bitmap font ~60 lines |
| B1 connection | 500 | 300 | the largest and most delicate piece |
| C1 buffers/canvas/sizing | 400 | 150 + elate | |
| C2 mouse/wheel | 220 | 80 + elate | |
| C3 keys/modes/paste | 180 | 80 + elate | |
| C4 page UI | 300 | 150 + elate | |
| D1 navigation | 150 | elate | |
| D2 find | 120 | elate | |
| D3 lifecycle | 150 | elate | |
| E1 harness | 200 sh/el/json | — | |
| E2 README | 250 org | — | |

Roughly 2 600 lines of Elisp, 450 of Python, 1 000 of tests. Critical path: A1 → B1 → C1 →
C2/C3/C4 → D → E; A2/A3/A4 run alongside A1/B1.
