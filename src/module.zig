/// ladybird-module — Emacs dynamic module entry point.
///
/// Exports emacs_module_init, which Emacs calls on load, and registers
/// the Elisp-callable functions.
const std = @import("std");
const emacs = @import("emacs.zig");
const options = @import("build_options");
const Session = @import("Session.zig");

const c = emacs.c;
const version = @import("version.zig").version;

const alloc = std.heap.c_allocator;

/// Returns 1 when the module ABI of Emacs is older than the one this module
/// was built for and 2 when Emacs has no canvas support (Emacs < 32).
export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) return 1;
    const raw_env = runtime.get_environment.?(runtime);
    if (raw_env.*.size < @sizeOf(c.emacs_env)) return 2;

    emacs.initModule(alloc, raw_env);
    Session.initModule(alloc);

    const env = emacs.Env.init(raw_env);
    const s = &emacs.sym;
    _ = env.f("define-error", .{ s.@"ladybird-module-error", "Ladybird module error" });
    env.registerFunctions(&module_functions);
    env.registerFunctions(&Session.functions);
    if (options.test_helpers) env.registerFunctions(&Session.test_functions);

    _ = env.f("provide", .{s.@"ladybird-module"});
    return 0;
}

export const plugin_is_GPL_compatible: c_int = 0;

const module_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ladybird-module-version",
        .arity = .{ 0, 0 },
        .doc =
        \\Return the native module version string.
        \\
        \\(ladybird-module-version)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                return env.makeString(version);
            }
        },
    },
};
