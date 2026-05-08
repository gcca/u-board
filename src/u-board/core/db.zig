const std = @import("std");
const uboard = @import("u-board");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

pub const c = sqlite;

pub const OpenError = error{
    MissingPath,
    InvalidPath,
    OpenFailed,
};

fn sqliteErrorMessage(db: ?*sqlite.sqlite3) []const u8 {
    if (db) |handle| return std.mem.span(sqlite.sqlite3_errmsg(handle));
    return "unknown sqlite error";
}

pub fn open(allocator: std.mem.Allocator, database_url: []const u8) !*sqlite.sqlite3 {
    const database_path = database_url;
    if (database_path.len == 0) return OpenError.MissingPath;
    if (std.mem.startsWith(u8, database_path, "sqlite:")) return OpenError.InvalidPath;

    const database_path_z = try allocator.dupeZ(u8, database_path);
    defer allocator.free(database_path_z);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(database_path_z.ptr, &db) != sqlite.SQLITE_OK or db == null) {
        std.debug.print("failed to open database {s}: {s}\n", .{ database_path, sqliteErrorMessage(db) });
        if (db) |handle| _ = sqlite.sqlite3_close(handle);
        return OpenError.OpenFailed;
    }

    return db.?;
}

pub fn openBy(context: *uboard.core.context.Context) !*sqlite.sqlite3 {
    return open(context.allocator, uboard.core.conf.settings.DATABASE_URL);
}

pub fn close(db: *sqlite.sqlite3) void {
    _ = sqlite.sqlite3_close(db);
}
