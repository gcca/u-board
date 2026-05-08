const std = @import("std");

pub const SaltLen = 16;
pub const PasswordHashLen = 32;
pub const StoredPasswordLen = SaltLen + PasswordHashLen;

pub fn hashPasswordInto(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    out: *[StoredPasswordLen]u8,
) !void {
    std.crypto.random.bytes(out[0..SaltLen]);

    const params = std.crypto.pwhash.argon2.Params{
        .t = 3,
        .m = 65536,
        .p = 1,
        .ad = username,
    };

    try std.crypto.pwhash.argon2.kdf(
        allocator,
        out[SaltLen..],
        password,
        out[0..SaltLen],
        params,
        .argon2id,
    );
}

pub fn checkPassword(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    stored: []const u8,
) !bool {
    if (stored.len != SaltLen + PasswordHashLen) return error.InvalidLength;

    const salt = stored[0..SaltLen];
    const expected = stored[SaltLen..];

    var hash: [PasswordHashLen]u8 = undefined;
    const params = std.crypto.pwhash.argon2.Params{
        .t = 3,
        .m = 65536,
        .p = 1,
        .ad = username,
    };

    try std.crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        password,
        salt,
        params,
        .argon2id,
    );

    return std.crypto.timing_safe.eql([PasswordHashLen]u8, hash, expected[0..PasswordHashLen].*);
}
