const std = @import("std");
const dialect = @import("dialect.zig");
const Dialect = dialect.Dialect;
const driver = @import("driver.zig");
const model = @import("model.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const AllocatorError = Allocator.Error;

/// All comptime-generated SQL for a given `Model` + `Dialect` pair.
pub fn Sql(comptime M: type, comptime D: type) type {
    return struct {
        /// Generates: SELECT `fields` FROM `table`
        ///
        /// Fields are derived from the model struct in declaration order.
        pub const select_all = blk: {
            var sql: []const u8 = "SELECT ";
            for (M.fields, 0..) |field, i| {
                sql = sql ++ field.name;
                if (i < M.fields.len - 1) sql = sql ++ ", ";
            }
            sql = sql ++ " FROM " ++ M.table_name;
            break :blk sql;
        };

        /// Generates: SELECT `fields` FROM `table` WHERE id = `<placeholder>`
        ///
        /// Requires `M.primary_key != .none` and will emit a compile error otherwise.
        pub const select_by_id = blk: {
            if (M.primary_key == .none)
                @compileError(M.table_name ++ " has no primary key, cannot generate SELECT by id");
            var buf: [16]u8 = undefined;
            const ph = D.placeholder(0, &buf);
            break :blk select_all ++ " WHERE id = " ++ ph;
        };

        /// Generates: INSERT INTO `table (fields)` VALUES `(placeholders)`
        ///
        /// If `M.primary_key` is `.auto`, the `id` field is skipped (DB generates it).
        ///
        /// If `M.primary_key` is `.manual`, all fields including `id` are included.
        ///
        /// If `M.primary_key` is `.none`, all fields are included.
        pub const insert = blk: {
            var cols: []const u8 = "";
            var vals: []const u8 = "";
            var index: usize = 0;
            for (M.fields) |field| {
                // skip `id` only if the DB generates it
                if (std.mem.eql(u8, field.name, "id") and M.primary_key == .auto) continue;
                if (index > 0) {
                    cols = cols ++ ", ";
                    vals = vals ++ ", ";
                }
                var buf: [16]u8 = undefined;
                const ph = D.placeholder(index, &buf);
                cols = cols ++ field.name;
                vals = vals ++ ph;
                index += 1;
            }
            break :blk "INSERT INTO " ++ M.table_name ++
                " (" ++ cols ++ ") VALUES (" ++ vals ++ ")";
        };

        /// Generates: UPDATE `table` SET `field` = `placeholder`, ... WHERE id = `placeholder`
        ///
        /// Requires `M.primary_key` to NOT be `.none` and will emit a compile error otherwise.
        ///
        /// Non-id fields are bound first (indices 0..n-1), id is bound last (index n).
        pub const update = blk: {
            if (M.primary_key == .none)
                @compileError(M.table_name ++ " has no primary key, cannot generate UPDATE by id");
            var sets: []const u8 = "";
            var index: usize = 0;
            for (M.fields) |field| {
                if (std.mem.eql(u8, field.name, "id")) continue;
                if (index > 0) sets = sets ++ ", ";
                var buf: [16]u8 = undefined;
                const ph = D.placeholder(index, &buf);
                sets = sets ++ field.name ++ " = " ++ ph;
                index += 1;
            }
            // id placeholder comes after all SET params
            var id_buf: [16]u8 = undefined;
            const id_ph = D.placeholder(index, &id_buf);
            break :blk "UPDATE " ++ M.table_name ++
                " SET " ++ sets ++
                " WHERE id = " ++ id_ph;
        };

        /// Generates: DELETE FROM `table` WHERE id = `placeholder`
        ///
        /// Requires `M.primary_key` to NOT be `.none` and will emit a compile error otherwise.
        pub const delete_by_id = blk: {
            if (M.primary_key == .none)
                @compileError(M.table_name ++ " has no primary key, cannot generate DELETE by id");
            var buf: [16]u8 = undefined;
            const ph = D.placeholder(0, &buf);
            break :blk "DELETE FROM " ++ M.table_name ++ " WHERE id = " ++ ph;
        };
    };
}

pub const WhereClause = struct {
    sql: []const u8, // driver owns this one
    params: []driver.Param, // and this one also
    allocator: Allocator,

    pub fn deinit(self: WhereClause) void {
        self.allocator.free(self.sql);
        self.allocator.free(self.params);
    }
};

test "select_all generates correct SQL" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
        email: []const u8,
    };
    const M = model.Model(User);
    const S = Sql(M, dialect.SQLite);
    try testing.expectEqualStrings(
        "SELECT id, name, email FROM users",
        S.select_all,
    );
}

test "insert skips id field" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
        email: []const u8,
    };
    const M = model.Model(User);
    const S = Sql(M, dialect.SQLite);
    try testing.expectEqualStrings(
        "INSERT INTO users (name, email) VALUES (?, ?)",
        S.insert,
    );
}

test "update places id placeholder last" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
        email: []const u8,
    };
    const M = model.Model(User);
    const S = Sql(M, dialect.SQLite);
    try testing.expectEqualStrings(
        "UPDATE users SET name = ?, email = ? WHERE id = ?",
        S.update,
    );
}

test "postgres uses indexed placeholders" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
        email: []const u8,
    };
    const M = model.Model(User);
    const S = Sql(M, dialect.Postgres);
    try testing.expectEqualStrings(
        "INSERT INTO users (name, email) VALUES ($1, $2)",
        S.insert,
    );
    try testing.expectEqualStrings(
        "UPDATE users SET name = $1, email = $2 WHERE id = $3",
        S.update,
    );
}

test "compile error on missing id - select_by_id" {
    // This test is intentionally left as a comment rather than live code —
    // compile errors can't be caught at runtime. To verify this manually,
    // temporarily define a model without `id` and confirm the error fires:
    //
    // const NoId = struct {
    //     pub const table_name = "things";
    //     name: []const u8,
    // };
    // const M = model.Model(NoId);
    // const S = Sql(M, dialect.SQLite);
    // _ = S.select_by_id; // should emit: "things has no `id` field"
}
