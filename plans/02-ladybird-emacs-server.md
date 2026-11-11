# 02 — Ladybird side: `EmacsWebView`, stream transport, protocol server

Implements the server half of `/Users/daniel/src/dakra/ladybird/plans/01-protocol.md`
(binding; message names below refer to it). Research was done against the Ladybird
checkout at `/Users/daniel/src/ladybird`, master `da9df7639` (2026-11-09). All relative
paths below are inside that checkout. Every function and type named here was verified
in that revision; where the protocol draft cannot be implemented as written, section 8
says so.

## 1. Scope and non-goals

v1 delivers `Ladybird --headless=emacs`:

- up to `--emacs-max-views` views (default 16), each an `EmacsWebView` with a WebContent
  process of its own (§2.10); `close_view` destroys one, and the server keeps running with
  zero views
- transports: stdio (default) and `--emacs-socket=PATH` (Unix listener, 0600, unlinked on exit)
- frame encodings raw (0), zstd (1), shm (2); one frame in flight, coalesced damage, `frame_ack`
- full input: `mouse` (down/up/move/wheel/leave, click counts), `key`, `text`
- navigation and page commands of protocol section 6 except `request_source` (see 8.4)
- `state`, `cursor`, `link_hover`, `tooltip`, `favicon`, `background_color`,
  `find_result`, `ime`, `console`, `crashed`
- dialogs and pickers of section 7 including `context_menu` and `external_url`
- second client replaces the first; disconnect keeps the view; SIGINT/SIGTERM/SIGHUP clean up

Out of scope (protocol section 10 plus Ladybird-side limits): TCP transport, file uploads from the client machine, `context_menu_action`, downloads,
devtools, Windows (`TerminalWebView` is also `if (NOT WIN32)`).

## 2. Design

### 2.1 Why headless mode is the seam

`Documentation/ProcessArchitecture.md`: with `--headless`, "UI has nothing to do, and Hub
takes over its process". Concretely `UI/Qt/main.cpp:38-45` (`LADYBIRD_HUB_IN_OWN_PROCESS`,
defined for `LINUX OR APPLE` in `UI/CMakeLists.txt:116`) `execv()`s the `Hub` executable
with the same argv when any argument starts with `--headless`. `execv` keeps fds 0/1/2,
so stdio reaches the Hub process untouched. `Services/Hub/main.cpp` then builds
`Hub::Application` (a `WebView::Application`, `Services/Hub/Application.h:46`), skips the
UI connection when `browser_options().headless_mode.has_value()`, and calls
`application->execute()`, which is `WebView::Application::execute()` in
`Libraries/LibWebView/Application.cpp:2103`. That function already creates a
`HeadlessWebView` or `TerminalWebView` and runs `m_event_loop->exec()`. Our view is a
third branch there. Every `ViewImplementation` callback a GUI would wire up is available
in-process, with no IPC to add: that is why the Emacs server lives in `LibWebView`.

What headless cannot do: there is no tab strip, so `Application::open_blank_new_tab`
returns `{}` (`Libraries/LibWebView/Application.h:284`; `Hub::Application` falls back to it
without a UI, `Services/Hub/Application.cpp:108-112`). Consequences: `get_source()` shows
nothing (8.4), and windows that pages open get an `EmacsWebView` of their own or, when
there is none for them, a hidden `HeadlessWebView::create_child` (2.11).

### 2.2 Files to add

| File | Content |
| --- | --- |
| `Libraries/LibWebView/EmacsProtocol.h/.cpp` | Record framing (`u32 LE length, u8 kind, payload`), `FrameHeader` struct + serializer, `RecordReader` (incremental parser over a `ByteBuffer`), JSON helpers (`JsonObject` builders for `state`, `welcome`, …), key/modifier/button/cursor mapping tables. No I/O, unit-testable. |
| `Libraries/LibWebView/EmacsTransport.h/.cpp` | `EmacsTransport` base (one connected client: non-blocking fd, read notifier, write queue with write notifier), `EmacsStdioTransport`, `EmacsSocketTransport` (`Core::LocalServer`), `take_over_stdio()` (stderr/stdout redirect). |
| `Libraries/LibWebView/EmacsFrameEncoder.h/.cpp` | Pixel copy from `Gfx::Bitmap` (BGRA swizzle if needed), zstd compression (`ZSTD_CCtx` reuse, level 1), `EmacsSharedFrameBuffer` (POSIX shm object: create, grow-by-replace, unlink). |
| `Libraries/LibWebView/EmacsWebView.h/.cpp` | `class EmacsWebView final : public HeadlessWebView`: one view, with everything that is per view (frames and their flow control, shared memory, state, input, requests, find, hints, screenshots, console). |
| `Libraries/LibWebView/EmacsServer.h/.cpp` | `EmacsServer`: the transport, the handshake, the views and the dispatch of client messages to them, and the turns the views take on the connection (§2.10). |
| `tools/ladybird-client.py` (in `/Users/daniel/src/dakra/ladybird/tools/`) | Python test client, section 5.9. |

Changes to existing files:

- `Libraries/LibWebView/Options.h`: add `Emacs` to `enum class HeadlessMode` (after `Terminal`);
  add to `BrowserOptions`: `Optional<ByteString> emacs_socket_path {}; Optional<ByteString> emacs_log_path {};`.
- `Libraries/LibWebView/Application.cpp`:
  - in the `--headless` `accept_value` lambda (line ~352), inside the existing `#if !defined(AK_OS_WINDOWS)`:
    `else if (value.equals_ignoring_ascii_case("emacs"sv)) headless_mode = HeadlessMode::Emacs;`
    and extend the help string.
  - add options `--emacs-socket=PATH` and `--emacs-log=PATH` next to `--device-pixel-ratio` (line ~379).
  - next to `TerminalWebView::take_over_terminal()` (line ~573, after option parsing, before
    `launch_services()` at ~706): `if (headless_mode == HeadlessMode::Emacs) TRY(EmacsTransport::take_over_stdio(emacs_socket_path.has_value() ? EmacsTransport::Kind::Socket : EmacsTransport::Kind::Stdio, emacs_log_path));`
  - in `execute()` (line ~2103): the `Emacs` branch does **not** create a view up front and
    does **not** enforce "exactly one URL": `if (mode == Emacs) { m_emacs_server = TRY(EmacsServer::create(move(theme), m_browser_options)); return m_event_loop->exec(); }`
    placed before the `urls.size() != 1` check. With a URL on the command line the
    server creates the view at startup and loads it (so `ssh host Ladybird --headless=emacs URL` works).
  - `Application.h`: `OwnPtr<EmacsServer> m_emacs_server;` (forward-declared in `Forward.h`).
- `Libraries/LibWebView/CMakeLists.txt`: inside the existing `if (NOT WIN32)` block
  (line 114): `list(APPEND SOURCES EmacsProtocol.cpp EmacsTransport.cpp EmacsFrameEncoder.cpp EmacsWebView.cpp)`;
  after line 173: `target_link_libraries(LibWebView PRIVATE $<IF:$<TARGET_EXISTS:zstd::libzstd_shared>,zstd::libzstd_shared,zstd::libzstd_static>)`.
- `Meta/CMake/check_for_dependencies.cmake`: `find_package(zstd CONFIG REQUIRED)` next to `find_package(ZLIB REQUIRED)` (line 78).
- `vcpkg.json`: add `"zstd"` as a top-level dependency (today it is only a `curl` feature, line 29, so no `zstd.h` is installed for us). Header: `#include <zstd.h>`.
- `Libraries/LibWebView/Forward.h`: `class EmacsWebView; class EmacsServer;`.

### 2.3 Callback → message table

All callbacks are members of `WebView::ViewImplementation` (`Libraries/LibWebView/ViewImplementation.h:594-693`) unless marked *virtual*, which means a protected virtual to override.

| Ladybird | Protocol message |
| --- | --- |
| `on_title_change(Utf16String const&)`, `on_url_change(URL::URL const&)`, `on_loading_state_change(bool)`, *virtual* `did_change_state()` (fires from `update_navigation_action_state()` when `can_navigate_back()`/`can_navigate_forward()` change), *virtual* `update_zoom()` | `state` built from `displayed_url().serialize()`, `title()`, `is_loading()`, `can_navigate_back()`, `can_navigate_forward()`, `zoom_level()`. Coalesce with `Core::deferred_invoke` so a navigation emits one `state`. |
| *virtual* `did_accept_presented_backing_store(i32 bitmap_id, Gfx::IntRect damage)` | frame record (2.4) |
| `on_cursor_change(Gfx::Cursor const&)` | `cursor` — `Gfx::Cursor` is `Variant<StandardCursor, ImageCursor>`; table 3.5; `ImageCursor` → `"default"` |
| `on_link_hover(URL const&)`, `on_link_unhover()` | `link_hover` with url / null |
| `on_enter_tooltip_area(ByteString const&)`, `on_leave_tooltip_area()` | `tooltip` with text / null |
| `on_favicon_change(Optional<Gfx::Bitmap const&>)` | `favicon` with `encode_base64(TRY(Gfx::PNGWriter::encode(bitmap)))` (`Libraries/LibGfx/ImageFormats/PNGWriter.h:37`, `AK/Base64.h:60`); absent bitmap → `png: null` |
| `on_page_background_color_change(Gfx::Color)` | `background_color` `#rrggbb` |
| `on_find_in_page(size_t current_match_index, Optional<size_t> const& total)` | `find_result` (`total` null when unknown) |
| `on_input_method_state_change()` → `input_method_state()` (`is_enabled`, `caret_rect: Optional<Web::DevicePixelRect>`) | `ime` |
| `on_console_message(ConsoleOutput)` (`Libraries/LibWebCommon/WebView/ConsoleOutput.h:58`: `Variant<ConsoleLog, ConsoleError, ConsoleTrace, ConsoleGroupEnd>`); enabled with `start_sending_console_output(bool messages, bool errors)` | `console` — level from `ConsoleLog::level` (`JS::ConsoleLogLevel`), text = arguments joined by space (`JsonValue::serialized()` for non-strings); `ConsoleError` → level `"error"`, text `name: message` |
| `on_web_content_crashed(WebContentCrashReason)` (`ProcessCrash`, `RejectedIPC`) | `crashed` with reason string |
| `on_close()` | `view_closed {reason:"closed"}`, then destroy the view |
| `on_request_alert(Utf16String const&)`, `on_request_confirm(…)`, `on_request_prompt(message, default)`, `on_request_before_unload(String const& source, Function<void(bool)>)` | `dialog` kinds alert/confirm/prompt/beforeunload. Answer: `alert_closed()`, `confirm_closed(bool)`, `prompt_closed(Optional<Utf16String>)`, stored before-unload callback. Keep `HeadlessWebView`'s `m_pending_dialog` bookkeeping so `on_request_accept_dialog`/`on_request_dismiss_dialog` (WebDriver) still work: set `m_pending_dialog` in our handlers too. |
| `on_request_set_prompt_text(Utf16String const&)` | `dialog_update` with the open prompt's `id` |
| `on_request_select_dropdown(Gfx::IntPoint widget_position, i32 minimum_width, Vector<Web::HTML::SelectItem>)` | `select`; answer `select_dropdown_closed(Optional<u32>)`. `SelectItem` is `Variant<SelectItemOption{id,selected,disabled,label,value}, SelectItemOptionGroup{label, items}, SelectItemSeparator>` → flatten groups into `group` field; separators become `{separator:true}`; `min_width` arrives in CSS px (`ViewImplementation.cpp:2799`) and is multiplied by the device pixel ratio before sending. |
| `on_request_file_picker(Web::HTML::FileFilter const&, Web::HTML::AllowMultipleFiles)` | `file_picker`; `accept` from `FileFilter::filters` (`Variant<FileType{Audio,Image,Video}, MimeType{value}, Extension{value}>` → `"audio/*"`, `"image/*"`, `"video/*"`, mime string, `".ext"`). Answer `file_picker_closed(Vector<SelectedFile>)` with `WebView::create_selected_file(ByteString path)` (`Libraries/LibWebView/Utilities.h:22`) per path; unreadable paths → `error` and skipped. |
| `on_request_color_picker(Color current)` | `color_picker`; answer `color_picker_update(Optional<Color>, Web::HTML::ColorPickerUpdateState::Closed)` |
| `on_request_date_picker(Utf16String input_type, value, min, max)` | `date_picker`; answer `date_picker_closed(Optional<Utf16String>)` |
| `on_request_permission(PermissionPromptRequest const&, PermissionPromptCallback)` (`ViewImplementation.h:110,123`; `name: Web::Permissions::PermissionName` via `Web::Permissions::to_string`, `top_level_origin.serialize()`, `is_file`) | `permission`; call `did_show_permission_prompt(request)` when sent; answer with `Web::Permissions::PromptOutcome` (`AllowAlways`, `AllowOnce`, `Block`, `Dismissed`, `Ignored`, `Cancelled`): `allow_once`→`AllowOnce`, `allow_always`→`AllowAlways`, `deny`→`Block`, `dismiss`→`Dismissed`. `on_cancel_permission_prompt(request)` → call stored callback with `Cancelled`, drop id, send `permission_cancelled`. |
| `on_request_external_url_confirmation(URL const&, URL::Origin const&, ExternalURLHandler const&, Function<void(bool)>)` | `external_url` with `application = handler.application_name()`; answer calls the stored function |
| *virtual* `did_request_context_menu(ContextMenuRequest)` (`Libraries/LibWebView/ContextMenuRequest.h`: `kind ∈ {Page, Link, Image, Media}`, `widget_position`, `is_editable`, `selected_text`, `link_navigation`/`navigation` (`Web::HTML::PreparedNavigationDescriptor`, URL via its `url` member), `image_mime_type`, `media`) | `context_menu` |
| `on_new_web_view` | A view for the window, announced with `view_created {opener}` (2.11). Without one, `popup_blocked {view, url}` (`url` null when the callback does not supply one): the callback must return a window handle synchronously, so `HeadlessWebView`'s hidden child is created; it is closed once its first URL is known, which is reported |
| page clipboard writes (copy, `navigator.clipboard.writeText`): headless keeps them in `Application`'s in-process `m_clipboard`; find the hook in T5 (`Application::insert_clipboard_item` or the view's clipboard callback) | `clipboard {view, text}` for `text/plain` representations |
| `on_request_screenshot`, `on_request_dictionary_lookup`, `on_activate_tab`, `on_theme_color_change`, DOM/devtools callbacks | ignored |

Client → server dispatch (`EmacsServer::handle_control(JsonObject const&)`):

| Message | Call |
| --- | --- |
| `hello` | validate `protocol == 1`, pick encoding (first of client list in {zstd, raw} that we support; raw always), shm only if `shm:true` and transport is stdio or socket on the same host (we cannot tell; trust the client), reply `welcome`, then `state` + full frame for the view if any |
| `create_view` | `EmacsWebView::create(theme, {width,height}, dpr)`; `view_created {view:1, url, title, width, height, dpr}`, `state`, full frame; `url` → `load` |
| `close_view` | `view = nullptr` (destructor runs; `HeadlessWebView` has no explicit close for the root), `view_closed {reason:"client"}` |
| `set_viewport` | `m_device_pixel_ratio = dpr; reset_viewport_size({width, height})` (`HeadlessWebView::reset_viewport_size` → `set_window_size` + `handle_resize()` which sends `async_set_viewport(viewport_size(), m_device_pixel_ratio, …)`); mark next frame `full` |
| `set_visibility` | `set_system_visibility_state(visible ? Web::HTML::VisibilityState::Visible : Hidden)` |
| `set_focus` | `set_has_system_focus(bool)` |
| `mouse`, `key`, `text` | section 3; `text` → `commit_text_from_input_method(Utf16String::from_utf8(text))` (what `TerminalWebView` does for bracketed paste) |
| `load` | `WebView::sanitize_url(text, Application::settings().search_engine_settings().engine)` (`Libraries/LibWebView/URL.h:35`), `load(url)`; `error` if none |
| `load_html` | `load_html(StringView)` |
| `reload` | `reload(bypass_cache ? BypassCache::Yes : BypassCache::No)` |
| `stop` | `stop_loading()` |
| `history` | `traverse_the_history_by_delta(int)` |
| `zoom` | `zoom_in()`, `zoom_out()`, `reset_zoom()` |
| `find` | empty query → `find_in_page_end()`; else `find_in_page(Utf16String, case_sensitive ? CaseSensitivity::CaseSensitive : CaseInsensitive, highlight_all)` |
| `find_step` | `find_in_page_next_match()` / `find_in_page_previous_match()` |
| `edit` | `select_all()`, `undo()`, `redo()`; `cut` → `cut_selected_text()` promise, resolved text sent as `clipboard` |
| `paste` | `Application::the().insert_clipboard_item({ .system_clipboard_representations = { { "text/plain"_string, ByteString(text) } } })` then `paste_from_clipboard(Web::Clipboard::PasteMode::PlainTextOnly)` — gives the page a real paste event with user activation (`ViewImplementation.cpp:2818`) |
| `request_selection` | `selected_text()->when_resolved(...)` → `selection` |
| `request_source` | answer `error` in v1 (8.4) |
| `screenshot` | `visible`: encode `displayed_frame()` bitmap with `PNGWriter` to `path`; `full`: `take_screenshot(ScreenshotType::Full)->when_resolved(LexicalPath)` then move the file to `path` with `FileSystem::move_file` (8.3) |
| `set_console` | `start_sending_console_output(enabled, enabled)` |
| `frame_ack` | 2.4 |
| `shm_failed` | drop the segment (unlink), disable shm for this client, `m_frame_in_flight = false`, `m_frame_needs_full = true`, flush |
| `ping` | `pong` |
| `*_closed` | table above |

### 2.4 Frame flow control

Source of truth: `ViewImplementation::server_did_paint` (`ViewImplementation.cpp:424`)
calls `m_backing_stores->present(bitmap_id, size, dpr)`, then `release_backing_store(bitmap_id_to_release)`
(the *previous* front buffer goes back to the Compositor immediately), then our
`did_accept_presented_backing_store(bitmap_id, damage_rect)`. The new front stays ours
until the next present. `backing_stores().displayed_frame()` returns
`PageBackingStores::Frame { shared_image_buffer, size, device_pixel_ratio, bitmap_id }`,
and `shared_image_buffer->bitmap_if_present()` yields a `RefPtr<Gfx::Bitmap>` only when the
view called `set_presents_from_cpu_memory(true)` (`ViewImplementation.cpp:493`) — do that
right after `initialize_tab(...)`, as `TerminalWebView::create` does. The buffers are
`BitmapFormat::BGRA8888`, premultiplied (`Libraries/LibGfx/SharedImageBuffer.cpp:18,34`),
which is exactly the protocol's pixel format; keep the RGBA swizzle from
`TerminalWebView`'s `convert_to_rgb` as a fallback keyed on `bitmap.format()`.

Because we copy pixels out at send time (into the record buffer, the zstd output, or the
shm segment), we never need to hold a backing store: no `release_backing_store` override.

State per view: `Optional<Gfx::IntRect> m_pending_damage; bool m_frame_needs_full { true };
bool m_frame_in_flight { false }; u32 m_frame_seq { 0 }; bool m_flush_scheduled { false };`

```
did_accept_presented_backing_store(_, damage):  m_pending_damage = union; schedule_frame_flush()
schedule_frame_flush(): once per event-loop turn via Core::deferred_invoke (copy of TerminalWebView::schedule_frame_flush)
flush_frame():
  if (!client || !client->handshake_done || m_frame_in_flight || !m_pending_damage) return
  frame = backing_stores().displayed_frame(); bitmap = frame->shared_image_buffer->bitmap_if_present(); if (!bitmap) return
  rect = full ? frame rect : m_pending_damage->intersected(frame rect); if empty return
  if (frame size != m_last_sent_size) full = true, rect = frame rect
  encode + send record (seq = ++m_frame_seq); m_frame_in_flight = true; m_pending_damage.clear(); m_frame_needs_full = false
handle frame_ack(seq): if seq == m_frame_seq: m_frame_in_flight = false; if (m_pending_damage) schedule_frame_flush()
```

A hidden view (`set_visibility false`) stops presenting (`update_compositor_context_visibility`), and `flush_frame` also sends nothing for it, as frames presented before the hide can still arrive (§2.10). On client disconnect: `m_frame_in_flight = false`, `m_frame_needs_full = true` so the next client gets a full frame. On viewport change: `m_frame_needs_full = true`.

Encoding choice per frame: shm if negotiated and the segment can hold the frame; else zstd if negotiated and `rect.w*rect.h*4 >= 16 KiB`; else raw. A raw payload above the 64 MiB record limit is split into horizontal bands (protocol §4.4): consecutive `seq`, flag `more` on all but the last, each band sent only after the previous one is acked.

### 2.5 Shared memory

`Core::AnonymousBuffer`/`Core::System::anon_create` are unusable here: on Linux they use
`memfd_create` and on macOS they `shm_unlink` the name immediately (`Libraries/LibCore/System.cpp:245-258`),
so no foreign process can map them. `EmacsSharedFrameBuffer` does it by hand:

- name `/ladybird-<pid>-<generation>` (macOS `PSHMNAMLEN` is 31 bytes, this fits);
  `shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600)` **without** `O_CLOEXEC` (rejected on macOS 26.4+,
  see comment at `System.cpp:253`), then `fcntl(fd, F_SETFD, FD_CLOEXEC)`; `ftruncate(fd, size)`; `mmap(PROT_READ|PROT_WRITE, MAP_SHARED)`
- size = `round_up_to_power_of_two(width*height*4, PAGE_SIZE)` for the viewport from `hello`/`set_viewport`, plus 25 % headroom
- macOS allows `ftruncate` only once per object, so growing means: create generation n+1, send
  `{"type":"shm","name":…,"size":…}` (8.10), unlink generation n after the next `frame_ack`
- shm frames: copy the whole frame into offset 0 with stride `frame_width*4` (only the damage rows need copying when the size is unchanged), payload `u64 offset = 0`
- `shm_unlink` in the destructor, on client replacement when the new client did not ask for shm, and from the signal handler

### 2.6 stdio transport and stderr redirection

Nothing but records may reach fd 1. Follow `TerminalWebView::take_over_terminal()`
(`TerminalWebView.cpp:70-90`) in `EmacsTransport::take_over_stdio()`:

1. `s_stream_out = dup(STDOUT_FILENO)`, `s_stream_in = dup(STDIN_FILENO)`, both `FD_CLOEXEC` (helpers must not inherit the stream).
2. log path: `--emacs-log` or `/tmp/ladybird-emacs-<pid>.log`; `open(O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0644)`; `dup2(log, STDOUT_FILENO)`; `dup2(log, STDERR_FILENO)`; `dup2(open("/dev/null"), STDIN_FILENO)`.
3. `signal(SIGPIPE, SIG_IGN)` so a dead reader shows up as `EPIPE` on write, handled as disconnect.

It must run before `launch_services()` (helpers inherit fds) and before any `outln` — the
call site in `Application::initialize` next to `take_over_terminal()` satisfies both;
`outln`/`dbgln` after that point land in the log (e.g. `display_download_confirmation_dialog`
uses `outln`, `Application.cpp:2308`). For the socket transport the same redirect
runs, so the log location is identical for both. The log path is sent in `welcome` as `log` (8.12).

### 2.7 Reading and writing the stream

`EmacsTransport::Client { int in_fd; int out_fd; ByteBuffer inbox; Vector<ByteBuffer> outbox; size_t outbox_offset; RefPtr<Core::Notifier> read_notifier, write_notifier; }`

- Read: `Core::Notifier::construct(in_fd, Core::Notifier::Type::Read)`, `on_activation` reads up to 64 KiB with `Core::System::read`; `0` bytes or error other than `EINTR/EAGAIN` → disconnect. Append to `inbox`, loop: need 5 bytes for header (`length` counts the kind byte, so the payload is `length - 1` bytes); `length == 0` or `length > 64 MiB` → `reject`+disconnect; when complete, dispatch (kind 1 → `JsonParser::parse(StringView)`, must be object, else `error`; kind 2 is never sent by the client, ignore).
- Write: `send_record(kind, payload)` builds `length|kind|payload` (`length = 1 + payload size`) in one `ByteBuffer` (frame header + pixels assembled directly into it to avoid a second copy), tries `Core::System::write` immediately while `outbox` is empty; on `EAGAIN`/partial write, queue and enable a `Type::Write` notifier that drains. `EPIPE`/`ECONNRESET` → disconnect.
- Stdio: `in_fd = s_stream_in`, `out_fd = s_stream_out`, set `O_NONBLOCK` on both.
- Socket: `Core::LocalServer::construct()`; `unlink(path)` first (`LocalServer::listen` does not, `LocalServer.cpp:59-103`); `listen(path)`; `Core::System::chmod(path, 0600)` right after (the `fchmod` in `listen` is skipped on macOS and only affects the fd anyway); `on_accept = [](NonnullOwnPtr<Core::LocalSocket>)`. Call `socket->set_blocking(false)` explicitly: `LocalServer::accept` sets `FIONBIO` on the listening fd, not the accepted one, on macOS (`LocalServer.cpp:124-128`). Use `socket->fd()` with our own notifiers rather than `on_ready_to_read`, so both transports share one code path; keep the `LocalSocket` alive for ownership.
- Second connection while one is connected: send `{"type":"replaced"}` to the old client, close it, adopt the new one. Only one pending connection is ever accepted per event-loop turn.

### 2.8 Lifecycle

- Startup: `EmacsServer::create(theme, options)` builds the transport; stdio starts in "connected, awaiting hello"; socket starts listening. If `options.urls` is non-empty, the view is created at once with `window_width/height` and `device_pixel_ratio` from the options and `load(urls.first())`.
- Hello timeout: none in v1 (ssh startup can be slow). Any non-`hello` first message → `reject`.
- Client disconnect: drop notifiers and fds, reset in-flight state, keep the view, keep listening (socket) or, for stdio, quit the event loop with `Core::EventLoop::current().quit(0)` — once stdin is at EOF nobody can ever reconnect.
- Page closes itself (`on_close`): `view_closed`, destroy view; the process stays up until the client goes away or sends nothing (stdio EOF ends it).
- Signals: headless runs do not register the SIGINT/SIGTERM handlers (`m_persists_sessions` is false, `Application.cpp:1764`), so register with `Core::EventLoop::register_signal(signo, handler)` for `SIGINT, SIGTERM, SIGHUP` as `TerminalWebView::enter_terminal_modes` does: handler closes the client, unlinks the socket path and shm segment, then `Core::EventLoop::current().quit(0)`. The `EmacsServer` destructor repeats the unlinking (idempotent). Helpers are torn down by `Application`'s destructor as today.

### 2.9 Hints

Protocol §6.1. The work is split between the UI process (`EmacsWebView.cpp`, with the
parts without I/O in `EmacsProtocol.cpp`, unit-tested: validation, labels, parsing the
processes' answers and merging them with `merge_hint_answers`) and every WebContent process
that hosts a document of the tab (`Services/WebContent/PageHints.cpp`, and the guarded
click in `Libraries/LibWeb/Page/GuardedClick.cpp`). No script runs in the page.

- **Messages.** `WebContentServer.ipc` has `hints_collect(request_id)`,
  `hints_draw(labels)`, `hints_narrow(prefix)`, `hints_clear()`,
  `hints_activate(request_id, node_id)`, `hints_guard_click(request_id, element, frame,
  root, event_ids)` and `hints_cancel_click(request_id)`; `WebContentClient.ipc` answers
  with `did_collect_hints`, `did_prepare_hint_activation` and `did_finish_hint_activation`,
  which `WebContentPage` hands to the view's `on_hints_collected`,
  `on_hint_activation_prepared` and `on_hint_activation_finished`.
- **Collecting.** `hints` validates `id` and `alphabet`, ends any previous session silently
  and sends `hints_collect` to every page of `CanonicalTraversable::for_each_hosting_page`.
  The process hosting the top-level document has 5 s to answer, or the session ends with
  `hints_cancelled`; once it answered, the others have 500 ms more, and the frames of a
  process that has not answered by then are left out. Each process walks every local root it
  hosts (also one inside a frame another process hosts) and, depth first, the documents of
  same-process frames inside it, every shadow root included except user-agent ones. A
  document that is not HTML (an SVG document) is not searched, as the labels would not show
  in it. An element is a candidate by the kinds of §6.1, an SVG `a` with `href` or
  `xlink:href` included; a link, `area`, `button`, `input` other than hidden, `select`,
  `textarea`, `summary` and an element with `contenteditable` qualify strongly, a `label`
  and an element that qualifies only by `onclick`, `tabindex` or `role` weakly. It is listed
  when it is not disabled, it and its ancestors have no `opacity: 0`, the bounding box of
  its client rectangles (those of its children for `display: contents`) is at least 3×3
  CSS pixels, and one of up to 34 points of one of its client rectangles (the middle, the
  corners and the middles of the edges 2 px inside, then a 5×5 grid), inside the visible
  part of the local root and of every same-process frame on the way, is hit by the hit test
  a mouse event would get from the local root (`node_hit_from_local_root`) on the element or
  something in it. A `label` whose control is listed is dropped, and so is a weak candidate
  around another listed one. A process answers per document with the items (unique node
  id, kind, text, URL, bounding box in the device pixels of the local root), the local root
  and the document's navigable, whether it left candidates out (past 4004 found, or 1001
  listed), and for every frame another process hosts whether the hit test at the centre of
  its visible part lands on its container (and the container is not transparent).
- **Listing.** `merge_hint_answers` checks each answer against the frame tree the UI
  process knows: a process speaks only for documents it hosts, under a local root it hosts
  that holds them, and only the process hosting a frame's parent says whether it shows the
  frame; a frame another process hosts adds items only if that is said of it and of every
  such frame it is in. Documents are ordered by the tree order of their navigables. Boxes
  are cut to the visible part of their local root, moved into the top-level viewport with
  `CanonicalTraversable::local_root_offset`, cut to it (an item with nothing left is
  dropped), and the first 1000 are listed. Each process is then sent the labels of its items.
- **Labels.** A process puts one host element `ladybirdhints` (not a valid custom element
  name) at the end of each document's root element, with inline `!important` styles
  (`all: initial`, absolute at 0,0, size 0, z-index 2147483647, `pointer-events: none`) and
  a closed user-agent shadow root, as form controls have, which holds one box per label:
  bold 11 px monospace, dark text on `#fff3a3`, a 1 px border. A box sits 6 CSS px up and to
  the left of the top-left corner of the first client rectangle of its element that shows,
  so that it straddles the corner, moved into what shows of the element's document, and
  scrolls with the document. Drawing and narrowing put the host's style back. Narrowing
  (`prefix` checked against the alphabet and the label length) hides the boxes that do not
  start with the prefix and draws the typed part in `#d04000`; one that arrives before the
  labels exist is sent after them. `hints_clear` removes the hosts.
- **Activation.** `hints_end` with an index sends `hints_activate` to the process hosting
  that element, then `hints_clear` to every process. The process checks that the element's
  label is intact: its host attached to the document's root element with the style it was
  given and where it was, and the label's box where it was put. If not, the client gets an
  `error` with the session's `id` that says the labels were tampered with. It then finds a
  point of the element where it is now (an element that moved since the list is clicked
  where it moved to) that is hit as above; with none, the client gets an `error`. A text
  field (a `textarea`, a text-like `input`, an element with `contenteditable`) gets the
  focus and a caret at its end. For anything else the process answers with the point. The
  UI accepts that answer only from the process it asked, once, for a local root that
  process hosts. It guards the click in every process the events pass through: the
  process hosting the element must hit the element, each process hosting a document around
  it must hit the container of the frame the events go on to (`hints_guard_click`, keyed by
  the ids the view gives the move, press and release). It then sends those three events into
  the view at the point in the top-level viewport, past the compositor so that they follow
  the guards, as a click of the user's mouse travels: the page displaying the tab hit-tests
  it and hands it on to the process of the frame. In `EventLoop::process_input_events`, in
  the task that dispatches each event, a guarded event goes through only while its hit test
  finds its target. Once one does not, the rest of the click is dropped, a press that went
  through is cancelled (`Page::handle_mousecancel`), the other processes are told to do the
  same, and the client gets an `error`. So a parent document that covers a frame's element
  with something of its own gets nothing, nor does the element. A link opens, a
  `target=_blank` link reports `popup_blocked` (also inside a frame of another site), a
  `select` opens the `select` request.
- **Session end.** Another active document, a WebContent crash and the page closing its view
  send `hints_cancelled` (before `view_closed`); the processes are sent `hints_clear`. A
  disconnecting or replaced client ends the session silently and the labels are removed.
  `close_view` destroys the view with `view_closed` alone. Errors that answer `hints`,
  `hints_narrow` or `hints_end`, also for an unknown view, carry the `id` of the message.
  A process forgets the hint state of a page that goes away.
- **What a page can still do.** It sees the host element and can remove, restyle or cover
  it (not the closed user-agent shadow root); an activation is then refused. It cannot change
  the list, which is read from layout and hit testing, nor the element a click goes to; it
  can move or cover the element, or what is around a frame, while the click is on its way,
  which then activates nothing. Whether a parent document covers part of a frame of another
  site is noticed only at the centre of the frame's visible part when listing, and for the
  element itself when clicking.
- **Check:** `tools/checks/hints.sh` (run.sh name `hints`) with the scripts `hints.txt`,
  `hints-hidden.txt`, `hints-hostile.txt`, `hints-refused.txt`, and, served over HTTP from
  127.0.0.1 with frames from localhost on one server whose processes are counted,
  `hints-frames.txt`, `hints-jack.txt` and `hints-hung.txt` (`hints-frames.txt` also with
  `--site-isolation=top-level`), the session scripts and the pages `hints*.html`.

### 2.10 Views

`EmacsServer` holds up to `--emacs-max-views=N` views (1 to 64, default 16; another
number stops the server from starting), announced as `welcome.max_views`. `create_view`
beyond that is answered with `error` echoing `request`. View ids count up from 1 and are
never reused. Each `EmacsWebView` is a `HeadlessWebView` of its own tab, so it has its own
WebContent process (Ladybird also keeps one spare process around), and its own frame
sequence, one frame in flight, shared memory segment, viewport, zoom, focus, state,
requests, find, hint session, console and crash handling. Request ids and the names of
screenshots saved without a `path` are counted by the server, so no two views have the
same; segment names count up per process. All views share the UI process's cookie jar
and storage. A `shm_failed` for any view makes every view send its next frame whole on
the stream; a new view announces its segment after its `view_created`, and every view
announces a new one to the next client.

- **Viewports.** Each viewport is brought within 16000 pixels a side and 64 M pixels, and
  all of them together within 256 M device pixels (`maximum_total_viewport_area`, about
  3 GiB in the Compositor). A `create_view` or `set_viewport` asking for more gets the
  size cut down; a `create_view` when the other views have all of the area is answered
  with `error`.
- **Visibility.** A view renders while a client knows it and has not hidden it with
  `set_visibility`; a new view is visible. While no client is connected every view is
  hidden, so a detached server renders nothing. The visibility the client last chose for a
  view comes back when the next client's `hello` is done: after `welcome` every view sends
  its `state` and its open requests, and the visible ones a whole frame. A view that becomes
  visible sends a whole frame first; a hidden one sends no frames. Hiding a view ends a
  frame it was sending in bands, and drops its segment and compression buffer once the
  client has acknowledged the frame in flight.
- **Turns on the connection** (`EmacsFrameTurns`, unit-tested in `TestEmacsProtocol`). A
  view asks `EmacsServer::begin_frame_turn` before it sends a frame record and ends every
  turn it was given with `end_frame_turn`, whether it sent a record or not. It does not
  get a turn while another view is between the bands of a frame (so bands are
  contiguous), while the transport holds 64 MiB or more that the client has yet to read
  (also for the next band of a frame), or while a view that has waited longer still
  waits. A view that does not get a turn is queued. The queued views are told to ask
  again, in order, when a turn ends without bands to follow, when the transport writes
  and holds less than 64 MiB afterwards, when a queued view at the head has nothing to
  send any more, and when a view is hidden, closed or crashes (which also ends a frame it
  was sending in bands). As each turn adds at most one frame record, frames take the
  bytes waiting for the client at most one record (64 MiB) beyond the budget. Messages
  that say only how something is now (`state`, `cursor`, `link_hover`, `tooltip`,
  `favicon`, `background_color`, `ime`) go out in batches: a view sends its next batch
  once the client has read the one before and the transport is below the budget, and
  meanwhile keeps the latest message of each type. A page that sets a title of 1 MiB in
  a loop thus has at most one on the connection. Other control messages are never held
  back.
- **Closing.** A view its page closes sends `view_closed` with `reason: "closed"` and
  leaves the server's views at once; it is destroyed after the callback returns. A
  `close_view` for a view that was closed already gets no answer; one for an id that was
  never a view's gets `error`.
- **Downloads.** A blocked download is reported with the id of the view whose page or
  user asked for it. One of a window without a view of its own (2.11) is reported with
  the only view's id, or without `view` when there are several.
- **Check:** `tools/checks/views.sh` (run.sh name `views`) with `views.txt` (three views
  with a limit of three: pages and pixels, the limit error, hiding and showing, bands of a
  4200×4100 frame beside another animating view, a dialog in one view while others work,
  find, hints and screenshots in two views, a crash of one view, closing and creating
  again), `views-turns.txt` (frames of one view not acknowledged, and hiding, closing and
  a crash in the middle of its bands, a view its page closes), `views-shm.txt` (names per
  view, a hidden view's new segment, `shm_failed` for one view), `views-shm-failed.txt`,
  `views-shared.txt` (cookies and storage over HTTP), bad `--emacs-max-views`, a flood of
  `create_view` with the WebContent processes and segments left after closing,
  `views-detach.txt` / `views-reattach.txt`, and `views-encodings-a.txt`, `-b.txt`, `-c.txt`
  (clients with and without shared memory and zstd, one after another).

### 2.11 Views opened by pages

A window a page opens goes through the engine's own path: the renderer asks for a new
top-level traversable only with user activation, which it consumes, so a page gets one
window per user activation however many it asks for;
`WebContentPage::did_request_new_web_view` checks the activation of the input it
delivered again, and `on_new_web_view` gets the traversable. A link the user middle- or
ctrl-clicks opens through `create_view_for_new_tab_or_window`, without a traversable and
without needing the activation, so a handler of that click that calls `window.open` gives
a second view. Both call
`EmacsServer::open_view(opener, traversable)`, which makes the view through
`create_view` like `create_view` from the client, on the engine's traversable, so
`window.opener`, the `WindowProxy` that `window.open` returns, `noopener`, named targets
and `window.close()` are the engine's. It has the opener's viewport and `dpr`, and is
announced with `view_created` carrying `opener` and no `request`, then `state` and a
frame. A view for a tab sends its first `state` once the caller has started loading the
URL in it, so that `state` has `loading` true.

- There is a view only while a client is connected whose `hello` had `"popups": true`,
  the server has fewer than `max_views` views, and the opener's area fits within what the
  other views leave. Otherwise the window gets the hidden child of 2.3 and the opener
  sends `popup_blocked`; the child closes once its URL is known or after 2 s.
- The window starts in the opener's WebContent process
  (`open_page_for_new_top_level_traversable`), and site isolation moves it as it does any
  navigation. A crash is reported for the view whose page it took.
- The opened view does not depend on its opener: closing the opener leaves it, and
  `window.opener` behaves as the engine defines. `window.close()` sends `view_closed`
  with `reason: "closed"` (2.10), after which the opener's reference reports `closed`.
- A client with another `popups` value than the one before finds the opened views as
  ordinary views; its value applies to windows opened from then on.
- A window whose first navigation turns out to be a download is closed again: a blocked
  download is reported for the view whose page or user asked for it
  (`Application::default_path_for_downloaded_file` gets that view), and a view a page
  opened that has not committed a navigation yet then sends `view_closed` with
  `reason: "closed"` after the `error`. A download of a window that has no view of its
  own is reported with the only view's id, or without `view` when there are several.
- **Check:** `tools/checks/popups.sh` (run.sh name `popups`), over HTTP with the frame on
  another site: `popups.txt` (`target=_blank`, middle click, named and unnamed
  `window.open` and a name used again, `rel=noopener`, a window opened without user
  activation, `postMessage` both ways, one window per click, a frame of
  another site, a hinted link, a middle click whose handler also opens a window, a view
  the client closes at once, the `noopener` feature, a download, find, visibility and a
  dialog in an opened view, `window.close()` from both sides, the opener closed first),
  `popups-limit.txt` (the limit, and a closed view's slot used again),
  `popups-off.txt` (a client without `popups`, also for a middle click), and
  `popups-detach.txt` / `popups-reattach.txt` on `popups-cross.html` (a client without
  `popups` comes back to opened views, one of another site in a WebContent process of
  its own), with the WebContent processes left after closing them.

## 3. Input mapping

### 3.1 Key names

`Libraries/LibWebCommon/UIEvents/KeyCode.h:17` defines `ENUMERATE_KEY_CODES` as
`__ENUMERATE_KEY_CODE(name, ui_name, code)` (138 entries). The protocol's `key` is the
enumerator *without* `Key_` — i.e. `#name`, not `ui_name` (which is `"!"`, `")"`, … for
punctuation). Generate the table in `EmacsProtocol.cpp`:

```cpp
static Optional<Web::UIEvents::KeyCode> key_code_from_name(StringView name)
{
#define __ENUMERATE_KEY_CODE(key, ui_name, code) \
    if (name == #key##sv) return Web::UIEvents::KeyCode::Key_##key;
    ENUMERATE_KEY_CODES
#undef __ENUMERATE_KEY_CODE
    return {};
}
```

Unknown → `Key_Invalid` (and a one-line log). Do not use the existing
`key_code_from_string(Utf16View)` (`KeyCode.h:161`): it matches `ui_name` and
`VERIFY_NOT_REACHED()`s on unknown input. Names worth telling the client plan:
`Left Right Up Down Return Escape Backspace Tab Space Delete Home End PageUp PageDown Insert F1..F12 A..Z 0..9 LeftShift RightShift LeftControl RightControl LeftAlt RightAlt LeftSuper RightSuper Menu Comma Period Slash Semicolon Apostrophe LeftBracket RightBracket Backslash Minus Equal Backtick`.

### 3.2 Modifiers

Ladybird (`KeyCode.h:172`): `Mod_Alt = 1, Mod_Ctrl = 2, Mod_Shift = 4, Mod_Super = 8, Mod_Keypad = 16`.
Protocol: shift 1, ctrl 2, alt 4, super 8, keypad 16. Translate bit by bit:
`shift→Mod_Shift, ctrl→Mod_Ctrl, alt→Mod_Alt, super→Mod_Super, keypad→Mod_Keypad`.

### 3.3 Key events

Mirror `TerminalWebView::handle_key_report` (`TerminalWebView.cpp:536-575`):

```cpp
Web::KeyEvent event {};
event.type = down ? Web::KeyEvent::Type::KeyDown : Web::KeyEvent::Type::KeyUp;
event.key = key_code; event.modifiers = mods; event.code_point = code_point; event.repeat = repeat;
bool shortcut = (mods & (Mod_Ctrl | Mod_Super)) != 0;
event.should_insert_text = down && code_point != 0 && !shortcut;
enqueue_input_event(move(event));
```

The client sends `up` itself (protocol), so no synthesized key-up here. Code points for
special keys follow `TerminalInputParser` (`TerminalInputParser.cpp:51-58`): Return `'\n'`,
Tab `'\t'`, Escape `0x1b`, Backspace `'\b'`, 0 for keys that type nothing (8.2).

### 3.4 Mouse events

Button names → `Web::UIEvents::MouseButton` (`Libraries/LibWebCommon/UIEvents/MouseButton.h`):
`left→Primary(1), right→Secondary(2), middle→Middle(4), back→Backward(8), forward→Forward(16)`;
`buttons` array OR-ed the same way; if the client omits `buttons`, keep a server-side held set as `TerminalWebView` does (`m_held_mouse_buttons`).

Build with the `mouse_event()` helper from `TerminalWebView.cpp:309` (`position` and
`screen_position` both the device-pixel point; clamp into the viewport). Types:
`down→MouseDown`, `up→MouseUp`, `move→MouseMove`, `leave→MouseLeave` (position `{0,0}`,
no buttons — what `WebContentView::handle_pointer_leave` sends, `UI/Qt/WebContentView.cpp:881`),
`wheel→MouseWheel`.

Clicks: there is **no** `DoubleClick` event type in `Web::MouseEvent::Type`
(`Libraries/LibWebCommon/Page/InputEvent.h`: `MouseDown, MouseUp, MouseMove, MouseLeave, MouseCancel, MouseWheel`).
Both Qt (`WebContentView::mousePressEvent`, `mouseDoubleClickEvent` forwards to it) and
`TerminalWebView` set `event.click_count` on `MouseDown` and repeat it on `MouseUp`. So:
`clicks` → `event.click_count` on down; remember it and set it on the following up (8.2).

Wheel: `event.wheel_delta_x = dx; event.wheel_delta_y = dy;` in device pixels, then
`event.wheel_tick_120ths_{x,y} = Web::wheel_tick_120ths_from_pixel_delta(delta, precision)`,
`event.wheel_delta_precision = precision`. Sign verified: Qt negates `pixelDelta()`/`angleDelta()`
(`WebContentView.cpp:587,593`) and the terminal maps wheel-down (SGR button 65) to `+1 * 40 px`
(`TerminalInputParser.cpp:205`, `TerminalWebView.cpp:35`), so **positive `dy` scrolls the content
down**, matching the protocol. Precision: `Discrete` unless the client sends `"precise":true` (8.2).

### 3.5 Cursor names

`Gfx::StandardCursor` → CSS: `None/Hidden→"none"`, `Arrow→"default"`, `Crosshair→"crosshair"`,
`IBeam→"text"`, `ResizeHorizontal→"ew-resize"`, `ResizeVertical→"ns-resize"`,
`ResizeDiagonalTLBR→"nwse-resize"`, `ResizeDiagonalBLTR→"nesw-resize"`, `ResizeColumn→"col-resize"`,
`ResizeRow→"row-resize"`, `Hand→"pointer"`, `Help→"help"`, `OpenHand→"grab"`, `Drag→"grabbing"`,
`DragCopy→"copy"`, `Move→"move"`, `Wait→"wait"`, `Disallowed→"not-allowed"`, `Eyedropper→"crosshair"`, `Zoom→"zoom-in"`.

## 4. Tasks in dependency order

Each task names files, what to write, and an acceptance check runnable without Emacs.
Build with `./Meta/ladybird.py build Hub` (section 5) unless a unit test is named.

### T1 — Build plumbing and option skeleton (small)

Files: `vcpkg.json`, `Meta/CMake/check_for_dependencies.cmake`, `Libraries/LibWebView/CMakeLists.txt`,
`Options.h`, `Application.cpp`, `Forward.h`. Add `HeadlessMode::Emacs`, `--emacs-socket`,
`--emacs-log`, the zstd dependency, empty `Emacs*.cpp` files compiled in.
Check: `./Meta/ladybird.py build Hub` succeeds; `Build/release/bin/Ladybird --headless=emacs about:blank`
exits with a clear "not implemented" error rather than the "exactly one URL" error; `--headless=bogus` still fails as before.

### T2 — `EmacsProtocol` framing, JSON, tables (medium)

Files: `EmacsProtocol.h/.cpp`, plus `Tests/LibWebView/TestEmacsProtocol.cpp` (register in `Tests/LibWebView/CMakeLists.txt`, pattern of the existing tests there).

```cpp
namespace WebView::EmacsProtocol {
enum class RecordKind : u8 { Control = 1, Frame = 2 };
struct FrameHeader { u32 seq; u32 view; u32 width; u32 height; double dpr; u32 damage_x, damage_y, damage_width, damage_height; u8 encoding; u8 flags; u16 reserved; };
constexpr size_t frame_header_size = 44;
void append_record_header(ByteBuffer&, RecordKind, u32 payload_length);
void append_frame_header(ByteBuffer&, FrameHeader const&);
class RecordReader { public: void feed(ReadonlyBytes); Optional<Record> next(); /* Record { RecordKind kind; ByteBuffer payload; } */ bool has_error() const; };
Optional<Web::UIEvents::KeyCode> key_code_from_name(StringView);
Web::UIEvents::KeyModifier modifiers_from_protocol(u32);
Optional<Web::UIEvents::MouseButton> mouse_button_from_name(StringView);
StringView css_cursor_name(Gfx::Cursor const&);
}
```

Check: the unit test round-trips a record split across arbitrary feed boundaries, rejects
`length == 0` and `length > 64 MiB`, maps `"Return"`→`Key_Return`, `"Bogus"`→none, modifiers `1|2|4|8`→`Mod_Shift|Mod_Ctrl|Mod_Alt|Mod_Super`, `16`→`Mod_Keypad`. Run `./Meta/ladybird.py test TestEmacsProtocol` (or `ninja -C Build/release TestEmacsProtocol && Build/release/bin/TestEmacsProtocol`).

### T3 — `EmacsTransport` (medium)

Files: `EmacsTransport.h/.cpp`.

```cpp
class EmacsTransport {
public:
    enum class Kind { Stdio, Socket };
    static ErrorOr<void> take_over_stdio(Kind, Optional<ByteString> const& log_path);  // 2.6
    static ByteString const& log_path();
    static ErrorOr<NonnullOwnPtr<EmacsTransport>> create(Kind, Optional<ByteString> socket_path);
    Function<void(JsonObject const&)> on_control;
    Function<void()> on_client_connected;   // a new (or replacing) client; server resets handshake state
    Function<void()> on_client_disconnected;
    bool has_client() const;
    void send_control(JsonObject const&);
    void send_record(EmacsProtocol::RecordKind, ReadonlyBytes payload);
    void send_frame(ByteBuffer&& record_already_framed);  // avoids copying pixels twice
    void disconnect_client();
    void shutdown();  // close everything, unlink socket
};
```

Check (no Ladybird view needed yet): a temporary `main`-less check via the Python client
in T9 is simplest; until then, build and run `Build/release/bin/Ladybird --headless=emacs` with
T4's stub that answers `hello` with `welcome{views:[]}` and `ping` with `pong`:
`printf` a hand-built record from Python (`struct.pack('<IB', len(p) + 1, 1) + p`) into the
process and see `welcome` come back on stdout while the log file receives Ladybird's stderr.

### T4 — `EmacsServer` handshake and view-less commands (medium)

Files: `EmacsWebView.h/.cpp` (server part), `Application.cpp/h` execute branch.

```cpp
class EmacsServer {
public:
    static ErrorOr<NonnullOwnPtr<EmacsServer>> create(Core::AnonymousBuffer theme, BrowserOptions const&);
    ~EmacsServer();  // unlink socket + shm
private:
    void handle_control(JsonObject const&);
    void handle_hello(JsonObject const&);
    void send_welcome();  // protocol, server string from Application version, host {hostname via ::gethostname, platform}, log path
    void send_error(u32 view, String message);
    void create_view(Web::DevicePixelSize, double dpr, Optional<URL::URL>);
    NonnullOwnPtr<EmacsTransport> m_transport;
    OwnPtr<EmacsWebView> m_view;
    Core::AnonymousBuffer m_theme;
    struct ClientState { bool hello_done; bool wants_zstd; bool wants_shm; Web::DevicePixelSize viewport; double dpr; } m_client;
    Vector<int> m_signal_handler_ids;
};
```

Check: Python client (T9, `--no-view`) connects over stdio and over `--emacs-socket=/tmp/l.sock`,
gets `welcome` with `views:[]`, `ping`→`pong`; a second socket client gets `welcome` and the
first reads `replaced` then EOF; `kill -TERM` removes `/tmp/l.sock`; `ls -l` shows mode 0600.

### T5 — `EmacsWebView`: view creation, state, frames raw (large)

Files: `EmacsWebView.h/.cpp`, `EmacsFrameEncoder.h/.cpp` (raw path only).

```cpp
class WEBVIEW_API EmacsWebView final : public HeadlessWebView {
public:
    static NonnullOwnPtr<EmacsWebView> create(Core::AnonymousBuffer theme, Web::DevicePixelSize, double dpr, EmacsServer&);
    void set_viewport(Web::DevicePixelSize, double dpr);
    void client_changed();            // reset in-flight, force full frame
    void handle_frame_ack(u32 seq);
    void send_state();                // deferred/coalesced
    JsonObject state_json() const;    // also used by welcome.views
    void handle_mouse(JsonObject const&); void handle_key(JsonObject const&); void handle_text(JsonObject const&);
    void handle_dialog_closed(JsonObject const&); /* …one per *_closed… */
private:
    EmacsWebView(Core::AnonymousBuffer, Web::DevicePixelSize, double dpr, EmacsServer&);
    virtual void did_accept_presented_backing_store(i32, Gfx::IntRect) override;
    virtual void did_change_state() override { send_state(); }
    virtual void update_zoom() override { HeadlessWebView::update_zoom(); send_state(); }
    virtual void did_request_context_menu(ContextMenuRequest) override;
    void schedule_frame_flush(); void flush_frame();
    // dialog bookkeeping: HashMap<u64, Function<void(bool)>> m_before_unload; HashMap<u64, PermissionPromptCallback> m_permissions; …
};
```

Constructor: `HeadlessWebView(move(theme), size)`, `m_device_pixel_ratio = dpr`, wire every
callback of 2.3; `create()` then calls `initialize_tab(Web::HTML::VisibilityState::Visible)`
and `set_presents_from_cpu_memory(true)` (order as in `TerminalWebView::create`).

Check: `tools/ladybird-client.py --url https://ladybird.dev --png /tmp/out.png` receives
`view_created`, at least one `state` with `title` non-empty after load, frames; the PNG
shows the page. `--viewport 800x600@1` then `--resize 1200x800@2` yields a frame with
`flags & 1` and the new size and `dpr == 2.0`. Frames stop while the client withholds
`frame_ack` and resume with a single coalesced frame when it acks.

### T6 — Input (medium)

Files: `EmacsWebView.cpp`. Section 3.

Check: load `data:text/html,<input id=i autofocus><script>i.oninput=()=>document.title=i.value</script>`,
send `key` down/up for `H`, `I` with code points → `state.title == "hi"`; `text "é"` appends;
`mouse wheel dy=400` on a tall page then `screenshot visible` shows scrolled content;
`mouse down/up clicks:2` on a word in a `<p>` and `request_selection` returns that word;
`mouse leave` after hovering a link produces `link_hover {url:null}`.

### T7 — zstd and shm encodings (medium)

Files: `EmacsFrameEncoder.cpp` (zstd: one `ZSTD_CCtx*` per encoder, `ZSTD_CCtx_setParameter(ctx, ZSTD_c_compressionLevel, 1)`, `ZSTD_compress2` into a buffer of `ZSTD_compressBound(n)`), `EmacsSharedFrameBuffer` (2.5), negotiation in `EmacsServer::handle_hello`.

Check: client with `--encodings zstd,raw` decodes every frame to identical pixels as `--encodings raw` (compare two PNGs of the same `data:` page). Client with `--shm` on the same machine maps `/dev/shm/<name>` (Linux) or `shm_open` via `posix_ipc`/ctypes (macOS) and produces the same PNG; after `--resize` to a larger viewport a `shm` control message arrives before the next frame.

### T8 — Dialogs, pickers, context menu, permissions, external URLs (medium)

Files: `EmacsWebView.cpp`.

Check with `data:` pages: `alert(1)` → `dialog kind=alert`, `dialog_closed` unblocks (title changes afterwards); `confirm()`/`prompt()` return the client's values (reflect them in `document.title`); `<select>` clicked → `select` message, `select_closed` changes the value; `<input type=file>` click → `file_picker`, `file_picker_closed {paths:[...]}` sets `files.length`; right click → `context_menu`; `navigator.geolocation.getCurrentPosition` → `permission`, `permission_closed` with `outcome:"deny"` → error callback in page; `window.onbeforeunload` + `load` → `dialog kind=beforeunload`.

### T9 — Python test client `tools/ladybird-client.py` (medium)

Location: `/Users/daniel/src/dakra/ladybird/tools/ladybird-client.py`, stdlib only; framing,
frame headers, zstd, composition and the PNG writer come from `tools/ladybird_protocol.py`
(05 §1). Behaviour:

- `--server CMD` (default: the macOS/Linux binary path from section 5) or `--socket PATH`
- speaks the handshake: `hello` with `--viewport WxH@dpr`, `--encodings`, `--shm`
- `--url URL`: `create_view` (or `load` if `welcome.views` non-empty), waits for `state.loading == false`
- `--png PATH`: keeps a BGRA frame buffer, applies every frame (raw/zstd/shm; honours `full`), acks each frame, writes the PNG after `--settle 1.0` seconds without frames
- `--send JSON` (repeatable, sent in order after load), `--resize WxH@dpr`, `--script FILE` (newline-separated JSON messages with optional `sleep N` lines) for the T6/T8 checks
- `--dump`: prints every control message as one JSON line to stderr; `--no-ack` for the flow-control test; `--no-view` for T4
- exit code 0 on success, 1 on `reject`/`error` while `--strict`

Check: every acceptance check above is expressible as a `--script`; keep the scripts under
`/Users/daniel/src/dakra/ladybird/tools/checks/*.txt`.

### T10 — Polish (small)

`Documentation/` mention in the `--headless` help string only (upstream docs are not ours to extend in this plan); log one line per connection with peer kind; make sure `Ladybird --headless=emacs` without client stays idle at ~0 % CPU (no busy notifier).

## 5. Build and run

No `Build/` exists yet in the checkout. The first build compiles every vcpkg dependency
and needs tens of GiB of free disk; check `df -h` before starting. Prerequisites on this Mac beyond the usual tools:
`brew install autoconf-archive nasm ccache rustup`; Ladybird pins Rust in
`rust-toolchain.toml`, which needs rustup's shims ahead of Homebrew's `rustc`
(`PATH="/opt/homebrew/opt/rustup/bin:$PATH"` for every build command); `pip` must reach
a working index (the `angle` port installs `ply`). On Linux (verified on Ubuntu 26.04
arm64 with clang 21): the package list of `Documentation/BuildInstructionsLadybird.md`
plus `clang lld zstd rustup patchelf python3-pip`, `rustup toolchain install 1.98.0`, then
`./Meta/ladybird.py build --cc clang --cxx clang++`; the binary is
`Build/release/bin/Ladybird`. A headless Linux machine needs no display and no
`--force-cpu-painting`; it needs fonts (`fonts-liberation2`). From
`/Users/daniel/src/ladybird`:

```sh
# Release (Build/release); set BUILD_PRESET=Debug for Build/debug
./Meta/ladybird.py build            # everything, first time (vcpkg bootstraps, long)
./Meta/ladybird.py build Hub        # the headless process (links LibWebView)
ninja -C Build/release Hub Ladybird # equivalent
./Meta/ladybird.py test TestEmacsProtocol
```

Run (the `Ladybird` launcher `execv`s `Hub`; running `Hub` directly is equivalent):

```sh
# macOS
./Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird --headless=emacs https://ladybird.dev
./Build/release/bin/Ladybird.app/Contents/MacOS/Hub --headless=emacs --emacs-socket=/tmp/ladybird.sock
# Linux
./Build/release/bin/Ladybird --headless=emacs https://ladybird.dev
./Build/release/bin/Hub --headless=emacs --emacs-socket=/tmp/ladybird.sock
# Through ladybird.py (arguments after the target pass through)
./Meta/ladybird.py run Ladybird --headless=emacs --device-pixel-ratio 2 https://ladybird.dev
# Test client
python3 -I /Users/daniel/src/dakra/ladybird/tools/ladybird-client.py --server ./Build/release/bin/Ladybird --url https://ladybird.dev --png /tmp/out.png --dump
```

Do not use `open -W … Ladybird.app` for the stdio transport (`open` does not pass stdin).
Log: `/tmp/ladybird-emacs-<pid>.log` unless `--emacs-log=PATH`; also reported in `welcome.log`.
Existing options that apply: `--window-width/--window-height` (initial view when a URL is given), `--device-pixel-ratio`, `--force-cpu-painting`, `--disable-sandbox`, `--profile-path`.

## 6. Risks and open questions

- **Frame copy cost**: raw copy of a 3200×2000 frame is 25 MiB per frame; with one-in-flight
  and damage rects this is fine locally, but zstd level 1 on 25 MiB costs ~20–40 ms. Consider
  compressing only damage (already the case) and measuring before adding threads.
- **Blocking on a slow client**: solved by the write queue, but the outbox can grow without
  bound if the client never reads control messages; cap at 256 MiB → disconnect.
- **macOS shm**: `ftruncate` once per object and 31-byte names; handled by generations (2.5).
  `shm_open` + `O_CLOEXEC` rejection on macOS 26.4+ is real (`System.cpp:253`).
- **Premultiplied alpha**: buffers are `AlphaType::Premultiplied`; page content is opaque, but
  transparent `<body>` backgrounds give alpha < 255. Emacs's ARGB32 canvas expects premultiplied too;
  verify with a `background: rgba(0,0,0,.5)` page.
- **Headless `Application` behaviours**: downloads go to the default download dir without a prompt
  (`Application.cpp:2290`); clipboard is the in-process `m_clipboard`; notifications are no-ops.
- **`HeadlessWebView` crash propagation**: children propagate crashes to the root via
  `propagate_web_content_crash`; a crash of a hidden child of a blocked popup would thus report `crashed` for its opener.
- **Open question**: should a stdio server exit when the view closes itself (`on_close`)? This plan keeps it running until EOF; the Emacs side can send `create_view` again.
- **Open question**: `--emacs-socket` on a path longer than `sizeof(sockaddr_un.sun_path)` (104 on macOS) fails in `SocketAddress::to_sockaddr_un`; report as a startup error.

## 7. Size estimate

| Task | New/changed lines | Effort |
| --- | --- | --- |
| T1 plumbing | ~60 | 0.5 d (plus vcpkg rebuild time) |
| T2 protocol + test | ~350 | 1 d |
| T3 transport | ~350 | 1 d |
| T4 server/handshake | ~300 | 1 d |
| T5 view + raw frames | ~500 | 2 d |
| T6 input | ~200 | 1 d |
| T7 zstd + shm | ~250 | 1 d |
| T8 dialogs & co. | ~400 | 1.5 d |
| T9 Python client | ~450 | 1 d |
| T10 polish | ~50 | 0.5 d |

Roughly 2.9 k lines, ~10 working days.

## 8. Protocol feedback

All items below were resolved in `01-protocol.md` v1 (its §11 lists the decisions:
keypad bit, `click_count`, `precise`, code points, enumerator key names, `clipboard`
message, optional screenshot path, `request_source` in v2, separators and device-pixel
`min_width`, four permission outcomes plus `permission_cancelled`, `dialog_update`,
`popup_blocked`, `shm` message, banding with the `more` flag, extra `welcome` fields,
server runs with zero views). Implement against the protocol file, not against the
draft wording quoted in the body above.

Items where `01-protocol.md` does not match Ladybird or leaves the server guessing. Each
should be resolved in the protocol file.

1. **Modifier bitmask** (§5): Ladybird's `KeyModifier` is `Alt=1, Ctrl=2, Shift=4, Super=8, Keypad=16`; the protocol order is fine (the server maps), but there is no AltGr modifier in Ladybird — `Key_AltGr` is a key code. Either drop bit 16 or redefine it as `keypad` (`Mod_Keypad`, used by `is_keyboard_scroll_key`).
2. **Clicks and key code points** (§5): there is no `DoubleClick` event type; Ladybird uses `MouseEvent::click_count` on `MouseDown` and `MouseUp` (Qt and terminal frontends). Say "`clicks` sets `click_count`" and let `up` carry `clicks` too. Add optional `"precise":true` on `wheel` for touchpad pixel deltas (`WheelDeltaPrecision::Precise`). Document the code points the engine expects for special keys: Return `10`, Tab `9`, Backspace `8`, Escape `27` (as `TerminalInputParser` sends), 0 for everything that types nothing. The `leave` example has `view` twice.
3. **`screenshot.path`** (§6): `ViewImplementation::take_screenshot` chooses its own file (`write_screenshot`); the server can honour `path` for `visible` (it encodes the displayed frame itself) and must *move* the file for `full`. Make `path` optional and have `screenshot_saved.path` be authoritative.
4. **`request_source`** (§6): `get_source()` does not return text — it opens a view-source tab through `Application::open_blank_new_tab`, which is a no-op in headless (`WebContentPage::did_get_highlighted_source`, `WebContentPage.cpp:3085`). Options: move to v2; or define `source.text` as the serialized DOM (`inspect_dom_tree()` + `get_dom_node_outer_html(root)` → `on_received_dom_node_html`); or as page text (`request_internal_page_info(PageInfoType::Text)`). v1 answers `error`.
5. **`select` items and units** (§7): Ladybird's `SelectItem` is a variant of option, option *group* and *separator*; add `"separator":true` items (or `kind`). `min_width` arrives already divided by the device pixel ratio (CSS px, `ViewImplementation.cpp:2799`) while `x`,`y` are device px — state the units, or let the server convert `min_width` back to device px.
6. **Permissions** (§7): Ladybird distinguishes `AllowAlways`/`AllowOnce`/`Block`/`Dismissed`; `"granted"` should become `"granted_once"` and `"granted_always"` (or add `persist:bool`). Add server → client `permission_cancelled {view,id}` for `on_cancel_permission_prompt` (page navigated away). The `name` values are `geolocation`, `microphone`, `notifications` (`Web::Permissions::to_string`).
7. **Prompt default text updates** (§7): `on_request_set_prompt_text` can change the default while a prompt is open (WebDriver). Either add `dialog_update {view,id,default}` or state that it is ignored.
8. **`edit` op `cut`** (§6): `cut_selected_text()` returns the cut text through a promise; since Emacs owns the clipboard the server must hand it back. Reuse `selection {view, request:null, text}` or add `cut_text`.
9. **Popups / `view_created` with `opener`** (§3): `on_new_web_view` must return a window handle synchronously, and `HeadlessWebView` creates a hidden child view for it. v1 cannot show it; specify that the server may send `error {message:"popup not shown"}` and that `view_created` for popups is v2 (requires an `EmacsWebView` child factory).
10. **shm segment lifetime** (§2, §4): the name is only in `welcome`, but macOS cannot grow a POSIX shm object (`ftruncate` once) and limits names to 31 bytes, so a bigger viewport needs a new segment. Add server → client `{"type":"shm","name":"/ladybird-123-2","size":N}` (client remaps, acks nothing) and state that a frame with encoding 2 refers to the most recent `shm` message. Also say that `shm:true` in `hello` is only honoured for stdio/socket transports.
11. **Record size limit vs. raw frames** (§1, §4): a raw 8K frame (132 MiB) exceeds 64 MiB. Specify that the server splits a damage rect into horizontal bands, each a frame record with its own `seq`, and that the client acks each.
12. **Additive `welcome` fields**: `log` (server log path) and `version` of the engine are useful; `views[].dpr` and `views[].width/height` too, so a reconnecting client can size its canvas before the first frame.
13. **"After `welcome` the server sends … a full frame"** (§2): only possible once the Compositor has presented; say "as soon as one is available".
14. **`context_menu`** (§7): Ladybird also supplies `media` state (`Web::MediaContextMenu`: playing, muted, loop, controls, PiP) and `image_mime_type`; add an optional `media` object and `image_mime_type`.
15. **`close_view` of the last view**: define whether the server keeps running with zero views (this plan: yes) and that `welcome.views` is then empty.
