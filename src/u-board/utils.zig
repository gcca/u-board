const std = @import("std");

pub const Role = enum(i64) {
    root = 0,
    admin = 1,
    staff = 2,
    user = 3,
};

pub fn roleLabel(role: Role) []const u8 {
    return switch (role) {
        .root => "root",
        .admin => "administrador",
        .staff => "staff",
        .user => "usuario",
    };
}

pub fn formatTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
}

pub fn getInitials(allocator: std.mem.Allocator, username: []const u8) ![]const u8 {
    if (username.len == 0) return try allocator.dupe(u8, "??");
    if (username.len == 1) return try std.fmt.allocPrint(allocator, "{c}", .{std.ascii.toUpper(username[0])});
    return try std.fmt.allocPrint(allocator, "{c}{c}", .{
        std.ascii.toUpper(username[0]),
        std.ascii.toUpper(username[1]),
    });
}
