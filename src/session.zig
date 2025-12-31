//! Session management for hif.
//!
//! A session is the fundamental unit of work in hif. It captures:
//! - Goal: what you're trying to accomplish
//! - Conversation: discussion between agents and humans
//! - Decisions: why things were done a certain way
//! - Changes: the actual file modifications

const std = @import("std");
const uuid = @import("uuid.zig");

pub const Uuid = uuid.Uuid;

pub const State = enum {
    open,
    landed,
    abandoned,

    pub fn toString(self: State) []const u8 {
        return switch (self) {
            .open => "open",
            .landed => "landed",
            .abandoned => "abandoned",
        };
    }

    pub fn fromString(str: []const u8) ?State {
        if (std.mem.eql(u8, str, "open")) return .open;
        if (std.mem.eql(u8, str, "landed")) return .landed;
        if (std.mem.eql(u8, str, "abandoned")) return .abandoned;
        return null;
    }
};

pub const Meta = struct {
    id: Uuid,
    goal: []const u8,
    state: State,
    created_at: i64,
    owner: []const u8,

    /// Serialize to JSON. Caller owns returned memory.
    pub fn toJson(self: Meta, allocator: std.mem.Allocator) ![]u8 {
        // Calculate required size
        const base_len = comptime blk: {
            const template = "{\"id\":\"\",\"goal\":\"\",\"state\":\"\",\"created_at\":,\"owner\":\"\"}";
            break :blk template.len;
        };
        const max_timestamp_len = 20; // i64 max digits
        const max_state_len = 9; // "abandoned"

        const total_len = base_len + self.id.len + self.goal.len + max_state_len + max_timestamp_len + self.owner.len;
        const buf = try allocator.alloc(u8, total_len);
        errdefer allocator.free(buf);

        const result = std.fmt.bufPrint(buf,
            \\{{"id":"{s}","goal":"{s}","state":"{s}","created_at":{d},"owner":"{s}"}}
        , .{ self.id, self.goal, self.state.toString(), self.created_at, self.owner }) catch unreachable;

        // Shrink to actual size
        if (result.len < buf.len) {
            return allocator.realloc(buf, result.len) catch buf[0..result.len];
        }
        return result;
    }
};

pub const StartError = error{
    AlreadyInSession,
    OutOfMemory,
    FileSystemError,
};

pub const StartResult = struct {
    id: Uuid,
};

/// Start a new session with the given goal.
pub fn start(allocator: std.mem.Allocator, hif_path: []const u8, goal: []const u8, owner: []const u8) StartError!StartResult {
    return startWithTimestamp(allocator, hif_path, goal, owner, std.time.timestamp());
}

/// Start a new session with a specific timestamp (for testing).
pub fn startWithTimestamp(
    allocator: std.mem.Allocator,
    hif_path: []const u8,
    goal: []const u8,
    owner: []const u8,
    timestamp: i64,
) StartError!StartResult {
    const cwd = std.fs.cwd();

    // Check if there's already a current session
    const current_path = std.fs.path.join(allocator, &.{ hif_path, "current" }) catch return StartError.OutOfMemory;
    defer allocator.free(current_path);

    if (cwd.access(current_path, .{})) |_| {
        return StartError.AlreadyInSession;
    } else |_| {
        // No current session, continue
    }

    // Generate session ID
    const session_id = uuid.v4();

    // Create session directory
    const session_dir = std.fs.path.join(allocator, &.{ hif_path, "sessions", &session_id }) catch return StartError.OutOfMemory;
    defer allocator.free(session_dir);
    cwd.makePath(session_dir) catch return StartError.FileSystemError;

    // Create meta.json
    const meta = Meta{
        .id = session_id,
        .goal = goal,
        .state = .open,
        .created_at = timestamp,
        .owner = owner,
    };

    const meta_json = meta.toJson(allocator) catch return StartError.OutOfMemory;
    defer allocator.free(meta_json);

    writeSessionFile(allocator, cwd, session_dir, "meta.json", meta_json) catch return StartError.FileSystemError;

    // Create empty log files
    writeSessionFile(allocator, cwd, session_dir, "conversation.jsonl", "") catch return StartError.FileSystemError;
    writeSessionFile(allocator, cwd, session_dir, "decisions.jsonl", "") catch return StartError.FileSystemError;
    writeSessionFile(allocator, cwd, session_dir, "ops.jsonl", "") catch return StartError.FileSystemError;

    // Write current session pointer
    const current_file = cwd.createFile(current_path, .{}) catch return StartError.FileSystemError;
    defer current_file.close();
    current_file.writeAll(&session_id) catch return StartError.FileSystemError;

    return StartResult{ .id = session_id };
}

fn writeSessionFile(allocator: std.mem.Allocator, cwd: std.fs.Dir, session_dir: []const u8, filename: []const u8, content: []const u8) !void {
    const file_path = try std.fs.path.join(allocator, &.{ session_dir, filename });
    defer allocator.free(file_path);

    const file = try cwd.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Get the current session ID, if any.
pub fn getCurrent(allocator: std.mem.Allocator, hif_path: []const u8) !?Uuid {
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

    var id: Uuid = undefined;
    const bytes_read = try file.readAll(&id);
    if (bytes_read != 36) {
        return null;
    }

    if (!uuid.isValid(&id)) {
        return null;
    }

    return id;
}

// Tests
test "State.toString returns correct strings" {
    try std.testing.expectEqualStrings("open", State.open.toString());
    try std.testing.expectEqualStrings("landed", State.landed.toString());
    try std.testing.expectEqualStrings("abandoned", State.abandoned.toString());
}

test "State.fromString parses valid states" {
    try std.testing.expectEqual(State.open, State.fromString("open"));
    try std.testing.expectEqual(State.landed, State.fromString("landed"));
    try std.testing.expectEqual(State.abandoned, State.fromString("abandoned"));
    try std.testing.expectEqual(@as(?State, null), State.fromString("invalid"));
}

test "Meta.toJson produces valid JSON" {
    const allocator = std.testing.allocator;

    const meta = Meta{
        .id = "550e8400-e29b-41d4-a716-446655440000".*,
        .goal = "Test goal",
        .state = .open,
        .created_at = 1234567890,
        .owner = "test-owner",
    };

    const json = try meta.toJson(allocator);
    defer allocator.free(json);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"550e8400-e29b-41d4-a716-446655440000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"goal\":\"Test goal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"created_at\":1234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"owner\":\"test-owner\"") != null);
}

test "start creates session directory and files" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create .hif structure
    try tmp_dir.dir.makePath("sessions");

    // Start session
    const result = try startWithTimestamp(allocator, tmp_path, "Test goal", "test-owner", 1234567890);

    // Verify session directory exists
    const session_dir_path = try std.fs.path.join(allocator, &.{ "sessions", &result.id });
    defer allocator.free(session_dir_path);

    var session_dir = try tmp_dir.dir.openDir(session_dir_path, .{});
    defer session_dir.close();

    // Verify files exist
    _ = try session_dir.statFile("meta.json");
    _ = try session_dir.statFile("conversation.jsonl");
    _ = try session_dir.statFile("decisions.jsonl");
    _ = try session_dir.statFile("ops.jsonl");

    // Verify current file
    const current_content = try tmp_dir.dir.readFileAlloc(allocator, "current", 1024);
    defer allocator.free(current_content);
    try std.testing.expectEqualStrings(&result.id, current_content);
}

test "start fails when session already exists" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create .hif structure
    try tmp_dir.dir.makePath("sessions");

    // Start first session
    _ = try startWithTimestamp(allocator, tmp_path, "First goal", "owner", 1234567890);

    // Try to start second session
    const result = startWithTimestamp(allocator, tmp_path, "Second goal", "owner", 1234567891);
    try std.testing.expectError(StartError.AlreadyInSession, result);
}

test "getCurrent returns null when no session" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const current = try getCurrent(allocator, tmp_path);
    try std.testing.expectEqual(@as(?Uuid, null), current);
}

test "getCurrent returns session ID when exists" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create .hif structure
    try tmp_dir.dir.makePath("sessions");

    // Start session
    const result = try startWithTimestamp(allocator, tmp_path, "Test goal", "owner", 1234567890);

    // Get current
    const current = try getCurrent(allocator, tmp_path);
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings(&result.id, &current.?);
}
