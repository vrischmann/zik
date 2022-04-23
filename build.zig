const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    var target = b.standardTargetOptions(.{});
    const target_info = try std.zig.system.NativeTargetInfo.detect(b.allocator, target);
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
    exe.addPackagePath("audiometa", "third_party/audiometa/src/main.zig");
    exe.addPackagePath("sqlite", "third_party/zig-sqlite/sqlite.zig");
    exe.addPackagePath("mibu", "third_party/mibu/src/main.zig");
    exe.addPackagePath("known-folders", "third_party/known-folders/known-folders.zig");
    exe.linkLibC();
    exe.linkLibrary(sqlite);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
