//! hif library entry points.
//!
//! This is the main entry point for the hif library, providing access to:
//! - Core algorithms (hash, hlc, bloom) via their respective namespaces

const std = @import("std");

// Core algorithms
pub const hash = @import("core/hash.zig");
pub const hlc = @import("core/hlc.zig");
pub const bloom = @import("core/bloom.zig");
pub const tree = @import("core/tree.zig");

// Re-export commonly used types for convenience
pub const Hash = hash.Hash;
pub const HLC = hlc.HLC;
pub const Clock = hlc.Clock;
pub const Bloom = bloom.Bloom;
pub const Tree = tree.Tree;

pub const InitError = error{
    PermissionDenied,
    OutOfMemory,
    SymLinkLoop,
    NameTooLong,
    InvalidUtf8,
    BadPathName,
    NoDevice,
    SystemResources,
    ReadOnlyFileSystem,
    NotDir,
    Unexpected,
};

pub const InitResult = enum {
    created,
    already_exists,
};

/// Initialize a new hif repository at the given path.
///
/// Creates the directory structure required for a hif repository:
/// - sessions/      - Active session data
/// - objects/blobs/ - Content-addressed blob storage
/// - objects/trees/ - Content-addressed tree storage
/// - main/          - Main branch state
/// - indexes/       - Path and bloom filter indexes
/// - locks/         - Lock files for coordination
///
/// Returns `.already_exists` if the path already exists as a directory.
/// Returns `.created` if the repository was newly created.
/// Returns an error for permission issues, disk full, or other failures.
pub fn initRepo(allocator: std.mem.Allocator, path: []const u8) InitError!InitResult {
    const cwd = std.fs.cwd();

    // Check if directory already exists
    if (cwd.openDir(path, .{})) |dir| {
        var d = dir;
        d.close();
        return .already_exists;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Directory doesn't exist, continue to create it
        },
        error.AccessDenied => return InitError.PermissionDenied,
        error.SymLinkLoop => return InitError.SymLinkLoop,
        error.NameTooLong => return InitError.NameTooLong,
        error.InvalidUtf8 => return InitError.InvalidUtf8,
        error.BadPathName => return InitError.BadPathName,
        error.NoDevice => return InitError.NoDevice,
        error.SystemResources => return InitError.SystemResources,
        error.NotDir => return InitError.NotDir,
        error.Unexpected => return InitError.Unexpected,
        else => return InitError.Unexpected,
    }

    // Create root directory
    cwd.makePath(path) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return InitError.PermissionDenied,
        error.SymLinkLoop => return InitError.SymLinkLoop,
        error.NameTooLong => return InitError.NameTooLong,
        error.InvalidUtf8 => return InitError.InvalidUtf8,
        error.BadPathName => return InitError.BadPathName,
        error.NoDevice => return InitError.NoDevice,
        error.SystemResources => return InitError.SystemResources,
        error.ReadOnlyFileSystem => return InitError.ReadOnlyFileSystem,
        error.NotDir => return InitError.NotDir,
        else => return InitError.Unexpected,
    };

    // Create subdirectories
    const dirs = [_][]const u8{
        "sessions",
        "objects/blobs",
        "objects/trees",
        "main",
        "indexes",
        "locks",
    };
    for (dirs) |subdir| {
        const full = std.fs.path.join(allocator, &.{ path, subdir }) catch return InitError.OutOfMemory;
        defer allocator.free(full);
        cwd.makePath(full) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return InitError.PermissionDenied,
            error.SymLinkLoop => return InitError.SymLinkLoop,
            error.NameTooLong => return InitError.NameTooLong,
            error.InvalidUtf8 => return InitError.InvalidUtf8,
            error.BadPathName => return InitError.BadPathName,
            error.NoDevice => return InitError.NoDevice,
            error.SystemResources => return InitError.SystemResources,
            error.ReadOnlyFileSystem => return InitError.ReadOnlyFileSystem,
            error.NotDir => return InitError.NotDir,
            else => return InitError.Unexpected,
        };
    }

    return .created;
}

// ============================================================================
// Tests
// ============================================================================

test "initRepo creates repository structure" {
    const allocator = std.testing.allocator;
    const test_path = ".hif-test-init";

    // Clean up any existing test directory
    std.fs.cwd().deleteTree(test_path) catch {};

    // Create new repository
    const result = try initRepo(allocator, test_path);
    defer std.fs.cwd().deleteTree(test_path) catch {};

    try std.testing.expectEqual(InitResult.created, result);

    // Verify directory structure
    const expected_dirs = [_][]const u8{
        "sessions",
        "objects/blobs",
        "objects/trees",
        "main",
        "indexes",
        "locks",
    };

    for (expected_dirs) |subdir| {
        const full = try std.fs.path.join(allocator, &.{ test_path, subdir });
        defer allocator.free(full);
        var dir = try std.fs.cwd().openDir(full, .{});
        dir.close();
    }
}

test "initRepo returns already_exists for existing directory" {
    const allocator = std.testing.allocator;
    const test_path = ".hif-test-exists";

    // Clean up and create directory
    std.fs.cwd().deleteTree(test_path) catch {};
    try std.fs.cwd().makePath(test_path);
    defer std.fs.cwd().deleteTree(test_path) catch {};

    // Try to init on existing directory
    const result = try initRepo(allocator, test_path);
    try std.testing.expectEqual(InitResult.already_exists, result);
}
