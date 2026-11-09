/// Backing store of one view: the latest composed frame as ARGB32 pixels.
/// Frame records are decoded into it, and rectangles of it are copied to a
/// paint target of the same size.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Frame = @import("Frame.zig");
const zstd = @import("zstd.zig");
const posix = @import("posix_c");

const View = @This();

width: u32 = 0,
height: u32 = 0,
store: []u32 = &.{},

pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

/// A pixel buffer to paint into, e.g. an Emacs canvas.
pub const Target = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
};

pub const Counters = struct {
    zstd_in_bytes: u64 = 0,
    zstd_out_bytes: u64 = 0,
    decode_ns: u64 = 0,
    copy_ns: u64 = 0,
};

/// Output buffer for zstd.  Every `review_interval` uses, a buffer whose
/// capacity exceeds twice the largest size asked for meanwhile gives its
/// memory back.
pub const Scratch = struct {
    data: std.ArrayList(u8) = .empty,
    window_largest: usize = 0,
    window_uses: usize = 0,

    pub const review_interval = 64;

    pub fn deinit(self: *Scratch, alloc: Allocator) void {
        self.data.deinit(alloc);
        self.* = .{};
    }

    /// SIZE bytes of undefined content, valid until the next call.
    pub fn get(self: *Scratch, alloc: Allocator, size: usize) Allocator.Error![]u8 {
        if (self.window_uses >= review_interval) {
            if (self.data.capacity > 2 * @max(self.window_largest, size)) self.data.clearAndFree(alloc);
            self.window_largest = 0;
            self.window_uses = 0;
        }
        self.window_largest = @max(self.window_largest, size);
        self.window_uses += 1;
        self.data.clearRetainingCapacity();
        try self.data.resize(alloc, size);
        return self.data.items;
    }
};

/// What decoding needs besides the record.
pub const Context = struct {
    alloc: Allocator,
    decoder: *zstd.Decoder,
    scratch: *Scratch,
    /// The shared memory segment mapped for the view.
    shm: ?[]const u8,
    counters: *Counters,
};

pub const Applied = enum { applied, stale, decode_error, shm_error };

/// What became of a frame record.
pub const Status = enum {
    /// Decoded and copied to the target.
    painted,
    /// Decoded; there is no target.
    stored,
    /// Decoded; the target has another size than the frame.
    size_mismatch,
    stale,
    bad_frame,
    decode_error,
    shm_error,
    /// The session has no such view; never returned by `receive`.
    unknown_view,
    /// Decoded; the session could not use the target; never returned by
    /// `receive`.
    canvas_error,
};

pub fn deinit(self: *View, alloc: Allocator) void {
    alloc.free(self.store);
    self.* = .{};
}

pub fn hasFrame(self: *const View) bool {
    return self.store.len != 0;
}

pub fn frameRect(self: *const View) Rect {
    return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
}

/// Decode the damage rectangle of a validated frame record into the store.
/// A `full` frame of another size replaces the store with a zeroed one of
/// that size; any other frame of another size is stale.  A frame that
/// cannot be decoded leaves the store as it was: a zstd body is checked and
/// decompressed, and a shared memory offset checked, before the store is
/// touched or replaced.
pub fn apply(
    self: *View,
    ctx: *const Context,
    header: Frame.Header,
    encoding: Frame.Encoding,
    body: []const u8,
) Allocator.Error!Applied {
    const raw_size = header.rawSize();
    const rect: Rect = .{ .x = header.x, .y = header.y, .width = header.width, .height = header.height };
    const same_size = header.frame_width == self.width and header.frame_height == self.height;
    const frame_stride = @as(usize, header.frame_width) * 4;

    // The pixels of the rectangle and the distance between its rows.
    var source: []const u8 = body;
    var stride: usize = @as(usize, rect.width) * 4;
    switch (encoding) {
        .raw => {},
        .zstd => switch (zstd.contentSize(body)) {
            .known => |size| if (size != raw_size) return .decode_error,
            .unknown, .invalid => return .decode_error,
        },
        .shm => {
            const segment = ctx.shm orelse return .shm_error;
            const offset = std.mem.readInt(u64, body[0..8], .little);
            const frame_size = @as(u64, frame_stride) * header.frame_height;
            if (offset > segment.len or frame_size > segment.len - offset) return .shm_error;
            const first = @as(usize, @intCast(offset)) + @as(usize, rect.y) * frame_stride + @as(usize, rect.x) * 4;
            source = segment[first..];
            stride = frame_stride;
        },
    }
    if (!same_size and !header.full()) return .stale;
    if (encoding == .zstd) {
        const start = now();
        const dst = try ctx.scratch.get(ctx.alloc, raw_size);
        const written = ctx.decoder.decompress(dst, body) catch return .decode_error;
        ctx.counters.decode_ns += now() - start;
        if (written != raw_size) return .decode_error;
        ctx.counters.zstd_in_bytes += body.len;
        ctx.counters.zstd_out_bytes += raw_size;
        source = dst;
    }

    if (!same_size) {
        const store = try ctx.alloc.alloc(u32, @as(usize, header.frame_width) * header.frame_height);
        @memset(store, 0);
        ctx.alloc.free(self.store);
        self.store = store;
        self.width = header.frame_width;
        self.height = header.frame_height;
    }
    self.copyIn(rect, source, stride, ctx.counters);
    return .applied;
}

/// Apply a validated frame record and copy what it changed to TARGET: the
/// damage rectangle, or the whole frame for a `full` record.
pub fn receive(
    self: *View,
    ctx: *const Context,
    header: Frame.Header,
    encoding: Frame.Encoding,
    body: []const u8,
    target: ?Target,
) Allocator.Error!Status {
    switch (try self.apply(ctx, header, encoding, body)) {
        .applied => {},
        .stale => return .stale,
        .decode_error => return .decode_error,
        .shm_error => return .shm_error,
    }
    const to = target orelse return .stored;
    const rect: Rect = if (header.full())
        self.frameRect()
    else
        .{ .x = header.x, .y = header.y, .width = header.width, .height = header.height };
    return if (self.paint(to, rect, ctx.counters)) .painted else .size_mismatch;
}

/// Copy RECT of the store to TARGET.  Returns false, copying nothing, when
/// TARGET has another size than the store.
pub fn paint(self: *const View, target: Target, rect: Rect, counters: *Counters) bool {
    if (target.width != self.width or target.height != self.height) return false;
    const start = now();
    const stride: usize = self.width;
    var row: usize = rect.y;
    while (row < @as(usize, rect.y) + rect.height) : (row += 1) {
        const at = row * stride + rect.x;
        @memcpy(target.pixels[at..][0..rect.width], self.store[at..][0..rect.width]);
    }
    counters.copy_ns += now() - start;
    return true;
}

/// Copy little-endian BGRA rows from SRC, SRC_STRIDE bytes apart, into RECT.
fn copyIn(self: *View, rect: Rect, src: []const u8, src_stride: usize, counters: *Counters) void {
    const start = now();
    const row_bytes = @as(usize, rect.width) * 4;
    var row: usize = 0;
    while (row < rect.height) : (row += 1) {
        const dst = self.store[(rect.y + row) * @as(usize, self.width) + rect.x ..][0..rect.width];
        const from = src[row * src_stride ..][0..row_bytes];
        if (comptime builtin.cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(dst), from);
        } else {
            for (dst, 0..) |*pixel, i| pixel.* = std.mem.readInt(u32, from[i * 4 ..][0..4], .little);
        }
    }
    counters.copy_ns += now() - start;
}

/// Monotonic time in nanoseconds.
fn now() u64 {
    var ts: posix.struct_timespec = undefined;
    _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}
