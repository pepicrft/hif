const std = @import("std");

pub const Config = struct {
    url: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_at: ?i64 = null,
    current_session: ?[]const u8 = null,
    
    pub fn getUrl(self: Config) []const u8 {
        return self.url orelse "https://micelio.dev";
    }
    
    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        if (self.url) |v| allocator.free(v);
        if (self.client_id) |v| allocator.free(v);
        if (self.access_token) |v| allocator.free(v);
        if (self.refresh_token) |v| allocator.free(v);
        if (self.current_session) |v| allocator.free(v);
    }
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

    return parseTOML(allocator, data);
}

fn parseTOML(allocator: std.mem.Allocator, data: []const u8) !Config {
    var config = Config{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        // Skip sections (we don't need them for flat config)
        if (trimmed[0] == '[') continue;
        
        // Parse key = value
        var parts = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const value_raw = std.mem.trim(u8, parts.rest(), " \t");
        
        if (value_raw.len == 0) continue;
        
        // Remove quotes if present
        const value = if (value_raw.len >= 2 and value_raw[0] == '"' and value_raw[value_raw.len - 1] == '"')
            value_raw[1 .. value_raw.len - 1]
        else
            value_raw;
        
        if (std.mem.eql(u8, key, "url")) {
            config.url = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "client_id")) {
            config.client_id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "access_token")) {
            config.access_token = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "refresh_token")) {
            config.refresh_token = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "expires_at")) {
            config.expires_at = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, key, "current_session")) {
            config.current_session = try allocator.dupe(u8, value);
        }
    }
    
    return config;
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

    // Build TOML content in memory
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    
    // Write header
    try aw.writer.writeAll("# hif configuration\n");
    try aw.writer.writeAll("# DO NOT SHARE - Contains authentication tokens\n\n");
    
    // Write fields in alphabetical order for deterministic output
    if (config.access_token) |v| {
        try aw.writer.print("access_token = \"{s}\"\n", .{v});
    }
    
    if (config.client_id) |v| {
        try aw.writer.print("client_id = \"{s}\"\n", .{v});
    }
    
    if (config.current_session) |v| {
        try aw.writer.print("current_session = \"{s}\"\n", .{v});
    }
    
    if (config.expires_at) |v| {
        try aw.writer.print("expires_at = {d}\n", .{v});
    }
    
    if (config.refresh_token) |v| {
        try aw.writer.print("refresh_token = \"{s}\"\n", .{v});
    }
    
    if (config.url) |v| {
        try aw.writer.print("url = \"{s}\"\n", .{v});
    }
    
    // Write to file
    const content = try aw.toOwnedSlice();
    defer allocator.free(content);
    try file.writeAll(content);
}
