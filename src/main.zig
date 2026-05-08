const std = @import("std");
const zap = @import("zap");
const uboard = @import("u-board");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.warn("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    try uboard.core.conf.init(allocator);
    defer uboard.core.conf.deinit(allocator);

    var context = uboard.core.context.Context.init(allocator);

    var router = zap.Router.init(allocator, .{});
    defer router.deinit();

    try router.handle_func_unbound("/", indexHandler);
    try router.handle_func_unbound("/u-board", indexHandler);
    try router.handle_func_unbound("/healthcheck", healthHandler);

    try uboard.handling.auth.routes.register(&router, &context);
    try uboard.handling.main.routes.register(&router, &context);
    try uboard.handling.admin.routes.register(&router, &context);
    try uboard.handling.root.routes.register(&router, &context);
    try uboard.handling.user.routes.register(&router, &context);

    var listener = zap.HttpListener.init(.{
        .interface = "0.0.0.0",
        .port = 5561,
        .on_request = router.on_request_handler(),
    });

    std.debug.print("Listening on 0.0.0.0:5561\n", .{});

    try listener.listen();

    zap.start(.{ .threads = 2, .workers = 1 });
}

fn indexHandler(r: zap.Request) !void {
    try r.redirectTo("/u-board/auth/signin", null);
}

fn healthHandler(r: zap.Request) !void {
    try r.sendBody("🙇");
}
