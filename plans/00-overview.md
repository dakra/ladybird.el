# 00 — Ladybird in Emacs: overview, work packages and schedule

Read this first. It says what is being built, how the work is split so several agents
can implement in parallel, which document wins on conflict, and how to hand a work
package to an agent.

## 1. What is being built

An Emacs browser mode that shows Ladybird pages in an Emacs 32 **canvas image**, as a
replacement for `xwidget-webkit`. Three processes/components:

```
 Emacs (client)                                 Ladybird (server), local or remote
 ┌──────────────────────────────┐   stdio /     ┌───────────────────────────────────┐
 │ ladybird.el  (mode, UI, keys)  │  unix socket  │ Ladybird --headless=emacs         │
 │ ladybird-conn.el (transport)   │◄────────────►│  Hub in-process (headless mode)    │
 │ ladybird-module (Zig, native)  │   records     │  EmacsWebView : HeadlessWebView   │
 │   parses records, zstd,      │               │  EmacsTransport / EmacsProtocol   │
 │   writes canvas_data pixels  │   (shm when   │  → Compositor, WebContent, …      │
 └──────────────────────────────┘    local)     └───────────────────────────────────┘
```

- The server is a Ladybird headless mode modelled on `TerminalWebView` (PR 14186,
  merged 2026-11-09). It presents frames from CPU memory, sends the damaged rectangle of
  each frame (raw, zstd, or via POSIX shared memory when local), and turns JSON input
  messages into `Web::MouseEvent`/`Web::KeyEvent`.
- The client is an Elisp package plus a small native module. Elisp owns the connection
  (`make-process`, `ssh`, Unix socket, TCP/TLS), the major mode, all UI and the event
  translation; the module owns the byte stream parsing, zstd decoding and the copy into
  the canvas pixel buffer (`env->canvas_data`).
- Because the server may run on another machine (over `ssh host Ladybird
  --headless=emacs`, `ssh -L` to its socket, or Tailscale), the **stream is primary**
  and shared memory is only an optimisation. Browser sessions live in the server and
  survive the client detaching (like tmux/Rex sessions; see
  `/Users/daniel/.emacs.d/lib/rexel/README.org` for the model this copies).

Pixel formats already match: Ladybird frames are BGRA8888, the canvas is ARGB32, the
copy is a `memcpy`.

## 2. Documents and precedence

| File | Owns | Precedence |
| --- | --- | --- |
| `01-protocol.md` | wire contract, v1 | **wins over every other plan** |
| `03-emacs-module.md` §2 | the module's Lisp API | wins over `04` on that API |
| `02-ladybird-emacs-server.md` | Ladybird-side work package | |
| `03-emacs-module.md` | native module work package | |
| `04-elisp-package.md` | Elisp work package | |
| `05-tooling-and-integration.md` | shared test tools, fixtures, integration milestones | wins on tool names and fixture formats |

Plans 02–04 were written against the protocol draft and then patched; `01 §11` lists
every change. An implementer who finds a contradiction fixes the plan, not the protocol,
unless the protocol is wrong, in which case the protocol file is edited first and the
change is listed in its §11.

## 3. Repositories and locations

| What | Where | Notes |
| --- | --- | --- |
| Emacs package + module + tools (new repo) | `/Users/daniel/src/dakra/ladybird` | layout below; package, prefix and module are named `ladybird` |
| Ladybird checkout | `/Users/daniel/src/ladybird` | master `da9df7639` on 2026-11-09, **not built yet**; work on branch `emacs-headless` |
| Emacs checkout | `/Users/daniel/src/emacs` | master with canvas; only for reading and for the possible NS patch (`plans/emacs-canvas-ns-transform.patch`) |
| Installed Emacs | `/opt/homebrew/bin/emacs` → emacs-plus@32 32.0.50, NS | has canvas, modules, `canvas_data` in its `emacs-module.h` |
| Patterns to copy | `/Users/daniel/.emacs.d/lib/rexel`, `/Users/daniel/.emacs.d/lib/ghostel` | connection code; Zig module build and `emacs.zig` bindings |

Repo layout (created by the first tasks of 03 and 04):

```
/Users/daniel/src/dakra/ladybird/
  plans/                 these files
  lisp/                  ladybird.el ladybird-conn.el ladybird-keys.el ladybird-module-load.el
  src/                   Zig module (module.zig emacs.zig Parser.zig Frame.zig View.zig Session.zig …)
  vendor/                emacs-module.h, zstd amalgamation
  tools/                 ladybird_protocol.py (shared), ladybird-client.py, mock-server.py, checks/
  test/                  ERT, fake module, fixtures/gen_stream.py + *.ladybird, elate/
  build.zig build.zig.zon Makefile README.org
```

Ladybird changes stay in the Ladybird tree (`Libraries/LibWebView/Emacs*.{h,cpp}`,
`Options.h`, `Application.cpp`, CMake, `vcpkg.json`), on the `emacs-headless` branch.

## 4. Work packages

| WP | Plan | Scope | Estimate (from the plan) |
| --- | --- | --- | --- |
| **S** server | `02` | `EmacsWebView`, `EmacsProtocol`, `EmacsTransport` (stdio + Unix socket), raw/zstd/shm frames with one-in-flight flow control, input mapping, state events, dialogs, Python test client | ~2.9 k lines C++/Python, ~10 days |
| **M** module | `03` | Zig module reusing ghostel's `emacs.zig`: record parser, frame header, per-view backing store, raw/zstd/shm decode, canvas paint, coalesced `canvas-refresh`, test accessors, fixture generator | ~1.5 k Zig + 0.6 k Elisp tests, ~8.5 days incl. the NS HiDPI check |
| **E** elisp | `04` | transports and redial, major mode with one canvas per buffer, viewport sizing, mouse/wheel/key translation, insert mode, dialogs/pickers/context menu, find, history, zoom, `browse-url`, mock server, elate scenarios, README | ~2.6 k Elisp + 450 Python + 1 k tests |
| **T** tooling | `05` | the shared Python protocol module, fixture formula, integration checkpoints, CI | small, mostly folded into S/M/E tasks |

Decisions already made (do not reopen without a reason):

1. Separate server process, not a module that links Ladybird into Emacs.
2. Headless mode (Hub in-process, `HeadlessWebView` subclass) is the seam, not the
   Hub↔UI IPC. One view in v1; `view` ids in every message for tabs later.
3. Zig for the module, zstd via a vendored C amalgamation (Zig's std decoder measured
   20× slower). Module calls `canvas-refresh` itself, coalesced per `feed`.
4. Key names are `KeyCode` enumerator names; Return is code point 10; modifier bit 16
   is keypad. `clicks` sets `click_count`.
5. Popups are blocked in v1 (`popup_blocked`); `request_source` is v2.
6. Locally prefer stdio (or shm) over a Unix socket: macOS Unix sockets hand Emacs 8 KiB
   per read.
7. Retina: render at `frame-scale-factor` and display the canvas with `:scale (/ 1.0 dpr)`.
   M-T0 showed that NS ignores `:scale` on a canvas (03 §7), so on NS this needs an Emacs
   built with `plans/emacs-canvas-ns-transform.patch`; an unpatched Emacs gets dpr 1 with
   blurry text. The client decides with `ladybird-device-pixel-ratio`.

## 5. Dependencies and parallel schedule

```
Phase 0 (spikes, 1–2 days, run in parallel)
  M-T0  NS :scale after canvas-refresh  ──┐  decides the HiDPI strategy for E (04 §4.2)
  S-T1  Ladybird build + option skeleton ─┤  the build alone takes hours the first time
  T-1   tools/ladybird_protocol.py          ┤  shared framing used by mock server, client, fixtures
  T-2   test/fixtures (gen_stream.py)     ┘  stream fixtures M and E both test against (03 T3)

Phase 1 (independent, in parallel; each tested with its own mock/fixtures)
  S: T2 protocol → T3 transport → T4 handshake → T5 view+raw frames → T6 input → T7 zstd/shm → T8 dialogs → T9 client
  M: T1 skeleton → T2 parser → T4 views/paint/feed → T5 zstd → T6 shm → T7 perf   (T3 is T-2)
  E: A1 A2 A3 A4 (∥) → B1 connection → C1 canvas/sizing → C2 mouse ∥ C3 keys ∥ C4 page UI → D1 D2 D3 (∥) → E1 E2

Integration checkpoints (05 §3)
  I1  S-T5 + tools/ladybird-client.py: a real page becomes a PNG            (no Emacs)
  I2  M-T4 + E-C1 + mock server: mock gradient visible in an Emacs buffer (no Ladybird)
  I3  S-T6/T7 + M-T5/T6 + E-C2/C3: real page in Emacs over stdio, local shm, click+type work
  I4  E-D3 + S-T3 socket: detach, reconnect, `ssh -L` and `ssh … Ladybird --headless=emacs`
  I5  polish: dialogs, find, zoom, favicon, README; elate matrix green
```

Three agents can work from Phase 1 on with no shared files: S touches only
`/Users/daniel/src/ladybird`, M touches `src/`, `vendor/`, `build.zig`, `lisp/
ladybird-module-load.el`, `test/fixtures`, `test/ladybird-module-test.el`; E touches
`lisp/ladybird*.el` (except the loader), `tools/mock-server.py`, `test/` (except module
tests and fixtures). `tools/ladybird_protocol.py` and `test/fixtures/` (05) are written in
Phase 0 and then only extended by whoever needs a field or a case, since M, E and both
Python tools depend on them. The `Makefile` is shared: M creates it (03 T1), E adds its
targets (04 E1).

## 6. Handing a work package to an agent

Each agent gets: this file, `01-protocol.md`, its own plan, `05-tooling-and-integration.md`,
and the conventions below. Suggested opening prompt (adjust the WP letter):

> Implement work package S from `/Users/daniel/src/dakra/ladybird/plans/02-ladybird-emacs-server.md`.
> Read `/Users/daniel/src/dakra/ladybird/plans/00-overview.md` and `01-protocol.md` first;
> the protocol file wins over the plan. Work on branch `emacs-headless` in
> `/Users/daniel/src/ladybird`. Do tasks in order, run each task's acceptance check before
> the next, and stop at integration checkpoint I1 (plan 05 §3) with a summary of what passed.
> Do not commit or push; report the changed files. Follow the conventions in 00 §7.

Agents for M and E start at their task 1 (M also runs T0) and stop at I2. One agent
then does I3–I5 with all three components, or the owner does.

## 7. Conventions (all work packages)

- Never commit or push without an explicit per-action request from Daniel; summarise the
  changes and wait. No AI attribution anywhere (commits, code, docs).
- Feature branches: `emacs-headless` in Ladybird, `main` is fine for the new repo until
  told otherwise.
- Comments and docs describe current behaviour only; no changelog-style prose, no
  reviewer-directed justifications.
- Ladybird code follows `Documentation/CodingStyle.md` and `CodingStyle`/`Patterns.md`
  in `/Users/daniel/src/ladybird/Documentation`; run `clang-format`. Emacs Lisp: byte-compile
  warnings as errors, checkdoc and package-lint clean (as rexel's `make`). Zig: as ghostel
  (`/Users/daniel/.emacs.d/lib/ghostel/src/CLAUDE.md`).
- Elisp must never prompt from a process filter (use a 0-delay timer), never use
  `(debug error)`, and must bind `read-process-output-max` to 1 MiB around
  `make-process` (it is captured per process at creation).
- Tests must run without the other components: S against `tools/ladybird-client.py`, M
  against `test/fixtures/*.ladybird`, E against `tools/mock-server.py` and the fake module.
- Interactive Emacs testing uses elate sandboxes (`uvx elate`, skill `elate`); stop every
  session you start. GUI tests need the screen unlocked for screenshots.

## 8. Known risks (owner's view)

| Risk | Impact | Mitigation |
| --- | --- | --- |
| NS ignores `:scale` on a canvas (confirmed, 03 §7 T0 result) | blurry Retina rendering until Emacs is patched | `plans/emacs-canvas-ns-transform.patch` (`nsimage.m`, untested); until then dpr 1 |
| NS canvas refresh costs 34 ms at 1600×1000 and 84 ms at 3200×2000 (03 §7) | 12 fps at Retina size even with the patch | throttle refreshes from Lisp; an Emacs patch that writes the NS bitmap planes directly |
| Ladybird internals move weekly (`TerminalWebView` is one day old) | rebases of the `emacs-headless` branch | keep `Emacs*` files self-contained, touch `Application.cpp` minimally; consider upstreaming the mode |
| Bandwidth on remote links while scrolling | a few fps over WAN | damage rects + zstd + one-in-flight already in v1; video codec is v2 |
| Unix-socket 8 KiB reads on macOS | slow local frames over `--emacs-socket` | stdio or shm locally; socket only for detach/attach and ssh |
| Emacs key model (no key-up, modifiers) | pages that rely on key-up timing | synthesized up after down, as the terminal frontend does |
| Premultiplied alpha on translucent page backgrounds | wrong colours at the margin | verify with a test page (02 §6); canvas is premultiplied too |
| `shm` negotiated over a forwarded Unix socket | no picture | `shm_failed` fallback (01 §4.3) |
| First Ladybird build needs hours and tens of GiB of disk | S blocked at T1 | check free space before `ladybird.py build`; M, E and T do not need Ladybird until I1/I3 |
