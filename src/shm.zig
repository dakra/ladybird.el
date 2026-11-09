/// Read-only mapping of a POSIX shared memory object.
const std = @import("std");
const c = @import("posix_c");

pub const Shm = @This();

base: [*]const u8,
size: usize,

/// A failed system call and its errno.
pub const Failure = struct {
    call: []const u8,
    errno: c_int,

    pub fn message(self: Failure) []const u8 {
        return std.mem.span(c.strerror(self.errno));
    }
};

pub const Result = union(enum) { ok: Shm, failed: Failure };

/// Map the whole object NAME.
pub fn open(name: [*:0]const u8) Result {
    const fd = c.shm_open(name, c.O_RDONLY, @as(c_int, 0));
    if (fd < 0) return failure("shm_open");
    defer _ = c.close(fd);
    return map(fd, c.PROT_READ);
}

pub fn close(self: Shm) void {
    _ = c.munmap(@constCast(self.base), self.size);
}

pub fn bytes(self: Shm) []const u8 {
    return self.base[0..self.size];
}

/// Create NAME if needed, large enough for DATA at OFFSET, and write DATA
/// there.  A new object gets its size from this call; an existing one keeps it.
pub fn write(name: [*:0]const u8, offset: usize, data: []const u8) ?Failure {
    const mode: c_int = 0o600;
    var fd = c.shm_open(name, c.O_CREAT | c.O_EXCL | c.O_RDWR, mode);
    if (fd >= 0) {
        if (c.ftruncate(fd, @intCast(offset + data.len)) != 0) {
            const result = failure("ftruncate").failed;
            _ = c.close(fd);
            _ = c.shm_unlink(name);
            return result;
        }
    } else {
        fd = c.shm_open(name, c.O_RDWR, mode);
        if (fd < 0) return failure("shm_open").failed;
    }
    defer _ = c.close(fd);
    const mapping = switch (map(fd, c.PROT_READ | c.PROT_WRITE)) {
        .ok => |m| m,
        .failed => |f| return f,
    };
    defer mapping.close();
    if (offset + data.len > mapping.size) return .{ .call = "write", .errno = c.ERANGE };
    @memcpy(@constCast(mapping.base)[offset..][0..data.len], data);
    return null;
}

pub fn unlink(name: [*:0]const u8) ?Failure {
    if (c.shm_unlink(name) != 0) return failure("shm_unlink").failed;
    return null;
}

fn map(fd: c_int, prot: c_int) Result {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return failure("fstat");
    const size: usize = @intCast(st.st_size);
    const address = c.mmap(null, size, prot, c.MAP_SHARED, fd, 0);
    if (@intFromPtr(address) == std.math.maxInt(usize)) return failure("mmap");
    return .{ .ok = .{ .base = @ptrCast(address.?), .size = size } };
}

fn failure(call: []const u8) Result {
    return .{ .failed = .{ .call = call, .errno = std.c._errno().* } };
}
