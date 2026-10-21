const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");

    const exe = b.addExecutable(.{
        .name = "space-hog",
        .root_module = b.createModule(.{
            .root_source_file = b.path(platformRoot(target.result.os.tag)),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vaxis", .module = vaxis }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

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
        const dep = b.dependency("vaxis", .{ .target = t, .optimize = v.mode }).module("vaxis");
        const c = b.addExecutable(.{
            .name = "space-hog",
            .root_module = b.createModule(.{
                .root_source_file = b.path(platformRoot(v.os)),
                .target = t,
                .optimize = v.mode,
                .imports = &.{.{ .name = "vaxis", .module = dep }},
            }),
        });
        check_step.dependOn(&c.step);
    }
}

fn platformRoot(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "src/platform/macos.zig",
        .linux => "src/platform/linux.zig",
        else => @panic("space-hog supports macOS and Linux only"),
    };
}
