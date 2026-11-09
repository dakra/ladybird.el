/// Wrapper over the vendored zstd decoder.
const std = @import("std");
const c = @import("zstd_c");

pub const ContentSize = union(enum) {
    known: u64,
    /// A valid frame header that does not state the size.
    unknown,
    /// Not the start of a zstd frame.
    invalid,
};

/// The decompressed size stated by the zstd frame header at the start of SRC.
pub fn contentSize(src: []const u8) ContentSize {
    const size = c.ZSTD_getFrameContentSize(src.ptr, src.len);
    // ZSTD_CONTENTSIZE_UNKNOWN and ZSTD_CONTENTSIZE_ERROR.
    if (size == std.math.maxInt(u64)) return .unknown;
    if (size == std.math.maxInt(u64) - 1) return .invalid;
    return .{ .known = size };
}

pub const Decoder = struct {
    dctx: *c.ZSTD_DCtx,

    pub fn init() error{OutOfMemory}!Decoder {
        return .{ .dctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Decoder) void {
        _ = c.ZSTD_freeDCtx(self.dctx);
    }

    /// Decompress the zstd frame SRC into DST and return the bytes written.
    pub fn decompress(self: *Decoder, dst: []u8, src: []const u8) error{ZstdError}!usize {
        const n = c.ZSTD_decompressDCtx(self.dctx, dst.ptr, dst.len, src.ptr, src.len);
        if (c.ZSTD_isError(n) != 0) return error.ZstdError;
        return n;
    }
};
