const std = @import("std");
const clap = @import("clap");
const uboard = @import("u-board");
const c = @cImport({
    @cInclude("sqlite3.h");
});

fn usage() void {
    std.debug.print(
        \\Usage: DATABASE_URL=<path> u-board-cmd_create-user -u <username> -p <password>
        \\
    , .{});
}

fn sqliteErrorMessage(db: ?*c.sqlite3) []const u8 {
    if (db) |handle| {
        return std.mem.span(c.sqlite3_errmsg(handle));
    }
    return "unknown sqlite error";
}

fn sqliteNoopDestructor(_: ?*anyopaque) callconv(.c) void {}

fn databasePathFromUrl(allocator: std.mem.Allocator, database_url: []const u8) ![]u8 {
    const prefix = "sqlite:";
    if (std.mem.startsWith(u8, database_url, prefix)) {
        return allocator.dupe(u8, database_url[prefix.len..]);
    }
    return allocator.dupe(u8, database_url);
}

fn bindUsername(stmt: *c.sqlite3_stmt, username: []const u8) bool {
    return c.sqlite3_bind_text(stmt, 1, username.ptr, @intCast(username.len), sqliteNoopDestructor) == c.SQLITE_OK;
}

fn bindPassword(stmt: *c.sqlite3_stmt, hashed_password: []const u8) bool {
    return c.sqlite3_bind_blob(stmt, 2, hashed_password.ptr, @intCast(hashed_password.len), sqliteNoopDestructor) == c.SQLITE_OK;
}

fn insertUser(
    db: *c.sqlite3,
    username: []const u8,
    hashed_password: []const u8,
) !void {
    const sql =
        \\INSERT INTO auth_user (username, password)
        \\VALUES (?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("failed to prepare insert: {s}\n", .{sqliteErrorMessage(db)});
        return error.Failure;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    if (!bindUsername(stmt.?, username)) {
        std.debug.print("failed to bind username: {s}\n", .{sqliteErrorMessage(db)});
        return error.Failure;
    }

    if (!bindPassword(stmt.?, hashed_password)) {
        std.debug.print("failed to bind password: {s}\n", .{sqliteErrorMessage(db)});
        return error.Failure;
    }

    if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
        std.debug.print("failed to insert user: {s}\n", .{sqliteErrorMessage(db)});
        return error.Failure;
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const database_url = std.process.getEnvVarOwned(allocator, "DATABASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            usage();
            std.debug.print("DATABASE_URL must be set\n", .{});
            return error.Failure;
        },
        else => return err,
    };
    defer allocator.free(database_url);

    if (database_url.len == 0) {
        usage();
        std.debug.print("DATABASE_URL must not be empty\n", .{});
        return error.Failure;
    }

    const database_path = try databasePathFromUrl(allocator, database_url);
    defer allocator.free(database_path);

    const database_path_z = try allocator.dupeZ(u8, database_path);
    defer allocator.free(database_path_z);

    var diag = clap.Diagnostic{};
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-u, --username <str>     Username to insert.
        \\-p, --password <str>     Password to insert.
        \\
    );

    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    const username = res.args.username orelse {
        usage();
        std.debug.print("username is required\n", .{});
        return error.Failure;
    };
    const password = res.args.password orelse {
        usage();
        std.debug.print("password is required\n", .{});
        return error.Failure;
    };

    var hashed_password: [uboard.handling.auth.securing.StoredPasswordLen]u8 = undefined;
    try uboard.handling.auth.securing.hashPasswordInto(allocator, username, password, &hashed_password);

    if (std.fs.path.dirname(database_url)) |db_dir| {
        try std.fs.cwd().makePath(db_dir);
    }

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(database_path_z.ptr, &db) != c.SQLITE_OK) {
        const message = sqliteErrorMessage(db);
        if (db) |handle| {
            _ = c.sqlite3_close(handle);
        }
        std.debug.print("failed to open {s}: {s}\n", .{ database_url, message });
        return error.Failure;
    }
    defer _ = c.sqlite3_close(db.?);

    try insertUser(db.?, username, hashed_password[0..]);

    std.debug.print("username={s}\n", .{username});
    std.debug.print("password=stored\n", .{});
}
