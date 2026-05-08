const std = @import("std");

const duckdb = @cImport({
    @cInclude("duckdb.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const datalake_dir = std.process.getEnvVarOwned(allocator, "DATALAKE_DIR") catch |err| {
        std.debug.print("EnvVar DATALAKE_DIR err: {}\n", .{err});
        return;
    };
    defer allocator.free(datalake_dir);

    std.fs.cwd().access(datalake_dir, .{}) catch |err| {
        std.debug.print("DATALAKE_DIR access err: {}\n", .{err});
        return;
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ datalake_dir, "db" });
    defer allocator.free(db_path);

    var db: duckdb.duckdb_database = null;
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    if (duckdb.duckdb_open(db_path_z.ptr, &db) == duckdb.DuckDBError) {
        std.debug.print("DuckDB open err: {s}\n", .{db_path});
        return error.DuckDBOpenFailed;
    }
    defer duckdb.duckdb_close(&db);

    var conn: duckdb.duckdb_connection = null;
    if (duckdb.duckdb_connect(db, &conn) == duckdb.DuckDBError) {
        std.debug.print("DuckDB connect err\n", .{});
        return error.DuckDBConnectFailed;
    }
    defer duckdb.duckdb_disconnect(&conn);

    try initDatalake(allocator, conn, datalake_dir);
}

fn initDatalake(
    allocator: std.mem.Allocator,
    conn: duckdb.duckdb_connection,
    datalake_dir: []const u8,
) !void {
    var datalake = try std.fs.cwd().openDir(datalake_dir, .{ .iterate = true });
    defer datalake.close();

    var dir_iter = datalake.iterate();
    while (try dir_iter.next()) |schema_entry| {
        if (schema_entry.kind != .directory) continue;
        if (std.mem.eql(u8, schema_entry.name, "db")) continue;

        try createSchema(allocator, conn, schema_entry.name);

        const schema_path = try std.fs.path.join(allocator, &[_][]const u8{ datalake_dir, schema_entry.name });
        defer allocator.free(schema_path);

        var schema_dir = try std.fs.cwd().openDir(schema_path, .{ .iterate = true });
        defer schema_dir.close();

        var file_iter = schema_dir.iterate();
        while (try file_iter.next()) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, file_entry.name, ".parquet")) continue;

            const table_name = file_entry.name[0 .. file_entry.name.len - ".parquet".len];
            const parquet_path = try std.fs.path.join(allocator, &[_][]const u8{ schema_path, file_entry.name });
            defer allocator.free(parquet_path);

            try createTableFromParquet(allocator, conn, schema_entry.name, table_name, parquet_path);
            std.debug.print("Created {s}.{s} from {s}\n", .{ schema_entry.name, table_name, parquet_path });
        }
    }
}

fn createSchema(
    allocator: std.mem.Allocator,
    conn: duckdb.duckdb_connection,
    schema_name: []const u8,
) !void {
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();

    try sql.writer.writeAll("CREATE SCHEMA IF NOT EXISTS ");
    try writeSqlIdentifier(&sql.writer, schema_name);

    try execSql(allocator, conn, sql.written());
}

fn createTableFromParquet(
    allocator: std.mem.Allocator,
    conn: duckdb.duckdb_connection,
    schema_name: []const u8,
    table_name: []const u8,
    parquet_path: []const u8,
) !void {
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();

    try sql.writer.writeAll("CREATE OR REPLACE TABLE ");
    try writeSqlIdentifier(&sql.writer, schema_name);
    try sql.writer.writeByte('.');
    try writeSqlIdentifier(&sql.writer, table_name);
    try sql.writer.writeAll(" AS FROM read_parquet(");
    try writeSqlString(&sql.writer, parquet_path);
    try sql.writer.writeByte(')');

    try execSql(allocator, conn, sql.written());
}

fn execSql(
    allocator: std.mem.Allocator,
    conn: duckdb.duckdb_connection,
    sql: []const u8,
) !void {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);

    var result: duckdb.duckdb_result = undefined;
    if (duckdb.duckdb_query(conn, sql_z.ptr, &result) == duckdb.DuckDBError) {
        defer duckdb.duckdb_destroy_result(&result);
        const err_msg = duckdb.duckdb_result_error(&result);
        if (err_msg) |msg| {
            std.debug.print("DuckDB query err: {s}\nSQL: {s}\n", .{ msg, sql });
        } else {
            std.debug.print("DuckDB query err\nSQL: {s}\n", .{sql});
        }
        return error.DuckDBQueryFailed;
    }
    duckdb.duckdb_destroy_result(&result);
}

fn writeSqlIdentifier(writer: *std.Io.Writer, identifier: []const u8) !void {
    try writer.writeByte('"');
    for (identifier) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

fn writeSqlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try writer.writeByte('\'');
        try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}
