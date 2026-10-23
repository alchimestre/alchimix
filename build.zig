const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Every effect warps the whole frame every frame, so an optimised build is
    // the normal one; `-Doptimize=Debug` still works when a backtrace is wanted.
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimisation mode") orelse .fast;

    // rekordbox keeps its collection in SQLCipher, so the system SQLite cannot
    // open it.
    const prefix = b.option([]const u8, "sqlcipher-prefix", "Prefix of the sqlcipher install") orelse
        std.mem.trimEnd(u8, b.run(&.{ "brew", "--prefix", "sqlcipher" }), "\r\n");

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include", "sqlcipher" }) });
    const sqlcipher = translate.createModule();

    // The mixer writes to an SDL audio stream; the window uses the same library.
    const sdl_prefix = b.option([]const u8, "sdl3-prefix", "Prefix of the SDL3 install") orelse
        std.mem.trimEnd(u8, b.run(&.{ "brew", "--prefix", "sdl3" }), "\r\n");
    const sdl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "include" }) });
    const sdlc = sdl_translate.createModule();

    const core = b.addModule("alchimix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = sqlcipher },
            .{ .name = "sdl3-c", .module = sdlc },
        },
    });
    core.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    core.linkSystemLibrary("sqlcipher", .{});
    // The audio stream must bind to the same SDL the window uses; without this
    // the stream pointer comes back from a mismatched dynapi table.
    core.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "lib" }) });
    core.linkSystemLibrary("SDL3", .{});
    core.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "alchimix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "alchimix", .module = core }},
        }),
    });
    linkUi(b, exe.root_module, target, optimize);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run alchimix").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = core });

    // The pointer rules and the drift field carry their own tests. The drift
    // works on dvui's geometry types, so this module imports dvui as well; no
    // window is opened, and the backend is never referenced.
    const ui_tests = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "alchimix", .module = core }},
    });
    linkUi(b, ui_tests, target, optimize);
    const hit_tests = b.addTest(.{ .root_module = ui_tests });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(hit_tests).step);
}

/// dvui draws the blocks; SDL3 opens the window and its GPU device fills them.
/// Both come from packages.
fn linkUi(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    // dvui compiles SDL3 from source unless the system copy is enabled; the
    // app links the Homebrew dylib itself, and two copies of SDL in one
    // process duplicate every Objective-C class.
    _ = b.systemIntegrationOption("sdl3", .{ .default = true });
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3gpu,
    });
    mod.addImport("dvui", dvui.module("dvui_sdl3gpu"));
    mod.addImport("sdl-backend", dvui.module("sdl3gpu"));
}
