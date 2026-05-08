const std = @import("std");
const zap = @import("zap");
const uboard = @import("u-board");
const securing = @import("securing.zig");

const dbc = uboard.core.db.c;

pub const AuthenticateError = error{
    InvalidCredentials,
    DatabaseError,
};

pub const LogInError = error{
    DatabaseError,
};

const session_lifetime_seconds: i64 = 7 * 24 * 60 * 60;
const random_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~";

fn sqliteErrorMessage(db: ?*dbc.sqlite3) []const u8 {
    if (db) |handle| {
        return std.mem.span(dbc.sqlite3_errmsg(handle));
    }
    return "unknown sqlite error";
}

fn sqliteNoopDestructor(_: ?*anyopaque) callconv(.c) void {}

pub fn randomStr(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    for (out) |*ch| {
        ch.* = random_chars[random.uintLessThan(usize, random_chars.len)];
    }

    return out;
}

pub fn authenticate(
    allocator: std.mem.Allocator,
    db: *dbc.sqlite3,
    username: []const u8,
    password: []const u8,
) !bool {
    const sql = "SELECT password FROM auth_user WHERE username = ? LIMIT 1";

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare auth query: {s}\n", .{sqliteErrorMessage(db)});
        return AuthenticateError.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, username.ptr, @intCast(username.len), sqliteNoopDestructor) != dbc.SQLITE_OK) {
        std.debug.print("failed to bind username: {s}\n", .{sqliteErrorMessage(db)});
        return AuthenticateError.DatabaseError;
    }

    switch (dbc.sqlite3_step(stmt.?)) {
        dbc.SQLITE_ROW => {},
        dbc.SQLITE_DONE => return AuthenticateError.InvalidCredentials,
        else => {
            std.debug.print("failed to execute auth query: {s}\n", .{sqliteErrorMessage(db)});
            return AuthenticateError.DatabaseError;
        },
    }

    const stored_password_ptr = dbc.sqlite3_column_blob(stmt.?, 0);
    if (stored_password_ptr == null) return AuthenticateError.DatabaseError;

    const stored_password_len: usize = @intCast(dbc.sqlite3_column_bytes(stmt.?, 0));
    const stored_password = @as([*]const u8, @ptrCast(stored_password_ptr))[0..stored_password_len];

    const valid = try securing.checkPassword(allocator, username, password, stored_password);
    return valid;
}

fn bindText(stmt: *dbc.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (dbc.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), sqliteNoopDestructor) != dbc.SQLITE_OK) {
        return LogInError.DatabaseError;
    }
}

fn bindInt64(stmt: *dbc.sqlite3_stmt, index: c_int, value: i64) !void {
    if (dbc.sqlite3_bind_int64(stmt, index, value) != dbc.SQLITE_OK) {
        return LogInError.DatabaseError;
    }
}

pub fn logIn(
    req: *const zap.Request,
    allocator: std.mem.Allocator,
    db: *dbc.sqlite3,
    username: []const u8,
) !void {
    const session_key = try randomStr(allocator, 40);
    defer allocator.free(session_key);

    const now = std.time.timestamp();
    const expires_at = now + session_lifetime_seconds;

    const sql = "INSERT INTO auth_session (key, username, revoked, expires_at, created_at) VALUES (?, ?, ?, ?, ?)";

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare login insert: {s}\n", .{sqliteErrorMessage(db)});
        return LogInError.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    try bindText(stmt.?, 1, session_key);
    try bindText(stmt.?, 2, username);
    try bindInt64(stmt.?, 3, 0);
    try bindInt64(stmt.?, 4, expires_at);
    try bindInt64(stmt.?, 5, now);

    if (dbc.sqlite3_step(stmt.?) != dbc.SQLITE_DONE) {
        std.debug.print("failed to insert auth session: {s}\n", .{sqliteErrorMessage(db)});
        return LogInError.DatabaseError;
    }

    const update_sql = "UPDATE auth_user SET last_logged_in = ? WHERE username = ?";

    var update_stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, update_sql, -1, &update_stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare last login update: {s}\n", .{sqliteErrorMessage(db)});
        return LogInError.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(update_stmt.?);

    try bindInt64(update_stmt.?, 1, now);
    try bindText(update_stmt.?, 2, username);

    if (dbc.sqlite3_step(update_stmt.?) != dbc.SQLITE_DONE) {
        std.debug.print("failed to update last login: {s}\n", .{sqliteErrorMessage(db)});
        return LogInError.DatabaseError;
    }

    try req.setCookie(.{
        .name = "session",
        .value = session_key,
        .path = "/u-board",
        .max_age_s = session_lifetime_seconds,
        .http_only = true,
        .secure = false,
        .same_site = .Lax,
    });
}
