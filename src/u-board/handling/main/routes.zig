const std = @import("std");

const uboard = @import("u-board");
const zap = @import("zap");

const utils = @import("utils.zig");

pub fn register(router: *zap.Router, context: *uboard.core.context.Context) !void {
    try uboard.core.http.Middleware(.{
        uboard.handling.auth.middlewares.LogInRequired(),
    }, mainGet).register(router, "/u-board/main", context);
}

fn mainGet(r: zap.Request, s: uboard.core.http.Scope) !void {
    const session_key = uboard.helpers.keyOfSession(s.arena.allocator(), r);
    const role = try utils.roleForSession(s, session_key);
    const path = try std.fmt.allocPrint(s.arena.allocator(), "/u-board/{s}", .{@tagName(role)});

    try r.redirectTo(path, null);
}
