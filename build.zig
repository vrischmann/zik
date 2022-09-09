const std = @import("std");

fn addDeps(step: *std.build.LibExeObjStep) void {
    step.addPackagePath("audiometa", "third_party/audiometa/src/audiometa.zig");
    step.addPackagePath("sqlite", "third_party/zig-sqlite/sqlite.zig");
    step.addPackagePath("mibu", "third_party/mibu/src/main.zig");
    step.addPackagePath("known-folders", "third_party/known-folders/known-folders.zig");
    step.addPackagePath("mecha", "third_party/mecha/mecha.zig");
}

pub fn build(b: *std.build.Builder) !void {
    var target = b.standardTargetOptions(.{});
    const target_info = try std.zig.system.NativeTargetInfo.detect(target);
    if (target_info.target.os.tag == .linux and target_info.target.abi == .gnu) {
        target.setGnuLibCVersion(2, 28, 0);
    }

    const mode = b.standardReleaseOptions();

    const sqlite = b.addStaticLibrary("sqlite", null);
    sqlite.addCSourceFile("third_party/zig-sqlite/c/sqlite3.c", &.{});
    sqlite.addIncludeDir("third_party/zig-sqlite/c");
    sqlite.linkLibC();
    sqlite.setTarget(target);
    sqlite.setBuildMode(mode);

    const exe = b.addExecutable("zik", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludeDir("third_party/zig-sqlite/c");
    exe.linkLibC();
    exe.linkLibrary(sqlite);
    addDeps(exe);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);
    exe_tests.addIncludeDir("third_party/zig-sqlite/c");
    exe_tests.linkLibC();
    exe_tests.linkLibrary(sqlite);
    addDeps(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
