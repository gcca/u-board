const std = @import("std");

pub const Settings = struct {
    DATABASE_URL: []const u8,
};

pub var settings = Settings{
    .DATABASE_URL = "db/u-board.db",
};

pub fn init(allocator: std.mem.Allocator) !void {
    const database_url = std.process.getEnvVarOwned(allocator, "DATABASE_URL") catch return;

    settings.DATABASE_URL = if (std.mem.startsWith(u8, database_url, "sqlite:"))
        try allocator.dupe(u8, database_url["sqlite:".len..])
    else
        try allocator.dupe(u8, database_url);

    allocator.free(database_url);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (!std.mem.eql(u8, settings.DATABASE_URL, "db/u-board.db")) {
        allocator.free(settings.DATABASE_URL);
        settings.DATABASE_URL = "db/u-board.db";
    }
}
