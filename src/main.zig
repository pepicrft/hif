const std = @import("std");
const yazap = @import("yazap");
const hif = @import("hif");

const App = yazap.App;
const Arg = yazap.Arg;

fn print(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout.writeAll(output) catch {};
}

fn printStr(str: []const u8) void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(str) catch {};
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
        const result = try hif.initRepo(allocator, ".hif");
        switch (result) {
            .created => printStr("Initialized empty hif repository in .hif\n"),
            .already_exists => printStr("hif repository already exists in .hif\n"),
        }
        return;
    }

    if (matches.subcommandMatches("session")) |session_matches| {
        if (session_matches.subcommandMatches("start")) |start_matches| {
            const goal = start_matches.getSingleValue("goal") orelse {
                printStr("Error: goal is required\n");
                return;
            };

            const result = hif.session.start(allocator, ".hif", goal, "local") catch |err| {
                print("Error starting session: {}\n", .{err});
                return;
            };

            switch (result.result) {
                .created => print("Started session {s}\nGoal: {s}\n", .{ result.id, goal }),
                .already_in_session => printStr("Error: already in a session. Land or abandon it first.\n"),
            }
            return;
        }

        try app.displayHelp();
        return;
    }

    try app.displayHelp();
}
