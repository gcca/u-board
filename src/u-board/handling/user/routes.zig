const std = @import("std");
const zap = @import("zap");

const uboard = @import("u-board");

const indexTemplate = @embedFile("template/index.html");
const dashboardTemplate = @embedFile("template/dashboard.html");
const rawFilesTemplate = @embedFile("template/rawfiles.html");

fn UserRoute(comptime handler: anytype) type {
    return uboard.shortcuts.RoleRoute(.user, handler);
}

pub fn register(r: *zap.Router, c: *uboard.core.context.Context) !void {
    try UserRoute(userGet).register(r, "/u-board/user", c);
    try UserRoute(dashboardGet).register(r, "/u-board/user/dashboard", c);
    try UserRoute(rawFilesGet).register(r, "/u-board/user/rawfiles", c);
}

fn userGet(r: zap.Request, s: uboard.core.http.Scope) !void {
    const session_key = uboard.helpers.keyOfSession(s.arena.allocator(), r);
    const info = uboard.helpers.infoForSession(s.arena.allocator(), s.db, session_key);

    try uboard.shortcuts.renderWith(r, indexTemplate, .{ .username = info.username });
}

fn dashboardGet(r: zap.Request, s: uboard.core.http.Scope) !void {
    const dbc = uboard.core.db.c;

    const session_key = uboard.helpers.keyOfSession(s.arena.allocator(), r);

    const sql =
        \\SELECT u.username, u.role, u.last_logged_in, u.created_at
        \\FROM auth_user u
        \\JOIN auth_session s ON u.username = s.username
        \\WHERE s.key = ?
        \\  AND s.revoked = 0
        \\  AND s.expires_at > unixepoch()
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(s.db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare dashboard query\n", .{});
        return error.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
        std.debug.print("failed to bind session key\n", .{});
        return error.DatabaseError;
    }

    if (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        const username_ptr = dbc.sqlite3_column_text(stmt.?, 0);
        const username_len = dbc.sqlite3_column_bytes(stmt.?, 0);
        const username = username_ptr[0..@intCast(username_len)];

        const role: uboard.utils.Role = @enumFromInt(dbc.sqlite3_column_int64(stmt.?, 1));

        const last_login = dbc.sqlite3_column_int64(stmt.?, 2);
        const created_at = dbc.sqlite3_column_int64(stmt.?, 3);

        const last_login_str = if (last_login > 0)
            try uboard.utils.formatTimestamp(s.arena.allocator(), last_login)
        else
            try s.arena.allocator().dupe(u8, "Never");

        const created_str = try uboard.utils.formatTimestamp(s.arena.allocator(), created_at);

        const data = .{
            .username = username,
            .role = @tagName(role),
            .last_login = last_login_str,
            .created_at = created_str,
        };

        try uboard.shortcuts.renderWith(r, dashboardTemplate, data);
    } else {
        return error.Unauthorized;
    }
}

fn rawFilesGet(r: zap.Request, _: uboard.core.http.Scope) !void {
    try uboard.shortcuts.renderWith(r, rawFilesTemplate, .{});
}
