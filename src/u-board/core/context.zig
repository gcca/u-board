const std = @import("std");
const uboard = @import("u-board");

pub const Context = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn makeArena(self: Context) std.heap.ArenaAllocator {
        return std.heap.ArenaAllocator.init(self.allocator);
    }
};
