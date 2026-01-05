const std = @import("std");
const yazap = @import("yazap");
const hif = @import("root.zig");
const config = @import("cli/config.zig");
const auth = @import("cli/auth.zig");

const App = yazap.App;
const Arg = yazap.Arg;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator, "hif", "A forge-first version control system for the agent era");
    defer app.deinit();

    var root = app.rootCommand();

    // Session commands
    var session_cmd = app.createCommand("session", "Manage work sessions");

    var session_start = app.createCommand("start", "Start a new session with a goal");
    try session_start.addArg(Arg.positional("GOAL", "The goal for this session", null));
    try session_cmd.addSubcommand(session_start);

    const session_status = app.createCommand("status", "Show current session status");
    try session_cmd.addSubcommand(session_status);

    const session_list = app.createCommand("list", "List all sessions");
    try session_cmd.addSubcommand(session_list);

    const session_land = app.createCommand("land", "Land the current session");
    try session_cmd.addSubcommand(session_land);

    const session_abandon = app.createCommand("abandon", "Abandon the current session");
    try session_cmd.addSubcommand(session_abandon);

    try root.addSubcommand(session_cmd);

    // Decision command
    var decide_cmd = app.createCommand("decide", "Record a decision in the current session");
    try decide_cmd.addArg(Arg.positional("TEXT", "The decision text", null));
    try root.addSubcommand(decide_cmd);

    // Conversation command
    var converse_cmd = app.createCommand("converse", "Add a conversation entry to the current session");
    try converse_cmd.addArg(Arg.positional("MESSAGE", "The message content", null));
    try root.addSubcommand(converse_cmd);

    // File operations
    var write_cmd = app.createCommand("write", "Write stdin to a path (records operation)");
    try write_cmd.addArg(Arg.positional("PATH", "Target path", null));
    try root.addSubcommand(write_cmd);

    var cat_cmd = app.createCommand("cat", "Print blob content");
    try cat_cmd.addArg(Arg.positional("HASH", "Blob hash (hex)", null));
    try root.addSubcommand(cat_cmd);

    // Hash command (local utility, no forge needed)
    const hash_cmd = app.createCommand("hash", "Hash stdin and print the result");
    try root.addSubcommand(hash_cmd);

    // Version command
    const version_cmd = app.createCommand("version", "Show version information");
    try root.addSubcommand(version_cmd);

    // Auth commands
    var auth_cmd = app.createCommand("auth", "Manage authentication");
    
    const auth_login = app.createCommand("login", "Authenticate with the forge");
    try auth_cmd.addSubcommand(auth_login);
    
    const auth_logout = app.createCommand("logout", "Clear authentication tokens");
    try auth_cmd.addSubcommand(auth_logout);
    
    const auth_status = app.createCommand("status", "Show authentication status");
    try auth_cmd.addSubcommand(auth_status);
    
    var auth_config = app.createCommand("config", "Configure forge URL");
    try auth_config.addArg(Arg.positional("URL", "Forge URL (e.g., https://micelio.dev)", null));
    try auth_cmd.addSubcommand(auth_config);
    
    try root.addSubcommand(auth_cmd);

    const matches = app.parseProcess() catch {
        try app.displayHelp();
        return;
    };

    // Get file handles for output
    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();

    // Output buffers
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    var stderr = stderr_file.writer(&stderr_buf);

    // Handle commands
    if (matches.subcommandMatches("version")) |_| {
        try stdout.interface.writeAll("hif 0.1.0\n");
        try stdout.interface.writeAll("A forge-first version control system for the agent era\n");
        try stdout.interface.flush();
        return;
    }

    if (matches.subcommandMatches("hash")) |_| {
        // Hash is a local utility - works without forge connection
        const stdin_file = std.fs.File.stdin();
        const content = stdin_file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
            try stderr.interface.print("Error reading stdin: {}\n", .{err});
            try stderr.interface.flush();
            return;
        };
        defer allocator.free(content);

        const hash = hif.hash.hashBlob(content);
        const hex = hif.hash.formatHex(hash);
        try stdout.interface.print("{s}\n", .{hex});
        try stdout.interface.flush();
        return;
    }

    if (matches.subcommandMatches("session")) |session_matches| {
        if (session_matches.subcommandMatches("start")) |start_matches| {
            if (start_matches.getSingleValue("GOAL")) |goal| {
                try stdout.interface.print("Starting session with goal: {s}\n", .{goal});
                try stdout.interface.writeAll("(Forge connection required - see DESIGN.md)\n");
                try stdout.interface.flush();
            } else {
                try stderr.interface.writeAll("Error: goal required\n");
                try stderr.interface.writeAll("Usage: hif session start <goal>\n");
                try stderr.interface.flush();
            }
            return;
        }

        if (session_matches.subcommandMatches("status")) |_| {
            try stdout.interface.writeAll("No active session.\n");
            try stdout.interface.writeAll("Start one with: hif session start <goal>\n");
            try stdout.interface.writeAll("(Requires forge connection)\n");
            try stdout.interface.flush();
            return;
        }

        if (session_matches.subcommandMatches("list")) |_| {
            try stdout.interface.writeAll("No sessions found.\n");
            try stdout.interface.writeAll("(Requires forge connection)\n");
            try stdout.interface.flush();
            return;
        }

        if (session_matches.subcommandMatches("land")) |_| {
            try stderr.interface.writeAll("Error: No active session to land.\n");
            try stderr.interface.writeAll("(Requires forge connection)\n");
            try stderr.interface.flush();
            return;
        }

        if (session_matches.subcommandMatches("abandon")) |_| {
            try stderr.interface.writeAll("Error: No active session to abandon.\n");
            try stderr.interface.writeAll("(Requires forge connection)\n");
            try stderr.interface.flush();
            return;
        }

        // Default: show session help
        try stdout.interface.writeAll("Session commands:\n");
        try stdout.interface.writeAll("  start <goal>  - Start a new session\n");
        try stdout.interface.writeAll("  status        - Show current session\n");
        try stdout.interface.writeAll("  list          - List all sessions\n");
        try stdout.interface.writeAll("  land          - Land current session\n");
        try stdout.interface.writeAll("  abandon       - Abandon current session\n");
        try stdout.interface.writeAll("\nNote: All session commands require a forge connection.\n");
        try stdout.interface.writeAll("The forge (server) is the source of truth - see DESIGN.md\n");
        try stdout.interface.flush();
        return;
    }

    if (matches.subcommandMatches("decide")) |decide_matches| {
        if (decide_matches.getSingleValue("TEXT")) |text| {
            try stdout.interface.print("Decision: {s}\n", .{text});
            try stdout.interface.writeAll("(Requires active session on forge)\n");
            try stdout.interface.flush();
        } else {
            try stderr.interface.writeAll("Error: decision text required\n");
            try stderr.interface.flush();
        }
        return;
    }

    if (matches.subcommandMatches("converse")) |converse_matches| {
        if (converse_matches.getSingleValue("MESSAGE")) |message| {
            try stdout.interface.print("[human] {s}\n", .{message});
            try stdout.interface.writeAll("(Requires active session on forge)\n");
            try stdout.interface.flush();
        } else {
            try stderr.interface.writeAll("Error: message required\n");
            try stderr.interface.flush();
        }
        return;
    }

    if (matches.subcommandMatches("write")) |write_matches| {
        if (write_matches.getSingleValue("PATH")) |path| {
            const stdin_file = std.fs.File.stdin();
            const content = stdin_file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
                try stderr.interface.print("Error reading stdin: {}\n", .{err});
                try stderr.interface.flush();
                return;
            };
            defer allocator.free(content);

            const hash = hif.hash.hashBlob(content);
            const hex = hif.hash.formatHex(hash);

            try stdout.interface.print("Path: {s} ({d} bytes)\n", .{ path, content.len });
            try stdout.interface.print("Hash: {s}\n", .{hex});
            try stdout.interface.writeAll("(Blob will be uploaded to forge)\n");
            try stdout.interface.flush();
        } else {
            try stderr.interface.writeAll("Error: path required\n");
            try stderr.interface.flush();
        }
        return;
    }

    if (matches.subcommandMatches("cat")) |cat_matches| {
        if (cat_matches.getSingleValue("HASH")) |hash_str| {
            try stderr.interface.print("Blob {s} not found.\n", .{hash_str});
            try stderr.interface.writeAll("(Will fetch from forge when connected)\n");
            try stderr.interface.flush();
        } else {
            try stderr.interface.writeAll("Error: hash required\n");
            try stderr.interface.flush();
        }
        return;
    }

    if (matches.subcommandMatches("auth")) |auth_matches| {
        if (auth_matches.subcommandMatches("login")) |_| {
            var cfg = try config.load(allocator);
            
            // Generate client ID if needed
            if (cfg.client_id == null) {
                cfg.client_id = try auth.generateClientId(allocator);
                try config.save(allocator, cfg);
            }
            
            try stdout.interface.writeAll("Starting device code flow...\n");
            try stdout.interface.flush();
            
            // Start device code flow
            const device_response = auth.deviceCodeFlow(allocator, cfg.forge_url, cfg.client_id.?) catch |err| {
                try stderr.interface.print("Failed to start authentication: {}\n", .{err});
                try stderr.interface.flush();
                return;
            };
            defer allocator.free(device_response.device_code);
            defer allocator.free(device_response.user_code);
            defer allocator.free(device_response.verification_uri);
            
            try stdout.interface.print("\nVerification URL: {s}\n", .{device_response.verification_uri});
            try stdout.interface.print("User code: {s}\n\n", .{device_response.user_code});
            try stdout.interface.writeAll("Please open the URL above and enter the code.\n");
            try stdout.interface.writeAll("Waiting for authorization...\n");
            try stdout.interface.flush();
            
            // Poll for token
            const token_response = auth.pollForToken(
                allocator,
                cfg.forge_url,
                device_response.device_code,
                device_response.interval,
            ) catch |err| {
                try stderr.interface.print("Authentication failed: {}\n", .{err});
                try stderr.interface.flush();
                return;
            };
            defer allocator.free(token_response.access_token);
            defer if (token_response.refresh_token) |rt| allocator.free(rt);
            
            // Save tokens
            cfg.access_token = token_response.access_token;
            cfg.refresh_token = token_response.refresh_token;
            const now = std.time.timestamp();
            cfg.expires_at = now + token_response.expires_in;
            
            try config.save(allocator, cfg);
            
            try stdout.interface.writeAll("\n✓ Authentication successful!\n");
            try stdout.interface.flush();
            return;
        }
        
        if (auth_matches.subcommandMatches("logout")) |_| {
            const cfg = config.Config{};
            try config.save(allocator, cfg);
            try stdout.interface.writeAll("Logged out successfully.\n");
            try stdout.interface.flush();
            return;
        }
        
        if (auth_matches.subcommandMatches("status")) |_| {
            const cfg = config.load(allocator) catch |err| {
                if (err == error.FileNotFound) {
                    try stdout.interface.writeAll("Not authenticated.\n");
                    try stdout.interface.flush();
                    return;
                }
                return err;
            };
            
            if (cfg.access_token) |_| {
                try stdout.interface.writeAll("Authenticated\n");
                try stdout.interface.print("Forge: {s}\n", .{cfg.forge_url});
                if (cfg.expires_at) |expires| {
                    const now = std.time.timestamp();
                    if (expires > now) {
                        const remaining = expires - now;
                        try stdout.interface.print("Token expires in: {d}s\n", .{remaining});
                    } else {
                        try stdout.interface.writeAll("Token expired (run 'hif auth login' to refresh)\n");
                    }
                }
            } else {
                try stdout.interface.writeAll("Not authenticated.\n");
                try stdout.interface.writeAll("Run 'hif auth login' to authenticate.\n");
            }
            try stdout.interface.flush();
            return;
        }
        
        if (auth_matches.subcommandMatches("config")) |config_matches| {
            if (config_matches.getSingleValue("URL")) |url| {
                var cfg = try config.load(allocator);
                cfg.forge_url = url;
                try config.save(allocator, cfg);
                try stdout.interface.print("Forge URL set to: {s}\n", .{url});
                try stdout.interface.flush();
            } else {
                const cfg = config.load(allocator) catch config.Config{};
                try stdout.interface.print("Current forge URL: {s}\n", .{cfg.forge_url});
                try stdout.interface.writeAll("\nTo change: hif auth config <url>\n");
                try stdout.interface.flush();
            }
            return;
        }
        
        // Default: show auth help
        try stdout.interface.writeAll("Auth commands:\n");
        try stdout.interface.writeAll("  login   - Authenticate with the forge\n");
        try stdout.interface.writeAll("  logout  - Clear authentication tokens\n");
        try stdout.interface.writeAll("  status  - Show authentication status\n");
        try stdout.interface.writeAll("  config  - Configure forge URL\n");
        try stdout.interface.flush();
        return;
    }

    // No command matched, show help
    try app.displayHelp();
}
