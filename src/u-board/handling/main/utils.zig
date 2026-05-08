const std = @import("std");
const uboard = @import("u-board");

const dbc = uboard.core.db.c;

pub fn roleForSession(scope: uboard.core.http.Scope, session_key: []const u8) !uboard.utils.Role {
    const sql =
        \\SELECT u.role
        \\FROM auth_session s
        \\JOIN auth_user u ON u.username = s.username
        \\WHERE s.key = ?
        \\LIMIT 1
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(scope.db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        return error.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
        return error.DatabaseError;
    }

    switch (dbc.sqlite3_step(stmt.?)) {
        dbc.SQLITE_ROW => return @enumFromInt(dbc.sqlite3_column_int64(stmt.?, 0)),
        else => return error.DatabaseError,
    }
}
