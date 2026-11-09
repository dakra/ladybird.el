# Integration log

| Date | Checkpoint | Machine | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-11-09 | I1 real page to PNG | macOS 27 arm64 | pass | `tools/checks/run.sh` all checks passed; ladybird.org at 1600×1000@2: zstd frame 349 KB, 4 ms to encode; `--no-ack` yields one frame; server stderr empty; idle CPU 0 % |
| 2026-11-09 | I2 mock frames in Emacs | macOS 27 arm64, emacs-plus@32 NS | pass at dpr 1 | native module + mock over stdio, Unix socket, TCP; `test/elate/run.sh` 12 runs pass; dpr 2 needs the Emacs canvas patch (03 §7) and is not tested |
| 2026-11-09 | I3 real page in Emacs, local stdio | macOS 27 arm64, emacs-plus@32 NS | pass at dpr 1 | ladybird.org and a local test page at 856×588 over shm, no dropped frames; link click, wheel, typing, paste, drag selection, history, find, split/resize, zoom work; module copy 0.05 ms per full frame, whole `feed` 9.3 ms of which 9.1 ms is NS `canvas-refresh`; 60 fps while scrolling. Found: drag release, hover text resizing the page, header tags pushed off-screen (fixed in `lisp/ladybird.el`); `find_result.index` base (fixed in the server, 01 §6); forwarded Emacs editing chords do not edit on a macOS server (open) |
| 2026-11-09 | I4 detach and reconnect, local Unix socket | same | pass (local part) | buffer killed with `ladybird-keep-view-on-kill`, reconnect finds the view with its form state; a second client takes over and Emacs shows `[detached]`; `ladybird-reconnect` takes the view back; redial after a server restart reopens the page by URL. ssh and forwarded sockets not tested |
