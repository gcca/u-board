const std = @import("std");

pub const Settings = struct {
    DATABASE_URL: []const u8,
};

pub var settings = Settings{
    .DATABASE_URL = "data/u-board.db",
};

var owned_database_url: ?[]const u8 = null;

pub fn init(allocator: std.mem.Allocator) !void {
    const database_url = std.process.getEnvVarOwned(allocator, "DATABASE_URL") catch return;
    defer allocator.free(database_url);

    owned_database_url = if (std.mem.startsWith(u8, database_url, "sqlite:"))
        try allocator.dupe(u8, database_url["sqlite:".len..])
    else
        try allocator.dupe(u8, database_url);

    settings.DATABASE_URL = owned_database_url.?;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (owned_database_url) |url| {
        allocator.free(url);
        owned_database_url = null;
        settings.DATABASE_URL = "data/u-board.db";
    }
}
