/// Describes how a model's primary key is managed.
///
/// Declared on a model struct as `pub const primary_key = PrimaryKey.auto`.
pub const PrimaryKey = enum {
    /// DB-generated (auto-increment, serial); excluded from INSERT
    auto,
    /// Client-generated (UUID, nanoid); included in INSERT
    manual,
    /// No single primary key field (composite or natural key); UPDATE and DELETE by this are currently unavailable
    none,
};

/// Wraps a struct as a ztorm model, validating the shape at comptime
/// and attaching schema metadata used by `sql.zig`, `db.zig`, and `mapping.zig`.
///
/// Example:
/// ```
///   const User = struct {
///       pub const table_name  = "users";
///       pub const primary_key = ztorm.PrimaryKey.auto;
///       id:    i64,
///       name:  []const u8,
///   };
///   const UserModel = ztorm.Model(User);
/// ```
///
/// If `table_name` is not declared, the struct's @typeName is used as a fallback.
///
/// If `primary_key` is not declared and an `id` field exists, `PrimaryKey.auto` is assumed.
pub fn Model(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Model must be a struct, got: " ++ @typeName(T));

    return struct {
        pub const Schema = T;
        pub const table_name = if (@hasDecl(T, "table_name")) T.table_name else @typeName(T);
        pub const fields = @typeInfo(T).@"struct".fields;
        pub const has_id = @hasField(T, "id");

        pub const primary_key: PrimaryKey = if (@hasDecl(T, "primary_key"))
            T.primary_key
        else if (@hasField(T, "id"))
            .auto // `id` was declared but no type was given
        else
            .none;
    };
}

test "model schema" {
    const testing = @import("std").testing;
    const User = struct {
        //pub const table_name = "users";
        id: i64,
        name: []const u8,
    };
    const M = Model(User);
    try testing.expectEqualStrings("users", M.table_name);
    try testing.expect(M.has_id);
}
