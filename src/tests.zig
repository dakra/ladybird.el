/// Unit tests that need no Emacs: record parser, frame header and the view
/// backing store, checked against the stream fixtures of test/fixtures/.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Frame = @import("Frame.zig");
const Parser = @import("Parser.zig");
const View = @import("View.zig");
const zstd = @import("zstd.zig");

const alloc = testing.allocator;

/// The pixel formula of plans/05-tooling-and-integration.md section 2.
fn formula(x: u32, y: u32, seed: u32, fw: u32, fh: u32) u32 {
    const r = x * 255 / @max(fw - 1, 1);
    const g = y * 255 / @max(fh - 1, 1);
    const b = (seed * 37 + (x ^ y)) & 0xFF;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

fn appendRecord(list: *std.ArrayList(u8), kind: u8, payload: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len + 1), .little);
    try list.appendSlice(alloc, &length);
    try list.append(alloc, kind);
    try list.appendSlice(alloc, payload);
}

const FrameSpec = struct {
    seq: u32 = 1,
    view: u32 = 1,
    fw: u32,
    fh: u32,
    x: u32 = 0,
    y: u32 = 0,
    w: ?u32 = null,
    h: ?u32 = null,
    encoding: u8 = 0,
    flags: u8 = 0,
    seed: u32 = 0,
    /// Replaces the raw formula pixels of the rectangle.
    body: ?[]const u8 = null,
};

/// A frame record payload: header and body.
fn framePayload(spec: FrameSpec) ![]u8 {
    const w = spec.w orelse spec.fw;
    const h = spec.h orelse spec.fh;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var header: [Frame.header_len]u8 = @splat(0);
    for ([_]u32{ spec.seq, spec.view, spec.fw, spec.fh }, 0..) |value, i|
        std.mem.writeInt(u32, header[i * 4 ..][0..4], value, .little);
    std.mem.writeInt(u64, header[16..24], @bitCast(@as(f64, 2.0)), .little);
    for ([_]u32{ spec.x, spec.y, w, h }, 0..) |value, i|
        std.mem.writeInt(u32, header[24 + i * 4 ..][0..4], value, .little);
    header[40] = spec.encoding;
    header[41] = spec.flags;
    try out.appendSlice(alloc, &header);
    if (spec.body) |body| {
        try out.appendSlice(alloc, body);
    } else {
        var py = spec.y;
        while (py < spec.y + h) : (py += 1) {
            var px = spec.x;
            while (px < spec.x + w) : (px += 1) {
                var pixel: [4]u8 = undefined;
                std.mem.writeInt(u32, &pixel, formula(px, py, spec.seed, spec.fw, spec.fh), .little);
                try out.appendSlice(alloc, &pixel);
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

const Record = struct { kind: Parser.Kind, payload: []u8 };

/// Feed STREAM in chunks of CHUNK bytes and collect the records.  A desync
/// ends the list; its reason and stream offset are returned.
const Collected = struct {
    records: std.ArrayList(Record) = .empty,
    desync: ?struct { reason: Parser.DesyncReason, offset: u64 } = null,

    fn deinit(self: *Collected) void {
        for (self.records.items) |record| alloc.free(record.payload);
        self.records.deinit(alloc);
    }
};

fn collect(stream: []const u8, chunk: usize) !Collected {
    var buffer: Parser.Buffer = .{};
    defer buffer.deinit(alloc);
    var result: Collected = .{};
    errdefer result.deinit();
    var at: usize = 0;
    feeding: while (at < stream.len) {
        const end = @min(stream.len, at + chunk);
        try buffer.append(alloc, stream[at..end]);
        at = end;
        while (true) switch (buffer.next(alloc)) {
            .need_more => break,
            .record => |record| try result.records.append(alloc, .{
                .kind = record.kind,
                .payload = try alloc.dupe(u8, record.payload),
            }),
            .desync => |reason| {
                result.desync = .{ .reason = reason, .offset = buffer.offset };
                break :feeding;
            },
        };
        buffer.compact(alloc);
    }
    if (result.desync == null) try testing.expectEqual(@as(usize, 0), buffer.buffered());
    return result;
}

/// A client: one view, its decoder state and an optional paint target.
const Client = struct {
    view: View = .{},
    decoder: zstd.Decoder,
    scratch: View.Scratch = .{},
    counters: View.Counters = .{},
    shm: ?[]const u8 = null,
    canvas: []u32 = &.{},
    canvas_width: u32 = 0,
    canvas_height: u32 = 0,

    fn init() !Client {
        return .{ .decoder = try zstd.Decoder.init() };
    }

    fn deinit(self: *Client) void {
        self.view.deinit(alloc);
        self.decoder.deinit();
        self.scratch.deinit(alloc);
        alloc.free(self.canvas);
    }

    /// Give the client a zeroed canvas of W by H pixels.
    fn resizeCanvas(self: *Client, w: u32, h: u32) !void {
        alloc.free(self.canvas);
        self.canvas = &.{};
        self.canvas = try alloc.alloc(u32, @as(usize, w) * h);
        @memset(self.canvas, 0);
        self.canvas_width = w;
        self.canvas_height = h;
    }

    fn receive(self: *Client, payload: []const u8) !View.Status {
        const header, const body = Frame.Header.parse(payload) catch return .bad_frame;
        const encoding = header.validate(body.len) catch return .bad_frame;
        const context: View.Context = .{
            .alloc = alloc,
            .decoder = &self.decoder,
            .scratch = &self.scratch,
            .shm = self.shm,
            .counters = &self.counters,
        };
        const target: ?View.Target = if (self.canvas.len == 0) null else .{
            .pixels = self.canvas.ptr,
            .width = self.canvas_width,
            .height = self.canvas_height,
        };
        return self.view.receive(&context, header, encoding, body, target);
    }

    /// Receive the frame records of STREAM and return their statuses.
    fn receiveStream(self: *Client, stream: []const u8) ![]View.Status {
        var collected = try collect(stream, 4096);
        defer collected.deinit();
        var statuses: std.ArrayList(View.Status) = .empty;
        errdefer statuses.deinit(alloc);
        for (collected.records.items) |record| {
            if (record.kind == .frame) try statuses.append(alloc, try self.receive(record.payload));
        }
        return statuses.toOwnedSlice(alloc);
    }
};

const SeededRect = struct { x: u32, y: u32, w: u32, h: u32, seed: u32 };

/// The pixel of a FW by FH frame composed from RECTS, later ones on top.
fn composed(rects: []const SeededRect, fw: u32, fh: u32, x: u32, y: u32) u32 {
    var pixel: u32 = 0;
    for (rects) |r| {
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h)
            pixel = formula(x, y, r.seed, fw, fh);
    }
    return pixel;
}

fn expectComposed(pixels: []const u32, rects: []const SeededRect, fw: u32, fh: u32) !void {
    try testing.expectEqual(@as(usize, fw) * fh, pixels.len);
    var y: u32 = 0;
    while (y < fh) : (y += 1) {
        var x: u32 = 0;
        while (x < fw) : (x += 1) {
            const expected = composed(rects, fw, fh, x, y);
            const actual = pixels[@as(usize, y) * fw + x];
            if (expected != actual) {
                std.debug.print("pixel ({d}, {d}): expected {x}, found {x}\n", .{ x, y, expected, actual });
                return error.TestExpectedEqual;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

test "records survive every chunking" {
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(alloc);
    var expected: std.ArrayList(Record) = .empty;
    defer {
        for (expected.items) |record| alloc.free(record.payload);
        expected.deinit(alloc);
    }
    const controls = [_][]const u8{ "{\"type\":\"welcome\"}", "", "{\"type\":\"state\",\"title\":\"h\xc3\xa9llo\"}" };
    const frames = [_]FrameSpec{
        .{ .fw = 16, .fh = 8, .flags = Frame.flag_full, .seed = 1 },
        .{ .seq = 2, .fw = 16, .fh = 8, .x = 3, .y = 2, .w = 5, .h = 4, .seed = 2 },
    };
    try expected.append(alloc, .{ .kind = .control, .payload = try alloc.dupe(u8, controls[0]) });
    try expected.append(alloc, .{ .kind = .frame, .payload = try framePayload(frames[0]) });
    try expected.append(alloc, .{ .kind = .control, .payload = try alloc.dupe(u8, controls[1]) });
    try expected.append(alloc, .{ .kind = .frame, .payload = try framePayload(frames[1]) });
    try expected.append(alloc, .{ .kind = .control, .payload = try alloc.dupe(u8, controls[2]) });
    for (expected.items) |record| try appendRecord(&stream, @backingInt(record.kind), record.payload);

    var sizes: std.ArrayList(usize) = .empty;
    defer sizes.deinit(alloc);
    for (1..98) |size| try sizes.append(alloc, size);
    try sizes.appendSlice(alloc, &.{ 4096, 65536 });
    for (sizes.items) |size| {
        var collected = try collect(stream.items, size);
        defer collected.deinit();
        try testing.expect(collected.desync == null);
        try testing.expectEqual(expected.items.len, collected.records.items.len);
        for (expected.items, collected.records.items) |want, got| {
            try testing.expectEqual(want.kind, got.kind);
            try testing.expectEqualSlices(u8, want.payload, got.payload);
        }
    }
}

test "framing errors desync at the offset of the bad record" {
    const good = [_]u8{ 3, 0, 0, 0, 1, '{', '}' };
    const cases = [_]struct { bytes: []const u8, reason: Parser.DesyncReason }{
        .{ .bytes = &.{ 0, 0, 0, 0, 1 }, .reason = .bad_length },
        .{ .bytes = &.{ 1, 0, 0, 4, 1 }, .reason = .oversize },
        .{ .bytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 2 }, .reason = .oversize },
        .{ .bytes = &.{ 4, 0, 0, 0, 3, 'a', 'b', 'c' }, .reason = .bad_kind },
        .{ .bytes = &.{ 4, 0, 0, 0, 0, 'a', 'b', 'c' }, .reason = .bad_kind },
    };
    for (cases) |case| {
        for ([_][]const u8{ "", &good }) |prefix| {
            const stream = try std.mem.concat(alloc, u8, &.{ prefix, case.bytes, &good });
            defer alloc.free(stream);
            for ([_]usize{ 1, 3, 4096 }) |chunk| {
                var collected = try collect(stream, chunk);
                defer collected.deinit();
                try testing.expectEqual(@as(usize, if (prefix.len == 0) 0 else 1), collected.records.items.len);
                try testing.expectEqual(case.reason, collected.desync.?.reason);
                try testing.expectEqual(@as(u64, prefix.len), collected.desync.?.offset);
            }
        }
    }
}

test "the largest record length is accepted" {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], Parser.max_record, .little);
    header[4] = 2;
    try testing.expectEqual(Parser.Step{ .need_more = 4 + Parser.max_record }, Parser.step(&header));
    try testing.expectEqual(Parser.Step{ .need_more = 0 }, Parser.step(header[0..4]));
}

test "an incomplete record reserves its size once and the buffer shrinks after a spike" {
    const big = 20 * 1024 * 1024;
    var buffer: Parser.Buffer = .{};
    defer buffer.deinit(alloc);

    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], big + 1, .little);
    header[4] = 1;
    try buffer.append(alloc, &header);
    try testing.expectEqual(Parser.Step{ .need_more = big + 5 }, buffer.next(alloc));
    const reserved = buffer.data.capacity;
    try testing.expect(reserved >= big + 5);

    const chunk = try alloc.alloc(u8, 65536);
    defer alloc.free(chunk);
    @memset(chunk, 'x');
    var remaining: usize = big;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        try buffer.append(alloc, chunk[0..n]);
        remaining -= n;
        if (remaining > 0) try testing.expect((buffer.next(alloc)) == .need_more);
    }
    try testing.expectEqual(reserved, buffer.data.capacity);
    const step = buffer.next(alloc);
    try testing.expectEqual(@as(usize, big), step.record.payload.len);
    buffer.compact(alloc);
    try testing.expectEqual(@as(usize, big + 5), buffer.largest_record);

    const small = [_]u8{ 3, 0, 0, 0, 1, '{', '}' };
    for (0..2 * Parser.Buffer.review_interval) |_| {
        try buffer.append(alloc, &small);
        try testing.expect((buffer.next(alloc)) == .record);
        buffer.compact(alloc);
    }
    try testing.expect(buffer.data.capacity < 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), buffer.buffered());
}

test "compaction keeps an unparsed tail" {
    var buffer: Parser.Buffer = .{};
    defer buffer.deinit(alloc);
    const bytes = [_]u8{ 3, 0, 0, 0, 1, '{', '}', 4, 0, 0, 0, 1, 'a' };
    try buffer.append(alloc, &bytes);
    try testing.expect((buffer.next(alloc)) == .record);
    try testing.expectEqual(Parser.Step{ .need_more = 8 }, buffer.next(alloc));
    buffer.compact(alloc);
    try testing.expectEqual(@as(usize, 0), buffer.consumed);
    try testing.expectEqual(@as(usize, 6), buffer.buffered());
    try testing.expectEqual(@as(u64, 7), buffer.offset);
    try buffer.append(alloc, "bc");
    const step = buffer.next(alloc);
    try testing.expectEqualStrings("abc", step.record.payload);
}

// ---------------------------------------------------------------------------
// Frame header
// ---------------------------------------------------------------------------

test "frame header fields" {
    const payload = try framePayload(.{
        .seq = 7,
        .view = 3,
        .fw = 64,
        .fh = 48,
        .x = 1,
        .y = 2,
        .w = 3,
        .h = 4,
        .flags = Frame.flag_full | Frame.flag_more,
    });
    defer alloc.free(payload);
    const header, const body = try Frame.Header.parse(payload);
    try testing.expectEqual(@as(u32, 7), header.seq);
    try testing.expectEqual(@as(u32, 3), header.view);
    try testing.expectEqual(@as(u32, 64), header.frame_width);
    try testing.expectEqual(@as(u32, 48), header.frame_height);
    try testing.expectEqual(@as(f64, 2.0), header.dpr);
    try testing.expectEqual(@as(u32, 1), header.x);
    try testing.expectEqual(@as(u32, 2), header.y);
    try testing.expectEqual(@as(u32, 3), header.width);
    try testing.expectEqual(@as(u32, 4), header.height);
    try testing.expect(header.full() and header.more());
    try testing.expectEqual(@as(usize, 48), body.len);
    try testing.expectEqual(Frame.Encoding.raw, try header.validate(body.len));
}

test "frame validation" {
    const Case = struct { spec: FrameSpec, body_len: usize };
    const good = [_]Case{
        .{ .spec = .{ .fw = 64, .fh = 48 }, .body_len = 64 * 48 * 4 },
        .{ .spec = .{ .fw = 64, .fh = 48, .encoding = 2 }, .body_len = 8 },
        .{ .spec = .{ .fw = 64, .fh = 48, .encoding = 1 }, .body_len = 17 },
        .{ .spec = .{ .fw = Frame.max_dimension, .fh = 4096, .w = 1, .h = 1 }, .body_len = 4 },
        .{ .spec = .{ .fw = 8192, .fh = 8192, .w = 1, .h = 1 }, .body_len = 4 },
        .{ .spec = .{ .fw = 64, .fh = 48, .x = 63, .y = 47, .w = 1, .h = 1 }, .body_len = 4 },
    };
    const bad = [_]Case{
        .{ .spec = .{ .fw = 64, .fh = 48, .w = 0 }, .body_len = 0 },
        .{ .spec = .{ .fw = 64, .fh = 48, .h = 0 }, .body_len = 0 },
        .{ .spec = .{ .fw = 64, .fh = 48, .x = 1 }, .body_len = 64 * 48 * 4 },
        .{ .spec = .{ .fw = 64, .fh = 48, .y = 1 }, .body_len = 64 * 48 * 4 },
        .{ .spec = .{ .fw = 64, .fh = 48, .x = 0xFFFFFFFF, .w = 2, .h = 1 }, .body_len = 8 },
        .{ .spec = .{ .fw = Frame.max_dimension + 1, .fh = 48, .w = 1, .h = 1 }, .body_len = 4 },
        .{ .spec = .{ .fw = 0, .fh = 48, .w = 1, .h = 1 }, .body_len = 4 },
        // More than `max_frame_bytes` of pixels.
        .{ .spec = .{ .fw = 8192, .fh = 8193, .w = 1, .h = 1 }, .body_len = 4 },
        .{ .spec = .{ .fw = Frame.max_dimension, .fh = Frame.max_dimension, .w = 1, .h = 1 }, .body_len = 4 },
        .{ .spec = .{ .fw = 64, .fh = 48, .w = 1, .h = 1, .encoding = 3 }, .body_len = 4 },
        .{ .spec = .{ .fw = 64, .fh = 48 }, .body_len = 64 * 48 * 4 - 1 },
        .{ .spec = .{ .fw = 64, .fh = 48, .encoding = 2 }, .body_len = 4 },
    };
    for (good, 0..) |case, i| {
        const payload = try framePayload(.{
            .fw = case.spec.fw,
            .fh = case.spec.fh,
            .x = case.spec.x,
            .y = case.spec.y,
            .w = case.spec.w,
            .h = case.spec.h,
            .encoding = case.spec.encoding,
            .body = "",
        });
        defer alloc.free(payload);
        const header, _ = try Frame.Header.parse(payload);
        _ = header.validate(case.body_len) catch {
            std.debug.print("good case {d} rejected\n", .{i});
            return error.TestUnexpectedResult;
        };
    }
    for (bad, 0..) |case, i| {
        const payload = try framePayload(.{
            .fw = case.spec.fw,
            .fh = case.spec.fh,
            .x = case.spec.x,
            .y = case.spec.y,
            .w = case.spec.w,
            .h = case.spec.h,
            .encoding = case.spec.encoding,
            .body = "",
        });
        defer alloc.free(payload);
        const header, _ = try Frame.Header.parse(payload);
        if (header.validate(case.body_len)) |_| {
            std.debug.print("bad case {d} accepted\n", .{i});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try testing.expectError(error.BadFrame, Frame.Header.parse(&@as([43]u8, @splat(0))));
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

test "raw rectangles compose in the store and on the canvas" {
    var client = try Client.init();
    defer client.deinit();
    try client.resizeCanvas(40, 30);
    const specs = [_]FrameSpec{
        .{ .fw = 40, .fh = 30, .flags = Frame.flag_full, .seed = 1 },
        .{ .fw = 40, .fh = 30, .x = 0, .y = 5, .w = 40, .h = 3, .seed = 2 },
        .{ .fw = 40, .fh = 30, .x = 7, .y = 9, .w = 11, .h = 13, .seed = 3 },
        .{ .fw = 40, .fh = 30, .x = 39, .y = 29, .w = 1, .h = 1, .seed = 4 },
    };
    var rects: [specs.len]SeededRect = undefined;
    for (specs, 0..) |spec, i| {
        const payload = try framePayload(spec);
        defer alloc.free(payload);
        try testing.expectEqual(View.Status.painted, try client.receive(payload));
        rects[i] = .{ .x = spec.x, .y = spec.y, .w = spec.w orelse spec.fw, .h = spec.h orelse spec.fh, .seed = spec.seed };
    }
    try expectComposed(client.view.store, &rects, 40, 30);
    try expectComposed(client.canvas, &rects, 40, 30);
}

test "resize rules" {
    var client = try Client.init();
    defer client.deinit();

    const damage_first = try framePayload(.{ .fw = 8, .fh = 6, .seed = 1 });
    defer alloc.free(damage_first);
    try testing.expectEqual(View.Status.stale, try client.receive(damage_first));
    try testing.expect(!client.view.hasFrame());

    const full = try framePayload(.{ .fw = 8, .fh = 6, .flags = Frame.flag_full, .seed = 1 });
    defer alloc.free(full);
    try testing.expectEqual(View.Status.stored, try client.receive(full));
    try testing.expect(client.view.hasFrame());

    try client.resizeCanvas(8, 6);
    try testing.expectEqual(View.Status.painted, try client.receive(damage_first));

    // A full frame of another size replaces the store; the canvas keeps its pixels.
    const bigger = try framePayload(.{ .fw = 10, .fh = 7, .x = 2, .y = 1, .w = 3, .h = 2, .flags = Frame.flag_full, .seed = 2 });
    defer alloc.free(bigger);
    try testing.expectEqual(View.Status.size_mismatch, try client.receive(bigger));
    try testing.expectEqual(@as(u32, 10), client.view.width);
    try testing.expectEqual(@as(u32, 7), client.view.height);
    try expectComposed(client.view.store, &.{.{ .x = 2, .y = 1, .w = 3, .h = 2, .seed = 2 }}, 10, 7);
    try expectComposed(client.canvas, &.{.{ .x = 0, .y = 0, .w = 8, .h = 6, .seed = 1 }}, 8, 6);

    // Damage for the old size is stale and changes nothing.
    try testing.expectEqual(View.Status.stale, try client.receive(damage_first));
    try expectComposed(client.view.store, &.{.{ .x = 2, .y = 1, .w = 3, .h = 2, .seed = 2 }}, 10, 7);

    // A canvas of the new size receives the whole store.
    try client.resizeCanvas(10, 7);
    try testing.expect(client.view.paint(
        .{ .pixels = client.canvas.ptr, .width = 10, .height = 7 },
        client.view.frameRect(),
        &client.counters,
    ));
    try expectComposed(client.canvas, &.{.{ .x = 2, .y = 1, .w = 3, .h = 2, .seed = 2 }}, 10, 7);

    // A full frame repaints the whole canvas, not only its damage.
    @memset(client.canvas, 0xDEADBEEF);
    const partial_full = try framePayload(.{ .fw = 10, .fh = 7, .x = 0, .y = 0, .w = 1, .h = 1, .flags = Frame.flag_full, .seed = 3 });
    defer alloc.free(partial_full);
    try testing.expectEqual(View.Status.painted, try client.receive(partial_full));
    try testing.expectEqualSlices(u32, client.view.store, client.canvas);
}

test "shm frames read the damage rectangle at the offset" {
    var client = try Client.init();
    defer client.deinit();
    const fw = 12;
    const fh = 5;
    const offset = 24;
    const pixels = try framePayload(.{ .fw = fw, .fh = fh, .seed = 9 });
    defer alloc.free(pixels);
    const segment = try alloc.alloc(u8, offset + fw * fh * 4);
    defer alloc.free(segment);
    @memset(segment, 0x55);
    @memcpy(segment[offset..], pixels[Frame.header_len..]);

    var body: [8]u8 = undefined;
    std.mem.writeInt(u64, &body, offset, .little);
    const full = try framePayload(.{ .fw = fw, .fh = fh, .encoding = 2, .flags = Frame.flag_full, .body = &body });
    defer alloc.free(full);
    try testing.expectEqual(View.Status.shm_error, try client.receive(full));
    client.shm = segment;
    try testing.expectEqual(View.Status.stored, try client.receive(full));
    try expectComposed(client.view.store, &.{.{ .x = 0, .y = 0, .w = fw, .h = fh, .seed = 9 }}, fw, fh);

    // Only the damage rectangle is read.
    @memset(client.view.store, 0);
    const damage = try framePayload(.{ .fw = fw, .fh = fh, .x = 3, .y = 1, .w = 4, .h = 2, .encoding = 2, .body = &body });
    defer alloc.free(damage);
    try testing.expectEqual(View.Status.stored, try client.receive(damage));
    try expectComposed(client.view.store, &.{.{ .x = 3, .y = 1, .w = 4, .h = 2, .seed = 9 }}, fw, fh);

    // The frame must fit behind the offset.
    for ([_]u64{ offset + 1, segment.len, std.math.maxInt(u64), 1 << 63 }) |bad_offset| {
        std.mem.writeInt(u64, &body, bad_offset, .little);
        const bad = try framePayload(.{ .fw = fw, .fh = fh, .encoding = 2, .body = &body });
        defer alloc.free(bad);
        try testing.expectEqual(View.Status.shm_error, try client.receive(bad));
    }
}

test "a frame that cannot be decoded leaves the store as it was" {
    var client = try Client.init();
    defer client.deinit();
    const good = try framePayload(.{ .fw = 8, .fh = 6, .flags = Frame.flag_full, .seed = 1 });
    defer alloc.free(good);
    try testing.expectEqual(View.Status.stored, try client.receive(good));
    const kept = [_]SeededRect{.{ .x = 0, .y = 0, .w = 8, .h = 6, .seed = 1 }};

    // A zstd frame without a content size: one raw block of four bytes.
    const no_size = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x21, 0x00, 0x00, 1, 2, 3, 4 };
    try testing.expectEqual(zstd.ContentSize.unknown, zstd.contentSize(&no_size));
    // The same with the size stated, and cut short.
    const sized = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x04, 0x21, 0x00, 0x00, 1, 2, 3, 4 };
    try testing.expectEqual(zstd.ContentSize{ .known = 4 }, zstd.contentSize(&sized));

    var offset: [8]u8 = undefined;
    std.mem.writeInt(u64, &offset, 1, .little);
    const segment: [8 * 6 * 4]u8 = @splat(0x77);
    client.shm = &segment;

    const Case = struct { spec: FrameSpec, status: View.Status };
    const cases = [_]Case{
        // Full frames of the stored size.
        .{ .spec = .{ .fw = 8, .fh = 6, .w = 1, .h = 1, .encoding = 1, .flags = Frame.flag_full, .body = &no_size }, .status = .decode_error },
        .{ .spec = .{ .fw = 8, .fh = 6, .w = 1, .h = 1, .encoding = 1, .flags = Frame.flag_full, .body = sized[0..11] }, .status = .decode_error },
        .{ .spec = .{ .fw = 8, .fh = 6, .encoding = 1, .flags = Frame.flag_full, .body = "not zstd" }, .status = .decode_error },
        .{ .spec = .{ .fw = 8, .fh = 6, .encoding = 2, .flags = Frame.flag_full, .body = &offset }, .status = .shm_error },
        // Full frames of another size.
        .{ .spec = .{ .fw = 9, .fh = 7, .w = 1, .h = 1, .encoding = 1, .flags = Frame.flag_full, .body = &no_size }, .status = .decode_error },
        .{ .spec = .{ .fw = 9, .fh = 7, .w = 1, .h = 1, .encoding = 1, .flags = Frame.flag_full, .body = sized[0..11] }, .status = .decode_error },
        .{ .spec = .{ .fw = 9, .fh = 7, .encoding = 2, .flags = Frame.flag_full, .body = &offset }, .status = .shm_error },
        .{ .spec = .{ .fw = 4096, .fh = 4096, .encoding = 2, .flags = Frame.flag_full, .body = &offset }, .status = .shm_error },
        // Damage of another size.
        .{ .spec = .{ .fw = 9, .fh = 7, .w = 1, .h = 1, .encoding = 1, .body = &sized }, .status = .stale },
    };
    for (cases) |case| {
        const payload = try framePayload(case.spec);
        defer alloc.free(payload);
        try testing.expectEqual(case.status, try client.receive(payload));
        try testing.expectEqual(@as(u32, 8), client.view.width);
        try testing.expectEqual(@as(u32, 6), client.view.height);
        try expectComposed(client.view.store, &kept, 8, 6);
    }

    // The frame with its size stated decodes.
    const pixel = try framePayload(.{ .fw = 8, .fh = 6, .x = 2, .y = 3, .w = 1, .h = 1, .encoding = 1, .body = &sized });
    defer alloc.free(pixel);
    try testing.expectEqual(View.Status.stored, try client.receive(pixel));
    try testing.expectEqual(@as(u32, 0x04030201), client.view.store[3 * 8 + 2]);
}

test "the zstd buffer gives memory back after a run of small frames" {
    var scratch: View.Scratch = .{};
    defer scratch.deinit(alloc);
    _ = try scratch.get(alloc, 1 << 20);
    try testing.expect(scratch.data.capacity >= 1 << 20);
    var i: usize = 0;
    while (i < View.Scratch.review_interval) : (i += 1) {
        const bytes = try scratch.get(alloc, 100);
        try testing.expectEqual(@as(usize, 100), bytes.len);
    }
    // The large frame is still in the window that ends here.
    try testing.expect(scratch.data.capacity >= 1 << 20);
    i = 0;
    while (i <= View.Scratch.review_interval) : (i += 1) _ = try scratch.get(alloc, 100);
    try testing.expect(scratch.data.capacity < 1 << 20);
    // A buffer in steady use keeps its memory.
    i = 0;
    while (i < 3 * View.Scratch.review_interval) : (i += 1) _ = try scratch.get(alloc, 4000);
    const capacity = scratch.data.capacity;
    i = 0;
    while (i < 3 * View.Scratch.review_interval) : (i += 1) _ = try scratch.get(alloc, 4000);
    try testing.expectEqual(capacity, scratch.data.capacity);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

test "fixture basic-raw-full" {
    var collected = try collect(@embedFile("basic-raw-full.ladybird"), 13);
    defer collected.deinit();
    const records = collected.records.items;
    try testing.expectEqual(@as(usize, 3), records.len);
    try testing.expectEqual(Parser.Kind.control, records[0].kind);
    try testing.expect(std.mem.startsWith(u8, records[0].payload, "{\"type\":\"welcome\""));
    try testing.expectEqual(Parser.Kind.frame, records[1].kind);
    try testing.expectEqual(Parser.Kind.control, records[2].kind);

    const header, const body = try Frame.Header.parse(records[1].payload);
    try testing.expectEqual(@as(u32, 1), header.seq);
    try testing.expectEqual(@as(u32, 1), header.view);
    try testing.expectEqual(@as(f64, 1.0), header.dpr);
    try testing.expect(header.full() and !header.more());
    try testing.expectEqual(Frame.Encoding.raw, try header.validate(body.len));

    var client = try Client.init();
    defer client.deinit();
    try client.resizeCanvas(64, 48);
    try testing.expectEqual(View.Status.painted, try client.receive(records[1].payload));
    try expectComposed(client.canvas, &.{.{ .x = 0, .y = 0, .w = 64, .h = 48, .seed = 1 }}, 64, 48);
}

test "fixture damage-mix" {
    const rects = [_]SeededRect{
        .{ .x = 0, .y = 0, .w = 320, .h = 200, .seed = 1 },
        .{ .x = 0, .y = 10, .w = 320, .h = 20, .seed = 2 },
        .{ .x = 40, .y = 50, .w = 100, .h = 60, .seed = 3 },
        .{ .x = 0, .y = 150, .w = 320, .h = 50, .seed = 4 },
        .{ .x = 319, .y = 0, .w = 1, .h = 200, .seed = 5 },
        .{ .x = 60, .y = 70, .w = 30, .h = 30, .seed = 6 },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .seed = 7 },
    };
    var collected = try collect(@embedFile("damage-mix.ladybird"), 65536);
    defer collected.deinit();
    try testing.expectEqual(rects.len, collected.records.items.len);
    const encodings = [_]Frame.Encoding{ .raw, .raw, .zstd, .zstd, .raw, .raw, .zstd };
    for (collected.records.items, rects, encodings, 1..) |record, rect, encoding, seq| {
        const header, const body = try Frame.Header.parse(record.payload);
        try testing.expectEqual(@as(u32, @intCast(seq)), header.seq);
        try testing.expectEqual(encoding, try header.validate(body.len));
        try testing.expectEqual(seq == 1, header.full());
        try testing.expectEqual(rect.x, header.x);
        try testing.expectEqual(rect.y, header.y);
        try testing.expectEqual(rect.w, header.width);
        try testing.expectEqual(rect.h, header.height);
    }

    var client = try Client.init();
    defer client.deinit();
    try client.resizeCanvas(320, 200);
    const statuses = try client.receiveStream(@embedFile("damage-mix.ladybird"));
    defer alloc.free(statuses);
    try testing.expectEqualSlices(View.Status, &@as([7]View.Status, @splat(.painted)), statuses);
    try expectComposed(client.view.store, &rects, 320, 200);
    try expectComposed(client.canvas, &rects, 320, 200);
    try testing.expectEqual(@as(u64, 4 * (100 * 60 + 320 * 50 + 1)), client.counters.zstd_out_bytes);
}

test "fixture resize" {
    var client = try Client.init();
    defer client.deinit();
    try client.resizeCanvas(320, 200);
    const statuses = try client.receiveStream(@embedFile("resize.ladybird"));
    defer alloc.free(statuses);
    try testing.expectEqualSlices(View.Status, &.{ .painted, .painted, .size_mismatch, .stale }, statuses);
    try expectComposed(client.view.store, &.{.{ .x = 0, .y = 0, .w = 400, .h = 300, .seed = 3 }}, 400, 300);
    try expectComposed(client.canvas, &.{
        .{ .x = 0, .y = 0, .w = 320, .h = 200, .seed = 1 },
        .{ .x = 10, .y = 10, .w = 100, .h = 50, .seed = 2 },
    }, 320, 200);
}

test "fixture bad" {
    var collected = try collect(@embedFile("bad.ladybird"), 7);
    defer collected.deinit();
    try testing.expectEqual(@as(usize, 10), collected.records.items.len);
    try testing.expectEqual(Parser.DesyncReason.oversize, collected.desync.?.reason);
    try testing.expectEqual(@as(u64, 636), collected.desync.?.offset);

    var client = try Client.init();
    defer client.deinit();
    try client.resizeCanvas(64, 48);
    for (collected.records.items[0..8]) |record|
        try testing.expectEqual(View.Status.bad_frame, try client.receive(record.payload));
    try testing.expectEqual(View.Status.decode_error, try client.receive(collected.records.items[8].payload));
    try testing.expectEqual(Parser.Kind.control, collected.records.items[9].kind);
    try testing.expect(!client.view.hasFrame());
}

test "fixture zstd" {
    const fw = 1600;
    const fh = 1000;
    var collected = try collect(@embedFile("zstd.ladybird"), 65536);
    defer collected.deinit();
    try testing.expectEqual(@as(usize, 1), collected.records.items.len);
    const payload = collected.records.items[0].payload;

    var client = try Client.init();
    defer client.deinit();
    try testing.expectEqual(View.Status.stored, try client.receive(payload));
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const x = (i * 7919) % fw;
        const y = (i * 104729) % fh;
        try testing.expectEqual(formula(x, y, 7, fw, fh), client.view.store[@as(usize, y) * fw + x]);
    }
    try expectComposed(client.view.store, &.{.{ .x = 0, .y = 0, .w = fw, .h = fh, .seed = 7 }}, fw, fh);
    try testing.expectEqual(@as(u64, fw * fh * 4), client.counters.zstd_out_bytes);
    try testing.expectEqual(@as(u64, payload.len - Frame.header_len), client.counters.zstd_in_bytes);

    // A truncated body, and one whose stated size is not that of the rectangle.
    const truncated = payload[0 .. payload.len / 2];
    try testing.expectEqual(View.Status.decode_error, try client.receive(truncated));
    const body = payload[Frame.header_len..];
    const wrong_size = try framePayload(.{ .fw = fw, .fh = fh, .h = fh - 1, .encoding = 1, .body = body });
    defer alloc.free(wrong_size);
    try testing.expectEqual(View.Status.decode_error, try client.receive(wrong_size));

    // An interior rectangle.
    const interior = try framePayload(.{ .fw = fw, .fh = fh, .x = 100, .y = 200, .w = 300, .h = 50, .seed = 8 });
    defer alloc.free(interior);
    try testing.expectEqual(View.Status.stored, try client.receive(payload));
    try testing.expectEqual(View.Status.stored, try client.receive(interior));
    try expectComposed(client.view.store, &.{
        .{ .x = 0, .y = 0, .w = fw, .h = fh, .seed = 7 },
        .{ .x = 100, .y = 200, .w = 300, .h = 50, .seed = 8 },
    }, fw, fh);
}

test "zstd content size" {
    const body = @embedFile("zstd.ladybird")[Parser.record_header_len + Frame.header_len ..];
    try testing.expectEqual(zstd.ContentSize{ .known = 1600 * 1000 * 4 }, zstd.contentSize(body));
    try testing.expectEqual(zstd.ContentSize.invalid, zstd.contentSize("not zstd"));
    try testing.expectEqual(zstd.ContentSize.invalid, zstd.contentSize(""));
}
