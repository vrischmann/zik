const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const os = std.os;

const known_folders = @import("known-folders");
const mibu = @import("mibu");
const sqlite = @import("sqlite");

const usage =
    mibu.color.print.fg(.yellow) ++ "Usage" ++ mibu.color.print.reset ++
    \\: zik <command> [options]
    \\
    \\
++ mibu.style.print.bold ++ "Commands" ++ mibu.style.print.reset ++
    \\
    \\
    \\  config      Configure Zik
    \\  scan        Scan your music libraries
    \\  query       Find information in your music libraries
    \\
    \\
++ mibu.style.print.bold ++ "General options" ++ mibu.style.print.reset ++
    \\
    \\
    \\  -h, --help    Print the documentation
    \\
;

const scan_usage =
    mibu.color.print.fg(.yellow) ++ "Usage" ++ mibu.color.print.reset ++
    \\: zik scan [options]
    \\
    \\
++ mibu.style.print.bold ++ "Options" ++ mibu.style.print.reset ++
    \\
    \\
    \\  -d, --directory [path]     Scan this directory instead of your configured libraries
    \\
;

const config_usage =
    mibu.color.print.fg(.yellow) ++ "Usage" ++ mibu.color.print.reset ++
    \\: zik config [options] <name> [value]
    \\
    \\
++ mibu.style.print.bold ++ "Description" ++ mibu.style.print.reset ++
    \\
    \\
    \\  Get or set options.
    \\  If value is not present the option value will be printed.
    \\
;

fn runConfigView(allocator: mem.Allocator, db: *sqlite.Db) !void {
    const query =
        \\SELECT key, value FROM config
    ;

    var diags = sqlite.Diagnostics{};

    var stmt = try db.prepareWithDiags(query, .{ .diags = &diags });
    defer stmt.deinit();

    var iter = try stmt.iterator(
        struct {
            key: []const u8,
            value: []const u8,
        },
        .{},
    );

    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (try iter.nextAlloc(arena.allocator(), .{})) |row| {
        print("{s} = \"{s}\"", .{
            fmt.fmtSliceEscapeLower(row.key),
            row.value,
        });
    }

    // const value_opt = db.oneAlloc(
    //     []const u8,
    //     allocator,
    //     query,
    //     .{ .diags = &diags },
    //     .{ .key = key },
    // ) catch |err| {
    //     print("unable to get config value, err: {s}\n", .{diags});
    //     return err;
    // };

    // if (value_opt) |value| {
    //     defer allocator.free(value);

    //     print("{s} = \"{s}\"", .{
    //         fmt.fmtSliceEscapeLower(key),
    //         value,
    //     });
    // } else {
    //     print("no value for config \"{s}\"", .{
    //         fmt.fmtSliceEscapeLower(key),
    //     });
    //     return;
    // }
}

fn runConfigGet(allocator: mem.Allocator, db: *sqlite.Db, key: []const u8) !void {
    const tag_opt = meta.stringToEnum(meta.Tag(Config), key);
    if (tag_opt == null) {
        print("no config named \"{s}\"", .{
            fmt.fmtSliceEscapeLower(key),
        });
        return error.Explained;
    }

    //

    const query =
        \\SELECT value FROM config WHERE key = $key
    ;

    var diags = sqlite.Diagnostics{};

    const value_opt = db.oneAlloc(
        []const u8,
        allocator,
        query,
        .{ .diags = &diags },
        .{ .key = key },
    ) catch |err| {
        print("unable to get config value, err: {s}\n", .{diags});
        return err;
    };

    if (value_opt) |value| {
        defer allocator.free(value);

        print("{s} = \"{s}\"", .{
            fmt.fmtSliceEscapeLower(key),
            value,
        });
    } else {
        print("no value for config \"{s}\"", .{
            fmt.fmtSliceEscapeLower(key),
        });
        return;
    }
}

fn runConfigSet(allocator: mem.Allocator, db: *sqlite.Db, key: []const u8, value: []const u8) !void {
    const tag_opt = meta.stringToEnum(meta.Tag(Config), key);
    if (tag_opt == null) {
        print("no config named \"{s}\"", .{
            fmt.fmtSliceEscapeLower(key),
        });
        return error.Explained;
    }

    const tag: meta.Tag(Config) = tag_opt.?;

    const config = switch (tag) {
        .library => blk: {
            var dir = fs.cwd().openDir(value, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    print("path \"{s}\" doesn't exist", .{value});
                    return error.Explained;
                },
                error.NotDir => {
                    print("path \"{s}\" is not a directory", .{value});
                    return error.Explained;
                },
                else => fatal("unable to open library \"{s}\", err: {s}", .{ value, err }),
            };
            defer dir.close();

            const absolute_path = try dir.realpathAlloc(allocator, ".");

            print("setting library to {s} (absolute path resolved from {s})", .{
                absolute_path,
                value,
            });

            break :blk Config{ .library = absolute_path };
        },
        .scan_parallelism => blk: {
            const n = fmt.parseInt(usize, value, 10) catch {
                print("invalid `scan_parallelism` value \"{s}\"", .{
                    fmt.fmtSliceEscapeLower(value),
                });
                return error.Explained;
            };

            print("setting scan parallelism to {d}", .{n});

            break :blk Config{ .scan_parallelism = n };
        },
    };
    defer config.deinit(allocator);

    try setConfig(allocator, db, config);
}

fn runConfig(allocator: mem.Allocator, db: *sqlite.Db, args: []const []const u8) !void {
    _ = allocator;
    _ = db;

    if (args.len <= 0) {
        return runConfigView(allocator, db);
    } else if (args.len == 1) {
        const key = args[0];

        return runConfigGet(allocator, db, key);
    } else {
        const key = args[0];
        const value = args[1];

        return runConfigSet(allocator, db, key, value);
    }
}

fn runScan(allocator: mem.Allocator, args: []const []const u8) !void {
    _ = allocator;

    // Parse the arguments and options

    var scan_mode: union(enum) {
        directory: []const u8,
        library,
    } = .library;

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg)) {
                print(scan_usage, .{});
                return error.Explained;
            } else if (mem.eql(u8, "-d", arg) or mem.eql(u8, "--directory", arg)) {
                if (i + 1 >= args.len) fatal("expected argument after \"{s}\"", .{arg});
                i += 1;
                scan_mode = .{ .directory = args[i] };
            }
        }
    }

    switch (scan_mode) {
        .directory => |directory| {
            print("scan a specific directory: {s}\n", .{directory});
        },
        .library => {
            print("scanning the library\n", .{});
        },
    }
}

const Config = union(enum) {
    library: []const u8,
    scan_parallelism: usize,

    fn deinit(self: *const Config, allocator: mem.Allocator) void {
        switch (self.*) {
            .library => |payload| {
                allocator.free(payload);
            },
            else => {},
        }
    }
};

// fn getConfig(comptime Tag: meta.Tag(Config), comptime Payload: type, allocator: mem.Allocator, db: *sqlite.Db) !?Config {
//     var diags = sqlite.Diagnostics{};

//     const query =
//         \\SELECT value FROM config WHERE key = $key
//     ;

//     const value = db.oneAlloc(
//         Payload,
//         allocator,
//         query,
//         .{ .diags = &diags },
//         .{ .key = @tagName(Tag) },
//     ) catch |err| {
//         print("unable to get config value, err: {s}\n", .{diags});
//         return err;
//     };
//     if (value == null) {
//         return null;
//     }

//     return @unionInit(Config, @tagName(Tag), value.?);
// }

fn setConfig(allocator: mem.Allocator, db: *sqlite.Db, config: Config) !void {
    const query =
        \\INSERT INTO config(key, value) VALUES($key{[]const u8}, $value)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ;

    var diags = sqlite.Diagnostics{};
    db.execAlloc(
        allocator,
        query,
        .{ .diags = &diags },
        .{
            .key = meta.tagName(meta.activeTag(config)),
            .value = config,
        },
    ) catch |err| {
        print("unable to get config value, err: {s}\n", .{diags});
        return err;
    };
}

fn openDatabase(allocator: mem.Allocator) !sqlite.Db {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var data_directory = (try known_folders.getPath(arena.allocator(), .data)) orelse return error.UnknownDataFolder;

    // Create the zik data directory

    var zik_directory = try fs.path.join(arena.allocator(), &.{
        data_directory, "zik",
    });
    fs.makeDirAbsolute(zik_directory) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var db_path = try fs.path.joinZ(arena.allocator(), &.{
        zik_directory, "data.db",
    });

    return sqlite.Db.init(.{
        .mode = .{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });
}

fn initDatabase(db: *sqlite.Db) !void {
    _ = try db.pragma(void, .{}, "foreign_keys", "on");

    //

    const ddls = &[_][]const u8{
        \\CREATE TABLE IF NOT EXISTS config(
        \\  key TEXT UNIQUE,
        \\  value ANY
        \\)
        ,
        \\CREATE TABLE IF NOT EXISTS artist(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT
        \\) STRICT
        ,
        \\CREATE TABLE IF NOT EXISTS album(
        \\  id INTEGER PRIMARY KEY,
        \\  name INTEGER,
        \\  artist_id INTEGER,
        \\  album_artist_id INTEGER,
        \\  release_date TEXT,
        \\
        \\  FOREIGN KEY(artist_id) REFERENCES artist(id)
        \\) STRICT
        ,
        \\CREATE TABLE IF NOT EXISTS track(
        \\  id INTEGER PRIMARY KEY,
        \\  name INTEGER,
        \\  artist_id INTEGER,
        \\  release_date TEXT,
        \\  album_id INTEGER,
        \\
        \\  FOREIGN KEY(artist_id) REFERENCES artist(id),
        \\  FOREIGN KEY(album_id) REFERENCES album(id)
        \\) STRICT
    };

    var savepoint = try db.savepoint("DDL");
    defer savepoint.rollback();

    inline for (ddls) |ddl| {
        var diags = sqlite.Diagnostics{};
        db.exec(ddl, .{ .diags = &diags }, .{}) catch |err| {
            print("unable to execute statement, err: {s}\n", .{diags});
            return err;
        };
    }

    savepoint.commit();
}

var stdout_file = io.getStdOut();
var stdout: fs.File.Writer = undefined;
var stdout_mutex: std.Thread.Mutex = .{};

var stderr_file = io.getStdErr();
var stderr: fs.File.Writer = undefined;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    stderr.print(format ++ "\n", args) catch unreachable;
    std.process.exit(1);
}

fn print(comptime format: []const u8, values: anytype) void {
    stdout_mutex.lock();
    defer stdout_mutex.unlock();

    stdout.print(format ++ "\n", values) catch unreachable;
}

pub fn main() anyerror!u8 {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        debug.panic("leaks detected", .{});
    };
    var allocator = gpa.allocator();

    stdout = stdout_file.writer();

    // Initialize the sqlite instance

    var db = try openDatabase(allocator);
    defer db.deinit();

    try initDatabase(&db);

    //

    var raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    debug.assert(raw_args.len > 0); // first argument is the process name
    var args = raw_args[1..];

    if (args.len < 1) {
        print(usage, .{});
        return 1;
    }

    const command = args[0];
    args = args[1..];

    const res = if (mem.eql(u8, "config", command))
        runConfig(allocator, &db, args)
    else if (mem.eql(u8, "scan", command))
        runScan(allocator, args);

    res catch |err| switch (err) {
        error.Explained => return 1,
        else => return err,
    };

    return 0;
}
