const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;

/// MMapableFile wraps a file and mmap's it if the user wants it.
/// It owns both the file and the mmapped memory slice if set.
pub const MMapableFile = union(enum) {
    const Self = @This();

    file: fs.File,
    mmapped_file: struct {
        file: fs.File,
        file_bytes: []align(mem.page_size) u8,
        fbs: io.FixedBufferStream([]u8),
    },

    pub const OpenError = fs.File.OpenError || fs.File.StatError || os.MMapError;

    /// Opens the file `basename` under `dir`, using mmap if asked.
    /// Call `close` to release the associated resources.
    pub fn open(dir: fs.Dir, basename: []const u8, flags: struct { use_mmap: bool }) OpenError!Self {
        var file = try dir.openFile(basename, .{});

        if (flags.use_mmap) {
            const stat = try file.stat();
            const file_size = @intCast(usize, stat.size);

            const file_bytes = try os.mmap(
                null,
                mem.alignForward(file_size, mem.page_size),
                os.PROT.READ,
                os.MAP.PRIVATE,
                file.handle,
                0,
            );

            return Self{
                .mmapped_file = .{
                    .file = file,
                    .file_bytes = file_bytes,
                    .fbs = io.fixedBufferStream(@ptrCast([]u8, file_bytes)),
                },
            };
        } else {
            return Self{
                .file = file,
            };
        }
    }

    pub fn close(self: *Self) void {
        switch (self.*) {
            .file => |f| f.close(),
            .mmapped_file => |mf| {
                os.munmap(mf.file_bytes);
                mf.file.close();
            },
        }
    }

    pub fn streamSource(self: *Self) io.StreamSource {
        switch (self.*) {
            .file => |f| return io.StreamSource{ .file = f },
            .mmapped_file => |mf| return io.StreamSource{ .buffer = mf.fbs },
        }
    }
};
