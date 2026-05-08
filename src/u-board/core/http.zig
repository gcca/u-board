const std = @import("std");
const zap = @import("zap");
const uboard = @import("u-board");

pub const Scope = struct {
    context: *uboard.core.context.Context,
    db: *uboard.core.db.c.sqlite3,
    arena: *std.heap.ArenaAllocator,
};

pub fn getPost(comptime get_handler: anytype, comptime post_handler: anytype) zap.HttpRequestFn {
    return struct {
        fn handle(req: zap.Request) !void {
            switch (req.methodAsEnum()) {
                .GET => try get_handler(req),
                .POST => try post_handler(req),
                else => {
                    req.setStatus(.method_not_allowed);
                    try req.sendBody("method not allowed");
                },
            }
        }
    }.handle;
}

pub fn Middleware(comptime middlewares: anytype, comptime handler: anytype) type {
    const type_info = @typeInfo(@TypeOf(middlewares));

    if (type_info != .@"struct") {
        @compileError("Middleware expects a tuple of middlewares");
    }

    const fields = type_info.@"struct".fields;

    if (fields.len == 0) {
        @compileError("Middleware requires at least one middleware in the chain");
    }

    const wrapped = composeMiddlewares(middlewares, fields, handler);

    return struct {
        context: *uboard.core.context.Context,
        pub var route: @This() = undefined;

        pub fn handle(self: *@This(), r: zap.Request) !void {
            r.parseCookies(false);

            var arena = self.context.makeArena();
            defer arena.deinit();

            const db = try uboard.core.db.openBy(self.context);
            defer uboard.core.db.close(db);

            var scope = Scope{ .context = self.context, .db = db, .arena = &arena };
            try wrapped(r, &scope);
        }

        pub fn register(router: *zap.Router, path: []const u8, ctx: *uboard.core.context.Context) !void {
            route = .{ .context = ctx };
            try router.handle_func(path, &route, &@This().handle);
        }
    };
}

fn composeMiddlewares(comptime middlewares: anytype, comptime fields: anytype, comptime handler: anytype) fn (zap.Request, *Scope) anyerror!void {
    comptime var wrapped = wrapHandler(handler);

    inline for (0..fields.len) |idx| {
        const i = fields.len - 1 - idx;
        const mw = @field(middlewares, fields[i].name);
        wrapped = mw.wrap(wrapped);
    }

    return wrapped;
}

fn wrapHandler(comptime handler: anytype) fn (zap.Request, *Scope) anyerror!void {
    return struct {
        fn wrapper(r: zap.Request, scope: *Scope) !void {
            const info = @typeInfo(@TypeOf(handler));
            comptime {
                if (info != .@"fn") @compileError("Handler must be a function");
                const params = info.@"fn".params;
                if (params.len != 1 and params.len != 2) {
                    @compileError("Handler must take one or two arguments");
                }
            }

            if (info.@"fn".params.len == 1) {
                try handler(r);
            } else {
                try handler(r, scope.*);
            }
        }
    }.wrapper;
}
