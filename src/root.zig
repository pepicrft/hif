//! hif library entry points.
//!
//! This is the main entry point for the hif library, providing access to:
//! - Core algorithms (hash) via the `hash` namespace

const std = @import("std");

// Core algorithms
pub const hash = @import("core/hash.zig");

// Re-export commonly used types for convenience
pub const Hash = hash.Hash;

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
        "sessions",
        "objects/blobs",
        "objects/trees",
        "main",
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
