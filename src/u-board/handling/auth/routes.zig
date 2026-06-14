const std = @import("std");

const uboard = @import("u-board");
const Context = uboard.core.context.Context;
const zap = @import("zap");

const securing = @import("securing.zig");
const utils = @import("utils.zig");

const signInTemplate = @embedFile("template/signin.html");
const appSignInTemplate = @embedFile("template/app/signin.html");

pub fn register(router: *zap.Router, ctx: *Context) !void {
    try uboard.core.http.Middleware(.{}, uboard.core.http.getPost(signInGet, signInPost)).register(router, "/u-board/auth/signin", ctx);
    try uboard.core.http.Middleware(.{}, signOut).register(router, "/u-board/auth/signout", ctx);
    try uboard.core.http.Middleware(.{}, appSignInGet).register(router, "/u-board/auth/app/signin", ctx);
    try uboard.core.http.Middleware(.{}, appValidatePost).register(router, "/u-board/auth/app/validate", ctx);
}

fn signInGet(r: zap.Request, _: uboard.core.http.Scope) !void {
    try signInPage(r, .{ .error_message = null });
}

fn appSignInGet(r: zap.Request, scope: uboard.core.http.Scope) !void {
    const allocator = scope.arena.allocator();

    const dbc = uboard.core.db.c;
    const sql = "SELECT client_id, tenant_id FROM auth_app_provider ORDER BY rowid DESC LIMIT 1";
    var stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(scope.db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
        return appSignInPage(r, .{
            .error_message = "El inicio de sesión con O365 no está configurado en este servidor.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    }
    defer _ = dbc.sqlite3_finalize(stmt.?);

    if (dbc.sqlite3_step(stmt.?) != dbc.SQLITE_ROW) {
        return appSignInPage(r, .{
            .error_message = "El inicio de sesión con O365 no está configurado en este servidor.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    }

    const client_id_ptr = dbc.sqlite3_column_text(stmt.?, 0);
    const client_id_len: usize = @intCast(dbc.sqlite3_column_bytes(stmt.?, 0));
    const client_id = try allocator.dupe(u8, client_id_ptr[0..client_id_len]);

    const tenant_id_ptr = dbc.sqlite3_column_text(stmt.?, 1);
    const tenant_id_len: usize = @intCast(dbc.sqlite3_column_bytes(stmt.?, 1));
    const tenant_id = try allocator.dupe(u8, tenant_id_ptr[0..tenant_id_len]);

    const url = try std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/devicecode",
        .{tenant_id},
    );
    const body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&scope=openid+profile+User.Read",
        .{client_id},
    );

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(allocator);

    const fetch_result = http_client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .payload = body,
        .response_writer = &response_writer.writer,
    }) catch {
        return appSignInPage(r, .{
            .error_message = "No se pudo contactar a Microsoft. Inténtalo de nuevo.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    };

    if (fetch_result.status != .ok) {
        return appSignInPage(r, .{
            .error_message = "Microsoft devolvió un error. Inténtalo de nuevo.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    }

    const response_data = response_writer.writer.buffer[0..response_writer.writer.end];
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_data, .{}) catch {
        return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const user_code_val = obj.get("user_code") orelse {
        return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    };
    const user_code = switch (user_code_val) {
        .string => |s| s,
        else => return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
        }),
    };

    const verification_uri_val = obj.get("verification_uri") orelse {
        return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    };
    const verification_uri = switch (verification_uri_val) {
        .string => |s| s,
        else => return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        }),
    };

    const device_code_val = obj.get("device_code") orelse {
        return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        });
    };
    const device_code = switch (device_code_val) {
        .string => |s| s,
        else => return appSignInPage(r, .{
            .error_message = "Respuesta inesperada de Microsoft.",
            .user_code = null,
            .verification_uri = null,
            .device_code = null,
        }),
    };

    try appSignInPage(r, .{
        .error_message = null,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .device_code = device_code,
    });
}

fn jwtStringClaim(allocator: std.mem.Allocator, token: []const u8, claim: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next();
    const payload_b64 = parts.next() orelse return error.InvalidToken;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidToken;
    const decoded = try allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, payload_b64) catch return error.InvalidToken;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return error.InvalidToken;
    defer parsed.deinit();

    const val = parsed.value.object.get(claim) orelse return error.ClaimNotFound;
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.ClaimNotString,
    };
}

fn dupeTextColumn(allocator: std.mem.Allocator, stmt: anytype, col: c_int) ![]u8 {
    const dbc = uboard.core.db.c;
    const ptr = dbc.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(dbc.sqlite3_column_bytes(stmt, col));
    return allocator.dupe(u8, ptr[0..len]);
}

fn appValidatePost(r: zap.Request, scope: uboard.core.http.Scope) !void {
    const allocator = scope.arena.allocator();

    try r.parseBody();
    r.parseQuery();

    const device_code = try r.getParamStr(allocator, "device_code") orelse {
        r.setStatus(.bad_request);
        try r.sendBody("{\"status\":\"error\",\"message\":\"Falta device_code\"}");
        return;
    };

    const dbc = uboard.core.db.c;
    const prov_sql = "SELECT client_id, client_secret, tenant_id FROM auth_app_provider ORDER BY rowid DESC LIMIT 1";
    var prov_stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(scope.db, prov_sql, -1, &prov_stmt, null) != dbc.SQLITE_OK) {
        r.setStatus(.internal_server_error);
        try r.sendBody("{\"status\":\"error\",\"message\":\"Error de base de datos\"}");
        return;
    }
    defer _ = dbc.sqlite3_finalize(prov_stmt.?);

    if (dbc.sqlite3_step(prov_stmt.?) != dbc.SQLITE_ROW) {
        r.setStatus(.internal_server_error);
        try r.sendBody("{\"status\":\"error\",\"message\":\"Proveedor no configurado\"}");
        return;
    }

    const client_id = try dupeTextColumn(allocator, prov_stmt.?, 0);
    const client_secret = try dupeTextColumn(allocator, prov_stmt.?, 1);
    const tenant_id = try dupeTextColumn(allocator, prov_stmt.?, 2);

    const url = try std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/token",
        .{tenant_id},
    );
    const body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&client_secret={s}&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code={s}",
        .{ client_id, client_secret, device_code },
    );

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var rw = std.Io.Writer.Allocating.init(allocator);

    _ = http_client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .payload = body,
        .response_writer = &rw.writer,
    }) catch {
        r.setStatus(.internal_server_error);
        try r.sendBody("{\"status\":\"error\",\"message\":\"No se pudo contactar a Microsoft\"}");
        return;
    };

    const response_data = rw.writer.buffer[0..rw.writer.end];
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_data, .{}) catch {
        r.setStatus(.internal_server_error);
        try r.sendBody("{\"status\":\"error\",\"message\":\"Respuesta inesperada de Microsoft\"}");
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    if (obj.get("error")) |err_val| {
        if (err_val == .string) {
            const code = err_val.string;
            if (std.mem.eql(u8, code, "authorization_pending") or std.mem.eql(u8, code, "slow_down")) {
                try r.sendBody("{\"status\":\"pending\"}");
                return;
            }
            const resp = try std.fmt.allocPrint(
                allocator,
                "{{\"status\":\"error\",\"message\":\"Error de inicio de sesión: {s}\"}}",
                .{code},
            );
            try r.sendBody(resp);
            return;
        }
    }

    const token_for_claims: []const u8 = blk: {
        if (obj.get("id_token")) |t| if (t == .string) break :blk t.string;
        const at = obj.get("access_token") orelse {
            try r.sendBody("{\"status\":\"pending\"}");
            return;
        };
        break :blk switch (at) {
            .string => |s| s,
            else => {
                try r.sendBody("{\"status\":\"pending\"}");
                return;
            },
        };
    };

    const username = jwtStringClaim(allocator, token_for_claims, "preferred_username") catch
        jwtStringClaim(allocator, token_for_claims, "upn") catch {
        try r.sendBody("{\"status\":\"error\",\"message\":\"No se pudo determinar la identidad del usuario\"}");
        return;
    };

    const user_sql = "SELECT username FROM auth_user WHERE username = ? LIMIT 1";
    var user_stmt: ?*dbc.sqlite3_stmt = null;
    if (dbc.sqlite3_prepare_v2(scope.db, user_sql, -1, &user_stmt, null) != dbc.SQLITE_OK) {
        try r.sendBody("{\"status\":\"error\",\"message\":\"Error de base de datos\"}");
        return;
    }
    defer _ = dbc.sqlite3_finalize(user_stmt.?);

    if (dbc.sqlite3_bind_text(user_stmt.?, 1, username.ptr, @intCast(username.len), null) != dbc.SQLITE_OK) {
        try r.sendBody("{\"status\":\"error\",\"message\":\"Error de base de datos\"}");
        return;
    }

    if (dbc.sqlite3_step(user_stmt.?) != dbc.SQLITE_ROW) {
        const rand_pass = utils.randomStr(allocator, 32) catch {
            try r.sendBody("{\"status\":\"error\",\"message\":\"No se pudo crear la cuenta\"}");
            return;
        };

        var stored: [securing.StoredPasswordLen]u8 = undefined;
        securing.hashPasswordInto(allocator, username, rand_pass, &stored) catch {
            try r.sendBody("{\"status\":\"error\",\"message\":\"No se pudo crear la cuenta\"}");
            return;
        };

        const insert_sql = "INSERT INTO auth_user (username, password, role) VALUES (?, ?, 3)";
        var ins_stmt: ?*dbc.sqlite3_stmt = null;
        if (dbc.sqlite3_prepare_v2(scope.db, insert_sql, -1, &ins_stmt, null) != dbc.SQLITE_OK) {
            try r.sendBody("{\"status\":\"error\",\"message\":\"Error de base de datos\"}");
            return;
        }
        defer _ = dbc.sqlite3_finalize(ins_stmt.?);

        if (dbc.sqlite3_bind_text(ins_stmt.?, 1, username.ptr, @intCast(username.len), null) != dbc.SQLITE_OK or
            dbc.sqlite3_bind_blob(ins_stmt.?, 2, &stored, securing.StoredPasswordLen, null) != dbc.SQLITE_OK)
        {
            try r.sendBody("{\"status\":\"error\",\"message\":\"Error de base de datos\"}");
            return;
        }

        if (dbc.sqlite3_step(ins_stmt.?) != dbc.SQLITE_DONE) {
            try r.sendBody("{\"status\":\"error\",\"message\":\"No se pudo crear la cuenta\"}");
            return;
        }
    }

    utils.logIn(&r, allocator, scope.db, username) catch {
        try r.sendBody("{\"status\":\"error\",\"message\":\"No se pudo crear la sesión\"}");
        return;
    };

    try r.sendBody("{\"status\":\"ok\",\"redirect\":\"/u-board/main\"}");
}

fn appSignInPage(req: zap.Request, data: anytype) !void {
    var mustache = try zap.Mustache.fromData(appSignInTemplate);
    defer mustache.deinit();

    const rendered = mustache.build(data);
    defer rendered.deinit();

    try req.sendBody(rendered.str().?);
}

fn signInPost(r: zap.Request, s: uboard.core.http.Scope) !void {
    try r.parseBody();
    r.parseQuery();

    const username = try r.getParamStr(s.arena.allocator(), "username") orelse {
        r.setStatus(.bad_request);
        try signInPage(r, .{ .error_message = "El usuario es obligatorio." });
        return;
    };
    if (username.len == 0) {
        r.setStatus(.bad_request);
        try signInPage(r, .{ .error_message = "El usuario es obligatorio." });
        return;
    }

    const password = try r.getParamStr(s.arena.allocator(), "password") orelse {
        r.setStatus(.bad_request);
        try signInPage(r, .{ .error_message = "La contraseña es obligatoria." });
        return;
    };
    if (password.len == 0) {
        r.setStatus(.bad_request);
        try signInPage(r, .{ .error_message = "La contraseña es obligatoria." });
        return;
    }

    const authenticated = utils.authenticate(s.arena.allocator(), s.db, username, password) catch |err| switch (err) {
        error.InvalidCredentials => {
            r.setStatus(.unauthorized);
            try signInPage(r, .{ .error_message = "Usuario o contraseña inválidos." });
            return;
        },
        else => {
            r.setStatus(.internal_server_error);
            try signInPage(r, .{ .error_message = "No se pudo autenticar." });
            return;
        },
    };

    if (!authenticated) {
        r.setStatus(.unauthorized);
        try signInPage(r, .{ .error_message = "Usuario o contraseña inválidos." });
        return;
    }

    try utils.logIn(&r, s.arena.allocator(), s.db, username);
    try r.redirectTo("/u-board/main", null);
}

fn signOut(r: zap.Request, s: uboard.core.http.Scope) !void {
    if (try r.getCookieStr(s.arena.allocator(), "session")) |session_key| {
        const dbc = uboard.core.db.c;
        const sql = "UPDATE auth_session SET revoked = 1 WHERE key = ?";

        var stmt: ?*dbc.sqlite3_stmt = null;
        if (dbc.sqlite3_prepare_v2(s.db, sql, -1, &stmt, null) != dbc.SQLITE_OK) {
            r.setStatus(.internal_server_error);
            try r.sendBody("no se pudo preparar el cierre de sesión");
            return;
        }
        defer _ = dbc.sqlite3_finalize(stmt.?);

        if (dbc.sqlite3_bind_text(stmt.?, 1, session_key.ptr, @intCast(session_key.len), null) != dbc.SQLITE_OK) {
            r.setStatus(.internal_server_error);
            try r.sendBody("no se pudo vincular la sesión");
            return;
        }

        if (dbc.sqlite3_step(stmt.?) != dbc.SQLITE_DONE) {
            r.setStatus(.internal_server_error);
            try r.sendBody("no se pudo revocar la sesión");
            return;
        }
    }

    try r.setCookie(.{
        .name = "session",
        .value = "invalid",
        .path = "/u-board",
        .max_age_s = -1,
        .http_only = true,
        .secure = false,
        .same_site = .Lax,
    });
    try r.redirectTo("/u-board/auth/signin", null);
}

fn signInPage(req: zap.Request, data: anytype) !void {
    var mustache = try zap.Mustache.fromData(signInTemplate);
    defer mustache.deinit();

    const rendered = mustache.build(data);
    defer rendered.deinit();

    try req.sendBody(rendered.str().?);
}
