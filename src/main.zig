const std = @import("std");
const yazap = @import("yazap");
const hif = @import("hif");

const App = yazap.App;
const Arg = yazap.Arg;

/// Simple stdout printing helper.
fn print(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout.writeAll(output) catch {};
}

fn printStr(str: []const u8) void {
    std.fs.File.stdout().writeAll(str) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator, "hif", "A version control system for an agent-first world");
    defer app.deinit();

    var root = app.rootCommand();

    // init command
    const init_cmd = app.createCommand("init", "Initialize a new hif repository");
    try root.addSubcommand(init_cmd);

    // session command with subcommands
    var session_cmd = app.createCommand("session", "Manage sessions");

    var session_start_cmd = app.createCommand("start", "Start a new session");
    try session_start_cmd.addArg(Arg.positional("goal", "The goal of this session", null));
    try session_cmd.addSubcommand(session_start_cmd);

    try root.addSubcommand(session_cmd);

    const matches = app.parseProcess() catch {
        try app.displayHelp();
        return;
    };

    if (matches.subcommandMatches("init")) |_| {
        runInit(allocator);
        return;
    }

    if (matches.subcommandMatches("session")) |session_matches| {
        if (session_matches.subcommandMatches("start")) |start_matches| {
            const goal = start_matches.getSingleValue("goal") orelse {
                printStr("Error: goal is required\n");
                return;
            };
            runSessionStart(allocator, goal);
            return;
        }

        try app.displayHelp();
        return;
    }

    try app.displayHelp();
}

fn runInit(allocator: std.mem.Allocator) void {
    const result = hif.initRepo(allocator, ".hif") catch |err| {
        print("Error initializing repository: {}\n", .{err});
        return;
    };
    switch (result) {
        .created => printStr("Initialized empty hif repository in .hif\n"),
        .already_exists => printStr("hif repository already exists in .hif\n"),
    }
}

fn runSessionStart(allocator: std.mem.Allocator, goal: []const u8) void {
    const result = hif.session.start(allocator, ".hif", goal, "local") catch |err| {
        switch (err) {
            hif.session.StartError.AlreadyInSession => {
                printStr("Error: already in a session. Land or abandon it first.\n");
            },
            hif.session.StartError.OutOfMemory => {
                printStr("Error: out of memory\n");
            },
            hif.session.StartError.FileSystemError => {
                printStr("Error: file system error. Is this a hif repository?\n");
            },
        }
        return;
    };

    print("Started session {s}\nGoal: {s}\n", .{ result.id, goal });
}
