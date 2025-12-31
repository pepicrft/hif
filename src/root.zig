//! hif library entry points.
const std = @import("std");

pub const InitResult = enum {
    created,
    already_exists,
};

pub fn initRepo(allocator: std.mem.Allocator, path: []const u8) !InitResult {
    const cwd = std.fs.cwd();
    if (cwd.openDir(path, .{})) |_| {
        return .already_exists;
    } else |_| {
        // Directory doesn't exist, continue to create it
    }

    try cwd.makePath(path);
    const dirs = [_][]const u8{
        "ops/patch",
        "patches",
        "sessions",
        "objects/blobs",
        "objects/trees",
        "indexes",
        "locks",
    };
    for (dirs) |subdir| {
        const full = try std.fs.path.join(allocator, &.{ path, subdir });
        defer allocator.free(full);
        try cwd.makePath(full);
    }

    return .created;
}
