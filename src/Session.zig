/// One connection's stream state and the Lisp functions that operate on it.
///
/// A session accumulates stream bytes, splits them into records, decodes
/// frame records into the backing stores of the views Lisp registered and
/// paints the attached Emacs canvases.  Everything runs on the Lisp thread
/// inside a module function.
const std = @import("std");
const Allocator = std.mem.Allocator;
const emacs = @import("emacs.zig");
const Frame = @import("Frame.zig");
const Parser = @import("Parser.zig");
const Shm = @import("shm.zig");
const View = @import("View.zig");
const zstd = @import("zstd.zig");

const Env = emacs.Env;
const Value = emacs.Value;

const Session = @This();

const State = enum { ok, desynced, closed };

const Slot = struct {
    view: View = .{},
    /// Global reference to the attached canvas spec.
    canvas: ?Value = null,
    /// Painted since the canvas was last refreshed.
    dirty: bool = false,
    /// The last frame record had the `more` flag: the presented frame is
    /// incomplete and the canvas is not refreshed.
    hold: bool = false,
    /// The shared memory segment the server announced for the view.
    shm: ?Shm = null,
};

const Stats = struct {
    bytes_in: u64 = 0,
    records: u64 = 0,
    control_records: u64 = 0,
    frames: u64 = 0,
    frames_painted: u64 = 0,
    frames_dropped: u64 = 0,
    counters: View.Counters = .{},
};

fn statusSymbol(status: View.Status) Value {
    const s = &emacs.sym;
    return switch (status) {
        .painted => s.painted,
        .stored => s.stored,
        .size_mismatch => s.@"size-mismatch",
        .stale => s.stale,
        .bad_frame => s.@"bad-frame",
        .decode_error => s.@"decode-error",
        .shm_error => s.@"shm-error",
        .unknown_view => s.@"unknown-view",
        .canvas_error => s.@"canvas-error",
    };
}

alloc: Allocator,
state: State = .ok,
buffer: Parser.Buffer = .{},
slots: std.AutoHashMapUnmanaged(u32, Slot) = .empty,
decoder: zstd.Decoder,
scratch: View.Scratch = .{},
stats: Stats = .{},

var module_alloc: Allocator = undefined;

pub fn initModule(alloc: Allocator) void {
    module_alloc = alloc;
}

fn create(alloc: Allocator) !*Session {
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .decoder = try zstd.Decoder.init() };
    return self;
}

/// Free what SLOT holds.  Without ENV the canvas reference is left for the
/// next module function call to free.
fn freeSlot(self: *Session, env: ?Env, slot: *Slot) void {
    slot.view.deinit(self.alloc);
    if (slot.canvas) |canvas| {
        if (env) |e| e.freeGlobalRef(canvas) else emacs.orphanGlobalRef(canvas);
    }
    if (slot.shm) |shm| shm.close();
    slot.* = .{};
}

/// Free everything but the struct.  Without ENV the canvas references are
/// left for the next module function call to free.
fn release(self: *Session, env: ?Env) void {
    if (self.state == .closed) return;
    self.state = .closed;
    var it = self.slots.valueIterator();
    while (it.next()) |slot| self.freeSlot(env, slot);
    self.slots.deinit(self.alloc);
    self.buffer.deinit(self.alloc);
    self.scratch.deinit(self.alloc);
    self.decoder.deinit();
}

fn finalize(ptr: ?*anyopaque) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(ptr orelse return));
    self.release(null);
    self.alloc.destroy(self);
}

/// The session behind user-ptr VALUE, closed or not.
fn fromValue(env: Env, value: Value) !*Session {
    return env.getUserPtr(Session, &finalize, value);
}

/// The open session behind user-ptr VALUE.
fn open(env: Env, value: Value) !*Session {
    const self = try fromValue(env, value);
    if (self.state == .closed) return env.fail("session is closed", .{});
    return self;
}

fn viewId(env: Env, value: Value) !u32 {
    return env.extractInt(u32, value);
}

/// The pixel buffer and size of canvas spec CANVAS.  The pixels are valid
/// until the next call into Emacs.
fn canvasTarget(env: Env, canvas: Value) !View.Target {
    const s = &emacs.sym;
    const plist = env.f("cdr", .{canvas});
    const width = try env.extractInt(u32, env.f("plist-get", .{ plist, s.@":data-width" }));
    const height = try env.extractInt(u32, env.f("plist-get", .{ plist, s.@":data-height" }));
    return .{ .pixels = try env.canvasData(canvas), .width = width, .height = height };
}

/// Consume records and return their events.  Once a record is consumed
/// nothing makes the call exit without its event: the caller acknowledges
/// frames from the events.
fn feed(self: *Session, env: Env, bytes: Value, no_refresh: bool) !Value {
    const s = &emacs.sym;
    if (self.state == .desynced) return env.nil();
    if (env.isNotNil(env.f("multibyte-string-p", .{bytes})))
        return env.fail("chunk must be unibyte; use :coding 'binary", .{});

    const before = self.buffer.data.items.len;
    try env.appendString(self.alloc, &self.buffer.data, bytes);
    self.stats.bytes_in += self.buffer.data.items.len - before;

    // Newest first.
    var events = env.nil();
    while (true) {
        switch (self.buffer.next(self.alloc)) {
            .need_more => break,
            .desync => |reason| {
                const reason_symbol = switch (reason) {
                    .bad_length => s.@"bad-length",
                    .oversize => s.oversize,
                    .bad_kind => s.@"bad-kind",
                };
                events = env.cons(env.list(.{ s.desync, reason_symbol, self.buffer.offset }), events);
                self.state = .desynced;
                self.buffer.reset(self.alloc);
                break;
            },
            .record => |record| {
                self.stats.records += 1;
                const event = switch (record.kind) {
                    .control => control: {
                        self.stats.control_records += 1;
                        break :control env.makeString(record.payload);
                    },
                    .frame => self.frameEvent(env, record.payload),
                };
                events = env.cons(event, events);
                // The caller acts on a control record before the records
                // after it are decoded.
                if (record.kind == .control and self.buffer.buffered() > 0) break;
            },
        }
    }
    self.buffer.compact(self.alloc);
    if (!no_refresh) self.refresh(env);
    return env.f("nreverse", .{events});
}

fn frameEvent(self: *Session, env: Env, payload: []const u8) Value {
    const s = &emacs.sym;
    self.stats.frames += 1;
    const header, const body = Frame.Header.parse(payload) catch {
        self.stats.frames_dropped += 1;
        const n = env.nil();
        return env.list(.{ s.frame, n, n, n, n, n, n, n, n, n, n, s.@"bad-frame" });
    };
    const status = self.applyFrame(env, header, body);
    switch (status) {
        .painted => self.stats.frames_painted += 1,
        .stored, .size_mismatch, .canvas_error => {},
        .stale, .bad_frame, .decode_error, .shm_error, .unknown_view => self.stats.frames_dropped += 1,
    }
    return env.list(.{
        s.frame,            header.view,         header.seq,
        header.frame_width, header.frame_height, header.dpr,
        header.x,           header.y,            header.width,
        header.height,      header.full(),       statusSymbol(status),
    });
}

fn applyFrame(self: *Session, env: Env, header: Frame.Header, body: []const u8) View.Status {
    // Only views Lisp registered have a store.
    const slot = self.slots.getPtr(header.view) orelse return .unknown_view;
    const encoding = header.validate(body.len) catch return .bad_frame;
    slot.hold = header.more();

    // A canvas spec Emacs rejects signals; the frame is stored without it.
    var canvas_failed = false;
    // No call into Emacs may follow while TARGET is in use.
    const target: ?View.Target = if (slot.canvas) |canvas|
        canvasTarget(env, canvas) catch failed: {
            env.nonLocalExitClear();
            canvas_failed = true;
            break :failed null;
        }
    else
        null;
    const context: View.Context = .{
        .alloc = self.alloc,
        .decoder = &self.decoder,
        .scratch = &self.scratch,
        .shm = if (slot.shm) |shm| shm.bytes() else null,
        .counters = &self.stats.counters,
    };
    // Without memory for its store or its pixels the frame is dropped.
    const status = slot.view.receive(&context, header, encoding, body, target) catch return .bad_frame;
    if (status == .painted) slot.dirty = true;
    if (canvas_failed and status == .stored) return .canvas_error;
    return status;
}

/// Call `canvas-refresh' for every canvas that was painted since its last
/// refresh and whose presented frame is complete.  A canvas whose refresh
/// signals stays dirty.
fn refresh(self: *Session, env: Env) void {
    // Emacs can run Lisp during a refresh, so the slots are not walked
    // while it is called.
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(self.alloc);
    var it = self.slots.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr;
        if (!slot.dirty or slot.hold or slot.canvas == null) continue;
        // A view that does not fit the list is refreshed by a later call.
        pending.append(self.alloc, entry.key_ptr.*) catch break;
    }
    for (pending.items) |id| {
        const slot = self.slots.getPtr(id) orelse continue;
        const canvas = slot.canvas orelse continue;
        slot.dirty = false;
        _ = env.f("canvas-refresh", .{canvas});
        if (env.nonLocalExitCheck() != .normal) {
            env.nonLocalExitClear();
            if (self.slots.getPtr(id)) |failed| failed.dirty = true;
        }
    }
}

/// Release the canvas of SLOT.  Returns whether it had one.
fn detach(env: Env, slot: *Slot) bool {
    const canvas = slot.canvas orelse return false;
    env.freeGlobalRef(canvas);
    slot.canvas = null;
    slot.dirty = false;
    return true;
}

fn statsPlist(self: *Session, env: Env) !Value {
    const s = &emacs.sym;
    var dirty = env.nil();
    var views = env.nil();
    var shm_size: usize = 0;
    if (self.state != .closed) {
        var it = self.slots.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const slot = entry.value_ptr;
            const mapped = if (slot.shm) |shm| shm.size else 0;
            shm_size += mapped;
            if (slot.dirty) dirty = env.cons(id, dirty);
            views = env.cons(env.list(.{ id, slot.view.width, slot.view.height, slot.canvas != null, mapped }), views);
        }
    }
    const closed = self.state == .closed;
    const counters = self.stats.counters;
    return env.list(.{
        s.@":state",
        switch (self.state) {
            .ok => s.ok,
            .desynced => s.desynced,
            .closed => s.closed,
        },
        s.@":bytes-in",
        self.stats.bytes_in,
        s.@":records",
        self.stats.records,
        s.@":control-records",
        self.stats.control_records,
        s.@":frames",
        self.stats.frames,
        s.@":frames-painted",
        self.stats.frames_painted,
        s.@":frames-dropped",
        self.stats.frames_dropped,
        s.@":zstd-in-bytes",
        counters.zstd_in_bytes,
        s.@":zstd-out-bytes",
        counters.zstd_out_bytes,
        s.@":decode-ns",
        counters.decode_ns,
        s.@":copy-ns",
        counters.copy_ns,
        s.@":buffered",
        if (closed) 0 else self.buffer.buffered(),
        s.@":buffer-capacity",
        if (closed) 0 else self.buffer.data.capacity,
        s.@":largest-record",
        self.buffer.largest_record,
        s.@":dirty-views",
        dirty,
        s.@":shm-size",
        shm_size,
        s.@":views",
        views,
    });
}

/// STRING as a NUL-terminated byte string owned by the caller.
fn extractName(env: Env, alloc: Allocator, string: Value) ![:0]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    try env.appendString(alloc, &bytes, string);
    return bytes.toOwnedSliceSentinel(alloc, 0);
}

pub const functions = [_]emacs.FunctionEntry{
    .{
        .name = "ladybird-module-create-session",
        .arity = .{ 0, 0 },
        .doc =
        \\Return a new session for one connection's byte stream.
        \\
        \\(ladybird-module-create-session)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, _: [*c]Value) !Value {
                const self = try create(module_alloc);
                return env.makeUserPtr(&finalize, self) catch |err| {
                    self.release(null);
                    module_alloc.destroy(self);
                    return err;
                };
            }
        },
    },
    .{
        .name = "ladybird-module-close",
        .arity = .{ 1, 1 },
        .doc =
        \\Free the buffers, shared memory mappings and canvas references of SESSION.
        \\Every later call with SESSION except `ladybird-module-stats' signals
        \\`ladybird-module-error'.
        \\
        \\(ladybird-module-close SESSION)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                self.release(env);
                return env.nil();
            }
        },
    },
    .{
        .name = "ladybird-module-feed",
        .arity = .{ 2, 3 },
        .doc =
        \\Append the unibyte string BYTES to SESSION's stream and consume complete
        \\records up to and including the first control record that has more
        \\bytes buffered after it.  Return one event per consumed record, in
        \\stream order.  Call again with BYTES \"\" until the result is nil to
        \\consume the rest; this lets the caller act on a control record, such
        \\as one that announces a view or shared memory, before later records
        \\are decoded.  The events are:
        \\
        \\- a control record is its payload as a multibyte string;
        \\- a frame record is
        \\  (frame VIEW SEQ FRAME-W FRAME-H DPR DX DY DW DH FULL STATUS),
        \\  STATUS being one of
        \\  `painted'        decoded and copied into the attached canvas;
        \\  `stored'         decoded, no canvas is attached;
        \\  `size-mismatch'  decoded, the canvas has another size;
        \\  `canvas-error'   decoded, Emacs rejected the attached canvas;
        \\  `unknown-view'   VIEW is not registered, nothing is kept;
        \\  `stale'          not FULL and of another size than the stored frame;
        \\  `bad-frame'      invalid header, a frame of more than 256 MiB of
        \\                   pixels, or no memory for it;
        \\  `decode-error'   the zstd body does not state the rectangle's
        \\                   size or does not decompress to it;
        \\  `shm-error'      no shared memory is mapped for VIEW, or the frame
        \\                   does not fit in it.
        \\  A frame that is not decoded leaves the stored frame as it was.  A
        \\  record too short for a frame header has nil for every field before
        \\  STATUS;
        \\- a framing error is (desync REASON BYTE-OFFSET) as the last event,
        \\  REASON being `bad-length', `oversize' or `bad-kind'.  The session
        \\  then returns nil from every feed until `ladybird-module-reset'.
        \\
        \\Unless NO-REFRESH is non-nil, call `canvas-refresh' once for every
        \\canvas painted since its last refresh, except while the last frame
        \\record of its view announced more records for the same frame.  With
        \\NO-REFRESH, and when a refresh signals an error, those canvases stay
        \\listed under :dirty-views of `ladybird-module-stats' until a feed
        \\that refreshes them, which BYTES \"\" makes a pure refresh.
        \\
        \\Every consumed record is in the result: the call does not poll for a
        \\quit and is meant to run with quitting inhibited, as in a process
        \\filter.
        \\
        \\(ladybird-module-feed SESSION BYTES &optional NO-REFRESH)
        ,
        .impl = struct {
            pub fn call(env: Env, nargs: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                return self.feed(env, args[1], nargs > 2 and env.isNotNil(args[2]));
            }
        },
    },
    .{
        .name = "ladybird-module-attach-canvas",
        .arity = .{ 3, 3 },
        .doc =
        \\Paint frames of VIEW into the canvas image spec CANVAS from now on,
        \\replacing a canvas attached before.  A VIEW that is not registered
        \\is registered.  Return t.
        \\
        \\(ladybird-module-attach-canvas SESSION VIEW CANVAS)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                const id = try viewId(env, args[1]);
                _ = try env.canvasData(args[2]);
                const entry = try self.slots.getOrPut(self.alloc, id);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                _ = detach(env, entry.value_ptr);
                entry.value_ptr.canvas = env.makeGlobalRef(args[2]);
                return env.t();
            }
        },
    },
    .{
        .name = "ladybird-module-detach",
        .arity = .{ 2, 2 },
        .doc =
        \\Stop painting VIEW into its canvas.  Return t if one was attached.
        \\
        \\(ladybird-module-detach SESSION VIEW)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                const slot = self.slots.getPtr(try viewId(env, args[1])) orelse return env.nil();
                return env.makeValue(detach(env, slot));
            }
        },
    },
    .{
        .name = "ladybird-module-repaint",
        .arity = .{ 2, 2 },
        .doc =
        \\Copy the whole stored frame of VIEW into its canvas and refresh it.
        \\Return `painted', `size-mismatch' when the canvas has another size than
        \\the frame, `no-canvas' or `no-frame'.
        \\
        \\(ladybird-module-repaint SESSION VIEW)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const s = &emacs.sym;
                const self = try open(env, args[0]);
                const slot = self.slots.getPtr(try viewId(env, args[1])) orelse return s.@"no-frame";
                if (!slot.view.hasFrame()) return s.@"no-frame";
                const canvas = slot.canvas orelse return s.@"no-canvas";
                const target = try canvasTarget(env, canvas);
                if (!slot.view.paint(target, slot.view.frameRect(), &self.stats.counters))
                    return s.@"size-mismatch";
                // Dirty until the refresh has returned.
                slot.dirty = true;
                _ = env.f("canvas-refresh", .{canvas});
                try env.check();
                if (self.slots.getPtr(try viewId(env, args[1]))) |painted| painted.dirty = false;
                return s.painted;
            }
        },
    },
    .{
        .name = "ladybird-module-view-size",
        .arity = .{ 2, 2 },
        .doc =
        \\Return (WIDTH . HEIGHT) of the stored frame of VIEW, or nil without one.
        \\
        \\(ladybird-module-view-size SESSION VIEW)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                const slot = self.slots.getPtr(try viewId(env, args[1])) orelse return env.nil();
                if (!slot.view.hasFrame()) return env.nil();
                return env.cons(slot.view.width, slot.view.height);
            }
        },
    },
    .{
        .name = "ladybird-module-register-view",
        .arity = .{ 2, 2 },
        .doc =
        \\Keep the frames of VIEW from now on.  A frame record for a view that
        \\is not registered is reported as `unknown-view' and dropped.  Return t.
        \\
        \\(ladybird-module-register-view SESSION VIEW)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                const entry = try self.slots.getOrPut(self.alloc, try viewId(env, args[1]));
                if (!entry.found_existing) entry.value_ptr.* = .{};
                return env.t();
            }
        },
    },
    .{
        .name = "ladybird-module-forget-view",
        .arity = .{ 2, 2 },
        .doc =
        \\Free the stored frame, the canvas reference and the shared memory
        \\mapping of VIEW and stop keeping its frames.  Return t if VIEW was
        \\registered.
        \\
        \\(ladybird-module-forget-view SESSION VIEW)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                var removed = self.slots.fetchRemove(try viewId(env, args[1])) orelse return env.nil();
                self.freeSlot(env, &removed.value);
                return env.t();
            }
        },
    },
    .{
        .name = "ladybird-module-set-shm",
        .arity = .{ 3, 3 },
        .doc =
        \\Map the POSIX shared memory object NAME read-only for the frames of
        \\VIEW with the shm encoding, replacing the view's mapping, and return
        \\its size in bytes.  NAME nil only unmaps and returns nil.  When VIEW
        \\is not registered or NAME cannot be mapped, signal
        \\`ladybird-module-error' and leave the view unmapped.
        \\
        \\The size is that of the object when it is mapped.  The server that
        \\made the object is trusted not to shrink it afterwards: reading a
        \\frame from pages that are gone kills Emacs with a bus error.  A
        \\server run by the same user on this machine has other ways to harm
        \\this Emacs; do not map objects of a server that is not.
        \\
        \\(ladybird-module-set-shm SESSION VIEW NAME)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                const id = try viewId(env, args[1]);
                const registered = self.slots.getPtr(id) orelse
                    return env.fail("view %d is not registered", .{id});
                if (registered.shm) |shm| shm.close();
                registered.shm = null;
                if (env.isNil(args[2])) return env.nil();
                const name = try extractName(env, self.alloc, args[2]);
                defer self.alloc.free(name);
                const shm = switch (Shm.open(name)) {
                    .ok => |shm| shm,
                    .failed => |failure| return env.fail("%s %s: %s", .{ failure.call, @as([]const u8, name), failure.message() }),
                };
                // Reading NAME called into Emacs, which can have changed the slots.
                const slot = self.slots.getPtr(id) orelse {
                    shm.close();
                    return env.fail("view %d is not registered", .{id});
                };
                slot.shm = shm;
                return env.makeInteger(@intCast(shm.size));
            }
        },
    },
    .{
        .name = "ladybird-module-reset",
        .arity = .{ 1, 1 },
        .doc =
        \\Drop SESSION's buffered bytes and its desync state, for a new stream.
        \\Registered views keep their canvases, stored frames and shared memory
        \\mappings.
        \\
        \\(ladybird-module-reset SESSION)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try open(env, args[0]);
                self.buffer.reset(self.alloc);
                self.state = .ok;
                var it = self.slots.valueIterator();
                while (it.next()) |slot| slot.hold = false;
                return env.nil();
            }
        },
    },
    .{
        .name = "ladybird-module-stats",
        .arity = .{ 1, 1 },
        .doc =
        \\Return a plist of SESSION's counters and state:
        \\:state (`ok', `desynced' or `closed'), :bytes-in, :records,
        \\:control-records, :frames, :frames-painted, :frames-dropped,
        \\:zstd-in-bytes, :zstd-out-bytes, :decode-ns, :copy-ns, :buffered,
        \\:buffer-capacity, :largest-record, :dirty-views (views painted since
        \\their canvas was last refreshed), :shm-size (bytes of shared memory
        \\mapped for all views) and :views, a list of
        \\(VIEW WIDTH HEIGHT ATTACHED-P SHM-SIZE) for the registered views.
        \\
        \\(ladybird-module-stats SESSION)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const self = try fromValue(env, args[0]);
                return self.statsPlist(env);
            }
        },
    },
    .{
        .name = "ladybird-module-canvas-pixel",
        .arity = .{ 3, 3 },
        .doc =
        \\Return pixel (X, Y) of the canvas image spec CANVAS as an ARGB integer.
        \\
        \\(ladybird-module-canvas-pixel CANVAS X Y)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const x = try env.extractInt(u32, args[1]);
                const y = try env.extractInt(u32, args[2]);
                const target = try canvasTarget(env, args[0]);
                if (x >= target.width or y >= target.height) return error.OutOfRange;
                return env.makeInteger(target.pixels[@as(usize, y) * target.width + x]);
            }
        },
    },
    .{
        .name = "ladybird-module-canvas-row",
        .arity = .{ 2, 2 },
        .doc =
        \\Return row Y of the canvas image spec CANVAS as a unibyte string of
        \\four bytes per pixel, each pixel a native-endian ARGB32 value.
        \\
        \\(ladybird-module-canvas-row CANVAS Y)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const y = try env.extractInt(u32, args[1]);
                const target = try canvasTarget(env, args[0]);
                if (y >= target.height) return error.OutOfRange;
                const row = target.pixels[@as(usize, y) * target.width ..][0..target.width];
                return env.makeUnibyteString(std.mem.sliceAsBytes(row));
            }
        },
    },
    .{
        .name = "ladybird-module-canvas-fill",
        .arity = .{ 2, 2 },
        .doc =
        \\Set every pixel of the canvas image spec CANVAS to the integer ARGB,
        \\without refreshing it.
        \\
        \\(ladybird-module-canvas-fill CANVAS ARGB)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const argb = try env.extractInt(u32, args[1]);
                const target = try canvasTarget(env, args[0]);
                @memset(target.pixels[0 .. @as(usize, target.width) * target.height], argb);
                return env.nil();
            }
        },
    },
};

/// Functions for tests that need a shared memory object to exist.
pub const test_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ladybird-module--test-shm-write",
        .arity = .{ 3, 3 },
        .doc =
        \\Write the unibyte string BYTES at OFFSET of the POSIX shared memory
        \\object NAME.  Create the object, sized to end with BYTES, if it does
        \\not exist.
        \\
        \\(ladybird-module--test-shm-write NAME OFFSET BYTES)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const name = try extractName(env, module_alloc, args[0]);
                defer module_alloc.free(name);
                const offset = try env.extractInt(usize, args[1]);
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(module_alloc);
                try env.appendString(module_alloc, &bytes, args[2]);
                if (Shm.write(name, offset, bytes.items)) |failure|
                    return env.fail("%s %s: %s", .{ failure.call, @as([]const u8, name), failure.message() });
                return env.nil();
            }
        },
    },
    .{
        .name = "ladybird-module--test-shm-unlink",
        .arity = .{ 1, 1 },
        .doc =
        \\Remove the POSIX shared memory object NAME.
        \\
        \\(ladybird-module--test-shm-unlink NAME)
        ,
        .impl = struct {
            pub fn call(env: Env, _: isize, args: [*c]Value) !Value {
                const name = try extractName(env, module_alloc, args[0]);
                defer module_alloc.free(name);
                if (Shm.unlink(name)) |failure|
                    return env.fail("%s %s: %s", .{ failure.call, @as([]const u8, name), failure.message() });
                return env.nil();
            }
        },
    },
};
