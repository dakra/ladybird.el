/// Frame record header: 44 bytes, little-endian, followed by the body.
const std = @import("std");

pub const header_len = 44;
pub const max_dimension = 16384;
/// Largest frame a view stores, in bytes of pixels: 256 MiB, which is
/// 8192 by 8192 pixels.
pub const max_frame_bytes = 256 * 1024 * 1024;

pub const Encoding = enum(u8) { raw = 0, zstd = 1, shm = 2 };

pub const flag_full = 1;
pub const flag_more = 2;

pub const Header = struct {
    seq: u32,
    view: u32,
    frame_width: u32,
    frame_height: u32,
    dpr: f64,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    encoding: u8,
    flags: u8,

    /// Split a frame record payload into its header and body.
    pub fn parse(payload: []const u8) error{BadFrame}!struct { Header, []const u8 } {
        if (payload.len < header_len) return error.BadFrame;
        const header: Header = .{
            .seq = readU32(payload, 0),
            .view = readU32(payload, 4),
            .frame_width = readU32(payload, 8),
            .frame_height = readU32(payload, 12),
            .dpr = @bitCast(std.mem.readInt(u64, payload[16..24], .little)),
            .x = readU32(payload, 24),
            .y = readU32(payload, 28),
            .width = readU32(payload, 32),
            .height = readU32(payload, 36),
            .encoding = payload[40],
            .flags = payload[41],
        };
        return .{ header, payload[header_len..] };
    }

    pub fn full(self: Header) bool {
        return self.flags & flag_full != 0;
    }

    pub fn more(self: Header) bool {
        return self.flags & flag_more != 0;
    }

    /// Bytes of the damage rectangle as raw pixels.
    pub fn rawSize(self: Header) usize {
        return @as(usize, self.width) * self.height * 4;
    }

    /// Check the geometry, that the frame is no larger than
    /// `max_frame_bytes` and that a body of BODY_LEN bytes fits the
    /// encoding, which is returned.
    pub fn validate(self: Header, body_len: usize) error{BadFrame}!Encoding {
        const fw = self.frame_width;
        const fh = self.frame_height;
        if (fw < 1 or fh < 1 or fw > max_dimension or fh > max_dimension) return error.BadFrame;
        if (@as(u64, fw) * fh * 4 > max_frame_bytes) return error.BadFrame;
        if (self.width < 1 or self.height < 1) return error.BadFrame;
        if (@as(u64, self.x) + self.width > fw or @as(u64, self.y) + self.height > fh) return error.BadFrame;
        switch (self.encoding) {
            0 => {
                if (body_len != self.rawSize()) return error.BadFrame;
                return .raw;
            },
            1 => return .zstd,
            2 => {
                if (body_len != 8) return error.BadFrame;
                return .shm;
            },
            else => return error.BadFrame,
        }
    }
};

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
