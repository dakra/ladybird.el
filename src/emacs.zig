/// Zig wrapper around the Emacs dynamic module API.
///
/// Provides type-safe access to emacs_env functions, cached symbol
/// interning, and helper methods for common operations.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const c = @import("emacs_c");

pub const Value = c.emacs_value;
pub const RawEnv = ?*c.emacs_env;
pub const FnArgs = [*c]Value;
pub const FnData = ?*anyopaque;
pub const UserPtr = ?*anyopaque;
pub const Finalizer = fn (?*anyopaque) callconv(.c) void;
pub const FuncallExit = enum(c_int) {
    normal = 0,
    signal = 1,
    throw = 2,
};

var module_alloc: Allocator = undefined;

/// Global references whose owner was garbage collected.  A finalizer has
/// no environment, so the next module function call frees them.
var orphaned_refs: std.ArrayList(Value) = .empty;

pub const FunctionEntry = struct {
    name: [:0]const u8,
    arity: struct { i32, i32 },
    doc: [:0]const u8,
    impl: type,
};

/// Emacs environment wrapper providing typed access to the module API.
pub const Env = struct {
    raw: *c.emacs_env,

    pub fn init(raw: *c.emacs_env) Env {
        return .{ .raw = raw };
    }

    pub fn intern(self: Env, name: [*:0]const u8) Value {
        return self.raw.intern.?(self.raw, name);
    }

    pub fn funcall(self: Env, func: Value, args: []const Value) Value {
        return self.raw.funcall.?(self.raw, func, @intCast(args.len), @constCast(args.ptr));
    }

    pub fn f(self: Env, comptime func: []const u8, args: anytype) Value {
        return self.funcall(@field(sym, func), switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => &self.makeValues(args),
            else => args,
        });
    }

    pub fn list(self: Env, items: anytype) Value {
        return self.f("list", items);
    }

    pub fn cons(self: Env, car: anytype, cdr: anytype) Value {
        return self.f("cons", .{ car, cdr });
    }

    pub fn makeInteger(self: Env, n: i64) Value {
        return self.raw.make_integer.?(self.raw, @intCast(n));
    }

    pub fn makeFloat(self: Env, n: f64) Value {
        return self.raw.make_float.?(self.raw, n);
    }

    /// Invalid UTF-8 keeps its bad bytes as raw-byte chars instead of signalling.
    pub fn makeString(self: Env, str: []const u8) Value {
        if (!std.unicode.utf8ValidateSlice(str)) {
            return self.f("decode-coding-string", .{ self.makeUnibyteString(str), sym.@"utf-8-unix" });
        }
        return self.raw.make_string.?(self.raw, str.ptr, @intCast(str.len));
    }

    pub fn makeUnibyteString(self: Env, str: []const u8) Value {
        return self.raw.make_unibyte_string.?(self.raw, str.ptr, @intCast(str.len));
    }

    /// Transfers ownership to Emacs on success; the caller retains it on error.
    pub fn makeUserPtr(self: Env, finalizer: *const Finalizer, ptr: UserPtr) error{EmacsNonLocalExit}!Value {
        const value = self.raw.make_user_ptr.?(self.raw, finalizer, ptr);
        try self.check();
        return value;
    }

    /// The pointer of user-ptr VAL when FINALIZER is its finalizer.
    pub fn getUserPtr(self: Env, comptime T: type, finalizer: *const Finalizer, val: Value) !*T {
        const found = self.raw.get_user_finalizer.?(self.raw, val);
        try self.check();
        if (found != finalizer) return error.ForeignUserPointer;
        const raw_ptr = self.raw.get_user_ptr.?(self.raw, val);
        try self.check();
        return @ptrCast(@alignCast(raw_ptr orelse return error.ForeignUserPointer));
    }

    pub fn makeValues(self: Env, args: anytype) [@typeInfo(@TypeOf(args)).@"struct".field_names.len]Value {
        const info = @typeInfo(@TypeOf(args)).@"struct";
        var converted_args: [info.field_names.len]Value = undefined;
        inline for (info.field_names, 0..) |field_name, i| {
            converted_args[i] = self.makeValue(@field(args, field_name));
        }
        return converted_args;
    }

    pub fn makeValue(self: Env, value: anytype) Value {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .float, .comptime_float => return self.makeFloat(value),
            .int, .comptime_int => return self.makeInteger(@as(i64, @intCast(value))),
            .optional => return if (value) |v| self.makeValue(v) else self.nil(),
            .bool => return if (value) self.t() else self.nil(),
            .pointer => |ptr| {
                if (comptime isStringLike(ptr)) return self.makeString(value);
                if (T == *c.struct_emacs_value_tag) return value;
            },
            else => {},
        }

        @compileError(std.fmt.comptimePrint("Non-supported type: {}", .{T}));
    }

    /// VAL as an integer of type T; a non-integer signals `wrong-type-argument'.
    pub fn extractInt(self: Env, comptime T: type, val: Value) !T {
        const n = self.raw.extract_integer.?(self.raw, val);
        try self.check();
        return std.math.cast(T, n) orelse error.IntegerOutOfRange;
    }

    /// The bytes of string VAL appended to LIST.  A multibyte string is
    /// appended in its UTF-8 encoding.
    pub fn appendString(self: Env, alloc: Allocator, list_: *std.ArrayList(u8), val: Value) !void {
        var len: isize = 0;
        if (!self.raw.copy_string_contents.?(self.raw, val, null, &len)) return error.EmacsNonLocalExit;
        const required: usize = @intCast(len);
        try list_.ensureUnusedCapacity(alloc, required);
        const dest = list_.unusedCapacitySlice();
        if (!self.raw.copy_string_contents.?(self.raw, val, dest.ptr, &len)) return error.EmacsNonLocalExit;
        // LEN includes the terminating NUL.
        list_.items.len += required - 1;
    }

    pub fn isNil(self: Env, val: Value) bool {
        return !self.isNotNil(val);
    }

    pub fn isNotNil(self: Env, val: Value) bool {
        return self.raw.is_not_nil.?(self.raw, val);
    }

    pub fn eq(self: Env, a: Value, b: Value) bool {
        return self.raw.eq.?(self.raw, a, b);
    }

    pub fn makeGlobalRef(self: Env, val: Value) Value {
        return self.raw.make_global_ref.?(self.raw, val);
    }

    pub fn freeGlobalRef(self: Env, val: Value) void {
        self.raw.free_global_ref.?(self.raw, val);
    }

    /// The pixel buffer of CANVAS, valid until the next call into Emacs.
    pub fn canvasData(self: Env, canvas: Value) error{EmacsNonLocalExit}![*]u32 {
        const data = self.raw.canvas_data.?(self.raw, canvas);
        try self.check();
        return data orelse error.EmacsNonLocalExit;
    }

    pub fn nonLocalExitCheck(self: Env) FuncallExit {
        return @fromBackingInt(@intCast(self.raw.non_local_exit_check.?(self.raw)));
    }

    /// Fail when a non-local exit is pending.
    pub fn check(self: Env) error{EmacsNonLocalExit}!void {
        if (self.nonLocalExitCheck() != .normal) return error.EmacsNonLocalExit;
    }

    pub fn nonLocalExitSignal(self: Env, symbol: Value, data: Value) void {
        self.raw.non_local_exit_signal.?(self.raw, symbol, data);
    }

    /// Forget a pending non-local exit.
    pub fn nonLocalExitClear(self: Env) void {
        self.raw.non_local_exit_clear.?(self.raw);
    }

    pub fn makeFunction(
        self: Env,
        min_arity: i32,
        max_arity: i32,
        func: *const fn (?*c.emacs_env, isize, [*c]c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value,
        docstring: [*:0]const u8,
        data: ?*anyopaque,
    ) Value {
        return self.raw.make_function.?(self.raw, min_arity, max_arity, func, docstring, data);
    }

    pub fn nil(_: Env) Value {
        return sym.nil;
    }

    pub fn t(_: Env) Value {
        return sym.t;
    }

    /// Register a named Elisp function backed by a C function.
    pub fn registerFunction(self: Env, comptime entry: *const FunctionEntry) void {
        const wrapped_fn = struct {
            fn call(
                raw_env: RawEnv,
                nargs: isize,
                args: FnArgs,
                _: FnData,
            ) callconv(.c) Value {
                const env = Env.init(raw_env.?);
                env.freeOrphanedRefs();
                return entry.impl.call(env, nargs, args) catch |e| {
                    const err: anyerror = e;
                    switch (err) {
                        // Preserve the pending Emacs non-local exit.
                        error.EmacsNonLocalExit => {},
                        else => env.signalError(entry.name ++ ": " ++ "%s", .{@errorName(err)}),
                    }
                    return env.nil();
                };
            }
        }.call;
        const fun = self.makeFunction(entry.arity[0], entry.arity[1], &wrapped_fn, entry.doc, null);
        _ = self.f("fset", .{ self.intern(entry.name), fun });
    }

    pub fn registerFunctions(self: Env, comptime entries: []const FunctionEntry) void {
        inline for (entries) |*entry| self.registerFunction(entry);
    }

    /// Signal `ladybird-module-error' with a message in Emacs format syntax.
    pub fn signalError(self: Env, comptime msg: []const u8, objects: anytype) void {
        const all_args = [1]Value{self.makeString(msg)} ++ self.makeValues(objects);
        const text = self.funcall(sym.format, &all_args);
        self.nonLocalExitSignal(sym.@"ladybird-module-error", self.f("list", .{text}));
    }

    /// Signal `ladybird-module-error' and return the error that makes the
    /// function wrapper keep that signal.
    pub fn fail(self: Env, comptime msg: []const u8, objects: anytype) error{EmacsNonLocalExit} {
        self.signalError(msg, objects);
        return error.EmacsNonLocalExit;
    }

    fn freeOrphanedRefs(self: Env) void {
        while (orphaned_refs.pop()) |ref| self.freeGlobalRef(ref);
    }

    fn isStringLike(comptime ty: std.lang.Type.Pointer) bool {
        const child_info = @typeInfo(ty.child);
        return switch (ty.size) {
            .slice => ty.child == u8,
            .one => child_info == .array and child_info.array.child == u8,
            else => false,
        };
    }
};

/// Hand a global reference to the next module function call for freeing.
/// Callable without an environment, e.g. from a user-ptr finalizer.  The
/// reference leaks when memory for the list is exhausted.
pub fn orphanGlobalRef(ref: Value) void {
    orphaned_refs.append(module_alloc, ref) catch {};
}

// ---------------------------------------------------------------------------
// Pre-interned symbol cache — initialized once at module load, valid for the
// lifetime of the Emacs session.  Every field is a global reference so it
// stays valid across different emacs_env pointers.
// ---------------------------------------------------------------------------

const interned_symbols = [_][:0]const u8{
    ":buffer-capacity",
    ":buffered",
    ":bytes-in",
    ":control-records",
    ":copy-ns",
    ":data-height",
    ":data-width",
    ":decode-ns",
    ":dirty-views",
    ":frames",
    ":frames-dropped",
    ":frames-painted",
    ":largest-record",
    ":records",
    ":shm-size",
    ":state",
    ":views",
    ":zstd-in-bytes",
    ":zstd-out-bytes",
    "bad-frame",
    "bad-kind",
    "bad-length",
    "canvas-error",
    "canvas-refresh",
    "cdr",
    "closed",
    "cons",
    "decode-coding-string",
    "decode-error",
    "define-error",
    "desync",
    "desynced",
    "format",
    "frame",
    "fset",
    "ladybird-module",
    "ladybird-module-error",
    "list",
    "multibyte-string-p",
    "nil",
    "no-canvas",
    "no-frame",
    "nreverse",
    "ok",
    "oversize",
    "painted",
    "plist-get",
    "provide",
    "shm-error",
    "size-mismatch",
    "stale",
    "stored",
    "stringp",
    "t",
    "unknown-view",
    "utf-8-unix",
};

fn SymbolCache(comptime symbols: []const [:0]const u8) type {
    var names: [symbols.len][]const u8 = undefined;
    var types: [symbols.len]type = undefined;
    var attrs: [symbols.len]std.lang.Type.Struct.FieldAttributes = undefined;

    for (symbols, 0..) |symbol, i| {
        names[i] = symbol;
        types[i] = Value;
        attrs[i] = .{
            .@"comptime" = false,
            .@"align" = @alignOf(Value),
            .default_value_ptr = null,
        };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub var sym: SymbolCache(&interned_symbols) = undefined;

/// Initialize the global symbol cache.  Must be called once from
/// emacs_module_init with the environment provided by Emacs.
pub fn initModule(alloc: Allocator, raw: *c.emacs_env) void {
    module_alloc = alloc;

    const env = Env.init(raw);
    inline for (@typeInfo(@TypeOf(sym)).@"struct".field_names) |field_name| {
        @field(sym, field_name) = env.makeGlobalRef(env.intern(field_name));
    }
}
