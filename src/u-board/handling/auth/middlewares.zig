const std = @import("std");
const zap = @import("zap");
const uboard = @import("u-board");

const dbc = uboard.core.db.c;

pub const LogInRequiredError = error{
    Unauthorized,
    DatabaseError,
};

pub const RoleRequiredError = error{
    Forbidden,
    DatabaseError,
};

pub fn LogInRequired() type {
    return struct {
        pub fn wrap(comptime next: anytype) fn (zap.Request, *uboard.core.http.Scope) anyerror!void {
            return struct {
                fn middleware(r: zap.Request, scope: *uboard.core.http.Scope) !void {
                    requireLogIn(&r, scope.arena.allocator(), scope.db) catch |err| switch (err) {
                        error.Unauthorized => {
                            try r.redirectTo("/u-board/auth/signin", null);
                            return;
                        },
                        else => return err,
                    };

                    try next(r, scope);
                }
            }.middleware;
        }
    };
}

fn sqliteErrorMessage(db: ?*dbc.sqlite3) []const u8 {
    if (db) |handle| return std.mem.span(dbc.sqlite3_errmsg(handle));
    return "unknown sqlite error";
}

fn requireLogIn(
    req: *const zap.Request,
    allocator: std.mem.Allocator,
    db: *dbc.sqlite3,
) !void {
    const session_key = try req.getCookieStr(allocator, "session") orelse {
        return LogInRequiredError.Unauthorized;
    };
    defer allocator.free(session_key);

    const sql =
        \\SELECT 1
        \\FROM auth_session
        \\WHERE key = ?
        \\  AND revoked = 0
        \\  AND expires_at > unixepoch()
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare session check: {s}\n", .{sqliteErrorMessage(db)});
        return LogInRequiredError.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
        std.debug.print("failed to bind session key: {s}\n", .{sqliteErrorMessage(db)});
        return LogInRequiredError.DatabaseError;
    }

    switch (dbc.sqlite3_step(stmt.?)) {
        dbc.SQLITE_ROW => return,
        dbc.SQLITE_DONE => return LogInRequiredError.Unauthorized,
        else => {
            std.debug.print("failed to execute session check: {s}\n", .{sqliteErrorMessage(db)});
            return LogInRequiredError.DatabaseError;
        },
    }
}

pub fn RoleRequired(comptime required_role: uboard.utils.Role) type {
    return struct {
        pub fn wrap(comptime next: anytype) fn (zap.Request, *uboard.core.http.Scope) anyerror!void {
            return struct {
                fn middleware(r: zap.Request, scope: *uboard.core.http.Scope) !void {
                    requireRole(&r, scope.arena.allocator(), scope.*, required_role) catch |err| switch (err) {
                        error.Forbidden => {
                            try r.sendBody("Forbidden: insufficient permissions");
                            r.setStatus(.forbidden);
                            return;
                        },
                        else => return err,
                    };

                    try next(r, scope);
                }
            }.middleware;
        }
    };
}

fn requireRole(
    req: *const zap.Request,
    allocator: std.mem.Allocator,
    scope: uboard.core.http.Scope,
    required_role: uboard.utils.Role,
) !void {
    const session_key = try req.getCookieStr(allocator, "session") orelse {
        return RoleRequiredError.Forbidden;
    };
    defer allocator.free(session_key);

    const username = try getUsernameFromSession(scope.db, allocator, session_key);
    defer allocator.free(username);

    const user_role = try getUserRole(scope.db, username);

    if (user_role != required_role) {
        return RoleRequiredError.Forbidden;
    }
}

fn getUsernameFromSession(db: *dbc.sqlite3, allocator: std.mem.Allocator, session_key: []const u8) ![]const u8 {
    const sql =
        \\SELECT username
        \\FROM auth_session
        \\WHERE key = ?
        \\  AND revoked = 0
        \\  AND expires_at > unixepoch()
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare username query: {s}\n", .{sqliteErrorMessage(db)});
        return RoleRequiredError.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
        std.debug.print("failed to bind session key: {s}\n", .{sqliteErrorMessage(db)});
        return RoleRequiredError.DatabaseError;
    }

    if (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        const username_ptr = dbc.sqlite3_column_text(stmt.?, 0);
        const username_len = dbc.sqlite3_column_bytes(stmt.?, 0);
        const username = username_ptr[0..@intCast(username_len)];

        const result = try allocator.alloc(u8, username.len);
        @memcpy(result, username);
        return result;
    }

    return RoleRequiredError.Forbidden;
}

fn getUserRole(db: *dbc.sqlite3, username: []const u8) !uboard.utils.Role {
    const sql =
        \\SELECT role
        \\FROM auth_user
        \\WHERE username = ?
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare role query: {s}\n", .{sqliteErrorMessage(db)});
        return RoleRequiredError.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, username.ptr, @intCast(username.len), null) != dbc.SQLITE_OK) {
        std.debug.print("failed to bind username: {s}\n", .{sqliteErrorMessage(db)});
        return RoleRequiredError.DatabaseError;
    }

    if (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        return @enumFromInt(dbc.sqlite3_column_int64(stmt.?, 0));
    }

    return RoleRequiredError.DatabaseError;
}
