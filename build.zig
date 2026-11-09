const std = @import("std");
const builtin = @import("builtin");
const module_version = @import("src/version.zig").version;

var io: std.Io.Threaded = .init_single_threaded;

// Keep in sync with build.zig.zon (minimum_zig_version).
const required_zig = std.SemanticVersion{ .major = 0, .minor = 17, .patch = 0 };
comptime {
    const found = builtin.zig_version;
    if (found.major != required_zig.major or found.minor != required_zig.minor or
        found.order(required_zig) == .lt)
        @compileError("ladybird requires Zig 0.17.x, found " ++ builtin.zig_version_string);
}

const vendored_emacs_module_dir = "vendor";

const zstd_flags = [_][]const u8{
    "-DZSTD_LEGACY_SUPPORT=0",
    "-DZSTD_STRIP_ERROR_STRINGS=0",
    "-DZSTD_DISABLE_ASM=1",
    "-DZSTDLIB_VISIBLE=",
    "-DZSTDERRORLIB_VISIBLE=",
    "-fvisibility=hidden",
};

/// Test fixtures embedded into the unit tests under their file names.
const embedded_fixtures = [_][]const u8{
    "basic-raw-full.ladybird",
    "damage-mix.ladybird",
    "resize.ladybird",
    "bad.ladybird",
    "zstd.ladybird",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_helpers = b.option(
        bool,
        "test-helpers",
        "Include the Lisp functions that only tests use",
    ) orelse false;
    const is_release = optimize != .debug;
    const target_os = target.result.os.tag;

    const translate_emacs = b.addTranslateC(.{
        .root_source_file = b.path("src/emacs.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_emacs.addIncludePath(resolveEmacsModuleDir(b));
    const emacs_c = translate_emacs.createModule();

    const translate_posix = b.addTranslateC(.{
        .root_source_file = b.path("src/posix.h"),
        .target = target,
        .optimize = optimize,
    });
    const posix_c = translate_posix.createModule();

    const translate_zstd = b.addTranslateC(.{
        .root_source_file = b.path("src/zstd_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_zstd.addIncludePath(b.path("vendor/zstd"));
    const zstd_c = translate_zstd.createModule();

    const build_options = b.addOptions();
    build_options.addOption(bool, "test_helpers", test_helpers);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (is_release) true else null,
        .omit_frame_pointer = if (is_release) true else null,
        .imports = &.{
            .{ .name = "emacs_c", .module = emacs_c },
            .{ .name = "posix_c", .module = posix_c },
            .{ .name = "zstd_c", .module = zstd_c },
        },
    });
    mod.addOptions("build_options", build_options);
    mod.addCSourceFile(.{ .file = b.path("vendor/zstd/zstddeclib.c"), .flags = &zstd_flags });

    const lib = b.addLibrary(.{
        .name = "ladybird-module",
        .linkage = .dynamic,
        .root_module = mod,
    });
    if (is_release) {
        lib.link_gc_sections = true;
        lib.link_function_sections = true;
        lib.link_data_sections = true;
        lib.dead_strip_dylibs = true;

        if (target_os == .linux) {
            lib.setVersionScript(b.path("symbols.map"));
        }
    }

    const copy_step = b.addInstallFile(lib.getEmittedBin(), moduleOutputName(target_os));
    b.getInstallStep().dependOn(&copy_step.step);

    // Version sidecar next to the binary.  The Elisp loader reads it before
    // `module-load' to detect a stale module without mapping it.
    const version_wf = b.addWriteFiles();
    const version_file = version_wf.add("ladybird-module.version", module_version ++ "\n");
    const copy_version_step = b.addInstallFile(version_file, "ladybird-module.version");
    b.getInstallStep().dependOn(&copy_version_step.step);

    // `zig build test`: unit tests that need no Emacs.  Tests through the
    // module API run via `make test-native`.
    const test_step = b.step("test", "Run Zig unit tests");
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "posix_c", .module = posix_c },
            .{ .name = "zstd_c", .module = zstd_c },
        },
    });
    tests_mod.addCSourceFile(.{ .file = b.path("vendor/zstd/zstddeclib.c"), .flags = &zstd_flags });
    for (embedded_fixtures) |name| {
        tests_mod.addAnonymousImport(name, .{
            .root_source_file = b.path(b.pathJoin(&.{ "test", "fixtures", name })),
        });
    }
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn resolveEmacsModuleDir(b: *std.Build) std.Build.LazyPath {
    if (b.graph.environ_map.get("EMACS_INCLUDE_DIR")) |dir| {
        if (!dirHasEmacsModuleHeader(b.allocator, dir))
            std.debug.panic("EMACS_INCLUDE_DIR={s} does not contain emacs-module.h", .{dir});
        return .{ .cwd_relative = dir };
    }

    if (b.graph.environ_map.get("EMACS_BIN_DIR")) |bin_dir| {
        for ([_][]const []const u8{
            &.{ bin_dir, "..", "include" },
            &.{ bin_dir, "..", "share", "emacs", "include" },
        }) |parts| {
            const dir = b.pathJoin(parts);
            if (dirHasEmacsModuleHeader(b.allocator, dir)) return .{ .cwd_relative = dir };
        }
        std.debug.panic(
            "EMACS_BIN_DIR={s} does not resolve to a directory containing emacs-module.h",
            .{bin_dir},
        );
    }

    return b.path(vendored_emacs_module_dir);
}

fn dirHasEmacsModuleHeader(allocator: std.mem.Allocator, dir: []const u8) bool {
    const header_path = std.fs.path.join(allocator, &.{ dir, "emacs-module.h" }) catch
        @panic("out of memory while resolving emacs-module.h");
    defer allocator.free(header_path);

    std.Io.Dir.cwd().access(io.io(), header_path, .{}) catch return false;
    return true;
}

fn moduleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "ladybird-module.dylib",
        else => "ladybird-module.so",
    };
}
