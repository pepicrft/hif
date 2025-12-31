//! C ABI for hif, intended for C extensions or other FFI callers.

const std = @import("std");
const hif = @import("root.zig");

/// Initialize a new hif repository at the given path.
/// Returns 0 on success (created), 1 if already exists, 2 on error.
pub export fn hif_init_repo(
    path_ptr: [*]const u8,
    path_len: usize,
) c_int {
    const allocator = std.heap.c_allocator;
    const path = path_ptr[0..path_len];

    const result = hif.initRepo(allocator, path) catch return 2;

    return switch (result) {
        .created => 0,
        .already_exists => 1,
    };
}

/// Free memory allocated by hif functions.
pub export fn hif_free(ptr: [*]u8, len: usize) void {
    std.heap.c_allocator.free(ptr[0..len]);
}
