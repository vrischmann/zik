const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const os = std.os;
const time = std.time;

const audiometa = @import("audiometa");
const known_folders = @import("known-folders");
const mibu = @import("mibu");
const sqlite = @import("sqlite");

const MMapableFile = @import("mmappable_file.zig").MMapableFile;
const Query = @import("Query.zig");

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
++ mibu.style.print.bold ++ "Description" ++ mibu.style.print.reset ++
    \\
    \\
    \\  Scan the music library.
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

// TODO(vincent): fugly
const query_usage =
    mibu.color.print.fg(.yellow) ++ "Usage" ++ mibu.color.print.reset ++
    \\: zik query <query string>
    \\
    \\
++ mibu.style.print.bold ++ "Description" ++ mibu.style.print.reset ++
    \\
    \\
    \\  Query your music library using a simple query language.
    \\  The query language is composed of a set of key-operator-value pairs.
    \\  For example:
    \\
++ mibu.style.print.bold ++ fmt.comptimePrint("\n    genre{s}Metal year{s}2000\n", .{
    mibu.color.print.fg(.green) ++ "=" ++ mibu.color.print.reset,
    mibu.color.print.fg(.green) ++ ">" ++ mibu.color.print.reset,
}) ++ mibu.style.print.reset ++ mibu.style.print.bold ++ fmt.comptimePrint("    artist{s}Bloodywood\n", .{
    mibu.color.print.fg(.green) ++ "=~" ++ mibu.color.print.reset,
}) ++ mibu.style.print.reset ++
    \\
    \\  The available operators are:
    \\  - `=` for a case insensitive equality check
    \\  - `=~` for a case insensitive "contains" check
    \\  - `!=` for a case insensitive non-equality check
    \\
    \\  The available queryable keys are:
    \\  - `artist` and `album_artist`
    \\  - `album`
    \\  - `year`
    \\  - `genre`
    \\
;

fn cmdConfig(allocator: mem.Allocator, db: *sqlite.Db, args: []const []const u8) !void {
    if (args.len <= 0) {
        // Read all configuration values

        var diags = sqlite.Diagnostics{};
        var stmt = try db.prepareWithDiags(
            "SELECT key, value FROM config",
            .{ .diags = &diags },
        );
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
    } else if (args.len == 1) {
        // Read the configuration value for the key provided in the first argument

        const key = args[0];

        if (mem.eql(u8, "-h", key) or mem.eql(u8, "--help", key)) {
            print(query_usage, .{});
            return error.Explained;
        }

        const tag_opt = meta.stringToEnum(meta.Tag(Config), key);
        if (tag_opt == null) {
            print("no config named \"{s}\"", .{
                fmt.fmtSliceEscapeLower(key),
            });
            return error.Explained;
        }

        var diags = sqlite.Diagnostics{};
        const value_opt = db.oneAlloc(
            []const u8,
            allocator,
            "SELECT value FROM config WHERE key = $key",
            .{ .diags = &diags },
            .{ .key = key },
        ) catch |err| {
            print("unable to get config value, diagnostics: {s}, err: {!}\n", .{ diags, err });
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
    } else {
        // Set the configuration value (the second argument) for the key provided in the first argument

        const key = args[0];
        const value = args[1];

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
                var dir = try openLibraryPath(value);
                defer dir.close();

                const absolute_path = try dir.dir.realpathAlloc(allocator, ".");

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
}

const ArtistID = usize;
const AlbumID = usize;
const TrackID = usize;

const MyMetadata = struct {
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    year: ?[]const u8 = null,
    track_name: ?[]const u8 = null,
    track_number: usize = 0,
    genre: ?[]const u8 = null,

    pub const FromAudioMetaError = error{} || mem.Allocator.Error || fmt.ParseIntError;

    fn dupeOrNull(allocator: mem.Allocator, data_opt: ?[]const u8) mem.Allocator.Error!?[]const u8 {
        if (data_opt) |data| {
            return try allocator.dupe(u8, data);
        }
        return null;
    }

    fn parseID3v1TCON(tcon: []const u8) []const u8 {
        if (tcon.len < 3) return "";

        const cleaned = tcon[1 .. tcon.len - 1];
        const n = fmt.parseInt(usize, cleaned, 10) catch return "";

        if (n >= audiometa.id3v1.id3v1_genre_names.len) return "";

        return audiometa.id3v1.id3v1_genre_names[n];
    }

    fn fromAudiometa(allocator: mem.Allocator, md: audiometa.metadata.TypedMetadata) FromAudioMetaError!?MyMetadata {
        switch (md) {
            .flac => |*flac_meta| {
                return MyMetadata{
                    .artist = try dupeOrNull(allocator, flac_meta.map.getFirst("ARTIST")),
                    .album = try dupeOrNull(allocator, flac_meta.map.getFirst("ALBUM")),
                    .album_artist = try dupeOrNull(allocator, flac_meta.map.getFirst("ALBUMARTIST")),
                    .year = try dupeOrNull(allocator, flac_meta.map.getFirst("DATE")),
                    .track_name = try dupeOrNull(allocator, flac_meta.map.getFirst("TITLE")),
                    .track_number = if (flac_meta.map.getFirst("TRACKNUMBER")) |n|
                        try fmt.parseInt(usize, n, 10)
                    else
                        0,
                    .genre = null, // TODO(vincent): doesn't seem to exist for FLAC files ?
                };
            },
            .mp4 => |mp4_meta| {
                return MyMetadata{
                    .artist = try dupeOrNull(allocator, mp4_meta.map.getFirst("\xA9ART")),
                    .album = try dupeOrNull(allocator, mp4_meta.map.getFirst("\xA9alb")),
                    .album_artist = try dupeOrNull(allocator, mp4_meta.map.getFirst("aART")),
                    .year = try dupeOrNull(allocator, mp4_meta.map.getFirst("\xA9day")),
                    .track_name = try dupeOrNull(allocator, mp4_meta.map.getFirst("\xA9nam")),
                    .track_number = if (mp4_meta.map.getFirst("trkn")) |n|
                        try fmt.parseInt(usize, n, 10)
                    else if (mp4_meta.map.getFirst("disk")) |n|
                        try fmt.parseInt(usize, n, 10)
                    else
                        0,
                    .genre = try dupeOrNull(allocator, mp4_meta.map.getFirst("\xA9gen")),
                };
            },
            .id3v2 => |id3v2_meta| {
                return MyMetadata{
                    .artist = try dupeOrNull(allocator, id3v2_meta.metadata.map.getFirst("TPE1")),
                    .album = try dupeOrNull(allocator, id3v2_meta.metadata.map.getFirst("TALB")),
                    .album_artist = try dupeOrNull(allocator, id3v2_meta.metadata.map.getFirst("TPE2")),
                    .year = try dupeOrNull(allocator, id3v2_meta.metadata.map.getFirst("TYER")),
                    .track_name = try dupeOrNull(allocator, id3v2_meta.metadata.map.getFirst("TIT2")),
                    .track_number = if (id3v2_meta.metadata.map.getFirst("TRCK")) |n|
                        try fmt.parseInt(usize, n, 10)
                    else
                        0,
                    .genre = if (id3v2_meta.metadata.map.getFirst("TCON")) |tcon|
                        parseID3v1TCON(tcon)
                    else
                        null,
                };
            },
            else => return null,
        }
    }
};

const ExtractMetadataOptions = struct {
    use_mmap: bool = false,
};

const ExtractMetadataError = error{
    Explained,
} || time.Timer.Error || mem.Allocator.Error || MMapableFile.OpenError || os.SeekError ||
    sqlite.Savepoint.InitError ||
    SaveDataError ||
    MyMetadata.FromAudioMetaError;

fn extractMetadata(allocator: mem.Allocator, db: *sqlite.Db, entry: fs.IterableDir.Walker.WalkerEntry, options: ExtractMetadataOptions) ExtractMetadataError!void {
    print("file {s}", .{entry.path});

    var metadata = blk: {
        var mmappable_file = try MMapableFile.open(entry.dir, entry.basename, .{
            .use_mmap = options.use_mmap,
        });
        defer mmappable_file.close();

        var stream_source = mmappable_file.streamSource();

        var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
        defer metadata.deinit();

        for (metadata.tags) |tag| {
            if (try MyMetadata.fromAudiometa(allocator, tag)) |md| {
                break :blk md;
            }
        }

        break :blk null;
    };

    if (metadata == null) return;

    const md = metadata.?;

    //

    // Find the artist
    const artist = md.artist orelse "Unknown";
    const artist_id = try saveArtist(db, artist);

    // Find the album
    const album = md.album orelse "Unknown";
    const album_id = try saveAlbum(db, artist_id, album, md.year);

    // Save the track

    try saveTrack(db, artist_id, album_id, md);

    print("artist=\"{s}\" (id={d}), album=\"{s}\" (id={d}), album artist=\"{?s}\", year=\"{?s}\", track=\"{?s}\", track number={d}, genre=\"{?s}\"", .{
        artist,
        artist_id,
        album,
        album_id,
        md.album_artist,
        md.year,
        md.track_name,
        md.track_number,
        md.genre,
    });

    // TODO(vincent): use the collator when ready
    // var collator = audiometa.collate.Collator.init(allocator, &metadata);
    // defer collator.deinit();
    // const artists = try collator.artists();
    // print("artists: {s}", .{artists});
}

const ScanError = error{
    Explained,
} || mem.Allocator.Error || fs.File.OpenError || ExtractMetadataError;

const ScanOptions = struct {
    use_mmap: bool = false,
};

fn doScan(allocator: mem.Allocator, db: *sqlite.Db, path: []const u8, options: ScanOptions) ScanError!void {
    var dir = try openLibraryPath(path);
    defer dir.close();

    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var savepoint = try db.savepoint("save_file_metadata");
    defer savepoint.rollback();

    // We completely recreate the database later anyway so just delete everything.
    var diags = sqlite.Diagnostics{};
    db.exec("DELETE FROM artist", .{ .diags = &diags }, .{}) catch {
        print("can't truncate artist table, err: {}", .{diags});
        return error.Explained;
    };

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .File, .SymLink => {
                var per_file_arena = heap.ArenaAllocator.init(allocator);
                defer per_file_arena.deinit();

                var extract_options = ExtractMetadataOptions{
                    .use_mmap = options.use_mmap,
                };

                try extractMetadata(per_file_arena.allocator(), db, entry, extract_options);
            },
            else => continue,
        }
    }

    savepoint.commit();
}

fn cmdScan(allocator: mem.Allocator, db: *sqlite.Db, args: []const []const u8) !void {
    // Parse the arguments and options

    var options = ScanOptions{};
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg)) {
                print(scan_usage, .{});
                return error.Explained;
            } else if (mem.eql(u8, "--use-mmap", arg)) {
                options.use_mmap = true;
                i += 1;
            }
        }
    }

    const config_opt = try getConfig(.library, allocator, db);
    if (config_opt) |config| {
        defer config.deinit(allocator);

        debug.assert(meta.activeTag(config) == .library);

        doScan(allocator, db, config.library, options) catch |err| switch (err) {
            error.Explained => return err,
            else => return err, // TODO(vincent): error handling
        };
    } else {
        print("no library configured", .{});
        return error.Explained;
    }
}

fn cmdQuery(root_allocator: mem.Allocator, db: *sqlite.Db, args: []const []const u8) !void {
    _ = db;

    var arena = heap.ArenaAllocator.init(root_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (args.len < 1) {
        print(query_usage, .{});
        return error.Explained;
    }

    var query_string: []const u8 = undefined;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg)) {
                print(query_usage, .{});
                return error.Explained;
            }
            query_string = arg;
            break;
        }
    }

    var diags = Query.ParseDiagnostics{};
    var query = try Query.parse(allocator, &diags, query_string);

    debug.print("query: {s}\n", .{query.ops});
}

fn openLibraryPath(path: []const u8) !fs.IterableDir {
    return fs.cwd().openIterableDir(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            print("path \"{s}\" doesn't exist", .{path});
            return error.Explained;
        },
        error.NotDir => {
            print("path \"{s}\" is not a directory", .{path});
            return error.Explained;
        },
        error.AccessDenied => {
            print("path \"{s}\" is not accessible", .{path});
            return error.Explained;
        },
        else => fatal("unable to open library \"{s}\", err: {!}", .{ path, err }),
    };
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

fn getConfig(comptime Tag: meta.Tag(Config), allocator: mem.Allocator, db: *sqlite.Db) !?Config {
    const Payload = meta.TagPayload(Config, Tag);
    const key = meta.tagName(Tag);

    var diags = sqlite.Diagnostics{};

    const value = try db.oneAlloc(
        Payload,
        allocator,
        "SELECT value FROM config WHERE key = $key{[]const u8}",
        .{ .diags = &diags },
        .{ .key = key },
    );
    if (value == null) {
        print("no value for config `{s}`", .{key});
        return error.Explained;
    }

    return @unionInit(Config, @tagName(Tag), value.?);
}

fn setConfig(allocator: mem.Allocator, db: *sqlite.Db, config: Config) !void {
    const key = meta.tagName(meta.activeTag(config));

    var diags = sqlite.Diagnostics{};
    db.execAlloc(
        allocator,
        \\INSERT INTO config(key, value) VALUES($key{[]const u8}, $value)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ,
        .{ .diags = &diags },
        .{
            .key = key,
            .value = config,
        },
    ) catch |err| {
        print("unable to set config `{s}`, err: {s}", .{ key, diags });
        return err;
    };
}

const SaveDataError = error{
    Workaround,
    Explained,
} || sqlite.Error;

fn saveArtist(db: *sqlite.Db, name: []const u8) SaveDataError!usize {
    var diags = sqlite.Diagnostics{};

    const id_opt = db.one(
        usize,
        "SELECT id FROM artist WHERE name = $name{[]const u8}",
        .{ .diags = &diags },
        .{ .name = name },
    ) catch {
        print("unable to get artist ID for name \"{s}\", err: {s}", .{ name, diags });
        return error.Explained;
    };
    if (id_opt) |id| return id;

    db.exec(
        "INSERT INTO artist(name) VALUES($name{[]const u8})",
        .{ .diags = &diags },
        .{ .name = name },
    ) catch {
        print("unable to insert artist \"{s}\", err: {s}", .{ name, diags });
        return error.Explained;
    };

    return @intCast(usize, db.getLastInsertRowID());
}

fn saveAlbum(db: *sqlite.Db, artist_id: usize, name: []const u8, year: ?[]const u8) SaveDataError!AlbumID {
    var diags = sqlite.Diagnostics{};

    const id_opt = db.one(
        usize,
        "SELECT id FROM album WHERE artist_id = $artist_id{usize} AND name = $name{[]const u8}",
        .{ .diags = &diags },
        .{
            .artist_id = artist_id,
            .name = name,
        },
    ) catch {
        print("unable to get album ID for name \"{s}\" and artist ID {d}, err: {s}", .{ name, artist_id, diags });
        return error.Explained;
    };
    if (id_opt) |id| return id;

    db.exec(
        \\INSERT INTO album(artist_id, name, year)
        \\VALUES($artist_id{usize}, $name{[]const u8}, $year{?[]const u8})
    ,
        .{ .diags = &diags },
        .{
            .artist_id = artist_id,
            .name = name,
            .year = year,
        },
    ) catch {
        print("unable to insert album \"{s}\" and artist ID {d}, err: {s}", .{ name, artist_id, diags });
        return error.Explained;
    };

    return @intCast(usize, db.getLastInsertRowID());
}

fn saveTrack(db: *sqlite.Db, artist_id: ArtistID, album_id: AlbumID, metadata: MyMetadata) SaveDataError!void {
    var diags = sqlite.Diagnostics{};

    db.exec(
        \\INSERT INTO track(name, artist_id, album_id, year, number)
        \\VALUES(
        \\  $name{?[]const u8},
        \\  $artist_id{usize},
        \\  $album_id{usize},
        \\  $year{?[]const u8},
        \\  $number{usize}
        \\)
        \\ON CONFLICT(name)
        \\DO UPDATE SET
        \\  name = excluded.name,
        \\  artist_id = excluded.artist_id,
        \\  album_id = excluded.album_id,
        \\  year = excluded.year,
        \\  number = excluded.number
    ,
        .{ .diags = &diags },
        .{
            .name = metadata.track_name,
            .artist_id = artist_id,
            .album_id = album_id,
            .year = metadata.year,
            .number = metadata.track_number,
        },
    ) catch {
        print("unable to insert track \"{?s}\" (artist_id={d}, album_id={d}, track number={d}), err: {s}", .{
            metadata.track_name,
            artist_id,
            album_id,
            metadata.track_number,
            diags,
        });
        return error.Explained;
    };
}

const OpenDatabaseError = error{
    Explained,
} || mem.Allocator.Error || os.MakeDirError || sqlite.Db.InitError || known_folders.Error;

fn openDatabase(allocator: mem.Allocator) OpenDatabaseError!sqlite.Db {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const data_directory_opt = try known_folders.getPath(arena.allocator(), .data);
    if (data_directory_opt == null) {
        print("can't find user data directory", .{});
        return error.Explained;
    }

    // Create the zik data directory

    var zik_directory = try fs.path.join(arena.allocator(), &.{
        data_directory_opt.?, "zik",
    });
    fs.makeDirAbsolute(zik_directory) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.AccessDenied => {
            print("can't create directory \"{s}\", permission denied", .{zik_directory});
            return error.Explained;
        },
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
        \\CREATE INDEX IF NOT EXISTS artist_name ON artist(name)
        ,
        \\CREATE TABLE IF NOT EXISTS album(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT,
        \\  artist_id INTEGER,
        \\  album_artist_id INTEGER,
        \\  year TEXT,
        \\
        \\  FOREIGN KEY(artist_id) REFERENCES artist(id) ON DELETE CASCADE
        \\) STRICT
        ,
        \\CREATE INDEX IF NOT EXISTS album_name ON album(name)
        ,
        \\CREATE TABLE IF NOT EXISTS track(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT UNIQUE,
        \\  artist_id INTEGER,
        \\  album_id INTEGER,
        \\  year TEXT,
        \\  number INTEGER,
        \\
        \\  FOREIGN KEY(artist_id) REFERENCES artist(id) ON DELETE CASCADE,
        \\  FOREIGN KEY(album_id) REFERENCES album(id) ON DELETE CASCADE
        \\) STRICT
    };

    var savepoint = try db.savepoint("DDL");
    defer savepoint.rollback();

    inline for (ddls) |ddl| {
        var diags = sqlite.Diagnostics{};
        db.exec(ddl, .{ .diags = &diags }, .{}) catch |err| {
            print("unable to execute statement, err: {s}", .{diags});
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

    var db = openDatabase(allocator) catch |err| switch (err) {
        error.Explained => return 1,
        else => return err,
    };
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
        cmdConfig(allocator, &db, args)
    else if (mem.eql(u8, "scan", command))
        cmdScan(allocator, &db, args)
    else if (mem.eql(u8, "query", command))
        cmdQuery(allocator, &db, args)
    else {
        print(usage, .{});
        return 0;
    };

    res catch |err| switch (err) {
        error.Explained => return 1,
        else => return err,
    };

    return 0;
}

test {
    _ = Query;

    std.testing.refAllDecls(@This());
}
