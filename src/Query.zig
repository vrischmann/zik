const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
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
    greater_than,
    greater_than_or_equal,
    less_than,
    less_than_or_equal,

    pub fn format(value: ComparisonOperator, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (value) {
            .equal => try writer.writeAll("="),
            .not_equal => try writer.writeAll("!="),
            .contains => try writer.writeAll("=~"),
            .greater_than => try writer.writeAll(">"),
            .greater_than_or_equal => try writer.writeAll(">="),
            .less_than => try writer.writeAll("<"),
            .less_than_or_equal => try writer.writeAll("<="),
        }
    }
};

const Op = struct {
    key: Key,
    operator: ComparisonOperator,
    value: []const u8,

    pub fn format(value: Op, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}{s}{s}", .{
            @tagName(value.key),
            value.operator,
            fmtSliceQuote(value.value),
        });
    }
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
        mecha.map(ComparisonOperator, genCmpOp(.greater_than_or_equal), mecha.string(">=")),
        mecha.map(ComparisonOperator, genCmpOp(.less_than_or_equal), mecha.string("<=")),
        mecha.map(ComparisonOperator, genCmpOp(.greater_than), mecha.string(">")),
        mecha.map(ComparisonOperator, genCmpOp(.less_than), mecha.string("<")),
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
            .query = 
            \\artist=~"   José  " album!="   Vincent   "         track=204
            ,
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
        .{
            .query = "year>2000 track_number<=20",
            .exp = &[_]Op{
                .{
                    .key = .year,
                    .operator = .greater_than,
                    .value = "2000",
                },
                .{
                    .key = .track_number,
                    .operator = .less_than_or_equal,
                    .value = "20",
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

//
fn fmtSliceQuote(slice: []const u8) fmt.Formatter(formatSliceQuote) {
    return .{ .data = slice };
}

fn formatSliceQuote(slice: []const u8, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    const charset = "0123456789abcdef";

    var buf: [4]u8 = undefined;

    for (slice) |c| {
        if (c == '\\' or c == '"') {
            buf[0] = '\\';
            buf[1] = c;
            try writer.writeAll(buf[0..2]);
        } else if (std.ascii.isPrint(c) or std.ascii.isAlNum(c) or std.ascii.isPunct(c)) {
            try writer.writeByte(c);
        } else {
            buf[0] = '\\';
            buf[1] = 'x';

            buf[2] = charset[c >> 4];
            buf[3] = charset[c & 15];

            try writer.writeAll(&buf);
        }
    }
}

test "fmtQuote" {
    const testCases = &[_]struct {
        input: []const u8,
        exp: []const u8,
    }{
        .{
            .input = "Foobar",
            .exp = "Foobar",
        },
        .{
            // TODO(vincent): would be better using multiline strings but zig.vim
            // always reposition the cursor to it and it's super annoying.
            .input = 
            \\The Wreck of "S.S." Needle
            ,
            .exp = 
            \\The Wreck of \"S.S.\" Needle
            ,
        },
    };

    inline for (testCases) |tc| {
        var list = std.ArrayList(u8).init(testing.allocator);

        try list.writer().print("{s}", .{fmtSliceQuote(tc.input)});

        const result = list.toOwnedSlice();
        defer testing.allocator.free(result);

        try testing.expectEqualStrings(tc.exp, result);
    }
}
