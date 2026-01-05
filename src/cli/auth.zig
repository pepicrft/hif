const std = @import("std");

pub const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32 = 5,
};

pub const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: i64,
};

pub fn generateClientId(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(random_bytes.len);
    const result = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(result, &random_bytes);
    
    return result;
}

pub fn deviceCodeFlow(
    allocator: std.mem.Allocator,
    url: []const u8,
    client_id: []const u8,
) !DeviceCodeResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    
    // Build URL
    const url_str = try std.fmt.allocPrint(allocator, "{s}/oauth/device", .{url});
    defer allocator.free(url_str);
    
    const uri = try std.Uri.parse(url_str);
    
    // Build request body
    const body = try std.fmt.allocPrint(allocator, "client_id={s}", .{client_id});
    defer allocator.free(body);
    
    // Make request
    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        },
    });
    defer req.deinit();
    
    try req.sendBodyComplete(body);
    
    // Receive response
    var response = try req.receiveHead(&.{});
    
    // Read response body
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    
    var body_reader = response.reader(&.{});
    _ = try body_reader.streamRemaining(&aw.writer);
    
    const response_buf = aw.toArrayList();
    
    // Parse JSON
    const parsed = try std.json.parseFromSlice(DeviceCodeResponse, allocator, response_buf.items, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    
    // Copy strings so they survive parsed.deinit()
    return .{
        .device_code = try allocator.dupe(u8, parsed.value.device_code),
        .user_code = try allocator.dupe(u8, parsed.value.user_code),
        .verification_uri = try allocator.dupe(u8, parsed.value.verification_uri),
        .interval = parsed.value.interval,
    };
}

pub fn pollForToken(
    allocator: std.mem.Allocator,
    url: []const u8,
    device_code: []const u8,
    interval: u32,
) !TokenResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    
    const url_str = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{url});
    defer allocator.free(url_str);
    
    const uri = try std.Uri.parse(url_str);
    
    const body = try std.fmt.allocPrint(allocator, "grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code={s}", .{device_code});
    defer allocator.free(body);
    
    while (true) {
        var req = try client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            },
        });
        defer req.deinit();
        
        try req.sendBodyComplete(body);
        
        var response = try req.receiveHead(&.{});
        
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        
        var body_reader = response.reader(&.{});
        _ = try body_reader.streamRemaining(&aw.writer);
        
        const response_buf = aw.toArrayList();
        
        // Try to parse as successful token response
        if (std.json.parseFromSlice(TokenResponse, allocator, response_buf.items, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            
            return .{
                .access_token = try allocator.dupe(u8, parsed.value.access_token),
                .refresh_token = if (parsed.value.refresh_token) |rt| try allocator.dupe(u8, rt) else null,
                .expires_in = parsed.value.expires_in,
            };
        } else |_| {
            // Check for authorization_pending error
            const ErrorResponse = struct {
                @"error": []const u8,
            };
            
            if (std.json.parseFromSlice(ErrorResponse, allocator, response_buf.items, .{
                .ignore_unknown_fields = true,
            })) |err_parsed| {
                defer err_parsed.deinit();
                
                if (std.mem.eql(u8, err_parsed.value.@"error", "authorization_pending")) {
                    // Keep polling
                    std.Thread.sleep(interval * std.time.ns_per_s);
                    continue;
                } else if (std.mem.eql(u8, err_parsed.value.@"error", "slow_down")) {
                    // Slow down
                    std.Thread.sleep((interval + 5) * std.time.ns_per_s);
                    continue;
                } else {
                    return error.AuthorizationFailed;
                }
            } else |_| {
                return error.InvalidResponse;
            }
        }
    }
}

pub fn refreshAccessToken(
    allocator: std.mem.Allocator,
    url: []const u8,
    client_id: []const u8,
    refresh_token: []const u8,
) !TokenResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    
    const url_str = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{url});
    defer allocator.free(url_str);
    
    const uri = try std.Uri.parse(url_str);
    
    const body = try std.fmt.allocPrint(allocator, "grant_type=refresh_token&refresh_token={s}&client_id={s}", .{ refresh_token, client_id });
    defer allocator.free(body);
    
    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        },
    });
    defer req.deinit();
    
    try req.sendBodyComplete(body);
    
    var response = try req.receiveHead(&.{});
    
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    
    var body_reader = response.reader(&.{});
    _ = try body_reader.streamRemaining(&aw.writer);
    
    const response_buf = aw.toArrayList();
    
    const parsed = try std.json.parseFromSlice(TokenResponse, allocator, response_buf.items, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    
    return .{
        .access_token = try allocator.dupe(u8, parsed.value.access_token),
        .refresh_token = if (parsed.value.refresh_token) |rt| try allocator.dupe(u8, rt) else null,
        .expires_in = parsed.value.expires_in,
    };
}
