# 03 — Emacs native module `ladybird-module`

Status: implementation-ready plan. Contract: `/Users/daniel/src/dakra/ladybird/plans/01-protocol.md`
(record framing §1, frame header §4). The module's only jobs: take stream bytes from Lisp,
parse records, decode frames (raw / zstd / shm) into the Emacs canvas pixel buffer, hand
control records back to Lisp as strings. No sockets, no JSON, no threads, no UI.

All Emacs references are to `/Users/daniel/src/emacs` at commit `0f76a435a2` (2026-11-09).
The installed Emacs used for testing is `/opt/homebrew/opt/emacs-plus@32` (32.0.50, NS build),
whose header `/opt/homebrew/opt/emacs-plus@32/include/emacs-module.h` declares
`struct emacs_env_32` (line 1291) with `canvas_data` (line 1481).

## 1. Findings

### 1.1 Canvas object and pixel buffer (src/image.c)

- `struct canvas` (image.c:113-124): `uint32_t *data` in ARGB32 ("same format on all
  platforms"), `uint32_t refresh` (always > 0), `int width, height`.
- Spec keywords (image.c:5476-5487): `:type canvas`, `:id` (symbol, mandatory), `:data-width`,
  `:data-height` (positive ints, mandatory), optional `:data` (unibyte string of 4·w·h bytes or
  vector of w·h ints) or `:file`, `:ascent`, `:margin`, `:relief`. `canvas_parse` (5505-5520)
  also requires `w*h*4 <= INT_MAX`. `:scale`, `:transform-smoothing`, `:map` are handled by the
  generic image code (display.texi:7533-7535).
- Identity: the spec **object** (`eq`) is the key in the weak hash `canvas_map`
  (image.c:5489-5501, created `Weak_Key` at 13627). `canvas_get` (5663-5710) allocates the
  `struct canvas` and the buffer on first sight of a spec (`xzalloc (4*w*h)`, 5683-5686); if the
  spec's `:data-width`/`:data-height` differ from the stored dims it `xrealloc`s **and zero-fills**
  the buffer (5699-5707). Any other spec change leaves the buffer alone. The buffer is freed only
  by `canvas_free_unused` (5534-5558), which runs when a new canvas is allocated (5681) or from
  `clear_image_cache` (2502), and only for specs that have been garbage collected. So: **the
  pointer from `canvas_data` is stable while (a) the spec object is reachable and (b) its
  dimensions do not change.** `:data` is excluded from the image-cache key for canvases
  (`filter_image_spec`, 2288-2311), so mutating `:data` does not recreate the image.
- `canvas_data (Lisp_Object image)` (5854-5864) = `canvas_get` + return `c->data`; it signals
  `error ("Not a canvas")` for a non-canvas spec and creates the canvas if it did not exist yet,
  so a module can write pixels before the spec is ever displayed.
- `canvas-refresh IMAGE &optional RELOAD-DATA` (5866-5906): optionally re-copies `:data`/`:file`
  (`canvas_apply_data`, 5567-5659), increments `c->refresh`, then `redraw_image_glyphs (image)`
  (xdisp.c:32931-32941 → 32869-32910): for every window whose current matrix shows an image
  glyph with `EQ (img->spec, spec)` it calls `prepare_image_for_display` and `draw_glyphs`
  immediately into the (double) buffer. It does **not** call `redisplay` or flush; the next
  redisplay flips the buffer (comment at 5898-5901). If a window is `must_be_updated_p` or the
  frame is garbaged, it just garbages the frame and waits for redisplay. So `canvas-refresh`
  called from a process filter becomes visible when Emacs next redisplays (returning to the
  command loop / `redisplay` / `sit-for`), not when the filter returns.
- Pixel upload happens in `canvas_prepare_for_display` (5741-5849), invoked from
  `prepare_image_for_display` whenever `img->refresh != c->refresh` (1899-1904). Backends:
  Cairo (PGTK, X with cairo): `memcpy` rows into the existing cairo surface (5760-5783, alpha
  preserved; cairo ARGB32 is premultiplied, so keep alpha 0xFF). X11: per-pixel
  `lookup_rgb_color` (5785-5806). **NS: `ns_image_reset` releases the old `EmacsImage` and
  allocates a new planar `NSBitmapImageRep`, then `PUT_PIXEL` per pixel** (5813-5822;
  nsimage.m:260-264, 421-440, 497-520; `ns_put_pixel` maps alpha 0 → 0xFF, nsimage.m:244-251).
  The NS path is O(width·height) Objective-C message sends per refresh regardless of damage
  size — the whole canvas is re-uploaded every time.
- If the canvas was resized but the displayed image still has the old `original_width/height`
  (dispextern.h:3298-3300), `canvas_prepare_for_display` garbages the frame (5749-5756) and
  redisplay reloads the image via `canvas_load` (5714-5737).
- `canvas-refresh` and `canvas_data` work in `emacs --batch` on a GUI-capable build (verified:
  `(canvas-refresh '(image :type canvas :id x :data-width 2 :data-height 2))` → nil in batch;
  `module_canvas_data` is compiled under `HAVE_WINDOW_SYSTEM`, emacs-module.c:966-977, which is
  a build-time define). There is **no Lisp accessor for canvas pixels** (the only DEFUN is
  `canvas-refresh`, image.c:5866), so tests need a module accessor (§2.9).

### 1.2 HiDPI (critical, user is on NS/Retina)

- A canvas is created as an `NSImage` whose **size in points equals its pixel size**
  (`initForXPMWithDepth`, nsimage.m:421-440: `initWithSize: {width,height}` and a bitmap rep
  `pixelsWide: width`). `ns_dumpglyphs_image` (nsterm.m:4267-4385) draws
  `[img drawInRect:ir fromRect:ir]` with `ir = (0,0,[img size])` in points (4323-4324, 4353).
  **A W×H canvas therefore covers W×H points = 2W×2H device pixels on a 2× screen**, upscaled
  by AppKit (interpolated unless smoothing is off). Same on PGTK: Cairo images are logical
  pixels, GDK scales them. Emacs has no per-image "device pixels" flag; `FRAME_SCALE_FACTOR`
  (frame.h:1057-1061) is used only for SVG pre-scaling (image.c:3100-3104).
- The way to get **1 canvas pixel = 1 device pixel**: render the page at device resolution
  (viewport `cols*dpr × rows*dpr`, `dpr` = `(frame-scale-factor)`, frame.c:5065-5076 →
  `backingScaleFactor` on NS, nsterm.m:828-841) and display the canvas with
  `:scale (/ 1.0 dpr)` and `:transform-smoothing nil`. `image_set_transform` (image.c:3058)
  computes the displayed size via `compute_image_size` (`image_compute_scale`, 2728-2778), sets
  the NS matrix `[0][0] = width / img->width = 1/dpr` (3139-3148), stores the logical size in
  `img->width/height` (3151-3152) and passes matrix + smoothing to the pixmap
  (`ns_image_set_transform`/`ns_image_set_smoothing`, 3386-3387). Glyph origins are integer
  points, so with integer dpr the sampling is exactly 1:1; `:transform-smoothing nil` selects
  `NSImageInterpolationNone` (nsterm.m:4347-4351). Verified live: a 200×200 canvas with
  `:scale 0.5` reports `(image-size c t)` = `(100 . 100)` on a frame with
  `(frame-scale-factor)` = 2.0. For fractional dpr (1.5 on some Linux setups) keep smoothing on
  or round dpr to 1 or 2.
- **Do not use `create-image`** for the spec: it adds `:scale default` (image.el:542-545),
  which maps to `image-scaling-factor` = `auto` = `FRAME_COLUMN_WIDTH/10` (image.c:2736-2750)
  and would scale the canvas with the font size. Build the spec by hand:
  `(list 'image :type 'canvas :id (gensym "ladybird-") :data-width W :data-height H
  :scale (/ 1.0 dpr) :transform-smoothing nil)`.
- **Probable Emacs bug (NS) to verify on day one (task 0):** `canvas_prepare_for_display`
  replaces `img->pixmap` with a fresh `EmacsImage` (image.c:5817) whose `transform` and
  `smoothing` ivars are nil/NO; `image_set_transform` is only called from `lookup_image` after
  the initial load (image.c:3673-3675). `ns_dumpglyphs_image` applies `img->transform` only
  when non-nil (nsterm.m:4338-4339). By code reading, **after the first `canvas-refresh` on NS
  the `:scale` is lost**: the 2W×2H-point image is drawn unscaled and clipped to the W×H-point
  glyph rect, i.e. only the top-left quarter of the page is visible. Test recipe (GUI session;
  elate: `uvx elate start --name c --ui gui`): display a 200×200 canvas with `:data` vector
  (left half red, right half blue), `:scale 0.5`; screenshot; change the vector (green|magenta),
  `(canvas-refresh c 'reload-data) (redisplay t)`; screenshot. If the second shows only one
  colour, the bug is confirmed. Fixes, in order of preference: (1) patch Emacs so
  `canvas_prepare_for_display` re-applies the transform on NS (after `ns_image_reset`, call
  `image_set_transform (f, img)` with `img->width/height` reset to `original_*`, or make
  `ns_image_reset` copy `transform`/`smoothing` to the new image); report upstream;
  (2) fallback without patch: render at dpr 1.0 (viewport in points, canvas `W/dpr × H/dpr`, no
  `:scale`), accepting blurry text. The module is unaffected either way; this only changes
  what `hello.viewport/dpr` the Elisp sends and how it builds the spec.
- Cairo canvases use `CAIRO_FILTER_GOOD`/`NEAREST` instead of `BEST` (image.c:3395-3401).

### 1.3 Module API facts (src/emacs-module.c, module-env-32.h)

- `env->canvas_data (env, canvas)` (module-env-32.h:5-12, emacs-module.c:966-977): returns
  `uint32_t *` or NULL with a pending non-local exit. Guard with
  `env->size >= sizeof (struct emacs_env_32)`; older Emacs → signal at load.
- Every env function starts with `MODULE_FUNCTION_BEGIN` (emacs-module.c:348-350) →
  `module_assert_thread` (1366-1375): with `--module-assertions` Emacs aborts if called from a
  thread other than the current Lisp thread or during GC. Process filters run on the Lisp
  thread inside `read_and_dispose_of_process_output` (process.c:6567), so a module function
  called from a filter is an ordinary funcall. **Rule: the module never touches `emacs_env`
  outside a module function invocation, never from another thread, never from a finalizer.**
- User pointers: `make_user_ptr` (868-877), `get_user_ptr` (880-888). The finalizer runs during
  GC (alloc.c:3041-3042) — it may only free module memory.
- Strings: `copy_string_contents` (790-830) calls `encode_string_utf_8 (…, nocopy=true, …)`
  (coding.c:9813-9820) which **returns a unibyte string unchanged** (`nchars == nbytes`), so
  copying a unibyte process-output chunk costs exactly one `memcpy` of its bytes. A multibyte
  string containing raw bytes makes it signal `wrong-type-argument unicode-string-p`
  (ghostel's `rawByteFallback` handles that; we instead require unibyte and signal). Verified:
  `make-process … :coding 'binary` delivers unibyte strings to the filter. `make_unibyte_string`
  (852-865), `make_string` (838-850, UTF-8 decode).
- Non-local exits: after any `env->funcall`, check `env->non_local_exit_check`; the ghostel
  wrapper (`registerFunction`, emacs.zig:357-389) converts Zig errors to an Emacs `error`
  signal and preserves pending exits.
- `open_channel` (1193-1201 → process.c:8720-8733) dup()s a pipe process' write fd so a
  module thread can wake Emacs by writing to it. Not needed in v1 (no threads).
- `read-process-output-max` default 65536 (process.c:9021-9028); **a process captures it at
  creation** (`p->readmax`, process.c:978), so it must be let-bound around `make-process` /
  `make-network-process`, as ghostel does (`/Users/daniel/.emacs.d/lib/ghostel/lisp/ghostel.el:4150`).
- `process_input`/`should_quit` (982-998): call `should_quit` between records in a long feed
  so `C-g` works; return early (keeping unparsed bytes) when it reports quit.

### 1.4 Shared memory (local fast path)

Verified on this Mac (Darwin 27): `shm_open` names are limited to `PSHMNAMLEN` = 31 chars
**including the leading slash** (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/posix_shm.h:53`;
a 31-char name succeeds, 32 fails with ENAMETOOLONG). **`ftruncate` on a macOS shm object
works exactly once** (a second call, even with the same size, fails EINVAL) → the server cannot
grow a segment on viewport change; it must create a new object under a new name. A name is
unopenable after `shm_unlink`, so the server must keep the object linked until the client has
mapped it. Linux: `/dev/shm`, NAME_MAX 255, `ftruncate` can grow. The client maps read-only
(`shm_open (name, O_RDONLY)`, `mmap (PROT_READ, MAP_SHARED)`), size from `fstat`.

### 1.5 Transport chunking

macOS `net.local.stream.recvspace` = 8192 (sysctl, this machine), and Emacs sets no
`SO_RCVBUF`, so a Unix-socket connection delivers ≤ 8 KiB per filter call (a raw 6.4 MB
frame ≈ 800 filter calls). Pipes (stdio) deliver up to 64 KiB, TCP loopback up to
`net.inet.tcp.recvspace` = 131072. The parser must be cheap per call; Lisp should prefer
stdio or shm locally (see §6 and §7).

## 2. Module API exposed to Lisp

Feature: `ladybird-module` (`(provide 'ladybird-module)` from `emacs_module_init`). All functions
are documented via the registration docstring. Errors are signalled with the condition
`ladybird-module-error` (Lisp defines it with `define-error`; the module signals
`(ladybird-module-error MESSAGE)` via `non_local_exit_signal`). Type errors from `extract_*`
propagate as Emacs' own `wrong-type-argument`.

| Function | Returns |
| --- | --- |
| `(ladybird-module-version)` | version string, equals the sidecar file (§4) |
| `(ladybird-module-create-session)` | session user-ptr |
| `(ladybird-module-close SESSION)` | nil; frees buffers, unmaps shm, releases canvas refs; later calls on it signal |
| `(ladybird-module-feed SESSION BYTES &optional NO-REFRESH)` | list of events in stream order (below) |
| `(ladybird-module-register-view SESSION VIEW)` | t; frames are stored only for registered views |
| `(ladybird-module-forget-view SESSION VIEW)` | t if it was registered; frees its store, canvas ref and shm mapping |
| `(ladybird-module-attach-canvas SESSION VIEW CANVAS)` | t; registers the view if needed |
| `(ladybird-module-detach SESSION VIEW)` | t if a canvas was attached |
| `(ladybird-module-repaint SESSION VIEW)` | `painted`, `size-mismatch`, `no-canvas`, or `no-frame` |
| `(ladybird-module-view-size SESSION VIEW)` | `(W . H)` of the view's backing store, or nil |
| `(ladybird-module-set-shm SESSION VIEW NAME)` | mapped size in bytes of the view's segment; NAME nil unmaps and returns nil; signals for an unregistered view |
| `(ladybird-module-reset SESSION)` | nil; drops buffered bytes and desync state, keeps attachments/shm |
| `(ladybird-module-stats SESSION)` | plist (below) |
| `(ladybird-module-canvas-pixel CANVAS X Y)` | integer ARGB (test accessor) |
| `(ladybird-module-canvas-row CANVAS Y)` | unibyte string of `4*W` bytes, native-endian ARGB32 (test accessor) |
| `(ladybird-module-canvas-fill CANVAS ARGB)` | nil; fills the whole canvas (test helper, no refresh) |

### 2.1 `ladybird-module-feed`

`BYTES` must be a unibyte string (checked with one funcall of `multibyte-string-p`; multibyte →
signal `ladybird-module-error "chunk must be unibyte; use :coding 'binary"`). The bytes are
appended to the session's accumulation buffer and every complete record is consumed. The
return value is a fresh list, one element per consumed record, in order:

- control record → the payload as a multibyte string (UTF-8 decoded; invalid UTF-8 kept as
  raw-byte chars, ghostel's `makeString` behaviour). Lisp does `json-parse-string`.
- frame record → `(frame VIEW SEQ FRAME-W FRAME-H DPR DX DY DW DH FULL STATUS)` with
  integers, `DPR` float, `FULL` t/nil, `STATUS` one of
  `painted` (pixels copied into the canvas),
  `stored` (decoded into the backing store, no canvas attached — Lisp may attach and `repaint`),
  `size-mismatch` (decoded into the store; attached canvas has other dims — Lisp should set the
  spec's `:data-width/:data-height` to `FRAME-W×FRAME-H` and call `ladybird-module-repaint`),
  `stale` (non-full frame whose dims differ from the store; dropped),
  `bad-frame` (header validation failed; dropped),
  `decode-error` (zstd failed or produced the wrong size; dropped),
  `shm-error` (encoding 2 without a mapping, or offset+size beyond the mapping; dropped),
  `unknown-view` (the view is not registered; nothing is stored),
  `canvas-error` (Emacs rejected the attached canvas; the frame is stored).
  A frame that fails leaves the store as it was. Frames above 256 MiB of pixels are
  `bad-frame`.
  **Lisp acks every frame event** (`frame_ack` with VIEW/SEQ) whatever the status; otherwise
  the server stalls (protocol §4 one-frame-in-flight).
- framing failure → `(desync REASON BYTE-OFFSET)` as the last element; the session enters
  `desynced` state, discards its buffer, and later feeds return nil until
  `ladybird-module-reset`. REASON: `bad-length` (0), `oversize` (length > 64 MiB), `bad-kind`.
  A frame record shorter than its 44-byte header is a `bad-frame` event with nil fields,
  which Lisp cannot ack. A length-prefixed stream has no sync marker, so the
  only recovery is reconnecting; Lisp should kill the process and reconnect.

Refresh rule: unless `NO-REFRESH` is non-nil, after all records are consumed the module calls
`(canvas-refresh CANVAS)` **once per attached canvas that received at least one `painted` frame
in this call** (coalescing many damage rects in one chunk into one refresh). With `NO-REFRESH`
non-nil nothing is refreshed and Lisp owns the timing (e.g. a 16 ms timer that calls
`canvas-refresh` only when the module reported paints; use `ladybird-module-stats` →
`:dirty-views`). `ladybird-module-repaint` always refreshes when it returns `painted`.
The module never calls `redisplay`.

### 2.2 Canvas attachment and the resize race

`attach-canvas` validates CANVAS by calling `env->canvas_data` once (signals "Not a canvas"
otherwise), stores a global ref (`make_global_ref`) and remembers the view. Attaching a second
canvas to the same view replaces the first (ref freed). Detach/close free the ref. The module
never caches the pixel pointer across calls: each paint calls `canvas_data` again (cheap: a
plist parse + hash lookup) and reads the current dimensions with two funcalls
`(plist-get (cdr CANVAS) :data-width)` / `:data-height`. This makes a Lisp-side spec mutation
(`plist-put`) safe at any time: the first paint after it sees the new dims (and Emacs has
already reallocated/zeroed the buffer inside `canvas_data`).

Per view the module keeps a **backing store**: a `frame_w × frame_h` ARGB buffer owned by the
module, holding the latest composed frame. Rules, applied per frame record:

1. Header validation: `dw,dh ≥ 1`, `dx+dw ≤ frame_w`, `dy+dh ≤ frame_h`, `frame_w,frame_h ≤
   16384`, encoding ∈ {0,1,2}, raw payload length `= dw*dh*4`,
   shm payload length `= 8`. Failure → `bad-frame`.
2. If the store has different dims: `full` → reallocate the store to `frame_w × frame_h`
   (zero-filled); not `full` → `stale`, stop.
3. Decode the damage rect into the store (§3.3-3.5).
4. If no canvas attached → `stored`. Else read canvas dims; if they differ from the store →
   `size-mismatch`. Else copy the damage rect store → canvas (row loop, stride `frame_w*4` on
   both sides) and mark the view dirty → `painted`.

`repaint` copies the whole store into the canvas when dims match (used after Lisp resized the
spec following `size-mismatch`, and after Lisp replaced the canvas object, e.g. buffer
re-creation). Consequence for Lisp on `set_viewport`: either change the spec dims first (the
canvas shows zeros until the full frame arrives) or wait for the `size-mismatch` event, set
dims, call `repaint` — no frame is lost either way. The store doubles memory per view
(6.4 MB at 1600×1000) and costs one extra rect copy per frame (6.4 MB memcpy = 0.07 ms
measured), which buys resize safety and `repaint`.

### 2.3 `ladybird-module-set-shm`

Opens `NAME` with `shm_open (name, O_RDONLY, 0)`, `fstat` for the size, `mmap (NULL, size,
PROT_READ, MAP_SHARED, fd, 0)`, closes the fd, keeps `(name, base, size)`. Failure signals
`ladybird-module-error` with `strerror`. A frame with encoding 2 reads `u64 offset` and requires
`offset + frame_w*frame_h*4 ≤ size`, else `shm-error` (segments are never resized, protocol
§4.3). Called again with a new name it unmaps the old mapping first. Not supported on Windows
(signal). When `set-shm` signals, or the mapped size is smaller than the `size` of the `shm`
message (`fstat` reports a page-rounded size), Lisp sends `shm_failed` (protocol §4.3) and calls `set-shm` with nil.

### 2.4 `ladybird-module-stats`

Plist: `:state` (`ok`/`desynced`/`closed`), `:bytes-in`, `:records`, `:control-records`,
`:frames`, `:frames-painted`, `:frames-dropped` (stale+bad+decode+shm), `:zstd-in-bytes`,
`:zstd-out-bytes`, `:decode-ns` (cumulative zstd time), `:copy-ns`, `:buffered` (bytes waiting
for a complete record), `:buffer-capacity`, `:largest-record`, `:dirty-views` (list of views
painted since the last refresh), `:shm-size`, `:views` (list of `(VIEW W H ATTACHED-P)`).

## 3. Internal design

Language: Zig 0.17.x (see §4), one dynamic library. Source files (all under `src/` of the
client package repo; the repo root is set by the Elisp work package, called `<ladybird>` here):

| File | Content |
| --- | --- |
| `src/module.zig` | `emacs_module_init`, function table, version, `plugin_is_GPL_compatible` (ghostel's pattern, `/Users/daniel/.emacs.d/lib/ghostel/src/module.zig`) |
| `src/emacs.zig`, `src/emacs.h` | copied from ghostel (`Env`, `FunctionEntry`, `registerFunction`, `makeString`, `extractStringAlloc`, `makeUserPtr`, symbol cache); add `canvasData(canvas) !*[*]u32` wrapping `env->canvas_data` with the `env.size` check; trim `interned_symbols` to what we use |
| `src/Session.zig` | session struct, `feed`, buffer management, event building |
| `src/Parser.zig` | pure record parser (no Emacs), unit-testable |
| `src/Frame.zig` | frame header parse/validate, `FrameHeader` struct |
| `src/View.zig` | backing store, decode-into-rect, canvas copy |
| `src/zstd.zig` | thin wrapper over the vendored C decoder |
| `src/shm.zig` | POSIX shm mapping (`std.c.shm_open`/`mmap`, or `posix.h` translate-c like ghostel) |
| `src/tests.zig` | Zig unit test root (`zig build test`) |
| `vendor/emacs-module.h` | copy of `/opt/homebrew/opt/emacs-plus@32/include/emacs-module.h` |
| `vendor/zstd/zstddeclib.c` | zstd decoder-only amalgamation (see §4) |

### 3.1 Session object

```zig
const Session = struct {
    buf: std.ArrayListUnmanaged(u8),   // accumulation buffer
    consumed: usize,                   // bytes of buf already parsed (compacted lazily)
    state: enum { ok, desynced, closed },
    views: std.AutoHashMapUnmanaged(u32, View),
    dctx: *ZSTD_DCtx,                  // one per session, reused
    scratch: []u8,                     // zstd output for partial-width rects, grown on demand
    shm: ?Shm,
    dirty: std.ArrayListUnmanaged(u32),// views painted since the last refresh
    stats: Stats,
};
const View = struct { w: u32, h: u32, store: []u32, canvas: ?emacs.Value /* global ref */ };
```

Created by `create-session` with `std.heap.c_allocator`, returned as a user-ptr whose finalizer
frees everything **except** canvas global refs (freeing a global ref needs an env). To avoid
leaking refs when Lisp drops a session without `close`, the finalizer pushes the refs onto a
module-global "orphaned refs" list that the next module function call drains with
`free_global_ref`. `close` releases everything immediately and sets `state = closed`; the
finalizer then only frees the struct.

### 3.2 Record parser state machine (`Parser.zig`)

Input: the accumulation buffer `buf[consumed..]`. Loop:

1. Need 5 bytes (`u32 LE length`, `u8 kind`); else stop (partial header is normal).
2. `length == 0` → desync `bad-length`; `length > 64 MiB` → desync `oversize`; `kind ∉ {1,2}`
   → desync `bad-kind`. `length` counts the kind byte (protocol §1).
3. Need `4 + length` bytes; else `ensureTotalCapacity (consumed + 4 + length)` once (so a large
   frame is not grown in 64 KiB steps) and stop.
4. Dispatch `payload = buf[consumed+5 .. consumed+4+length]`; `consumed += 4 + length`.
5. After a control record with more bytes buffered behind it: stop, so Lisp can act on it
   (`shm` → `set-shm`) before a later record is decoded; Lisp calls `feed` again with an
   empty string until it returns nil. `feed` does not poll for quit: it is meant to run
   with quit inhibited, as in a process filter.

After the loop: if `consumed == buf.len` reset both to 0; else if `consumed > buf.len/2`
`memmove` the tail to the front. When the buffer's capacity exceeds 2× the largest record seen
and it is empty, shrink it (frees a 64 MiB spike). The parser is a pure function over slices and
is unit-tested with inputs split at every possible boundary.

Frame payload (kind 2): first 44 bytes are the header (`4+4+4+4+8+4·4+1+1+2`, all LE, parsed
with `std.mem.readInt`); fewer → `bad-frame`. Then `rest = payload[44..]` is raw pixels, a zstd
frame, or `u64 offset`.

### 3.3 Raw (encoding 0)

`rest.len == dw*dh*4` (else `bad-frame`). Row loop: `@memcpy (store[(dy+r)*w + dx ..][0..dw],
rest[r*dw*4 ..][0..dw*4])` reinterpreting bytes as `u32` little-endian (the protocol pixel is
`0xAARRGGBB` as LE u32 = Emacs ARGB32; on big-endian hosts byte-swap, as `canvas_apply_data`
does at image.c:5589-5594 — compile-time `builtin.cpu.arch.endian()`).

### 3.4 zstd (encoding 1)

`ZSTD_decompressDCtx (dctx, dst, dstCap, rest.ptr, rest.len)`; this works for frames with
unknown content size as long as `dstCap` suffices (zstd.h:184-189, 312). Destination:
- `dx == 0 and dw == w` (full-width rect, including every `full` frame): decode **directly into
  the store** at `store[dy*w ..]`, `dstCap = dh*w*4`. No scratch copy.
- else decode into `scratch` (grown to `dw*dh*4`), then row-copy as in §3.3.
`ZSTD_isError (ret)` or `ret != dw*dh*4` → `decode-error`. Accumulate `:decode-ns` with
`std.time`-equivalent (`std.Io.Clock.boot`).

### 3.5 shm (encoding 2)

`rest.len == 8` → `offset`. Check mapping (§2.3). Source rows at `base + offset + ((dy+r)*w +
dx)*4`, stride `w*4`, copied into the store rect, then store → canvas as usual. (Two copies of
the damage rect; with shm the payload on the stream is 8 bytes so chunking cost disappears,
which is the point of shm.) Per protocol §4 the server writes the segment only between ack and
next frame, so reading inside `feed` is race-free as long as Lisp acks after `feed` returns.

### 3.6 Canvas paint

`paintRect (view, canvas, dx, dy, dw, dh)`: `data = env.canvasData (canvas)`; dims via
`plist-get`; mismatch → `size-mismatch`; else row loop `@memcpy` from the store. Writes are
bounded by both dims (identical by construction). After the record loop, for each dirty view
with a canvas: `env.f ("canvas-refresh", .{canvas})`; check `nonLocalExitCheck` and stop on a
pending exit (return what we have; the wrapper propagates the signal).

### 3.7 Error policy

- Signal (`ladybird-module-error` or `wrong-type-argument`): programmer errors — wrong types,
  multibyte chunk, closed session, unknown view in `detach`/`repaint` is **not** an error
  (returns nil/`no-frame`), shm open failure, non-canvas spec, out of memory.
- Return as data: everything that comes from the stream (bad frames, decode errors, desync),
  because the filter must not blow up on peer data and Lisp must still ack.
- The module never logs to stderr in release builds (stderr may be the user's tty).

### 3.8 Memory ownership

Lisp string → one memcpy into `buf` (module-owned). Store, scratch, buf: `c_allocator`,
freed in `close`/finalizer. Canvas pixels: owned by Emacs; written only inside module
functions; never retained. Global refs: owned by the session, freed in `close` or via the
orphan list. Shm mapping: owned by the session; `munmap` in `close`/`set-shm nil`/finalizer.

### 3.9 Threads

None. All work happens inside `feed` on the Lisp thread. The decode cost (§6) does not justify
a thread; if one is ever added, it must only touch module-owned memory and wake Emacs via a
pipe process + `open_channel` (ghostel's `GhostelTerm.zig:975` pattern); Lisp calls are still
confined to module functions.

## 4. Language and build decision

**Decision: Zig 0.17.x module reusing ghostel's `emacs.zig`, with the zstd decoder vendored
as a C amalgamation compiled by `zig build`.** Measured on this machine (Apple Silicon,
synthetic 1600×1000 page-like BGRA frame, 6.4 MB → 827 KB at zstd level 1, ratio 7.7):
libzstd 1.5.7 decodes it in **2.3 ms** (2786 MB/s, `zstd -b1`); Zig 0.17.1
`std.compress.zstd.Decompress` (pure Zig, `/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std/compress/zstd/Decompress.zig`)
takes **46.6 ms** in ReleaseFast (137 MB/s; it also needs a `window_len + 128 KiB` buffer and
does not verify checksums — `Options.verify_checksum` panics if set). 20× slower rules the Zig
std decoder out for the hot path; it may stay as a build-option fallback for exotic targets but
is not the default. Pure C with libzstd would be as fast but loses ghostel's bindings, error
wrapper, build and CI scheme, and the user's familiarity; Zig compiles the C decoder fine
(ghostel already compiles `src/stb_image.c` via `addCSourceFile`, build.zig:104-106).

Zig version: ghostel pins `0.17.x` (`build.zig:7-14` comptime check, `build.zig.zon`
`minimum_zig_version = "0.17.0"`, CI uses 0.17.1, Homebrew has 0.17.1). Use the same check.

zstd source: generate `zstddeclib.c` from the facebook/zstd `v1.5.7` tag with
`build/single_file_libs/create_single_file_decoder.sh` (BSD-3/GPL-2 dual licence, GPL
compatible) and commit it under `vendor/zstd/` with `zstd.h` and `LICENSE`. Compile with
`-DZSTD_LEGACY_SUPPORT=0 -DZSTD_STRIP_ERROR_STRINGS=0 -DZSTD_DISABLE_ASM=1` (ASM is only for
x86_64 Huffman decode; keep it off for cross builds unless measured). Expose via
translate-c of a 3-line `src/zstd_c.h` (`#include "zstd.h"`).

### 4.1 Files and `build.zig`

```
<ladybird>/
  build.zig  build.zig.zon  symbols.map  Makefile
  src/{module,emacs,Session,Parser,Frame,View,zstd,shm,tests,version}.zig  src/emacs.h  src/posix.h  src/zstd_c.h
  vendor/emacs-module.h  vendor/zstd/{zstddeclib.c,zstd.h,LICENSE}
  lisp/ladybird-module-load.el   (loader; the rest of the Elisp is the other work package)
  test/ladybird-module-test.el  test/ladybird-test-helpers.el  test/fixtures/gen_stream.py  test/fixtures/*.ladybird
```

`build.zig` mirrors ghostel's minus ghostty/stb/Android/Windows-ConPTY: `standardTargetOptions`,
`standardOptimizeOption`, translate-c of `src/emacs.h` (include dir: `EMACS_INCLUDE_DIR` env,
`EMACS_BIN_DIR/../include`, else `vendor/`, ghostel `build.zig:178-236`), `addLibrary (.dynamic)`
named `ladybird-module`, `addCSourceFile (vendor/zstd/zstddeclib.c)`, release flags
(`strip`, gc-sections, `symbols.map` on Linux exporting only `emacs_module_init` and
`plugin_is_GPL_compatible`), install step renaming to `ladybird-module.{dylib,so}`
(`moduleOutputName`, ghostel `build.zig:238-244`), sidecar `ladybird-module.version` written from
`src/version.zig` (ghostel `build.zig:141-144`), and a `test` step on `src/tests.zig`.

`Makefile` targets (ghostel's shape, `/Users/daniel/.emacs.d/lib/ghostel/Makefile`):
`build` (`zig build --prefix . -Doptimize=ReleaseFast -Dcpu=baseline`), `test-zig`
(`zig build test`), `fixtures` (runs `gen_stream.py`), `test-native` (`emacs --batch -Q -L lisp
-L test -l ert -l test/ladybird-test-helpers.el -l test/ladybird-module-test.el -f
ert-run-tests-batch-and-exit`, depends on `build` and `fixtures`), `test` = both, `clean`.
`EMACS ?= emacs` — on this machine `/opt/homebrew/bin/emacs` (32.0.50).

### 4.2 Loading from Elisp (`lisp/ladybird-module-load.el`)

Mirror ghostel-module-install.el (`/Users/daniel/.emacs.d/lib/ghostel/lisp/ghostel-module-install.el:27-39,
71-74, 356-370, 529-614`): `defcustom ladybird-module-directory` (nil → directory of the package
file, resolved via `locate-library`), `defconst ladybird--minimum-module-version`, sidecar
`ladybird-module.version` read **before** `module-load` (refuse a stale module without mapping
it), `(concat "ladybird-module" module-file-suffix)`, `(module-load path)`, then
`(ladybird-module-version)` compared with `version<`. Loader never prompts or downloads at load
time; `ladybird-module-compile` (interactive) runs `zig build --prefix DIR …` with
`compilation-start` — download of prebuilt binaries is out of scope for v1. Platforms:
macOS arm64/x86_64 (`-Dtarget=x86_64-macos` for the cross build), Linux x86_64/aarch64
(`-Dtarget=x86_64-linux-gnu.2.35`, `aarch64-linux-gnu.2.35`, as ghostel CI
`.github/workflows/ci.yml:191-207`). Windows: not in v1 (no shm; stdio works but untested).

### 4.3 Running tests

`make test-zig` (parser/frame/view unit tests with embedded fixtures, no Emacs);
`make test-native` (ERT in `emacs --batch`, loads the built module, feeds fixture files);
`uvx elate -s NAME test --load-file test/ladybird-module-test.el` for an interactive GUI run of
the same ERT file (needed for the NS scale bug check and refresh timing).

## 5. Tasks (dependency order)

Each task lists files, what to write, and acceptance tests that run without Ladybird.

**T0 — Verify the NS `:scale` behaviour (½ day).** Run the §1.2 recipe in a GUI Emacs
(screen unlocked for screenshots). Record the result in this file under §7. If the bug is
confirmed, write the Emacs patch (image.c `canvas_prepare_for_display`, NS branch) and build
emacs-plus with it, or decide on the dpr-1 fallback. Deliverable: a note + optional patch
file `plans/emacs-canvas-ns-transform.patch`. Acceptance: the second screenshot shows both
colours at 100×100 points.

**T1 — Skeleton module (1 day).** `build.zig`, `build.zig.zon`, `symbols.map`, `Makefile`,
`src/module.zig`, `src/emacs.zig`/`emacs.h` (copied from ghostel, symbols trimmed to:
`nil t error quit wrong-type-argument ladybird-module-error canvas-refresh plist-get
multibyte-string-p provide ladybird-module list cons :data-width :data-height frame desync`
plus status symbols), `src/version.zig` = "0.1.0", `vendor/emacs-module.h`,
`lisp/ladybird-module-load.el`. Functions: `ladybird-module-version`, `create-session`, `close`,
`stats` (zeros). Add `env.canvasData` with the `env.size` check; `emacs_module_init` returns 2
if `runtime->size`/env too small (Emacs < 32).
Acceptance: `make build` on macOS arm64; `emacs --batch -l lisp/ladybird-module-load.el --eval
'(progn (ladybird-load-module) (princ (ladybird-module-version)))'` prints `0.1.0`; ERT
`ladybird-test-version` and `ladybird-test-session-lifecycle` (create, stats, close, `close` again
signals `ladybird-module-error`, dropping a session and `(garbage-collect)` does not crash).

**T2 — Record parser (1 day).** `src/Parser.zig`: `Parser.step (buf, consumed) → Step` where
`Step = union { need_more, record { kind, payload }, desync { reason, offset } }` and the
buffer management helpers (ensure capacity, compact). `src/Frame.zig`: `FrameHeader.parse
([]const u8) !FrameHeader` + `validate (payload_len)`. Zig tests: build a byte stream of 3
control records and 2 frame records in memory; for every split size in `1..=97` and for sizes
4096/65536 feed the stream in chunks and assert the identical record sequence; oversize length
→ desync; kind 3 → desync; frame header shorter than 44 bytes → `bad-frame`; `dx+dw > w` →
`bad-frame`; raw payload length mismatch → `bad-frame`. Compaction test: after a 20 MiB record
the buffer shrinks when empty.

**T3 — Fixture generator (½ day).** `test/fixtures/gen_stream.py` (stdlib only; uses
`compression.zstd` on Python ≥ 3.14, else shells out to the `zstd` CLI, both present here:
Python 3.15.2, zstd 1.5.7). Writes `*.ladybird` stream files and sidecar `*.json` describing the
expected final pixels. It imports `tools/ladybird_protocol.py` (inserting `../../tools` relative
to its own file into `sys.path`) for framing and for the pixel formula of 05 §2, which the ERT
and Zig tests reimplement. Fixtures:
`basic-raw-full.ladybird` (hello/welcome-shaped control records around one raw full 64×48
frame, view 1, seq 1); `zstd.ladybird` (one zstd full 1600×1000 frame, seed 7);
`damage-mix.ladybird` (full raw 320×200 then 6 damage rects alternating raw/zstd, some
full-width, some interior; expected = composed image); `resize.ladybird` (full 320×200, damage
rect 320×200, full 400×300, stale damage rect with old dims — expected statuses `painted
painted size-mismatch stale` when the canvas stays 320×200, and the expected 400×300 image);
`shm.ladybird` (one shm frame with offset 4096; the test creates the segment itself);
`bad.ladybird` (bad-frame cases followed by a valid control record, then an oversize length →
desync); `control-utf8.ladybird` (control payload with "héllo" and a 1 MiB JSON string).
Acceptance: `python3 -I test/fixtures/gen_stream.py test/fixtures/` writes all files; Zig tests
embed `basic-raw-full.ladybird` and `damage-mix.ladybird` via `@embedFile` and check parsing.

**T4 — Views, raw decode, canvas paint, feed (2 days).** `src/View.zig`, `src/Session.zig`,
`feed` with control + raw frames + events + coalesced refresh, `attach-canvas`, `detach`,
`repaint`, `view-size`, `canvas-pixel`, `canvas-row`, `canvas-fill`. Zig tests: `View.apply`
with raw rects on a store compared to the Python formula; resize rules (§2.2 steps 2-4) via a
fake canvas (dims + slice) injected through a small interface so `View` does not need Emacs.
ERT (batch): `ladybird-test-raw-full` — spec with `:data-width 64 :data-height 48`, attach, feed
`basic-raw-full.ladybird` in chunks of 1, 7, 13, 4096 and whole; events = 2 strings + one frame
event with status `painted`; every pixel equals the formula (`canvas-row` compared with
`unibyte` string built in Lisp via `(apply #'unibyte-string …)` for a row, and spot checks via
`canvas-pixel`); `ladybird-test-damage-mix` (statuses all `painted`, final image equals expected);
`ladybird-test-no-canvas` (statuses `stored`, then attach + `repaint` → `painted`, pixels
correct); `ladybird-test-resize` (statuses as in the fixture; then `plist-put` dims to 400×300,
`repaint` → `painted`, pixels correct); `ladybird-test-multibyte-chunk-signals`;
`ladybird-test-control-utf8` (string equals "…héllo…", `json-parse-string` works);
`ladybird-test-bad-and-desync` (statuses `bad-frame`, then the control string, then a `desync`
element; next feed returns nil; `reset` then feeding `basic-raw-full` works again);
`ladybird-test-refresh-called` (advice-add a counter on `canvas-refresh`: one call per feed that
painted, zero with `NO-REFRESH`, zero when nothing painted); `ladybird-test-quit` optional.

**T5 — zstd (1 day).** Vendor `zstddeclib.c`, `src/zstd.zig`, decode paths of §3.4, stats.
Zig test: decode the embedded `zstd.ladybird` frame and compare 64 sampled
pixels + a full `std.mem.eql` against the formula; truncated zstd payload → `decode-error`.
ERT: `ladybird-test-zstd-full` (chunks of 65536 and 8192 — the macOS socket case — statuses
`painted`, 1600×1000 pixels equal formula, sampled every 97th pixel for speed plus 3 full rows);
`ladybird-test-damage-mix` now exercises zstd rects as well.

**T6 — shm (1 day).** `src/shm.zig` (`std.c.shm_open`, `fstat`, `mmap`, `munmap`;
`posix.h` translate-c if the std declarations are missing on 0.17), `set-shm`, encoding 2,
ERT (`:tags '(posix)`): the test creates `/ladybird-t-<pid>` (≤ 31 chars) with
`ladybird-test--shm-create` — a tiny C/Zig helper is avoided by writing the segment from Emacs:
`shm_open` is not reachable from Lisp, so add a **test-only** module function
`ladybird-module--test-shm-write NAME OFFSET BYTES` (creates with `O_CREAT|O_RDWR`, `ftruncate`
once, copies bytes) compiled only when `-Dtest-helpers=true`; the Makefile builds the test
module with that flag into `.build/`. Test: write formula pixels at offset 4096, `set-shm`,
feed `shm.ladybird`, status `painted`, pixels correct; feed again after `set-shm nil` →
`shm-error`; name longer than 31 chars → signal with ENAMETOOLONG text (macOS only).

**T7 — Performance pass (1 day).** Benchmarks in `bench/ladybird-bench.el`: see §6. Tune:
`-Dcpu=baseline` vs native, `ZSTD_DISABLE_ASM` on x86_64, scratch reuse, `should_quit`
frequency (every 8 records). Record numbers in this file (§6).

**T8 — Loader polish and docs (½ day).** `ladybird-module-compile`, version mismatch warning,
README section "Building the native module" (Zig 0.17.1, `make build`, `EMACS_INCLUDE_DIR`),
`.github/workflows` job matrix for the four targets producing `ladybird-module-<arch>-<os>.*`
+ sidecar (copy ghostel's `build-native` job, drop Android/Windows/FreeBSD).

## 6. Performance plan

Measured here (M-series Mac): memcpy 6.4 MB = **0.07 ms**; libzstd decode of the synthetic
page frame = **2.3 ms** (compressed 827 KB); Zig std decoder 46.6 ms (not used). Per full
1600×1000 frame the module therefore costs ≈ 0.1 ms raw or ≈ 2.5 ms zstd, plus chunk copies:
6.4 MB / 64 KiB = 98 filter calls (stdio), 800 calls at 8 KiB (Unix socket on macOS), 7 calls
at 1 MiB; zstd payload 827 KB → 13 / 101 / 1 calls. Each filter call also allocates a Lisp
string of chunk size (Emacs does this regardless of the module). The dominant Emacs-side cost
is `canvas_prepare_for_display` on NS (per-pixel Objective-C, §1.1), expected 10–40 ms per
refresh for 1.6 Mpixel and independent of damage size; a 1.95 ms figure measured in a sandboxed
GUI session is unreliable (the screen was locked, the frame likely not drawn) — **re-measure
in T7** with the display awake. If it is tens of ms, cap refreshes at ~30 Hz from Lisp with
`NO-REFRESH` + timer, and consider an Emacs patch writing the NS bitmap planes directly.

How to measure (`bench/ladybird-bench.el`, run in a GUI Emacs via elate or `M-x`):
```elisp
(benchmark-run 20 (ladybird-module-feed s chunk t))          ; parse+decode+copy, no refresh
(benchmark-run 20 (ladybird-module-feed s chunk))            ; with canvas-refresh
(benchmark-run 20 (canvas-refresh c) (redisplay t))        ; Emacs upload + draw
(ladybird-module-stats s)                                    ; :decode-ns / :copy-ns per frame
```
with `chunk` = whole fixture file read via `insert-file-contents-literally` + `buffer-string`
(unibyte), and `ladybird-test--chunks` to split it.

`read-process-output-max`: let-bind to `(* 1024 1024)` around `make-process` /
`make-network-process` (captured per process, process.c:978). It only helps when the OS
buffer can deliver that much: pipes 64 KiB on macOS (Linux `/proc/sys/fs/pipe-max-size`,
default 1 MiB), Unix sockets 8 KiB on macOS, TCP 128 KiB. Recommendation to the Elisp
package: local server → stdio (`make-process`) with shm negotiated; remote → ssh stdio;
`--emacs-socket` on macOS is the slowest transport for frame payloads. Also set
`process-adaptive-read-buffering` nil for the connection (process.c:8981) so Emacs does not
delay after short reads.

## 7. Risks, open questions, protocol feedback

All protocol feedback items below were resolved in `01-protocol.md` v1 (its §11 lists the
decisions: 44-byte header stated, `seq` from 1, pledged zstd content size, `shm` message
per segment instead of a name in `welcome`, every record acked, `full` damage equals the
frame, `more` flag for bands above 64 MiB, stdio preferred locally). Note the new `more`
flag (bit 1): the view stays dirty without a `canvas-refresh` until a frame record without
`more` has been painted. Bands arrive one per ack, so this state lives in the view across
`feed` calls. Implement against the protocol file.

T0 result (2026-11-09, emacs-plus@32 32.0.50 NS, `frame-scale-factor` 2.0, elate GUI
session, screenshots analysed per device pixel)
- On NS a canvas never honours `:scale`, on first display as well as after a refresh: a
  200×200 canvas with `:scale 0.5` reports `(image-size c t)` = `(100 . 100)` but shows only
  its top-left 100×100 pixels, unscaled. `canvas_load` leaves `img->refresh` at 1 while
  `canvas_get` starts `c->refresh` at 2, so `canvas_prepare_for_display` runs right after
  `lookup_image` applied the transform, and `ns_image_reset` returns an `EmacsImage` with
  no transform.
- No Lisp workaround on a canvas helps (fresh spec per refresh, `image-flush`,
  `clear-image-cache`, `:width`/`:height` instead of `:scale`).
- `plans/emacs-canvas-ns-transform.patch` makes `ns_image_reset` (`src/nsimage.m`) carry
  `transform` and `smoothing` over to the new image. It applies to Emacs `0f76a435a2`; it
  is neither compiled nor tested.
- The NS transform path itself is exact: a `pbm` image of the same pattern at `:scale 0.5`
  draws 1 image pixel per device pixel. `:transform-smoothing nil` means "unspecified" in
  `image_set_transform`, not `NSImageInterpolationNone`; a 2:1 downscale is exact anyway.
- Refresh cost, `(canvas-refresh c) (redisplay t)`: 84 ms at 3200×2000, 34.5 ms at
  1600×1000, the same with the display off, so the per-pixel loop in
  `canvas_prepare_for_display` dominates (R2).
- Not verified: an uncompressed RGBA `tiff` image with `:data`, `:scale 0.5` and
  `image-flush` per frame measured 19 ms at 3200×2000, but with the screen locked and
  without a screenshot.
- Until Emacs is patched the client renders at dpr 1.0 without `:scale`
  (`ladybird-device-pixel-ratio` 1.0): correct picture, 2× nearest-neighbour upscale.

Risks
- R1 NS ignores `:scale` on a canvas (T0 result above) — blocks crisp Retina output until
  Emacs is patched; fallback renders at dpr 1 (blurry).
- R2 NS refresh cost O(canvas) per refresh (§1.1) caps the frame rate at about 29 Hz for
  1600×1000 and 12 Hz for 3200×2000 (measured in T0); mitigation: Lisp-side refresh throttling, Emacs patch.
- R3 `canvas-refresh` draws via `redraw_image_glyphs` outside a normal update cycle; on NS this
  relies on `ns_focus`/double buffering working from a process filter. If artefacts appear,
  Lisp can call `canvas-refresh` from a timer instead (`NO-REFRESH`).
- R4 `--module-assertions` aborts if a module function runs during GC: never call module
  functions from `post-gc-hook`; finalizer touches no env (designed in §3.1).
- R5 Zig 0.17 API churn (std.Io, translate-c of system headers); ghostel is the working
  reference for the same version.
- R6 Big-endian hosts: untested; byte-swap path compile-time only.

Open questions
- Should `feed` also accept a buffer position range (to avoid the Lisp string copy when
  output is inserted into a process buffer)? Not possible through the module API; strings only.
- Multiple frames per view in one chunk: current design paints each and refreshes once;
  fine with one-frame-in-flight.

Protocol feedback (01-protocol.md)
- §4 header size is 44 bytes; state it explicitly ("44-byte header followed by payload").
- §4 shm: macOS cannot grow a POSIX shm object (`ftruncate` works once, verified) and names are
  ≤ 31 chars including `/`; `/ladybird-12345` is fine, but anything with hostname or view id is
  not. Specify: on `set_viewport` with a larger frame the server creates a **new** segment and
  announces it before the first frame that uses it (e.g. `{"type":"shm","name":"/ladybird-12345-2",
  "size":N}`); the client answers `{"type":"shm_attached","name":…}` and only then may the
  server `shm_unlink` the old one and start writing shm frames to the new one. Add `size` to
  `welcome.shm` as well (`"shm":{"name":"/ladybird-12345","size":6400000}`).
- §4: say that the client acks frames it could not decode too, and that `seq` is per view
  starting at 1 (the module reports it verbatim).
- §4 zstd: recommend the server set the frame content size (`ZSTD_compress`/`ZSTD_compress2`
  with pledged size does) — not required by the client but cheap and helps other clients.
- §1: note the macOS Unix-socket 8 KiB chunking; recommend stdio for local use and reserve
  `--emacs-socket` for forwarding scenarios; or set `SO_SNDBUF` server-side (does not help the
  receiver's 8 KiB `recvspace`).
- §2 `hello.viewport.dpr`: the client sends `(frame-scale-factor)`; if T0 forces the dpr-1
  fallback, the client will send `dpr: 1.0` with a viewport in points — the protocol already
  allows that, no change needed.
- Missing: a `frame` validation statement that `damage` for `full` frames equals the frame
  rect (the module tolerates a smaller rect and zero-fills the rest on resize).

## 8. Size estimate

| Task | Effort | New code |
| --- | --- | --- |
| T0 NS scale verification (+ optional Emacs patch) | 0.5 d | 0–30 lines C |
| T1 skeleton, build, loader | 1 d | ~250 Zig (excl. copied emacs.zig ~650), ~120 Elisp |
| T2 parser + frame header + tests | 1 d | ~250 Zig + ~200 tests |
| T3 fixture generator | 0.5 d | ~200 Python |
| T4 views, raw, paint, feed, ERT | 2 d | ~500 Zig, ~300 Elisp tests |
| T5 zstd | 1 d | ~80 Zig + vendored C |
| T6 shm | 1 d | ~150 Zig, ~80 Elisp tests |
| T7 performance | 1 d | ~100 Elisp bench |
| T8 polish, CI | 0.5 d | ~100 YAML/Elisp |
| Total | ~8.5 d | ~1.5k Zig, ~0.6k Elisp, 0.2k Python |
