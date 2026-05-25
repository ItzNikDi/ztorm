# ztorm

A comptime-driven ORM for Zig. Define models as plain structs and
ztorm will generate type-safe SQL at compile time with zero runtime overhead.

Driver-independent: create backends via the driver interface.
Existing drivers live in separate packages so only what you need is pulled in.

> **Status:** v0 - core API is functional but unstable.
> Just like the language itself, expect breaking changes before v1.

---

## Packages

| Package                                                  | Description                                       |
|----------------------------------------------------------|---------------------------------------------------|
| `ztorm`                                                  | Core library - models, SQL generation and mapping |
| [ztorm_sqlite](https://github.com/ItzNikDi/ztorm_sqlite) | SQLite driver via `sqlite3` C library             |

---

## Quick start

### 1. Add dependencies

```shell
zig fetch --save "git+https://github.com/ItzNikDi/ztorm.git#main"
zig fetch --save "git+https://github.com/ItzNikDi/ztorm_sqlite.git#main"
```

### 2. Wire up `build.zig`

```zig
const ztorm = b.dependency("ztorm", .{
    .target = target,
    .optimize = optimize,
});

const ztorm_sqlite = b.dependency("ztorm_sqlite", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("ztorm", ztorm.module("ztorm"));
exe.root_module.addImport("ztorm_sqlite", ztorm_sqlite.module("ztorm_sqlite"));
```

### 3. Define a model

```zig
const Food = struct {
    pub const table_name  = "foods";
    pub const primary_key = ztorm.PrimaryKey.auto;
    id:    i64,
    name:  []const u8,
    flavor: []const u8,
};
const FoodModel = ztorm.Model(Food);
```

### 4. Open a connection and query

```zig
const ztorm  = @import("ztorm");
const zt_sqlite = @import("ztorm_sqlite");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var db = ztorm.DB(ztorm.dialect.SQLite).init(
        try zt_sqlite.open(allocator, "food_app.db"),
    );
    defer db.close();

    // DDL — ztorm does not run migrations as of now
    try db.exec(
        "CREATE TABLE IF NOT EXISTS foods " ++
        "(id INTEGER PRIMARY KEY, name TEXT, flavor TEXT)",
        &.{},
    );

    try db.insert(FoodModel, allocator, .{
        .id    = 0,           // ignored — primary_key is .auto
        .name  = "pineapple",
        .flavor = "oddly specific",
    });

    const foods = try db.findAll(FoodModel, allocator);
    defer allocator.free(foods);

    for (foods) |f| {
        std.debug.print("{s} tastes {s}\n", .{ f.name, f.flavor });
    }
}
```

---

## Model declaration

```zig
const Article = struct {
    // not a hard requirement - maps to a SQL table name, will default to @typeName(@This());
    pub const table_name  = "articles";

    // optional: defaults to .auto if an `id` field exists, otherwise .none;
    pub const primary_key = ztorm.PrimaryKey.auto;

    id:      i64,
    title:   []const u8,
    body:    []const u8,
    draft:   bool,
};
```

### `PrimaryKey` variants

| Variant   | Behaviour                                                                                                    |
|-----------|--------------------------------------------------------------------------------------------------------------|
| `.auto`   | DB-generated (auto-increment, serial); excluded from INSERT.                                                 |
| `.manual` | Client-generated (UUID, nanoid); included in INSERT.                                                         |
| `.none`   | No single primary key field (composite or natural key); UPDATE and DELETE by this are currently unavailable. |

---

## Supported field types

| Zig type                   | SQL type                                       |
|----------------------------|------------------------------------------------|
| `i8` … `i64`, `u8` … `u64` | INTEGER                                        |
| `f32`, `f64`               | REAL                                           |
| `bool`                     | INTEGER (0/1) on SQLite, BOOLEAN on PostgreSQL |
| `[]const u8`               | TEXT                                           |
| `?T`                       | nullable column — any of the above             |

---

## Raw SQL

ztorm is not meant to cover every SQL feature. Use raw statements freely:

```zig
// Statement with no result
try db.exec("CREATE INDEX ...", &.{});

// Query returning raw rows
var rows = try db.rawQuery("SELECT ...", &.{ .{ .int = 42 } });
defer rows.close();
while (try rows.next()) |row| {
    const val = row.getColumn(0);
}
```

---

## Writing a driver

Implement three functions matching the `Driver` function pointer signatures
and wrap them in a `driver.Driver` struct. See [ztorm_sqlite](https://github.com/ItzNikDi/ztorm_sqlite) for a
reference implementation.

```zig
pub fn open(allocator: std.mem.Allocator, ...) !ztorm.Driver {
    // allocate your context, open the connection
    return ztorm.Driver{
        .executeFn = execute,
        .queryFn   = query,
        .closeFn   = close,
        .ctx       = ctx,
    };
}
```

---