const std = @import("std");
const zap = @import("zap");
const uboard = @import("u-board");

const dbc = uboard.core.db.c;

pub const SessionInfo = struct {
    username: []const u8,
    role: []const u8,
};

pub fn infoForSession(
    allocator: std.mem.Allocator,
    db: *dbc.sqlite3,
    session_key: []const u8,
) SessionInfo {
    const sql =
        \\SELECT u.username, u.role
        \\FROM auth_user u
        \\JOIN auth_session s ON u.username = s.username
        \\WHERE s.key = ?
        \\  AND s.revoked = 0
        \\  AND s.expires_at > unixepoch()
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        return .{ .username = "desconocido", .role = "desconocido" };
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
        return .{ .username = "desconocido", .role = "desconocido" };
    }

    if (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        const uname_ptr = dbc.sqlite3_column_text(stmt.?, 0);
        const uname_len = dbc.sqlite3_column_bytes(stmt.?, 0);
        const username = allocator.dupe(u8, uname_ptr[0..@intCast(uname_len)]) catch "";

        const role_int = dbc.sqlite3_column_int64(stmt.?, 1);
        const role: uboard.utils.Role = @enumFromInt(role_int);
        const role_str = allocator.dupe(u8, uboard.utils.roleLabel(role)) catch "";

        return .{ .username = username, .role = role_str };
    }

    return .{ .username = "desconocido", .role = "desconocido" };
}

pub fn keyOfSession(allocator: std.mem.Allocator, r: zap.Request) []const u8 {
    return r.getCookieStr(allocator, "session") catch null orelse "";
}
