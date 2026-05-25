const std = @import("std");

pub fn Dialect(
    comptime placeholderFn: fn (usize, []u8) []const u8,
    comptime has_returning: bool,
    comptime has_native_bools: bool,
) type {
    return struct {
        pub fn placeholder(index: usize, buf: []u8) []const u8 {
            return placeholderFn(index, buf);
        }
        pub const supports_returning = has_returning;
        pub const native_bools = has_native_bools;
    };
}

fn sqlitePlaceholder(_: usize, _: []u8) []const u8 {
    return "?";
}
fn postgresPlaceholder(index: usize, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "${d}", .{index + 1}) catch unreachable;
}

/// SQLite: positional `?`, no `RETURNING`, no native bools.
pub const SQLite = Dialect(sqlitePlaceholder, false, false);

/// PostgreSQL: indexed `$1 $2 ...`, `RETURNING`, native bools.
pub const Postgres = Dialect(postgresPlaceholder, true, true);
