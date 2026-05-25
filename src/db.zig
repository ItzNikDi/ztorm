const std = @import("std");
const driver_mod = @import("driver.zig");
const Driver = driver_mod.Driver;
const mapping = @import("mapping.zig");
const model = @import("model.zig");
const sql = @import("sql.zig");

const Allocator = std.mem.Allocator;

/// The main database handle. Create one of these at startup
/// and pass it around for the lifetime of the application.
///
/// D is a `Dialect` type (`dialect.SQLite`, `dialect.Postgres`, etc.)
///
/// The driver carries its own allocator - see `driver.zig`.
pub fn DB(comptime D: type) type {
    return struct {
        const Self = @This();

        driver: Driver,

        pub fn init(driver: Driver) Self {
            return .{ .driver = driver };
        }

        pub fn close(self: Self) void {
            self.driver.close();
        }

        // -- Queries --

        /// Fetches all rows from the model's table.
        ///
        /// Caller owns the returned slice — free with `allocator.free()`.
        pub fn findAll(
            self: Self,
            comptime M: type,
            allocator: Allocator,
        ) ![]M.Schema {
            const S = sql.Sql(M, D);
            var rows = try self.driver.query(S.select_all, &.{});
            defer rows.close();

            var list: std.ArrayList(M.Schema) = .empty;
            errdefer list.deinit(allocator);

            while (try rows.next()) |row| {
                try list.append(allocator, try mapping.mapRow(M.Schema, row));
            }

            return try list.toOwnedSlice(allocator);
        }

        /// Fetches a single row by primary key.
        /// Returns null if no row matched.
        pub fn findById(
            self: Self,
            comptime M: type,
            id: anytype,
        ) !?M.Schema {
            const S = sql.Sql(M, D);
            const param = paramFromValue(id);
            var rows = try self.driver.query(S.select_by_id, &.{param});
            defer rows.close();

            const row = try rows.next() orelse return null;
            return try mapping.mapRow(M.Schema, row);

            //_ = allocator; reserved for future use
        }

        // -- Mutations --

        /// Inserts a new row. For `auto` primary key models, `id` is ignored.
        pub fn insert(
            self: Self,
            comptime M: type,
            allocator: Allocator,
            value: M.Schema,
        ) !void {
            const S = sql.Sql(M, D);
            const params = try buildInsertParams(M, allocator, value);
            defer allocator.free(params);
            try self.driver.execute(S.insert, params);
        }

        /// Updates an existing row matched by primary key.
        pub fn update(
            self: Self,
            comptime M: type,
            allocator: Allocator,
            value: M.Schema,
        ) !void {
            const S = sql.Sql(M, D);
            const params = try buildUpdateParams(M, allocator, value);
            defer allocator.free(params);
            try self.driver.execute(S.update, params);
        }

        /// Deletes a row by primary key.
        pub fn deleteById(
            self: Self,
            comptime M: type,
            id: anytype,
        ) !void {
            const S = sql.Sql(M, D);
            const param = paramFromValue(id);
            try self.driver.execute(S.delete_by_id, &.{param});
        }

        // -- Raw escape hatch --

        /// Executes a raw SQL string with no result mapping.
        /// Use for DDL, migrations, or anything ztorm can't express yet.
        ///
        /// WARNING: never interpolate user-supplied input into `s` directly.
        ///
        /// Use the `params` slice for all user-supplied values - they are
        /// bound via prepared statements and are safe from SQL injection.
        pub fn exec(
            self: Self,
            s: []const u8,
            params: []const driver_mod.Param,
        ) !void {
            try self.driver.execute(s, params);
        }

        /// Executes a raw SQL query and returns unmapped Rows.
        /// Caller must call rows.close() when done.
        ///
        /// WARNING: never interpolate user-supplied input into `s` directly.
        ///
        /// Use the `params` slice for all user-supplied values - they are
        /// bound via prepared statements and are safe from SQL injection.
        pub fn rawQuery(
            self: Self,
            s: []const u8,
            params: []const driver_mod.Param,
        ) !driver_mod.Rows {
            return self.driver.query(s, params);
        }
    };
}

// -- Helpers --

/// Converts a Zig value to a driver.Param.
/// Supports the same types as ColumnValue.
fn paramFromValue(value: anytype) driver_mod.Param {
    return switch (@TypeOf(value)) {
        i8, i16, i32, i64, u8, u16, u32, u64 => .{ .int = @intCast(value) },
        f32, f64 => .{ .float = @floatCast(value) },
        bool => .{ .bool = value },
        []const u8 => .{ .text = value },
        []u8 => .{ .text = value },
        comptime_int => .{ .int = @as(i64, value) },
        comptime_float => .{ .float = @as(f64, value) },
        else => @compileError("paramFromValue - unsupported param type: " ++ @typeName(@TypeOf(value))),
    };
}

/// Builds the `param` slice for an INSERT statement.
///
/// Skips `id` when `M.primary_key` is `.auto`.
fn buildInsertParams(
    comptime M: type,
    allocator: std.mem.Allocator,
    value: M.Schema,
) ![]driver_mod.Param {
    const fields = @typeInfo(M.Schema).@"struct".fields;

    // Count how many params we'll actually emit
    comptime var count: usize = 0;
    comptime {
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, "id") and M.primary_key == .auto) continue;
            count += 1;
        }
    }

    var params = try allocator.alloc(driver_mod.Param, count);
    var index: usize = 0;

    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "id") and M.primary_key == .auto) continue;
        params[index] = paramFromValue(@field(value, field.name));
        index += 1;
    }

    return params;
}

/// Builds the param slice for an UPDATE statement.
/// Non-id fields come first and id is appended last to match the WHERE clause.
fn buildUpdateParams(
    comptime M: type,
    allocator: std.mem.Allocator,
    value: M.Schema,
) ![]driver_mod.Param {
    const fields = @typeInfo(M.Schema).@"struct".fields;
    var params = try allocator.alloc(driver_mod.Param, fields.len);
    var index: usize = 0;

    // SET fields first, excluding id
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "id")) continue;
        params[index] = paramFromValue(@field(value, field.name));
        index += 1;
    }

    // id goes last - matches WHERE id = `placeholder` position in sql.zig
    params[index] = paramFromValue(@field(value, "id"));

    return params;
}
