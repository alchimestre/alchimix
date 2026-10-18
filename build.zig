const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const core = b.addModule("playlister", .{
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
    core.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "playlister",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "playlister", .module = core }},
        }),
    });
    linkUi(b, exe.root_module, target, optimize);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run playlister").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = core });

    // The pointer rules carry their own tests and no dvui, so they run here too.
    const hit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "playlister", .module = core }},
    }) });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(hit_tests).step);
}

/// dvui draws the blocks; SDL3 opens the window. Both come from packages.
fn linkUi(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    mod.addImport("dvui", dvui.module("dvui_sdl3"));
    mod.addImport("sdl-backend", dvui.module("sdl3"));
}
