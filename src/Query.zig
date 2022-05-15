const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

const mecha = @import("mecha");

const Self = @This();

pub const Key = enum {
    artist,
    album,
    album_artist,
    year,
    track,
    track_number,
    genre,
};

pub const ComparisonOperator = enum {
    equal,
    not_equal,
    contains,
};

const Op = struct {
    key: Key,
    operator: ComparisonOperator,
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
    _ = diags;

    const result = try parser.query(allocator, query_str);
    defer allocator.free(result.value);

    var ops = try allocator.alloc(Op, result.value.len);
    errdefer allocator.free(ops);

    for (ops) |*op, i| {
        const res = result.value[i];

        op.* = .{
            .key = res.key,
            .operator = res.operator,
            .value = res.value,
        };
    }

    return Self{
        .allocator = allocator,
        .ops = ops,
    };
}

pub fn deinit(self: *const Self) void {
    // for (self.ops) |*op| {
    //     self.allocator.free(op.value);
    // }
    self.allocator.free(self.ops);
}

const parser = struct {
    const key = mecha.enumeration(Key);

    const cmp_op = mecha.oneOf(.{
        mecha.map(ComparisonOperator, genCmpOp(.not_equal), mecha.string("!=")),
        mecha.map(ComparisonOperator, genCmpOp(.contains), mecha.string("=~")),
        mecha.map(ComparisonOperator, genCmpOp(.equal), mecha.string("=")),
    });

    const escape = mecha.oneOf(.{
        mecha.ascii.char('"'),
        mecha.ascii.char('\\'),
    });

    const value_string = mecha.many(
        mecha.oneOf(.{
            mecha.discard(mecha.utf8.range(0x0021, '"' - 1)),
            mecha.discard(mecha.utf8.range('"' + 1, '\\' - 1)),
            mecha.discard(mecha.utf8.range('\\' + 1, 0x10FFFF)),
        }),
        .{ .min = 1, .collect = false },
    );
    const escaped_value_string = mecha.combine(.{
        mecha.ascii.char('"'),
        mecha.many(
            mecha.oneOf(.{
                mecha.discard(mecha.utf8.range(0x0020, '"' - 1)),
                mecha.discard(mecha.utf8.range('"' + 1, '\\' - 1)),
                mecha.discard(mecha.utf8.range('\\' + 1, 0x10FFFF)),
                mecha.combine(.{ mecha.ascii.char('\\'), escape }),
            }),
            .{ .min = 1, .collect = false },
        ),
        mecha.ascii.char('"'),
    });

    const value = mecha.oneOf(.{
        escaped_value_string,
        value_string,
    });

    const op_parser = mecha.map(Op, mecha.toStruct(Op), mecha.combine(.{
        key,
        cmp_op,
        value,
    }));

    fn genCmpOp(comptime op: ComparisonOperator) fn (void) ComparisonOperator {
        return struct {
            fn func(_: void) ComparisonOperator {
                return op;
            }
        }.func;
    }

    const query = mecha.many(
        mecha.combine(.{
            op_parser,
            mecha.discard(mecha.many(mecha.ascii.space, .{ .collect = false })),
        }),
        .{ .min = 1 },
    );
};

test "query parse" {
    const testCases = &[_]struct {
        query: []const u8,
        exp: []const Op,
    }{
        .{
            .query = "artist=Vincent album=José",
            .exp = &[_]Op{
                .{
                    .key = .artist,
                    .operator = .equal,
                    .value = "Vincent",
                },
                .{
                    .key = .album,
                    .operator = .equal,
                    .value = "José",
                },
            },
        },
        .{
            .query = "artist=~\"   José  \" album!=\"   Vincent   \"         track=204",
            .exp = &[_]Op{
                .{
                    .key = .artist,
                    .operator = .contains,
                    .value = "   José  ",
                },
                .{
                    .key = .album,
                    .operator = .not_equal,
                    .value = "   Vincent   ",
                },
                .{
                    .key = .track,
                    .operator = .equal,
                    .value = "204",
                },
            },
        },
    };

    inline for (testCases) |tc| {
        var parse_diags = ParseDiagnostics{};
        const res = try parse(testing.allocator, &parse_diags, tc.query);
        defer res.deinit();

        try testing.expectEqual(@as(usize, tc.exp.len), res.ops.len);

        for (tc.exp) |exp, i| {
            try testing.expectEqual(exp.key, res.ops[i].key);
            try testing.expectEqual(exp.operator, res.ops[i].operator);
            try testing.expectEqualStrings(exp.value, res.ops[i].value);
        }
    }
}
