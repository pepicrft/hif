const std = @import("std");
const clap = @import("clap");
const hif = @import("hif");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const SubCommand = enum { init };
    const main_params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit.
        \\<command>...
        \\
    );
    const main_parsers = comptime .{
        .command = clap.parsers.enumeration(SubCommand),
    };

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    var diag = clap.Diagnostic{};
    const res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try clap.helpToFile(.stdout(), clap.Help, &main_params, .{});
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stdout(), clap.Help, &main_params, .{});
        return;
    }

    const commands = res.positionals[0];
    if (commands.len == 0) {
        try clap.helpToFile(.stdout(), clap.Help, &main_params, .{});
        return;
    }
    const command = commands[0];

    if (iter.next()) |extra| {
        try std.io.getStdErr().writer().print("Unexpected argument: {s}\n", .{extra});
        return error.InvalidArgument;
    }

    switch (command) {
        .init => {
            const result = try hif.initRepo(allocator, ".hif");
            switch (result) {
                .created => try std.io.getStdOut().writer().print("Initialized empty hif repository in .hif\n", .{}),
                .already_exists => try std.io.getStdOut().writer().print("hif repository already exists in .hif\n", .{}),
            }
        },
    }
}
