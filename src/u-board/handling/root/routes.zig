const std = @import("std");
const zap = @import("zap");

const uboard = @import("u-board");

const indexTemplate = @embedFile("template/index.html");
const dashboardTemplate = @embedFile("template/dashboard.html");
const usersListTemplate = @embedFile("template/users/list.html");
const lakehouseListTemplate = @embedFile("template/lakehouse/list.html");
const lakehouseDetailsTemplate = @embedFile("template/lakehouse/details.html");

fn RootRoute(comptime handler: anytype) type {
    return uboard.shortcuts.RoleRoute(.root, handler);
}

pub fn register(r: *zap.Router, c: *uboard.core.context.Context) !void {
    try RootRoute(root).register(r, "/u-board/root", c);
    try RootRoute(dashboard).register(r, "/u-board/root/dashboard", c);
    try RootRoute(usersList).register(r, "/u-board/root/users/list", c);
    try RootRoute(lakehouseList).register(r, "/u-board/root/lakehouse/list", c);
    try RootRoute(lakehouseDetails).register(r, "/u-board/root/lakehouse/details", c);
}

fn root(r: zap.Request, s: uboard.core.http.Scope) !void {
    const session_key = uboard.helpers.keyOfSession(s.arena.allocator(), r);
    const info = uboard.helpers.infoForSession(s.arena.allocator(), s.db, session_key);

    try uboard.shortcuts.renderWith(r, indexTemplate, .{ .username = info.username });
}

fn dashboard(r: zap.Request, s: uboard.core.http.Scope) !void {
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

const User = struct {
    username: []const u8,
    role: []const u8,
    last_login: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    initials: []const u8,
    badge_color: []const u8,
};

fn usersList(r: zap.Request, scope: uboard.core.http.Scope) !void {
    const dbc = uboard.core.db.c;

    const sql = "SELECT username, role, last_logged_in, created_at, updated_at FROM auth_user ORDER BY created_at DESC";

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(scope.db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare users query\n", .{});
        return error.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    var users = std.array_list.AlignedManaged(User, null).init(scope.arena.allocator());
    defer users.deinit();

    while (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        const username_ptr = dbc.sqlite3_column_text(stmt.?, 0);
        const username_len = dbc.sqlite3_column_bytes(stmt.?, 0);
        const username = username_ptr[0..@intCast(username_len)];

        const role: uboard.utils.Role = @enumFromInt(dbc.sqlite3_column_int64(stmt.?, 1));

        const last_logged_in = if (dbc.sqlite3_column_type(stmt.?, 2) == dbc.SQLITE_NULL)
            0
        else
            dbc.sqlite3_column_int64(stmt.?, 2);
        const created_at = dbc.sqlite3_column_int64(stmt.?, 3);
        const updated_at = dbc.sqlite3_column_int64(stmt.?, 4);

        const user_copy = try scope.arena.allocator().dupe(u8, username);

        const last_login_str = if (last_logged_in > 0)
            try uboard.utils.formatTimestamp(scope.arena.allocator(), last_logged_in)
        else
            try scope.arena.allocator().dupe(u8, "Never");
        const created_str = try uboard.utils.formatTimestamp(scope.arena.allocator(), created_at);
        const updated_str = try uboard.utils.formatTimestamp(scope.arena.allocator(), updated_at);

        const initials = try uboard.utils.getInitials(scope.arena.allocator(), username);
        const badge_color = if (role == .staff) "badge-secondary" else "badge-accent";

        try users.append(.{
            .username = user_copy,
            .role = @tagName(role),
            .last_login = last_login_str,
            .created_at = created_str,
            .updated_at = updated_str,
            .initials = initials,
            .badge_color = badge_color,
        });
    }

    const data = .{ .users = users.items };
    try uboard.shortcuts.renderWith(r, usersListTemplate, data);
}

fn lakehouseList(r: zap.Request, scope: uboard.core.http.Scope) !void {
    const schemas = try uboard.handling.root.utils.lakehouseList(scope.arena.allocator());
    const data = .{ .schemas = schemas };

    try uboard.shortcuts.renderWith(r, lakehouseListTemplate, data);
}

fn lakehouseDetails(r: zap.Request, scope: uboard.core.http.Scope) !void {
    r.parseQuery();

    const schema_name = try r.getParamStr(scope.arena.allocator(), "s") orelse {
        r.setStatus(.bad_request);
        try r.sendBody("missing s");
        return;
    };
    const table_name = try r.getParamStr(scope.arena.allocator(), "t") orelse {
        r.setStatus(.bad_request);
        try r.sendBody("missing t");
        return;
    };

    const details = try uboard.handling.root.utils.lakehouseDetails(scope.arena.allocator(), schema_name, table_name);
    try uboard.shortcuts.renderWith(r, lakehouseDetailsTemplate, details);
}
