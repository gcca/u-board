const zap = @import("zap");
const uboard = @import("u-board");

pub fn render(req: zap.Request, template: []const u8) !void {
    try renderWith(req, template, .{});
}

pub fn renderWith(req: zap.Request, template: []const u8, data: anytype) !void {
    var mustache = try zap.Mustache.fromData(template);
    defer mustache.deinit();

    const rendered = mustache.build(data);
    defer rendered.deinit();

    try req.sendBody(rendered.str().?);
}

pub fn RoleRoute(comptime role: uboard.utils.Role, comptime handler: anytype) type {
    return uboard.core.http.Middleware(.{
        uboard.handling.auth.middlewares.LogInRequired(),
        uboard.handling.auth.middlewares.RoleRequired(role),
    }, handler);
}
