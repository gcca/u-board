const std = @import("std");

const duckdb = @cImport({
    @cInclude("duckdb.h");
});

pub const LakehouseTable = struct {
    name: []const u8,
    detail_url: []const u8,
};

pub const LakehouseSchema = struct {
    name: []const u8,
    tables: []const LakehouseTable,
};

pub const LakehouseCell = struct {
    value: []const u8,
};

pub const LakehouseColumn = struct {
    name: []const u8,
};

pub const LakehouseRow = struct {
    cells: []const LakehouseCell,
};

pub const LakehouseDetails = struct {
    schema_name: []const u8,
    table_name: []const u8,
    columns: []const LakehouseColumn,
    rows: []const LakehouseRow,
};

pub fn lakehouseList(allocator: std.mem.Allocator) ![]LakehouseSchema {
    const db_path = "datalake/db";

    std.fs.cwd().access(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };

    var db: duckdb.duckdb_database = null;
    if (duckdb.duckdb_open(db_path, &db) == duckdb.DuckDBError) {
        return error.DuckDBOpenFailed;
    }
    defer duckdb.duckdb_close(&db);

    var conn: duckdb.duckdb_connection = null;
    if (duckdb.duckdb_connect(db, &conn) == duckdb.DuckDBError) {
        return error.DuckDBConnectFailed;
    }
    defer duckdb.duckdb_disconnect(&conn);

    const sql =
        \\SELECT table_schema, table_name
        \\FROM information_schema.tables
        \\WHERE table_type = 'BASE TABLE'
        \\  AND table_schema NOT IN ('information_schema', 'pg_catalog')
        \\ORDER BY table_schema, table_name
    ;

    var result: duckdb.duckdb_result = undefined;
    if (duckdb.duckdb_query(conn, sql, &result) == duckdb.DuckDBError) {
        defer duckdb.duckdb_destroy_result(&result);
        return error.DuckDBQueryFailed;
    }
    defer duckdb.duckdb_destroy_result(&result);

    var schemas = std.array_list.AlignedManaged(LakehouseSchema, null).init(allocator);
    var current_tables = std.array_list.AlignedManaged(LakehouseTable, null).init(allocator);
    var current_schema: ?[]const u8 = null;

    const rows = duckdb.duckdb_row_count(&result);
    var row: duckdb.idx_t = 0;
    while (row < rows) : (row += 1) {
        const schema_name = try valueString(allocator, &result, 0, row);
        const table_name = try valueString(allocator, &result, 1, row);
        const detail_url = try std.fmt.allocPrint(
            allocator,
            "/u-board/root/lakehouse/details?s={s}&t={s}",
            .{
                try urlEncode(allocator, schema_name),
                try urlEncode(allocator, table_name),
            },
        );

        if (current_schema) |name| {
            if (!std.mem.eql(u8, name, schema_name)) {
                try schemas.append(.{
                    .name = name,
                    .tables = try current_tables.toOwnedSlice(),
                });
                current_tables = std.array_list.AlignedManaged(LakehouseTable, null).init(allocator);
                current_schema = schema_name;
            }
        } else {
            current_schema = schema_name;
        }

        try current_tables.append(.{
            .name = table_name,
            .detail_url = detail_url,
        });
    }

    if (current_schema) |name| {
        try schemas.append(.{
            .name = name,
            .tables = try current_tables.toOwnedSlice(),
        });
    }

    return schemas.toOwnedSlice();
}

pub fn lakehouseDetails(
    allocator: std.mem.Allocator,
    schema_name: []const u8,
    table_name: []const u8,
) !LakehouseDetails {
    const db_path = "datalake/db";

    std.fs.cwd().access(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.LakehouseDatabaseNotFound,
        else => return err,
    };

    var db: duckdb.duckdb_database = null;
    if (duckdb.duckdb_open(db_path, &db) == duckdb.DuckDBError) {
        return error.DuckDBOpenFailed;
    }
    defer duckdb.duckdb_close(&db);

    var conn: duckdb.duckdb_connection = null;
    if (duckdb.duckdb_connect(db, &conn) == duckdb.DuckDBError) {
        return error.DuckDBConnectFailed;
    }
    defer duckdb.duckdb_disconnect(&conn);

    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();

    try sql.writer.writeAll("SELECT * FROM ");
    try writeSqlIdentifier(&sql.writer, schema_name);
    try sql.writer.writeByte('.');
    try writeSqlIdentifier(&sql.writer, table_name);
    try sql.writer.writeAll(" LIMIT 50");

    const sql_z = try allocator.dupeZ(u8, sql.written());
    defer allocator.free(sql_z);

    var result: duckdb.duckdb_result = undefined;
    if (duckdb.duckdb_query(conn, sql_z.ptr, &result) == duckdb.DuckDBError) {
        defer duckdb.duckdb_destroy_result(&result);
        return error.DuckDBQueryFailed;
    }
    defer duckdb.duckdb_destroy_result(&result);

    const column_count = duckdb.duckdb_column_count(&result);
    var columns = std.array_list.AlignedManaged(LakehouseColumn, null).init(allocator);
    var column: duckdb.idx_t = 0;
    while (column < column_count) : (column += 1) {
        if (duckdb.duckdb_column_name(&result, column)) |column_name| {
            try columns.append(.{ .name = try allocator.dupe(u8, std.mem.span(column_name)) });
        } else {
            try columns.append(.{ .name = try allocator.dupe(u8, "") });
        }
    }

    const row_count = duckdb.duckdb_row_count(&result);
    var rows = std.array_list.AlignedManaged(LakehouseRow, null).init(allocator);
    var row: duckdb.idx_t = 0;
    while (row < row_count) : (row += 1) {
        var cells = std.array_list.AlignedManaged(LakehouseCell, null).init(allocator);
        column = 0;
        while (column < column_count) : (column += 1) {
            const cell_value = if (duckdb.duckdb_value_is_null(&result, column, row))
                try allocator.dupe(u8, "")
            else
                try valueString(allocator, &result, column, row);

            try cells.append(.{ .value = cell_value });
        }

        try rows.append(.{ .cells = try cells.toOwnedSlice() });
    }

    return .{
        .schema_name = try allocator.dupe(u8, schema_name),
        .table_name = try allocator.dupe(u8, table_name),
        .columns = try columns.toOwnedSlice(),
        .rows = try rows.toOwnedSlice(),
    };
}

fn valueString(
    allocator: std.mem.Allocator,
    result: *duckdb.duckdb_result,
    column: duckdb.idx_t,
    row: duckdb.idx_t,
) ![]const u8 {
    const value = duckdb.duckdb_value_varchar(result, column, row) orelse return error.DuckDBNullValue;
    defer duckdb.duckdb_free(value);

    return allocator.dupe(u8, std.mem.span(value));
}

fn writeSqlIdentifier(writer: *std.Io.Writer, identifier: []const u8) !void {
    try writer.writeByte('"');
    for (identifier) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

fn urlEncode(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();

    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try encoded.writer.writeByte(byte);
        } else {
            try encoded.writer.print("%{X:0>2}", .{byte});
        }
    }

    return encoded.toOwnedSlice();
}
