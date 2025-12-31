const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const yazap_mod = b.addModule("yazap", .{
        .root_source_file = b.path("vendor/yazap/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the hif module
    const hif_mod = b.addModule("hif", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable (skip for WASM)
    var exe: ?*std.Build.Step.Compile = null;
    if (target.result.os.tag != .freestanding) {
        const exe_val = b.addExecutable(.{
            .name = "hif",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hif", .module = hif_mod },
                    .{ .name = "yazap", .module = yazap_mod },
                },
            }),
        });
        b.installArtifact(exe_val);
        exe = exe_val;
    }

    // C ABI static library for FFI integration (skip for WASM)
    if (target.result.os.tag != .freestanding) {
        const ffi_lib = b.addLibrary(.{
            .name = "hif_ffi",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ffi.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hif", .module = hif_mod },
                },
            }),
        });
        ffi_lib.linkLibC();
        b.installArtifact(ffi_lib);
    }

    // Run step
    if (exe) |exe_val| {
        const run_cmd = b.addRunArtifact(exe_val);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Unit tests for lib
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Unit tests for exe
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hif", .module = hif_mod },
                .{ .name = "yazap", .module = yazap_mod },
            },
        }),
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
