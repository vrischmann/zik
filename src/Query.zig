const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

const Self = @This();

pub const Key = enum {
    artist,
    album_artist,
    album,
    year,
    genre,
};

pub const Operation = enum {
    equal,
    not_equal,
    contains,
};

const Op = struct {
    key: Key,
    operation: Operation,
    value: []const u8,
};

allocator: mem.Allocator,
ops: []const Op,

pub const ParseError = error{} || mem.Allocator.Error;

pub const ParseDiagnostics = struct {
    message: ?[]const u8 = null,
    pos: ?usize = null,
};

pub fn parse(allocator: mem.Allocator, diags: *ParseDiagnostics, query_str: []const u8) !Self {
    var ops = try std.ArrayList(Op).initCapacity(allocator, 4);
    errdefer ops.deinit();

    // Parsing state
    var state: enum {
        key_start,
        operation_start,
        value_start,
    } = .key_start;

    var scratch = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer scratch.deinit();

    var current_key: Key = undefined;
    var current_operation: Operation = undefined;

    for (query_str) |ch, i| {
        switch (state) {
            .key_start => switch (ch) {
                'a'...'z' => try scratch.append(ch),
                '=', '!' => {
                    current_key = meta.stringToEnum(Key, scratch.items) orelse return error.InvalidQueryKey;
                    scratch.clearRetainingCapacity();

                    try scratch.append(ch);
                    state = .operation_start;
                },
                else => {
                    diags.message = "invalid character in key";
                    diags.pos = i;
                    return error.InvalidQueryKey;
                },
            },
            .operation_start => {
                if (ch == '~' or ch == '=') {
                    try scratch.append(ch);
                }

                current_operation = if (mem.eql(u8, "=~", scratch.items))
                    Operation.contains
                else if (mem.eql(u8, "!=", scratch.items))
                    Operation.not_equal
                else if (mem.eql(u8, "=", scratch.items))
                    Operation.equal
                else
                    return error.InvalidQueryOperation;

                scratch.clearRetainingCapacity();
                try scratch.append(ch);

                state = .value_start;
            },
            .value_start => switch (ch) {
                ' ' => {
                    try ops.append(.{
                        .key = current_key,
                        .operation = current_operation,
                        .value = blk: {
                            const value = scratch.toOwnedSlice();
                            errdefer allocator.free(value);
                            scratch.clearRetainingCapacity();

                            break :blk value;
                        },
                    });

                    current_key = undefined;
                    current_operation = undefined;

                    state = .key_start;
                },
                else => try scratch.append(ch),
            },
        }
    }

    try ops.append(.{
        .key = current_key,
        .operation = current_operation,
        .value = blk: {
            const value = scratch.toOwnedSlice();
            errdefer allocator.free(value);
            scratch.clearRetainingCapacity();

            break :blk value;
        },
    });

    return Self{
        .allocator = allocator,
        .ops = ops.toOwnedSlice(),
    };
}

pub fn deinit(self: *const Self) void {
    for (self.ops) |*op| {
        self.allocator.free(op.value);
    }
    self.allocator.free(self.ops);
}

test "query parse" {
    const testCases = &[_]struct {
        query: []const u8,
        exp: []const Op,
    }{
        .{
            .query = "artist=Vincent",
            .exp = &[_]Op{
                .{
                    .key = .artist,
                    .operation = .equal,
                    .value = "Vincent",
                },
            },
        },
    };

    inline for (testCases) |tc| {
        var parse_diags = ParseDiagnostics{};
        const res = try parse(testing.allocator, &parse_diags, tc.query);
        defer res.deinit();

        try testing.expectEqual(@as(usize, 1), res.ops.len);
        try testing.expectEqual(Key.artist, res.ops[0].key);
        try testing.expectEqual(Operation.equal, res.ops[0].operation);
        try testing.expectEqualStrings("Vincent", res.ops[0].value);
    }
}
