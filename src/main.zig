const std = @import("std");
const yazap = @import("yazap");
const hif = @import("hif");

const App = yazap.App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator, "hif", "A content-addressable version control system");
    defer app.deinit();

    var root = app.rootCommand();

    const init_cmd = app.createCommand("init", "Initialize a new hif repository");
    try root.addSubcommand(init_cmd);

    const matches = app.parseProcess() catch {
        try app.displayHelp();
        return;
    };

    if (matches.subcommandMatches("init")) |_| {
        const result = try hif.initRepo(allocator, ".hif");
        var buf: [256]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&buf);
        switch (result) {
            .created => try stdout.interface.writeAll("Initialized empty hif repository in .hif\n"),
            .already_exists => try stdout.interface.writeAll("hif repository already exists in .hif\n"),
        }
        try stdout.interface.flush();
        return;
    }

    try app.displayHelp();
}
