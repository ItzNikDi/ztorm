const std = @import("std");
const driver = @import("driver.zig");
const PrimaryKey = @import("model.zig").PrimaryKey;

const testing = std.testing;

/// Errors that can occur when mapping a Row into a typed struct.
pub const MappingError = error{
    /// A column value's runtime type did not match the expected Zig field type.
    /// This usually means the SELECT column order doesn't match the struct's
    /// field declaration order, or the schema and struct have drifted apart.
    TypeMismatch,
};

/// Maps a single Row into a value of type T.
///
/// Field order in T must match the column order returned by the query -
/// this is guaranteed when using `sql.Sql`-generated SELECT statements.
pub fn mapRow(comptime T: type, row: driver.Row) MappingError!T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;

    inline for (info.fields, 0..) |field, i| {
        const col = row.getColumn(i);
        @field(result, field.name) = try coerce(field.type, col);
    }

    return result;
}

/// Coerces a `ColumnValue` into the expected Zig type.
///
/// Will emit a compile error for unsupported field types.
fn coerce(comptime T: type, value: driver.ColumnValue) MappingError!T {
    return switch (T) {
        i8, i16, i32, i64, u8, u16, u32, u64 => switch (value) {
            .int => |v| @intCast(v),
            .bool => |v| if (v) 1 else 0,
            else => MappingError.TypeMismatch,
        },

        f32, f64 => switch (value) {
            .float => |v| @floatCast(v),
            .int => |v| @floatFromInt(v),
            else => MappingError.TypeMismatch,
        },

        bool => switch (value) {
            .bool => |v| v,
            .int => |v| v != 0, // SQLite stores bools as 0/1
            else => MappingError.TypeMismatch,
        },

        []const u8 => switch (value) {
            .text => |v| v,
            .blob => |v| v,
            else => MappingError.TypeMismatch,
        },

        []u8 => switch (value) {
            .text => |v| @constCast(v),
            .blob => |v| @constCast(v),
            else => MappingError.TypeMismatch,
        },

        else => {
            // optionals (?T) handling
            const type_info = @typeInfo(T);
            if (type_info == .optional) {
                if (value == .null) return null;
                return try coerce(type_info.optional.child, value);
            }
            @compileError("coercion error - unsupported field type: " ++ @typeName(T));
        },
    };
}

test "mapRow maps integer and text fields" {
    const User = struct {
        id: i64,
        name: []const u8,
    };

    //fake Row backed by known values
    const cols = [_]driver.ColumnValue{
        .{ .int = 42 },
        .{ .text = "ztorm2" },
    };

    const FakeRow = struct {
        fn getCol(ctx: *anyopaque, index: usize) driver.ColumnValue {
            const c: *const [2]driver.ColumnValue = @ptrCast(@alignCast(ctx));
            return c[index];
        }
        fn colCount(_: *anyopaque) usize {
            return 2;
        }
    };

    var cols_copy = cols;
    const row = driver.Row{
        .getColumnFn = FakeRow.getCol,
        .columnCountFn = FakeRow.colCount,
        .ctx = &cols_copy,
    };

    const user = try mapRow(User, row);
    try testing.expect(user.id == 42);
    try testing.expectEqualStrings("ztorm", user.name);
}

test "mapRow handles optional null" {
    const Row = struct {
        id: i64,
        email: ?[]const u8,
    };

    const cols = [_]driver.ColumnValue{
        .{ .int = 1 },
        .null,
    };

    const FakeRow = struct {
        fn getCol(ctx: *anyopaque, index: usize) driver.ColumnValue {
            const c: *const [2]driver.ColumnValue = @ptrCast(@alignCast(ctx));
            return c[index];
        }
        fn colCount(_: *anyopaque) usize {
            return 2;
        }
    };

    var cols_copy = cols;
    const row = driver.Row{
        .getColumnFn = FakeRow.getCol,
        .columnCountFn = FakeRow.colCount,
        .ctx = &cols_copy,
    };

    const result = try mapRow(Row, row);
    try testing.expect(result.id == 1);
    try testing.expect(result.email == null);
}
