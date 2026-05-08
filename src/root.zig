pub const core = struct {
    pub const http = @import("u-board/core/http.zig");
    pub const conf = @import("u-board/core/conf.zig");
    pub const db = @import("u-board/core/db.zig");
    pub const context = @import("u-board/core/context.zig");
};

pub const shortcuts = @import("u-board/shortcuts.zig");
pub const helpers = @import("u-board/helpers.zig");
pub const utils = @import("u-board/utils.zig");

pub const handling = struct {
    pub const auth = struct {
        pub const middlewares = @import("u-board/handling/auth/middlewares.zig");
        pub const routes = @import("u-board/handling/auth/routes.zig");
        pub const securing = @import("u-board/handling/auth/securing.zig");
    };
    pub const admin = struct {
        pub const routes = @import("u-board/handling/admin/routes.zig");
    };
    pub const root = struct {
        pub const routes = @import("u-board/handling/root/routes.zig");
        pub const utils = @import("u-board/handling/root/utils.zig");
    };
    pub const main = struct {
        pub const routes = @import("u-board/handling/main/routes.zig");
    };
    pub const user = struct {
        pub const routes = @import("u-board/handling/user/routes.zig");
    };
};
