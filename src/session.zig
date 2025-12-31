//! Session management for hif.
//!
//! A session is the fundamental unit of work in hif. It captures:
//! - Goal: what you're trying to accomplish
//! - Conversation: discussion between agents and humans
//! - Decisions: why things were done a certain way
//! - Changes: the actual file modifications

const std = @import("std");

pub const SessionState = enum {
    open,
    landed,
    abandoned,

    pub fn toString(self: SessionState) []const u8 {
        return switch (self) {
            .open => "open",
            .landed => "landed",
            .abandoned => "abandoned",
        };
    }
};

pub const StartResult = enum {
    created,
    already_in_session,
};

/// Generate a UUID v4 string
fn generateUuid(buf: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Set version (4) and variant (RFC 4122)
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;

    // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    while (j < 16) : (j += 1) {
        if (j == 4 or j == 6 or j == 8 or j == 10) {
            buf[i] = '-';
            i += 1;
        }
        buf[i] = hex[random_bytes[j] >> 4];
        buf[i + 1] = hex[random_bytes[j] & 0x0f];
        i += 2;
    }
}

/// Start a new session with the given goal.
/// Returns the session ID on success.
pub fn start(allocator: std.mem.Allocator, hif_path: []const u8, goal: []const u8, owner: []const u8) !struct { result: StartResult, id: [36]u8 } {
    const cwd = std.fs.cwd();

    // Check if there's already a current session
    const current_path = try std.fs.path.join(allocator, &.{ hif_path, "current" });
    defer allocator.free(current_path);

    if (cwd.access(current_path, .{})) |_| {
        return .{ .result = .already_in_session, .id = undefined };
    } else |_| {
        // No current session, continue
    }

    // Generate session ID
    var session_id: [36]u8 = undefined;
    generateUuid(&session_id);

    // Create session directory
    const session_dir = try std.fs.path.join(allocator, &.{ hif_path, "sessions", &session_id });
    defer allocator.free(session_dir);
    try cwd.makePath(session_dir);

    // Create meta.json with simple format
    const meta_path = try std.fs.path.join(allocator, &.{ session_dir, "meta.json" });
    defer allocator.free(meta_path);

    const meta_file = try cwd.createFile(meta_path, .{});
    defer meta_file.close();

    // Write JSON manually to avoid ArrayList issues
    const timestamp = std.time.timestamp();
    var json_buf: [4096]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf,
        \\{{"id":"{s}","goal":"{s}","state":"open","created_at":{d},"owner":"{s}"}}
    , .{ session_id, goal, timestamp, owner }) catch return error.BufferTooSmall;
    try meta_file.writeAll(json);

    // Create empty conversation.jsonl
    const conv_path = try std.fs.path.join(allocator, &.{ session_dir, "conversation.jsonl" });
    defer allocator.free(conv_path);
    const conv_file = try cwd.createFile(conv_path, .{});
    conv_file.close();

    // Create empty decisions.jsonl
    const dec_path = try std.fs.path.join(allocator, &.{ session_dir, "decisions.jsonl" });
    defer allocator.free(dec_path);
    const dec_file = try cwd.createFile(dec_path, .{});
    dec_file.close();

    // Create empty ops.jsonl
    const ops_path = try std.fs.path.join(allocator, &.{ session_dir, "ops.jsonl" });
    defer allocator.free(ops_path);
    const ops_file = try cwd.createFile(ops_path, .{});
    ops_file.close();

    // Write current session pointer
    const current_file = try cwd.createFile(current_path, .{});
    defer current_file.close();
    try current_file.writeAll(&session_id);

    return .{ .result = .created, .id = session_id };
}

/// Get the current session ID, if any.
pub fn current(allocator: std.mem.Allocator, hif_path: []const u8) !?[36]u8 {
    const cwd = std.fs.cwd();

    const current_path = try std.fs.path.join(allocator, &.{ hif_path, "current" });
    defer allocator.free(current_path);

    const file = cwd.openFile(current_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };
    defer file.close();

    var id: [36]u8 = undefined;
    const bytes_read = try file.readAll(&id);
    if (bytes_read != 36) {
        return null;
    }

    return id;
}
