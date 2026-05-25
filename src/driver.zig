const AllocatorError = @import("std").mem.Allocator.Error;

/// Canonical error set for all ztorm driver operations.
/// Driver implementations must map their native errors to these variants
/// rather than surfacing backend-specific error types.
pub const DriverError = error{
    /// The database file or connection endpoint could not be opened.
    OpenFailed,
    /// A SQL statement could not be parsed or prepared by the backend.
    PrepareFailed,
    /// A parameter could not be bound to a prepared statement.
    BindFailed,
    /// The backend returned an unexpected result while stepping through a statement.
    StepFailed,
    /// An operation was attempted on a closed connection.
    ConnectionClosed,
};

/// Combined error set used as the return type for all driver-facing functions.
/// Includes allocator errors since drivers own their memory internally.
pub const Error = DriverError || AllocatorError;

/// A type-erased value passed as a bind parameter to a SQL statement.
/// Driver implementations pattern-match on the tag to bind the correct
/// native type. Booleans are mapped to 0/1 integers on backends that
/// lack a native bool type.
///
/// See also:
/// * `Dialect.native_bools`
pub const Param = union(enum) {
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    bool: bool,
    null,
};

/// A type-erased value read back from a single column in a result row.
/// Text and blob slices are owned by the driver and remain valid until
/// the next call to `Rows.next()` or `Rows.close()` - dupe if they need
/// to outlive the current iteration.
pub const ColumnValue = union(enum) {
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    bool: bool,
    null,
};

/// A single result row returned by a query.
/// Column indices correspond to the field declaration order of the model
/// struct when using ztorm-generated SELECT statements. Raw queries
/// must match their own column order manually.
pub const Row = struct {
    getColumnFn: *const fn (ctx: *anyopaque, index: usize) ColumnValue,
    columnCountFn: *const fn (ctx: *anyopaque) usize,
    ctx: *anyopaque,

    pub fn getColumn(self: Row, index: usize) ColumnValue {
        return self.getColumnFn(self.ctx, index);
    }

    pub fn columnCount(self: Row) usize {
        return self.columnCountFn(self.ctx);
    }
};

/// An iterator over a set of result rows.
/// Always call `close()` when done - even if iteration was cut short
/// to release the underlying prepared statement and any driver memory.
pub const Rows = struct {
    nextFn: *const fn (ctx: *anyopaque) Error!?Row,
    closeFn: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,

    pub fn next(self: Rows) Error!?Row {
        return self.nextFn(self.ctx);
    }

    pub fn close(self: Rows) void {
        self.closeFn(self.ctx);
    }
};

/// A type-erased database connection handle.
/// Obtain one from a driver package (e.g. ztorm_sqlite) and pass it to `DB.init()`.
/// The driver owns its allocator and all memory it allocates - do NOT free
/// ColumnValue slices returned from Row.getColumn().
pub const Driver = struct {
    executeFn: *const fn (ctx: *anyopaque, sql: []const u8, params: []const Param) Error!void,
    queryFn: *const fn (ctx: *anyopaque, sql: []const u8, params: []const Param) Error!Rows,
    closeFn: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,

    pub fn execute(self: Driver, sql: []const u8, params: []const Param) Error!void {
        return self.executeFn(self.ctx, sql, params);
    }

    pub fn query(self: Driver, sql: []const u8, params: []const Param) Error!Rows {
        return self.queryFn(self.ctx, sql, params);
    }

    pub fn close(self: Driver) void {
        self.closeFn(self.ctx);
    }
};
