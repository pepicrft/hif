const std = @import("std");

pub const Config = struct {
    forge_url: []const u8 = "https://micelio.dev",
    client_id: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_at: ?i64 = null,
    current_session: ?[]const u8 = null,
};

fn getHomeDir(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME");
}

fn configDirPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".hif" });
}

fn configFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".hif", "config" });
}

pub fn load(allocator: std.mem.Allocator) !Config {
    const path = try configFilePath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    return try std.json.parseFromSliceLeaky(Config, allocator, data, .{
        .ignore_unknown_fields = true,
    });
}

pub fn save(allocator: std.mem.Allocator, config: Config) !void {
    const dir_path = try configDirPath(allocator);
    defer allocator.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const path = try configFilePath(allocator);
    defer allocator.free(path);

    var file = try std.fs.createFileAbsolute(path, .{
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();

    // Use an allocating writer for JSON stringification
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    
    var jw = std.json.Stringify{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.write(config);
    
    const json_str = try aw.toOwnedSlice();
    defer allocator.free(json_str);
    
    try file.writeAll(json_str);
    try file.writeAll("\n");
}
