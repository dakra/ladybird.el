/// Record framing of the ladybird stream:
/// `u32 LE length, u8 kind, payload`, where LENGTH counts KIND and the payload.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_record = 64 * 1024 * 1024;
/// Bytes of a record before its payload.
pub const record_header_len = 5;

pub const Kind = enum(u8) { control = 1, frame = 2 };

pub const DesyncReason = enum { bad_length, oversize, bad_kind };

pub const Step = union(enum) {
    /// The record at the start of the input is incomplete.  The value is its
    /// total size, or 0 while its header is incomplete.
    need_more: usize,
    record: struct {
        kind: Kind,
        payload: []const u8,
        /// Bytes the record occupies in the input.
        size: usize,
    },
    desync: DesyncReason,
};

/// Classify the start of BYTES.
pub fn step(bytes: []const u8) Step {
    if (bytes.len < record_header_len) return .{ .need_more = 0 };
    const length = std.mem.readInt(u32, bytes[0..4], .little);
    if (length == 0) return .{ .desync = .bad_length };
    if (length > max_record) return .{ .desync = .oversize };
    const kind: Kind = switch (bytes[4]) {
        1 => .control,
        2 => .frame,
        else => return .{ .desync = .bad_kind },
    };
    const size = 4 + @as(usize, length);
    if (bytes.len < size) return .{ .need_more = size };
    return .{ .record = .{ .kind = kind, .payload = bytes[record_header_len..size], .size = size } };
}

/// Accumulation buffer for stream chunks.
pub const Buffer = struct {
    data: std.ArrayList(u8) = .empty,
    /// Bytes at the start of DATA that are already parsed.
    consumed: usize = 0,
    /// Stream offset of `data.items[consumed]`.
    offset: u64 = 0,
    largest_record: usize = 0,
    /// Largest record and number of records since the last capacity review.
    window_largest: usize = 0,
    window_records: usize = 0,

    /// Records between capacity reviews.
    pub const review_interval = 64;

    pub fn deinit(self: *Buffer, alloc: Allocator) void {
        self.data.deinit(alloc);
        self.* = .{};
    }

    /// Drop all bytes and restart the stream offset.
    pub fn reset(self: *Buffer, alloc: Allocator) void {
        self.data.clearAndFree(alloc);
        self.consumed = 0;
        self.offset = 0;
    }

    pub fn append(self: *Buffer, alloc: Allocator, bytes: []const u8) Allocator.Error!void {
        try self.data.appendSlice(alloc, bytes);
    }

    pub fn buffered(self: *const Buffer) usize {
        return self.data.items.len - self.consumed;
    }

    /// The next step of the stream.  A returned payload is valid until the
    /// buffer is next appended to or compacted.  An incomplete record
    /// reserves room for all of itself when there is memory for it.
    pub fn next(self: *Buffer, alloc: Allocator) Step {
        const result = step(self.data.items[self.consumed..]);
        switch (result) {
            .record => |record| {
                self.consumed += record.size;
                self.offset += record.size;
                self.largest_record = @max(self.largest_record, record.size);
                self.window_largest = @max(self.window_largest, record.size);
                self.window_records += 1;
            },
            .need_more => |size| if (size > 0) {
                self.largest_record = @max(self.largest_record, size);
                // Without the reservation the appends grow the buffer.
                self.data.ensureTotalCapacityPrecise(alloc, self.consumed + size) catch {};
            },
            .desync => {},
        }
        return result;
    }

    /// Reclaim the parsed prefix.  Every `review_interval` records, an empty
    /// buffer whose capacity exceeds twice the largest of them gives its
    /// memory back.
    pub fn compact(self: *Buffer, alloc: Allocator) void {
        const items = self.data.items;
        if (self.consumed == items.len) {
            self.data.clearRetainingCapacity();
            self.consumed = 0;
            if (self.window_records >= review_interval) {
                if (self.data.capacity > 2 * self.window_largest) self.data.clearAndFree(alloc);
                self.window_largest = 0;
                self.window_records = 0;
            }
        } else if (self.consumed > items.len / 2) {
            const tail = items.len - self.consumed;
            @memmove(items[0..tail], items[self.consumed..]);
            self.data.items.len = tail;
            self.consumed = 0;
        }
    }
};
