const std = @import("std");
const zap = @import("zap");
const uboard = @import("u-board");

const dbc = uboard.core.db.c;

pub const SessionInfo = struct {
    username: []const u8,
};

pub fn infoForSession(
    allocator: std.mem.Allocator,
    db: *dbc.sqlite3,
    session_key: []const u8,
) SessionInfo {
    const sql =
        \\SELECT u.username
        \\FROM auth_user u
        \\JOIN auth_session s ON u.username = s.username
        \\WHERE s.key = ?
        \\  AND s.revoked = 0
        \\  AND s.expires_at > unixepoch()
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        return .{ .username = "unknown" };
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
        return .{ .username = "unknown" };
    }

    if (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        const ptr = dbc.sqlite3_column_text(stmt.?, 0);
        const len = dbc.sqlite3_column_bytes(stmt.?, 0);
        const username = allocator.dupe(u8, ptr[0..@intCast(len)]) catch "";
        return .{ .username = username };
    }

    return .{ .username = "unknown" };
}

pub fn keyOfSession(allocator: std.mem.Allocator, r: zap.Request) []const u8 {
    return r.getCookieStr(allocator, "session") catch null orelse "";
}
