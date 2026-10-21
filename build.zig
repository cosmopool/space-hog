const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug info from the binary (release archives)") orelse false;
    const exe = addExe(b, target, optimize, strip);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    for ([_][]const u8{ "test/core_test.zig", "test/scan_test.zig", "test/fsops_test.zig", "test/tui_test.zig", "test/fuzzy/names_fuzz.zig", "test/fuzzy/keymap_fuzz.zig" }) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = exe.root_module.import_table.get("core").? },
                .{ .name = "scan_pool", .module = exe.root_module.import_table.get("scan_pool").? },
                .{ .name = "fsops", .module = exe.root_module.import_table.get("fsops").? },
                .{ .name = "tui", .module = exe.root_module.import_table.get("tui").? },
                .{ .name = "vaxis", .module = exe.root_module.import_table.get("tui").?.import_table.get("vaxis").? },
            },
        }) });
        // Always execute: results depend on the OS and filesystem (du, trash, firmlinks), not just on the test
        // binary, so a cached "pass" from an earlier run must not count. Compilation stays cached.
        const run = b.addRunArtifact(t);
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }

    // screenshots: README images from mock data drawn by the real paint() code.
    const shots = b.addExecutable(.{
        .name = "screenshots",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/screenshots.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = exe.root_module.import_table.get("core").? },
                .{ .name = "tui", .module = exe.root_module.import_table.get("tui").? },
                .{ .name = "vaxis", .module = exe.root_module.import_table.get("tui").?.import_table.get("vaxis").? },
            },
        }),
    });
    const run_shots = b.addRunArtifact(shots);
    run_shots.setCwd(b.path("."));
    run_shots.addArg("docs/img");
    b.step("screenshots", "Render README screenshots into docs/img").dependOn(&run_shots.step);

    // check: tests + Debug + ReleaseSafe + Linux cross-compile
    const check_step = b.step("check", "Tests, Debug and ReleaseSafe builds, Linux cross-compile");
    check_step.dependOn(test_step);
    const variants = [_]struct { os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, mode: std.builtin.OptimizeMode }{
        .{ .os = target.result.os.tag, .arch = target.result.cpu.arch, .mode = .Debug },
        .{ .os = target.result.os.tag, .arch = target.result.cpu.arch, .mode = .ReleaseSafe },
        .{ .os = .linux, .arch = .x86_64, .mode = .ReleaseSafe },
        .{ .os = .linux, .arch = .aarch64, .mode = .ReleaseSafe },
    };
    for (variants) |v| {
        const t = b.resolveTargetQuery(.{ .os_tag = v.os, .cpu_arch = v.arch, .abi = if (v.os == .linux) .musl else null });
        check_step.dependOn(&addExe(b, t, v.mode, false).step);
    }
}

fn addExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool) *std.Build.Step.Compile {
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");
    const core = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize });
    const scan_pool = b.createModule(.{
        .root_source_file = b.path("src/scan_pool.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    const tui = b.createModule(.{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "vaxis", .module = vaxis } },
    });
    const fsops = b.createModule(.{
        .root_source_file = b.path("src/fsops.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "scan_pool", .module = scan_pool } },
    });
    const root = switch (target.result.os.tag) {
        .macos => "src/platform/macos.zig",
        .linux => "src/platform/linux.zig",
        else => @panic("space-hog supports macOS and Linux only"),
    };
    return b.addExecutable(.{
        .name = "space-hog",
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "scan_pool", .module = scan_pool },
                .{ .name = "tui", .module = tui },
                .{ .name = "fsops", .module = fsops },
            },
        }),
    });
}
