const std = @import("std");
const zap = @import("zap");

const uboard = @import("u-board");

const indexTemplate = @embedFile("template/index.html");
const dashboardTemplate = @embedFile("template/dashboard.html");
const usersListTemplate = @embedFile("template/users/list.html");
const datamarkViewsListTemplate = @embedFile("template/datamark_views/list.html");
const datamarkViewsFormTemplate = @embedFile("template/datamark_views/form.html");
const datamarkSourcesListTemplate = @embedFile("template/datamark_sources/list.html");
const datamarkSourcesFormTemplate = @embedFile("template/datamark_sources/form.html");
const datamarkReportsListTemplate = @embedFile("template/datamark_reports/list.html");
const datamarkReportsRunTemplate = @embedFile("template/datamark_reports/run.html");
const datamarkReportsResultTemplate = @embedFile("template/datamark_reports/result.html");
const datamarkReportsTableTemplate = @embedFile("template/datamark_reports/result_table.html");

const sqlite = uboard.core.db.c;
const ddb = @import("../../core/duckdb.zig").c;
const reports = @import("datamark_reports.zig");

fn AdminRoute(comptime handler: anytype) type {
    return uboard.shortcuts.RoleRoute(.admin, handler);
}

pub fn register(r: *zap.Router, c: *uboard.core.context.Context) !void {
    try AdminRoute(admin).register(r, "/u-board/admin", c);
    try AdminRoute(dashboard).register(r, "/u-board/admin/dashboard", c);
    try AdminRoute(usersList).register(r, "/u-board/admin/users/list", c);
    try AdminRoute(datamarkViewsList).register(r, "/u-board/admin/datamark-views/list", c);
    try AdminRoute(datamarkViewsForm).register(r, "/u-board/admin/datamark-views/form", c);
    try AdminRoute(datamarkViewsSave).register(r, "/u-board/admin/datamark-views/save", c);
    try AdminRoute(datamarkViewsRemove).register(r, "/u-board/admin/datamark-views/remove", c);
    try AdminRoute(datamarkSourcesList).register(r, "/u-board/admin/datamark-sources/list", c);
    try AdminRoute(datamarkSourcesForm).register(r, "/u-board/admin/datamark-sources/form", c);
    try AdminRoute(datamarkSourcesSave).register(r, "/u-board/admin/datamark-sources/save", c);
    try AdminRoute(datamarkSourcesRemove).register(r, "/u-board/admin/datamark-sources/remove", c);
    try AdminRoute(datamarkReportsList).register(r, "/u-board/admin/datamark-reports/list", c);
    try AdminRoute(datamarkReportsRun).register(r, "/u-board/admin/datamark-reports/run", c);
    try AdminRoute(datamarkReportsResult).register(r, "/u-board/admin/datamark-reports/result", c);
    try AdminRoute(datamarkReportsTable).register(r, "/u-board/admin/datamark-reports/table", c);
}

fn admin(r: zap.Request, s: uboard.core.http.Scope) !void {
    const session_key = uboard.helpers.keyOfSession(s.arena.allocator(), r);
    const info = uboard.helpers.infoForSession(s.arena.allocator(), s.db, session_key);

    try uboard.shortcuts.renderWith(r, indexTemplate, .{ .username = info.username, .role = info.role });
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
        if (username_ptr == null) return error.DatabaseError;
        const username = username_ptr[0..@intCast(username_len)];

        const role: uboard.utils.Role = @enumFromInt(dbc.sqlite3_column_int64(stmt.?, 1));

        const last_login = dbc.sqlite3_column_int64(stmt.?, 2);
        const created_at = dbc.sqlite3_column_int64(stmt.?, 3);

        const last_login_str = if (last_login > 0)
            try uboard.utils.formatTimestamp(s.arena.allocator(), last_login)
        else
            try s.arena.allocator().dupe(u8, "Nunca");

        const created_str = try uboard.utils.formatTimestamp(s.arena.allocator(), created_at);

        const data = .{
            .username = username,
            .role = uboard.utils.roleLabel(role),
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
    created_at: []const u8,
    updated_at: []const u8,
    initials: []const u8,
    badge_color: []const u8,
};

fn usersList(r: zap.Request, s: uboard.core.http.Scope) !void {
    const dbc = uboard.core.db.c;

    const sql =
        \\SELECT username, role, created_at, updated_at
        \\FROM auth_user
        \\WHERE role IN (2, 3)
        \\ORDER BY created_at DESC
    ;

    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(s.db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        std.debug.print("failed to prepare users query\n", .{});
        return error.DatabaseError;
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    const alloc = s.arena.allocator();
    var users: std.ArrayList(User) = .{};
    defer users.deinit(alloc);

    while (dbc.sqlite3_step(stmt.?) == dbc.SQLITE_ROW) {
        const username_ptr = dbc.sqlite3_column_text(stmt.?, 0);
        const username_len = dbc.sqlite3_column_bytes(stmt.?, 0);
        if (username_ptr == null) continue;
        const username = username_ptr[0..@intCast(username_len)];

        const role: uboard.utils.Role = @enumFromInt(dbc.sqlite3_column_int64(stmt.?, 1));

        const created_at = dbc.sqlite3_column_int64(stmt.?, 2);
        const updated_at = dbc.sqlite3_column_int64(stmt.?, 3);

        const user_copy = try alloc.dupe(u8, username);

        const created_str = try uboard.utils.formatTimestamp(alloc, created_at);
        const updated_str = try uboard.utils.formatTimestamp(alloc, updated_at);

        const initials = try uboard.utils.getInitials(alloc, username);
        const badge_color = if (role == .staff) "badge-secondary" else "badge-accent";

        try users.append(alloc, .{
            .username = user_copy,
            .role = uboard.utils.roleLabel(role),
            .created_at = created_str,
            .updated_at = updated_str,
            .initials = initials,
            .badge_color = badge_color,
        });
    }

    const data = .{ .users = users.items };
    try uboard.shortcuts.renderWith(r, usersListTemplate, data);
}

// ── Datamark Views ─────────────────────────────────────────────────────────────

const DatamarkView = struct {
    name: []const u8,
    source_name: []const u8, // joined display name
    query: []const u8,
    created_at: []const u8,
    url_name: []const u8,
};

const DatamarkSourceOption = struct {
    id: []const u8, // decimal string of integer id, used as form option value
    name: []const u8,
    selected: bool,
};

const DatamarkViewForm = struct {
    title: []const u8,
    submit_label: []const u8,
    original_name: []const u8,
    name: []const u8,
    query: []const u8,
    source_id: []const u8, // decimal string of current source_id for form value
    sources: []const DatamarkSourceOption,
    has_error: bool,
    error_message: []const u8,
};

fn datamarkViewsList(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);

    try renderDatamarkViewsList(r, s, null, "");
}

fn datamarkViewsForm(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);

    r.parseQuery();

    const maybe_name = try r.getParamStr(s.arena.allocator(), "name");
    const name = if (maybe_name) |n| n else "";

    if (name.len > 0) {
        const view = try loadDatamarkViewForm(s, name) orelse {
            try renderDatamarkViewsList(r, s, "Vista Datamark no encontrada.", "alert-error");
            return;
        };
        try renderDatamarkViewForm(r, view);
        return;
    }

    const sources = try loadSourceOptions(s.db, s.arena.allocator(), 0);
    try renderDatamarkViewForm(r, newDatamarkViewForm(sources, null));
}

fn datamarkViewsSave(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .POST) return methodNotAllowed(r);

    try r.parseBody();
    r.parseQuery();

    const original_name = try r.getParamStr(s.arena.allocator(), "original_name") orelse "";
    const raw_name = try r.getParamStr(s.arena.allocator(), "name") orelse "";
    const raw_query = try r.getParamStr(s.arena.allocator(), "query") orelse "";
    const raw_source_id = try r.getParamStr(s.arena.allocator(), "source_id") orelse "";

    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    const query = std.mem.trim(u8, raw_query, " \t\r\n");
    const source_id = std.mem.trim(u8, raw_source_id, " \t\r\n");

    const source_id_int: i64 = if (source_id.len > 0)
        std.fmt.parseInt(i64, source_id, 10) catch 0
    else
        0;

    const sources = try loadSourceOptions(s.db, s.arena.allocator(), source_id_int);

    if (name.len == 0) {
        try renderDatamarkViewForm(r, datamarkViewFormFromValues(sources, original_name, name, query, source_id, "El nombre es obligatorio."));
        return;
    }
    if (query.len == 0) {
        try renderDatamarkViewForm(r, datamarkViewFormFromValues(sources, original_name, name, query, source_id, "La consulta es obligatoria."));
        return;
    }
    if (source_id_int == 0) {
        try renderDatamarkViewForm(r, datamarkViewFormFromValues(sources, original_name, name, query, source_id, "La fuente es obligatoria."));
        return;
    }

    const form = datamarkViewFormFromValues(sources, original_name, name, query, source_id, null);

    if (original_name.len == 0) {
        insertDatamarkView(s.db, name, query, source_id_int) catch |err| {
            const message = if (err == error.Constraint) "Ya existe una vista Datamark con ese nombre." else "No se pudo guardar la vista Datamark.";
            try renderDatamarkViewForm(r, datamarkViewFormWithError(form, message));
            return;
        };
    } else {
        updateDatamarkView(s.db, original_name, name, query, source_id_int) catch |err| {
            const message = switch (err) {
                error.Constraint => "Ya existe una vista Datamark con ese nombre.",
                error.NotFound => "Vista Datamark no encontrada.",
                else => "No se pudo guardar la vista Datamark.",
            };
            try renderDatamarkViewForm(r, datamarkViewFormWithError(form, message));
            return;
        };
    }

    try r.setHeader("HX-Push-Url", "?t=datamark-views");
    try renderDatamarkViewsList(r, s, "Vista Datamark guardada.", "alert-success");
}

fn datamarkViewsRemove(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .POST) return methodNotAllowed(r);

    try r.parseBody();
    r.parseQuery();

    const name = try r.getParamStr(s.arena.allocator(), "name") orelse {
        try renderDatamarkViewsList(r, s, "El nombre es obligatorio.", "alert-error");
        return;
    };

    if (name.len == 0) {
        try renderDatamarkViewsList(r, s, "El nombre es obligatorio.", "alert-error");
        return;
    }

    deleteDatamarkView(s.db, name) catch {
        try renderDatamarkViewsList(r, s, "No se pudo eliminar la vista Datamark.", "alert-error");
        return;
    };

    try renderDatamarkViewsList(r, s, "Vista Datamark eliminada.", "alert-success");
}

fn renderDatamarkViewsList(
    r: zap.Request,
    s: uboard.core.http.Scope,
    message: ?[]const u8,
    message_class: []const u8,
) !void {
    const sql =
        \\SELECT dv.name, ds.name, dv.query, dv.create_at
        \\FROM datamark_view dv
        \\JOIN datamark_source ds ON ds.id = dv.source_id
        \\ORDER BY dv.create_at DESC, dv.name ASC
    ;

    const stmt = try prepareStatement(s.db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    const alloc = s.arena.allocator();
    var views: std.ArrayList(DatamarkView) = .{};
    defer views.deinit(alloc);

    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;

        const name = try alloc.dupe(u8, columnText(stmt, 0));
        const source_name = try alloc.dupe(u8, columnText(stmt, 1));
        const query = try alloc.dupe(u8, columnText(stmt, 2));
        const created_at = sqlite.sqlite3_column_int64(stmt, 3);

        const created_str = try uboard.utils.formatTimestamp(alloc, created_at);
        const url_name = try queryComponentEncode(alloc, name);

        try views.append(alloc, .{
            .name = name,
            .source_name = source_name,
            .query = query,
            .created_at = created_str,
            .url_name = url_name,
        });
    }

    try uboard.shortcuts.renderWith(r, datamarkViewsListTemplate, .{
        .views = views.items,
        .has_views = views.items.len > 0,
        .has_message = message != null,
        .message = message orelse "",
        .message_class = message_class,
    });
}

fn renderDatamarkViewForm(r: zap.Request, data: DatamarkViewForm) !void {
    try uboard.shortcuts.renderWith(r, datamarkViewsFormTemplate, data);
}

fn loadDatamarkViewForm(s: uboard.core.http.Scope, name: []const u8) !?DatamarkViewForm {
    const sql =
        \\SELECT name, query, source_id
        \\FROM datamark_view
        \\WHERE name = ?
        \\LIMIT 1
    ;

    const stmt = try prepareStatement(s.db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);

    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;

    const stored_name = try s.arena.allocator().dupe(u8, columnText(stmt, 0));
    const query = try s.arena.allocator().dupe(u8, columnText(stmt, 1));
    const source_id_int = sqlite.sqlite3_column_int64(stmt, 2);
    const source_id = try std.fmt.allocPrint(s.arena.allocator(), "{d}", .{source_id_int});

    const sources = try loadSourceOptions(s.db, s.arena.allocator(), source_id_int);

    return .{
        .title = "Editar vista Datamark",
        .submit_label = "Guardar",
        .original_name = stored_name,
        .name = stored_name,
        .query = query,
        .source_id = source_id,
        .sources = sources,
        .has_error = false,
        .error_message = "",
    };
}

fn newDatamarkViewForm(sources: []const DatamarkSourceOption, message: ?[]const u8) DatamarkViewForm {
    return .{
        .title = "Nueva vista Datamark",
        .submit_label = "Crear",
        .original_name = "",
        .name = "",
        .query = "",
        .source_id = "",
        .sources = sources,
        .has_error = message != null,
        .error_message = message orelse "",
    };
}

fn datamarkViewFormFromValues(
    sources: []const DatamarkSourceOption,
    original_name: []const u8,
    name: []const u8,
    query: []const u8,
    source_id: []const u8,
    message: ?[]const u8,
) DatamarkViewForm {
    return .{
        .title = if (original_name.len == 0) "Nueva vista Datamark" else "Editar vista Datamark",
        .submit_label = if (original_name.len == 0) "Crear" else "Guardar",
        .original_name = original_name,
        .name = name,
        .query = query,
        .source_id = source_id,
        .sources = sources,
        .has_error = message != null,
        .error_message = message orelse "",
    };
}

fn datamarkViewFormWithError(form: DatamarkViewForm, message: []const u8) DatamarkViewForm {
    return .{
        .title = form.title,
        .submit_label = form.submit_label,
        .original_name = form.original_name,
        .name = form.name,
        .query = form.query,
        .source_id = form.source_id,
        .sources = form.sources,
        .has_error = true,
        .error_message = message,
    };
}

fn insertDatamarkView(
    db: *sqlite.sqlite3,
    name: []const u8,
    query: []const u8,
    source_id: i64,
) !void {
    const sql =
        \\INSERT INTO datamark_view (name, query, source_id)
        \\VALUES (?, ?, ?)
    ;

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);
    try bindText(stmt, 2, query);
    try bindInt64(stmt, 3, source_id);

    try stepDone(db, stmt);
}

fn updateDatamarkView(
    db: *sqlite.sqlite3,
    original_name: []const u8,
    name: []const u8,
    query: []const u8,
    source_id: i64,
) !void {
    if (!try datamarkViewExists(db, original_name)) return error.NotFound;

    const sql =
        \\UPDATE datamark_view
        \\SET name = ?, query = ?, source_id = ?
        \\WHERE name = ?
    ;

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);
    try bindText(stmt, 2, query);
    try bindInt64(stmt, 3, source_id);
    try bindText(stmt, 4, original_name);

    try stepDone(db, stmt);
}

fn deleteDatamarkView(db: *sqlite.sqlite3, name: []const u8) !void {
    const sql = "DELETE FROM datamark_view WHERE name = ?";

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);
    try stepDone(db, stmt);
}

fn datamarkViewExists(db: *sqlite.sqlite3, name: []const u8) !bool {
    const sql = "SELECT 1 FROM datamark_view WHERE name = ? LIMIT 1";

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);

    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_ROW) return true;
    if (rc == sqlite.SQLITE_DONE) return false;
    return error.DatabaseError;
}

fn loadSourceOptions(
    db: *sqlite.sqlite3,
    allocator: std.mem.Allocator,
    selected: i64,
) ![]const DatamarkSourceOption {
    const sql = "SELECT id, name FROM datamark_source ORDER BY name ASC";

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var options: std.ArrayList(DatamarkSourceOption) = .{};

    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;

        const id_int = sqlite.sqlite3_column_int64(stmt, 0);
        const id_str = try std.fmt.allocPrint(allocator, "{d}", .{id_int});
        const name = try allocator.dupe(u8, columnText(stmt, 1));

        try options.append(allocator, .{
            .id = id_str,
            .name = name,
            .selected = id_int == selected,
        });
    }

    return try options.toOwnedSlice(allocator);
}

// ── Datamark Sources ───────────────────────────────────────────────────────────

const DatamarkSource = struct {
    name: []const u8,
    kind: []const u8,
    description: []const u8,
    url_name: []const u8,
};

const DatamarkSourceForm = struct {
    title: []const u8,
    submit_label: []const u8,
    original_name: []const u8,
    name: []const u8,
    kind: []const u8,
    description: []const u8,
    gh_org: []const u8,
    gh_repo: []const u8,
    gh_release: []const u8,
    gh_asset: []const u8,
    drive_fpath: []const u8,
    has_error: bool,
    error_message: []const u8,
};

fn datamarkSourcesList(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);

    try renderDatamarkSourcesList(r, s, null, "");
}

fn datamarkSourcesForm(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);

    r.parseQuery();

    const maybe_name = try r.getParamStr(s.arena.allocator(), "name");
    const name = if (maybe_name) |n| n else "";

    if (name.len > 0) {
        const source = try loadDatamarkSourceForm(s, name) orelse {
            try renderDatamarkSourcesList(r, s, "Fuente Datamark no encontrada.", "alert-error");
            return;
        };
        try renderDatamarkSourceForm(r, source);
        return;
    }

    try renderDatamarkSourceForm(r, newDatamarkSourceForm(null));
}

fn datamarkSourcesSave(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .POST) return methodNotAllowed(r);

    try r.parseBody();
    r.parseQuery();

    const original_name = try r.getParamStr(s.arena.allocator(), "original_name") orelse "";
    const raw_name = try r.getParamStr(s.arena.allocator(), "name") orelse "";
    const raw_kind = try r.getParamStr(s.arena.allocator(), "kind") orelse "";
    const raw_description = try r.getParamStr(s.arena.allocator(), "description") orelse "";
    const raw_gh_org = try r.getParamStr(s.arena.allocator(), "gh_org") orelse "";
    const raw_gh_repo = try r.getParamStr(s.arena.allocator(), "gh_repo") orelse "";
    const raw_gh_release = try r.getParamStr(s.arena.allocator(), "gh_release") orelse "";
    const raw_gh_asset = try r.getParamStr(s.arena.allocator(), "gh_asset") orelse "";
    const raw_drive_fpath = try r.getParamStr(s.arena.allocator(), "drive_fpath") orelse "";

    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    const kind = std.mem.trim(u8, raw_kind, " \t\r\n");
    const description = std.mem.trim(u8, raw_description, " \t\r\n");
    const gh_org = std.mem.trim(u8, raw_gh_org, " \t\r\n");
    const gh_repo = std.mem.trim(u8, raw_gh_repo, " \t\r\n");
    const gh_release = std.mem.trim(u8, raw_gh_release, " \t\r\n");
    const gh_asset = std.mem.trim(u8, raw_gh_asset, " \t\r\n");
    const drive_fpath = std.mem.trim(u8, raw_drive_fpath, " \t\r\n");

    if (name.len == 0) {
        try renderDatamarkSourceForm(r, sourceFormFromValues(original_name, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath, "El nombre es obligatorio."));
        return;
    }
    if (!std.mem.eql(u8, kind, "github") and !std.mem.eql(u8, kind, "drive")) {
        try renderDatamarkSourceForm(r, sourceFormFromValues(original_name, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath, "El tipo debe ser github o drive."));
        return;
    }
    if (std.mem.eql(u8, kind, "github") and (gh_org.len == 0 or gh_repo.len == 0 or gh_release.len == 0 or gh_asset.len == 0)) {
        try renderDatamarkSourceForm(r, sourceFormFromValues(original_name, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath, "Todos los campos de GitHub son obligatorios."));
        return;
    }
    if (std.mem.eql(u8, kind, "drive") and drive_fpath.len == 0) {
        try renderDatamarkSourceForm(r, sourceFormFromValues(original_name, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath, "La ruta del archivo de Drive es obligatoria."));
        return;
    }

    const form = sourceFormFromValues(original_name, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath, null);

    if (original_name.len == 0) {
        insertDatamarkSource(s.db, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath) catch |err| {
            const message = if (err == error.Constraint) "Ya existe una fuente Datamark con ese nombre." else "No se pudo guardar la fuente Datamark.";
            try renderDatamarkSourceForm(r, sourceFormWithError(form, message));
            return;
        };
    } else {
        updateDatamarkSource(s.db, original_name, name, kind, description, gh_org, gh_repo, gh_release, gh_asset, drive_fpath) catch |err| {
            const message = switch (err) {
                error.Constraint => "Ya existe una fuente Datamark con ese nombre.",
                error.NotFound => "Fuente Datamark no encontrada.",
                else => "No se pudo guardar la fuente Datamark.",
            };
            try renderDatamarkSourceForm(r, sourceFormWithError(form, message));
            return;
        };
    }

    try r.setHeader("HX-Push-Url", "?t=datamark-sources");
    try renderDatamarkSourcesList(r, s, "Fuente Datamark guardada.", "alert-success");
}

fn datamarkSourcesRemove(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .POST) return methodNotAllowed(r);

    try r.parseBody();
    r.parseQuery();

    const name = try r.getParamStr(s.arena.allocator(), "name") orelse {
        try renderDatamarkSourcesList(r, s, "El nombre es obligatorio.", "alert-error");
        return;
    };

    if (name.len == 0) {
        try renderDatamarkSourcesList(r, s, "El nombre es obligatorio.", "alert-error");
        return;
    }

    deleteDatamarkSource(s.db, name) catch {
        try renderDatamarkSourcesList(r, s, "No se pudo eliminar la fuente Datamark.", "alert-error");
        return;
    };

    try renderDatamarkSourcesList(r, s, "Fuente Datamark eliminada.", "alert-success");
}

fn renderDatamarkSourcesList(
    r: zap.Request,
    s: uboard.core.http.Scope,
    message: ?[]const u8,
    message_class: []const u8,
) !void {
    const sql =
        \\SELECT name, kind, description
        \\FROM datamark_source
        \\ORDER BY name ASC
    ;

    const stmt = try prepareStatement(s.db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    const alloc = s.arena.allocator();
    var sources: std.ArrayList(DatamarkSource) = .{};
    defer sources.deinit(alloc);

    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;

        const name = try alloc.dupe(u8, columnText(stmt, 0));
        const kind = try alloc.dupe(u8, columnText(stmt, 1));
        const description = try alloc.dupe(u8, columnText(stmt, 2));
        const url_name = try queryComponentEncode(alloc, name);

        try sources.append(alloc, .{
            .name = name,
            .kind = kind,
            .description = description,
            .url_name = url_name,
        });
    }

    try uboard.shortcuts.renderWith(r, datamarkSourcesListTemplate, .{
        .sources = sources.items,
        .has_sources = sources.items.len > 0,
        .has_message = message != null,
        .message = message orelse "",
        .message_class = message_class,
    });
}

fn renderDatamarkSourceForm(r: zap.Request, data: DatamarkSourceForm) !void {
    try uboard.shortcuts.renderWith(r, datamarkSourcesFormTemplate, data);
}

fn loadDatamarkSourceForm(s: uboard.core.http.Scope, name: []const u8) !?DatamarkSourceForm {
    const sql =
        \\SELECT ds.name, ds.kind, ds.description,
        \\  COALESCE(gh.org, ''), COALESCE(gh.repo, ''),
        \\  COALESCE(gh.release, ''), COALESCE(gh.asset, ''),
        \\  COALESCE(dr.fpath, '')
        \\FROM datamark_source ds
        \\LEFT JOIN datamark_source_github gh ON gh.source_id = ds.id
        \\LEFT JOIN datamark_source_drive dr ON dr.source_id = ds.id
        \\WHERE ds.name = ?
        \\LIMIT 1
    ;

    const stmt = try prepareStatement(s.db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);

    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;

    return .{
        .title = "Editar fuente Datamark",
        .submit_label = "Guardar",
        .original_name = try s.arena.allocator().dupe(u8, columnText(stmt, 0)),
        .name = try s.arena.allocator().dupe(u8, columnText(stmt, 0)),
        .kind = try s.arena.allocator().dupe(u8, columnText(stmt, 1)),
        .description = try s.arena.allocator().dupe(u8, columnText(stmt, 2)),
        .gh_org = try s.arena.allocator().dupe(u8, columnText(stmt, 3)),
        .gh_repo = try s.arena.allocator().dupe(u8, columnText(stmt, 4)),
        .gh_release = try s.arena.allocator().dupe(u8, columnText(stmt, 5)),
        .gh_asset = try s.arena.allocator().dupe(u8, columnText(stmt, 6)),
        .drive_fpath = try s.arena.allocator().dupe(u8, columnText(stmt, 7)),
        .has_error = false,
        .error_message = "",
    };
}

fn newDatamarkSourceForm(message: ?[]const u8) DatamarkSourceForm {
    return .{
        .title = "Nueva fuente Datamark",
        .submit_label = "Crear",
        .original_name = "",
        .name = "",
        .kind = "github",
        .description = "",
        .gh_org = "",
        .gh_repo = "",
        .gh_release = "",
        .gh_asset = "",
        .drive_fpath = "",
        .has_error = message != null,
        .error_message = message orelse "",
    };
}

fn sourceFormFromValues(
    original_name: []const u8,
    name: []const u8,
    kind: []const u8,
    description: []const u8,
    gh_org: []const u8,
    gh_repo: []const u8,
    gh_release: []const u8,
    gh_asset: []const u8,
    drive_fpath: []const u8,
    message: ?[]const u8,
) DatamarkSourceForm {
    return .{
        .title = if (original_name.len == 0) "Nueva fuente Datamark" else "Editar fuente Datamark",
        .submit_label = if (original_name.len == 0) "Crear" else "Guardar",
        .original_name = original_name,
        .name = name,
        .kind = kind,
        .description = description,
        .gh_org = gh_org,
        .gh_repo = gh_repo,
        .gh_release = gh_release,
        .gh_asset = gh_asset,
        .drive_fpath = drive_fpath,
        .has_error = message != null,
        .error_message = message orelse "",
    };
}

fn sourceFormWithError(form: DatamarkSourceForm, message: []const u8) DatamarkSourceForm {
    return .{
        .title = form.title,
        .submit_label = form.submit_label,
        .original_name = form.original_name,
        .name = form.name,
        .kind = form.kind,
        .description = form.description,
        .gh_org = form.gh_org,
        .gh_repo = form.gh_repo,
        .gh_release = form.gh_release,
        .gh_asset = form.gh_asset,
        .drive_fpath = form.drive_fpath,
        .has_error = true,
        .error_message = message,
    };
}

fn insertDatamarkSource(
    db: *sqlite.sqlite3,
    name: []const u8,
    kind: []const u8,
    description: []const u8,
    gh_org: []const u8,
    gh_repo: []const u8,
    gh_release: []const u8,
    gh_asset: []const u8,
    drive_fpath: []const u8,
) !void {
    const base_sql = "INSERT INTO datamark_source (kind, name, description) VALUES (?, ?, ?)";
    const base_stmt = try prepareStatement(db, base_sql);
    defer _ = sqlite.sqlite3_finalize(base_stmt);
    try bindText(base_stmt, 1, kind);
    try bindText(base_stmt, 2, name);
    try bindText(base_stmt, 3, description);
    try stepDone(db, base_stmt);

    const source_id = sqlite.sqlite3_last_insert_rowid(db);

    if (std.mem.eql(u8, kind, "github")) {
        const gh_sql = "INSERT INTO datamark_source_github (source_id, org, repo, release, asset) VALUES (?, ?, ?, ?, ?)";
        const gh_stmt = try prepareStatement(db, gh_sql);
        defer _ = sqlite.sqlite3_finalize(gh_stmt);
        try bindInt64(gh_stmt, 1, source_id);
        try bindText(gh_stmt, 2, gh_org);
        try bindText(gh_stmt, 3, gh_repo);
        try bindText(gh_stmt, 4, gh_release);
        try bindText(gh_stmt, 5, gh_asset);
        try stepDone(db, gh_stmt);
    } else {
        const dr_sql = "INSERT INTO datamark_source_drive (source_id, fpath) VALUES (?, ?)";
        const dr_stmt = try prepareStatement(db, dr_sql);
        defer _ = sqlite.sqlite3_finalize(dr_stmt);
        try bindInt64(dr_stmt, 1, source_id);
        try bindText(dr_stmt, 2, drive_fpath);
        try stepDone(db, dr_stmt);
    }
}

fn updateDatamarkSource(
    db: *sqlite.sqlite3,
    original_name: []const u8,
    name: []const u8,
    kind: []const u8,
    description: []const u8,
    gh_org: []const u8,
    gh_repo: []const u8,
    gh_release: []const u8,
    gh_asset: []const u8,
    drive_fpath: []const u8,
) !void {
    const source_id = try getDatamarkSourceId(db, original_name) orelse return error.NotFound;

    const update_sql = "UPDATE datamark_source SET name = ?, kind = ?, description = ? WHERE id = ?";
    const update_stmt = try prepareStatement(db, update_sql);
    defer _ = sqlite.sqlite3_finalize(update_stmt);
    try bindText(update_stmt, 1, name);
    try bindText(update_stmt, 2, kind);
    try bindText(update_stmt, 3, description);
    try bindInt64(update_stmt, 4, source_id);
    try stepDone(db, update_stmt);

    // Replace variant rows (handles kind changes)
    const del_gh = "DELETE FROM datamark_source_github WHERE source_id = ?";
    const del_gh_stmt = try prepareStatement(db, del_gh);
    defer _ = sqlite.sqlite3_finalize(del_gh_stmt);
    try bindInt64(del_gh_stmt, 1, source_id);
    try stepDone(db, del_gh_stmt);

    const del_dr = "DELETE FROM datamark_source_drive WHERE source_id = ?";
    const del_dr_stmt = try prepareStatement(db, del_dr);
    defer _ = sqlite.sqlite3_finalize(del_dr_stmt);
    try bindInt64(del_dr_stmt, 1, source_id);
    try stepDone(db, del_dr_stmt);

    if (std.mem.eql(u8, kind, "github")) {
        const gh_sql = "INSERT INTO datamark_source_github (source_id, org, repo, release, asset) VALUES (?, ?, ?, ?, ?)";
        const gh_stmt = try prepareStatement(db, gh_sql);
        defer _ = sqlite.sqlite3_finalize(gh_stmt);
        try bindInt64(gh_stmt, 1, source_id);
        try bindText(gh_stmt, 2, gh_org);
        try bindText(gh_stmt, 3, gh_repo);
        try bindText(gh_stmt, 4, gh_release);
        try bindText(gh_stmt, 5, gh_asset);
        try stepDone(db, gh_stmt);
    } else {
        const dr_sql = "INSERT INTO datamark_source_drive (source_id, fpath) VALUES (?, ?)";
        const dr_stmt = try prepareStatement(db, dr_sql);
        defer _ = sqlite.sqlite3_finalize(dr_stmt);
        try bindInt64(dr_stmt, 1, source_id);
        try bindText(dr_stmt, 2, drive_fpath);
        try stepDone(db, dr_stmt);
    }
}

fn deleteDatamarkSource(db: *sqlite.sqlite3, name: []const u8) !void {
    const sql = "DELETE FROM datamark_source WHERE name = ?";

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);
    try stepDone(db, stmt);
}

fn getDatamarkSourceId(db: *sqlite.sqlite3, name: []const u8) !?i64 {
    const sql = "SELECT id FROM datamark_source WHERE name = ? LIMIT 1";

    const stmt = try prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    try bindText(stmt, 1, name);

    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;
    return sqlite.sqlite3_column_int64(stmt, 0);
}

// ── Datamark Reports ──────────────────────────────────────────────────────────

fn datamarkReportsList(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);

    const alloc = s.arena.allocator();

    const sql = "SELECT name FROM datamark_source ORDER BY name ASC";
    const stmt = try prepareStatement(s.db, sql);
    defer _ = sqlite.sqlite3_finalize(stmt);

    const SourceItem = struct { name: []const u8, url_name: []const u8 };
    var sources: std.ArrayList(SourceItem) = .{};
    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;
        const name = try alloc.dupe(u8, columnText(stmt, 0));
        try sources.append(alloc, .{
            .name = name,
            .url_name = try queryComponentEncode(alloc, name),
        });
    }

    try uboard.shortcuts.renderWith(r, datamarkReportsListTemplate, .{
        .sources = sources.items,
        .has_sources = sources.items.len > 0,
    });
}

fn datamarkReportsRun(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);
    r.parseQuery();

    const alloc = s.arena.allocator();

    const source_name = try r.getParamStr(alloc, "source") orelse {
        try datamarkReportsList(r, s);
        return;
    };
    const source_url_name = try queryComponentEncode(alloc, source_name);

    const view_sql =
        \\SELECT dv.name
        \\FROM datamark_view dv
        \\JOIN datamark_source ds ON ds.id = dv.source_id
        \\WHERE ds.name = ?
        \\ORDER BY dv.name ASC
    ;
    const view_stmt = try prepareStatement(s.db, view_sql);
    defer _ = sqlite.sqlite3_finalize(view_stmt);
    try bindText(view_stmt, 1, source_name);

    const ViewItem = struct { name: []const u8, url_name: []const u8, source_url_name: []const u8 };
    var views: std.ArrayList(ViewItem) = .{};
    while (true) {
        const rc = sqlite.sqlite3_step(view_stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;
        const name = try alloc.dupe(u8, columnText(view_stmt, 0));
        try views.append(alloc, .{
            .name = name,
            .url_name = try queryComponentEncode(alloc, name),
            .source_url_name = source_url_name,
        });
    }

    try uboard.shortcuts.renderWith(r, datamarkReportsRunTemplate, .{
        .source_name = source_name,
        .views = views.items,
        .has_views = views.items.len > 0,
    });
}

const ReportColumn = reports.ReportColumn;
const ReportRow = reports.ReportRow;

const DatamarkReportPayload = struct {
    source_name: []const u8,
    source_url_name: []const u8,
    view_name: []const u8,
    view_url_name: []const u8,
    has_error: bool,
    error_message: []const u8,
    columns: []const ReportColumn,
    rows: []const ReportRow,
    has_rows: bool,
    filter_views: []const reports.ReportFilterColumnView,
    active_filters: []const reports.ReportActiveFilter,
    has_active_filters: bool,
    row_count_label: []const u8,
    no_rows_message: []const u8,
};

fn loadDatamarkReport(r: zap.Request, s: uboard.core.http.Scope) !DatamarkReportPayload {
    const alloc = s.arena.allocator();
    const empty_columns = @as([]const ReportColumn, &.{});
    const empty_rows = @as([]const ReportRow, &.{});
    const empty_filter_views = @as([]const reports.ReportFilterColumnView, &.{});
    const empty_active_filters = @as([]const reports.ReportActiveFilter, &.{});

    const source_name = try r.getParamStr(alloc, "source") orelse return error.MissingSource;
    const view_name = try r.getParamStr(alloc, "view") orelse return error.MissingView;
    const source_url_name = try queryComponentEncode(alloc, source_name);
    const view_url_name = try queryComponentEncode(alloc, view_name);

    const base = DatamarkReportPayload{
        .source_name = source_name,
        .source_url_name = source_url_name,
        .view_name = view_name,
        .view_url_name = view_url_name,
        .has_error = false,
        .error_message = "",
        .columns = empty_columns,
        .rows = empty_rows,
        .has_rows = false,
        .filter_views = empty_filter_views,
        .active_filters = empty_active_filters,
        .has_active_filters = false,
        .row_count_label = "",
        .no_rows_message = "",
    };

    const query_sql =
        \\SELECT dv.query
        \\FROM datamark_view dv
        \\JOIN datamark_source ds ON ds.id = dv.source_id
        \\WHERE ds.name = ?
        \\  AND dv.name = ?
        \\LIMIT 1
    ;
    const query_stmt = try prepareStatement(s.db, query_sql);
    defer _ = sqlite.sqlite3_finalize(query_stmt);
    try bindText(query_stmt, 1, source_name);
    try bindText(query_stmt, 2, view_name);

    const rc = sqlite.sqlite3_step(query_stmt);
    if (rc == sqlite.SQLITE_DONE) {
        return .{
            .source_name = base.source_name,
            .source_url_name = base.source_url_name,
            .view_name = base.view_name,
            .view_url_name = base.view_url_name,
            .has_error = true,
            .error_message = "Vista no encontrada.",
            .columns = empty_columns,
            .rows = empty_rows,
            .has_rows = false,
            .filter_views = empty_filter_views,
            .active_filters = empty_active_filters,
            .has_active_filters = false,
            .row_count_label = "",
            .no_rows_message = "",
        };
    }
    if (rc != sqlite.SQLITE_ROW) return error.DatabaseError;
    const raw_query = try alloc.dupe(u8, columnText(query_stmt, 0));

    const duckdb_path = "data/dmark.db";
    var duck_db: ddb.duckdb_database = null;
    var duck_conn: ddb.duckdb_connection = null;
    const duckdb_opened = ddb.duckdb_open(duckdb_path, &duck_db) != ddb.DuckDBError;
    defer if (duckdb_opened) ddb.duckdb_close(&duck_db);
    if (duckdb_opened) {
        _ = ddb.duckdb_connect(duck_db, &duck_conn);
    }
    defer if (duck_conn != null) ddb.duckdb_disconnect(&duck_conn);

    if (duck_conn == null) {
        return .{
            .source_name = base.source_name,
            .source_url_name = base.source_url_name,
            .view_name = base.view_name,
            .view_url_name = base.view_url_name,
            .has_error = true,
            .error_message = "DuckDB no está disponible en data/dmark.db",
            .columns = empty_columns,
            .rows = empty_rows,
            .has_rows = false,
            .filter_views = empty_filter_views,
            .active_filters = empty_active_filters,
            .has_active_filters = false,
            .row_count_label = "",
            .no_rows_message = "",
        };
    }

    const filter_columns = try reports.probeReportColumns(duck_conn, raw_query, alloc);
    try reports.parseFilterParams(r, filter_columns, alloc);

    const filtered_query = try reports.buildFilteredQuery(alloc, raw_query, filter_columns);
    const query_z = try alloc.dupeZ(u8, filtered_query);
    var result: ddb.duckdb_result = undefined;
    if (ddb.duckdb_query(duck_conn, query_z.ptr, &result) == ddb.DuckDBError) {
        defer ddb.duckdb_destroy_result(&result);
        const err_ptr = ddb.duckdb_result_error(&result);
        const err_msg = if (err_ptr != null)
            try alloc.dupe(u8, std.mem.span(err_ptr))
        else
            "La consulta falló.";
        return .{
            .source_name = base.source_name,
            .source_url_name = base.source_url_name,
            .view_name = base.view_name,
            .view_url_name = base.view_url_name,
            .has_error = true,
            .error_message = err_msg,
            .columns = empty_columns,
            .rows = empty_rows,
            .has_rows = false,
            .filter_views = empty_filter_views,
            .active_filters = empty_active_filters,
            .has_active_filters = false,
            .row_count_label = "",
            .no_rows_message = "",
        };
    }
    defer ddb.duckdb_destroy_result(&result);

    const report_data = try reports.extractReportData(&result, alloc);
    const filter_views = try reports.buildFilterColumnViews(filter_columns, alloc);
    const active_filters = try reports.buildActiveFilters(filter_columns, alloc);

    const has_active_filters = active_filters.len > 0;
    const row_count_label = if (report_data.row_count >= reports.report_row_limit)
        try std.fmt.allocPrint(alloc, "{d} filas (límite alcanzado)", .{report_data.row_count})
    else
        try std.fmt.allocPrint(alloc, "{d} fila{s}", .{
            report_data.row_count,
            if (report_data.row_count == 1) "" else "s",
        });
    const no_rows_message = if (has_active_filters)
        "Ninguna fila coincide con los filtros"
    else
        "Sin datos";

    return .{
        .source_name = base.source_name,
        .source_url_name = base.source_url_name,
        .view_name = base.view_name,
        .view_url_name = base.view_url_name,
        .has_error = false,
        .error_message = "",
        .columns = report_data.columns,
        .rows = report_data.rows,
        .has_rows = report_data.row_count > 0,
        .filter_views = filter_views,
        .active_filters = active_filters,
        .has_active_filters = has_active_filters,
        .row_count_label = row_count_label,
        .no_rows_message = no_rows_message,
    };
}

fn buildExportB64(alloc: std.mem.Allocator, payload: DatamarkReportPayload) ![]const u8 {
    if (payload.has_error or !payload.has_rows) return alloc.dupe(u8, "");
    const json = try reports.serializeReportExportJson(alloc, payload.columns, payload.rows);
    defer alloc.free(json);
    const out_len = std.base64.standard.Encoder.calcSize(json.len);
    const buf = try alloc.alloc(u8, out_len);
    const encoded = std.base64.standard.Encoder.encode(buf, json);
    return try alloc.dupe(u8, encoded);
}

fn renderDatamarkReportTable(r: zap.Request, alloc: std.mem.Allocator, payload: DatamarkReportPayload) !void {
    const export_b64 = try buildExportB64(alloc, payload);
    try uboard.shortcuts.renderWith(r, datamarkReportsTableTemplate, .{
        .has_error = payload.has_error,
        .error_message = payload.error_message,
        .columns = payload.columns,
        .rows = payload.rows,
        .has_rows = payload.has_rows,
        .active_filters = payload.active_filters,
        .has_active_filters = payload.has_active_filters,
        .row_count_label = payload.row_count_label,
        .no_rows_message = payload.no_rows_message,
        .has_export_data = payload.has_rows and !payload.has_error,
        .export_b64 = export_b64,
    });
}

fn datamarkReportsResult(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);
    r.parseQuery();

    const payload = loadDatamarkReport(r, s) catch |err| switch (err) {
        error.MissingSource => {
            try datamarkReportsList(r, s);
            return;
        },
        error.MissingView => {
            try datamarkReportsRun(r, s);
            return;
        },
        else => |e| return e,
    };

    const alloc = s.arena.allocator();
    const export_b64 = try buildExportB64(alloc, payload);
    try uboard.shortcuts.renderWith(r, datamarkReportsResultTemplate, .{
        .source_name = payload.source_name,
        .source_url_name = payload.source_url_name,
        .view_name = payload.view_name,
        .view_url_name = payload.view_url_name,
        .has_error = payload.has_error,
        .error_message = payload.error_message,
        .columns = payload.columns,
        .rows = payload.rows,
        .has_rows = payload.has_rows,
        .filter_columns = payload.filter_views,
        .has_filter_columns = payload.filter_views.len > 0,
        .active_filters = payload.active_filters,
        .has_active_filters = payload.has_active_filters,
        .row_count_label = payload.row_count_label,
        .no_rows_message = payload.no_rows_message,
        .has_export_data = payload.has_rows and !payload.has_error,
        .export_b64 = export_b64,
    });
}

fn datamarkReportsTable(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (r.methodAsEnum() != .GET) return methodNotAllowed(r);
    r.parseQuery();

    const alloc = s.arena.allocator();
    const payload = loadDatamarkReport(r, s) catch |err| switch (err) {
        error.MissingSource, error.MissingView => {
            r.setStatus(.bad_request);
            try r.sendBody("fuente y vista son obligatorias");
            return;
        },
        else => |e| return e,
    };

    const push_url = try buildReportPushUrl(alloc, payload.source_url_name, payload.view_url_name, payload.filter_views);
    try r.setHeader("HX-Push-Url", push_url);

    try renderDatamarkReportTable(r, alloc, payload);
}

fn buildReportPushUrl(
    alloc: std.mem.Allocator,
    source_url_name: []const u8,
    view_url_name: []const u8,
    filter_views: []const reports.ReportFilterColumnView,
) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    try out.appendSlice(alloc, "?t=datamark-reports&source=");
    try out.appendSlice(alloc, source_url_name);
    try out.appendSlice(alloc, "&view=");
    try out.appendSlice(alloc, view_url_name);

    for (filter_views) |col| {
        const op_key = try std.fmt.allocPrint(alloc, "f{s}_op", .{col.index_str});
        defer alloc.free(op_key);
        const v0_key = try std.fmt.allocPrint(alloc, "f{s}_v0", .{col.index_str});
        defer alloc.free(v0_key);
        const v1_key = try std.fmt.allocPrint(alloc, "f{s}_v1", .{col.index_str});
        defer alloc.free(v1_key);

        const op_encoded = try queryComponentEncode(alloc, col.op);
        defer alloc.free(op_encoded);
        try out.appendSlice(alloc, "&");
        try out.appendSlice(alloc, op_key);
        try out.appendSlice(alloc, "=");
        try out.appendSlice(alloc, op_encoded);

        if (col.v0.len > 0) {
            const v0_encoded = try queryComponentEncode(alloc, col.v0);
            defer alloc.free(v0_encoded);
            try out.appendSlice(alloc, "&");
            try out.appendSlice(alloc, v0_key);
            try out.appendSlice(alloc, "=");
            try out.appendSlice(alloc, v0_encoded);
        }

        if (col.v1.len > 0) {
            const v1_encoded = try queryComponentEncode(alloc, col.v1);
            defer alloc.free(v1_encoded);
            try out.appendSlice(alloc, "&");
            try out.appendSlice(alloc, v1_key);
            try out.appendSlice(alloc, "=");
            try out.appendSlice(alloc, v1_encoded);
        }
    }

    return try out.toOwnedSlice(alloc);
}

// ── Shared SQLite helpers ──────────────────────────────────────────────────────

fn prepareStatement(db: *sqlite.sqlite3, sql: []const u8) !*sqlite.sqlite3_stmt {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != sqlite.SQLITE_OK) {
        std.debug.print("failed to prepare statement: {s}\n", .{std.mem.span(sqlite.sqlite3_errmsg(db))});
        return error.DatabaseError;
    }

    return stmt.?;
}

fn bindText(stmt: *sqlite.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (sqlite.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != sqlite.SQLITE_OK) {
        return error.DatabaseError;
    }
}

fn bindInt64(stmt: *sqlite.sqlite3_stmt, index: c_int, value: i64) !void {
    if (sqlite.sqlite3_bind_int64(stmt, index, value) != sqlite.SQLITE_OK) {
        return error.DatabaseError;
    }
}

fn stepDone(db: *sqlite.sqlite3, stmt: *sqlite.sqlite3_stmt) !void {
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return;
    if (rc == sqlite.SQLITE_CONSTRAINT) return error.Constraint;

    std.debug.print("failed to execute statement: {s}\n", .{std.mem.span(sqlite.sqlite3_errmsg(db))});
    return error.DatabaseError;
}

fn columnText(stmt: *sqlite.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = sqlite.sqlite3_column_text(stmt, index);
    const len = sqlite.sqlite3_column_bytes(stmt, index);
    if (ptr == null) return "";
    return ptr[0..@intCast(len)];
}

fn queryComponentEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .{};

    const hex = "0123456789ABCDEF";
    for (input) |char| {
        if (isQueryComponentChar(char)) {
            try out.append(allocator, char);
            continue;
        }

        try out.append(allocator, '%');
        try out.append(allocator, hex[char >> 4]);
        try out.append(allocator, hex[char & 0x0F]);
    }

    return try out.toOwnedSlice(allocator);
}

fn isQueryComponentChar(char: u8) bool {
    return (char >= 'A' and char <= 'Z') or
        (char >= 'a' and char <= 'z') or
        (char >= '0' and char <= '9') or
        char == '-' or
        char == '_' or
        char == '.' or
        char == '~';
}

fn methodNotAllowed(r: zap.Request) !void {
    r.setStatus(.method_not_allowed);
    try r.sendBody("método no permitido");
}
