//! Integration: key presses → core commands → fsops side effects on real temp directories.
//! Trash goes to a temp trash root, never the user's real trash.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const scan = @import("scan_pool");
const fsops = @import("fsops");
const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn noop(_: *anyopaque) void {}

/// A scanned temp tree plus everything `fsops.execute` needs.
const World = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    trash_root: []u8,
    app: core.App,
    scanner: scan.Scanner,
    listing: scan.Listing = .{},
    arena: std.heap.ArenaAllocator,
    dummy: u8 = 0,

    /// `build` populates `<tmp>/root`; `<tmp>/trash` is the trash root.
    fn init(w: *World, build: *const fn (std.Io.Dir) anyerror!void) !void {
        w.tmp = std.testing.tmpDir(.{});
        try w.tmp.dir.createDirPath(io, "root");
        try w.tmp.dir.createDirPath(io, "trash");
        var root_dir = try w.tmp.dir.openDir(io, "root", .{});
        defer root_dir.close(io);
        try build(root_dir);
        var buf: [4096]u8 = undefined;
        const base = buf[0..try w.tmp.dir.realPath(io, &buf)];
        w.root = try std.fmt.allocPrint(gpa, "{s}/root", .{base});
        w.trash_root = try std.fmt.allocPrint(gpa, "{s}/trash", .{base});
        w.app = try core.App.init(gpa, w.root);
        w.scanner = scan.Scanner.init(gpa, io, &w.app, .{ .ctx = &w.dummy, .func = noop });
        w.listing = .{};
        w.arena = .init(gpa);
        w.scanner.lock();
        try w.scanner.pushLocked(&.{w.app.root});
        w.scanner.unlock();
        try w.scanner.start(2);
        try w.waitScan();
    }

    fn deinit(w: *World) void {
        w.scanner.deinit();
        w.listing.deinit(gpa);
        w.app.deinit();
        w.arena.deinit();
        gpa.free(w.root);
        gpa.free(w.trash_root);
        w.tmp.cleanup();
    }

    fn waitScan(w: *World) !void {
        while (true) {
            w.scanner.lock();
            const done = w.app.scan_done;
            w.scanner.unlock();
            if (done) return;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
    }

    fn env(w: *World) fsops.Env {
        return .{ .home = "/nonexistent", .trash_root = w.trash_root, .keymap_path = "/nonexistent/keymap.zon" };
    }

    /// Types `keys` and runs each resulting command like the platform main does.
    fn press(w: *World, keys: []const u8) !void {
        for (keys) |k| {
            w.scanner.lock();
            defer w.scanner.unlock();
            const cmd = try w.app.handleKey(core.Key.char(k));
            _ = try fsops.execute(gpa, io, w.env(), &w.app, &w.scanner, &w.listing, 20, cmd);
        }
        try w.waitScan();
    }

    fn view(w: *World) !core.View {
        _ = w.arena.reset(.retain_capacity);
        w.scanner.lock();
        defer w.scanner.unlock();
        return w.app.view(w.arena.allocator());
    }

    fn exists(w: *World, sub: []const u8) bool {
        _ = w.tmp.dir.statFile(io, sub, .{ .follow_symlinks = false }) catch return false;
        return true;
    }
};

fn twoDirs(d: std.Io.Dir) !void {
    try d.createDirPath(io, "big/inner");
    try d.createDirPath(io, "small");
    const blob = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(blob);
    @memset(blob, 'b');
    try d.writeFile(io, .{ .sub_path = "big/inner/blob", .data = blob });
    try d.writeFile(io, .{ .sub_path = "small/s", .data = "s" });
}

test "x moves the selected directory into the trash root and drops it from the view" {
    var w: World = undefined;
    try w.init(twoDirs);
    defer w.deinit();
    const before = (try w.view()).size;
    try w.press("x");

    try expect(!w.exists("root/big"));
    try expect(w.exists("trash/big/inner/blob") or w.exists("trash/files/big/inner/blob"));
    const v = try w.view();
    try expectEqual(@as(usize, 1), v.current.len);
    try expectEqualStrings("small", v.current[0].name);
    try expect(v.size < before);
    try expectEqual(@as(usize, 0), v.status.errors);
}

test "trashing two items with the same name keeps both" {
    var w: World = undefined;
    try w.init(struct {
        fn build(d: std.Io.Dir) !void {
            try d.createDirPath(io, "a/dup");
            try d.createDirPath(io, "b/dup");
            try d.writeFile(io, .{ .sub_path = "a/dup/f", .data = "first-and-bigger" });
            try d.writeFile(io, .{ .sub_path = "b/dup/f", .data = "2nd" });
        }
    }.build);
    defer w.deinit();
    // After the first trash `b` is the larger one, so gg selects it.
    try w.press("lxhgglx");

    const second = if (builtin.os.tag == .macos) "trash/dup 2" else "trash/files/dup.2";
    const first = if (builtin.os.tag == .macos) "trash/dup" else "trash/files/dup";
    try expect(w.exists(first));
    try expect(w.exists(second));
    try expect(!w.exists("root/a/dup") and !w.exists("root/b/dup"));
}

test "X then y removes the directory; symlinks inside are removed, never followed" {
    var w: World = undefined;
    try w.init(struct {
        fn build(d: std.Io.Dir) !void {
            try d.createDirPath(io, "victim/sub");
            try d.writeFile(io, .{ .sub_path = "victim/sub/f", .data = &@as([5000]u8, @splat('x')) });
            try d.symLink(io, "../../outside", "victim/to-outside", .{});
            try d.symLink(io, "../../outside/keep.txt", "victim/sub/to-file", .{});
        }
    }.build);
    defer w.deinit();
    try w.tmp.dir.createDirPath(io, "outside");
    try w.tmp.dir.writeFile(io, .{ .sub_path = "outside/keep.txt", .data = "precious" });

    try w.press("Xy");
    try expect(!w.exists("root/victim"));
    try expect(w.exists("outside/keep.txt"));
    try expectEqual(@as(usize, 0), (try w.view()).current.len);
}

test "X followed by anything but y deletes nothing" {
    var w: World = undefined;
    try w.init(twoDirs);
    defer w.deinit();
    try w.press("Xn");
    try w.press("XX");
    try w.press("Xq");
    try expect(w.exists("root/big/inner/blob"));
    try expectEqual(@as(usize, 2), (try w.view()).current.len);
}

test "dry run: x and Xy leave the disk untouched" {
    var w: World = undefined;
    try w.init(twoDirs);
    defer w.deinit();
    w.app.dry_run = true;
    try w.press("xjXy");
    try expect(w.exists("root/big/inner/blob"));
    try expect(w.exists("root/small/s"));
    var it = (try w.tmp.dir.openDir(io, "trash", .{ .iterate = true }));
    defer it.close(io);
    var iter = it.iterate();
    try expect((try iter.next(io)) == null);
}

test "a failed rm -r is logged and the target is rescanned to match the disk" {
    if (std.c.getuid() == 0) return error.SkipZigTest;
    var w: World = undefined;
    try w.init(struct {
        fn build(d: std.Io.Dir) !void {
            try d.createDirPath(io, "ro/locked");
            try d.writeFile(io, .{ .sub_path = "ro/locked/f", .data = &@as([9000]u8, @splat('y')) });
            try d.writeFile(io, .{ .sub_path = "ro/loose", .data = &@as([9000]u8, @splat('z')) });
        }
    }.build);
    defer w.deinit();
    const locked = try std.fmt.allocPrintSentinel(gpa, "{s}/ro/locked", .{w.root}, 0);
    defer gpa.free(locked);
    _ = std.c.chmod(locked, 0o555);
    defer _ = std.c.chmod(locked, 0o755);

    try w.press("Xy");
    try expect(w.exists("root/ro/locked/f"));
    const v = try w.view();
    try expectEqual(@as(usize, 1), v.status.errors);
    try expectEqualStrings("ro", v.current[0].name);
    // Whatever rm -r managed to remove before failing, the rescanned view lists exactly what is on disk.
    try w.press("l");
    const inside = try w.view();
    const on_disk: usize = @as(usize, @intFromBool(w.exists("root/ro/locked"))) + @intFromBool(w.exists("root/ro/loose"));
    try expectEqual(on_disk, inside.current.len);
}

test "r picks up external changes without duplicates" {
    var w: World = undefined;
    try w.init(twoDirs);
    defer w.deinit();
    try w.press("l");
    try w.tmp.dir.writeFile(io, .{ .sub_path = "root/big/new", .data = &@as([70000]u8, @splat('n')) });
    try w.tmp.dir.deleteTree(io, "root/big/inner");
    try w.press("r");
    const v = try w.view();
    try expectEqual(@as(usize, 1), v.current.len);
    try expectEqualStrings("new", v.current[0].name);
    try w.press("r");
    try expectEqual(@as(usize, 1), (try w.view()).current.len);
}

test "readDisk: the scan root's volume has a size, free space within it, and a name" {
    var w: World = undefined;
    try w.init(twoDirs);
    defer w.deinit();
    w.scanner.lock();
    try fsops.readDisk(gpa, &w.app);
    w.scanner.unlock();
    const d = (try w.view()).disk;
    try expect(d.total > 0);
    try expect(d.free <= d.total);
    try expect(d.name.len > 0);
    // Linux names the mount point, which must contain the scan root.
    if (builtin.os.tag == .linux) try expect(std.mem.startsWith(u8, w.root, d.name));
}

test "parseArgs: flags, -j forms, last path wins, bad -j rejected" {
    const a = try fsops.parseArgs(&.{ "space-hog", "-n", "-j", "4", "/tmp" });
    try expect(a.dry_run);
    try expectEqual(@as(usize, 4), a.jobs);
    try expectEqualStrings("/tmp", a.path.?);
    const b = try fsops.parseArgs(&.{ "space-hog", "--dry-run", "-j8", "a", "b" });
    try expect(b.dry_run);
    try expectEqual(@as(usize, 8), b.jobs);
    try expectEqualStrings("b", b.path.?);
    const c = try fsops.parseArgs(&.{"space-hog"});
    try expect(!c.dry_run and c.path == null and c.jobs == 0);
    try std.testing.expectError(error.InvalidJobs, fsops.parseArgs(&.{ "space-hog", "-j", "abc" }));
    try expectEqual(@as(usize, fsops.MAX_JOBS), (try fsops.parseArgs(&.{ "space-hog", "-j", "100000" })).jobs);
}

test "Env: XDG values that are empty or relative are ignored" {
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("HOME", "/home/u");
    try map.put("XDG_CONFIG_HOME", "");
    try map.put("XDG_DATA_HOME", "relative/data");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const e = try fsops.Env.init(arena.allocator(), &map);
    try expectEqualStrings("/home/u/.config/space-hog/keymap.zon", e.keymap_path);
    const want_trash = if (builtin.os.tag == .macos) "/home/u/.Trash" else "/home/u/.local/share/Trash";
    try expectEqualStrings(want_trash, e.trash_root);

    try map.put("XDG_CONFIG_HOME", "/cfg");
    try map.put("XDG_DATA_HOME", "/data");
    const f = try fsops.Env.init(arena.allocator(), &map);
    try expectEqualStrings("/cfg/space-hog/keymap.zon", f.keymap_path);
    if (builtin.os.tag != .macos) try expectEqualStrings("/data/Trash", f.trash_root);
}

test "loadKeymap: missing file is silent, a valid file applies, a broken one is logged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(gpa, "{s}/keymap.zon", .{base});
    defer gpa.free(path);
    const env: fsops.Env = .{ .home = base, .trash_root = base, .keymap_path = path };

    var app = try core.App.init(gpa, "/r");
    defer app.deinit();
    try fsops.loadKeymap(gpa, io, env, &app);
    try expectEqual(@as(usize, 0), app.log.items.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "keymap.zon", .data = ".{ .quit = \"Q\" }" });
    try fsops.loadKeymap(gpa, io, env, &app);
    try expectEqual(core.Command.quit, try app.handleKey(core.Key.char('Q')));

    try tmp.dir.writeFile(io, .{ .sub_path = "keymap.zon", .data = ".{ .quit = " });
    try fsops.loadKeymap(gpa, io, env, &app);
    try expectEqual(@as(usize, 1), app.log.items.len);
    try expectEqual(core.Command.quit, try app.handleKey(core.Key.char('q')));
}

test "a parent swapped for a symlink after the scan: delete and trash refuse and leave the link target alone" {
    var w: World = undefined;
    try w.init(struct {
        fn build(d: std.Io.Dir) !void {
            try d.createDirPath(io, "proj/build");
            try d.writeFile(io, .{ .sub_path = "proj/build/out", .data = "o" });
        }
    }.build);
    defer w.deinit();
    // Elsewhere: a directory with the same shape that must survive.
    try w.tmp.dir.createDirPath(io, "elsewhere/build");
    try w.tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/build/precious", .data = "keep" });
    try w.press("l"); // into proj, cursor on build
    try w.tmp.dir.deleteTree(io, "root/proj");
    try w.tmp.dir.symLink(io, "../elsewhere", "root/proj", .{});

    try w.press("Xy");
    try expect(w.exists("elsewhere/build/precious"));
    try w.press("x");
    try expect(w.exists("elsewhere/build/precious"));
    try expect((try w.view()).status.errors >= 1);
}

test "linux: trash writes a .trashinfo with the percent-encoded original path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var w: World = undefined;
    try w.init(struct {
        fn build(d: std.Io.Dir) !void {
            try d.createDirPath(io, "has space%#é");
            try d.writeFile(io, .{ .sub_path = "has space%#é/f", .data = "x" });
        }
    }.build);
    defer w.deinit();
    try w.press("x");
    try expect(w.exists("trash/files/has space%#é/f"));
    const info = try w.tmp.dir.readFileAlloc(io, "trash/info/has space%#é.trashinfo", gpa, .limited(4096));
    defer gpa.free(info);
    const want_path = try std.fmt.allocPrint(gpa, "[Trash Info]\nPath={s}/has%20space%25%23%C3%A9\nDeletionDate=", .{w.root});
    defer gpa.free(want_path);
    try expect(std.mem.startsWith(u8, info, want_path));
    try expectEqual(@as(usize, "YYYY-MM-DDThh:mm:ss\n".len), info.len - want_path.len);
}

test "linux: names too long for the trash are shortened, the info keeps the full path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var w: World = undefined;
    try w.init(struct {
        fn build(d: std.Io.Dir) !void {
            const long = comptime rep("L", 250);
            try d.createDirPath(io, long);
            try d.writeFile(io, .{ .sub_path = comptime (long ++ "/f"), .data = "x" });
        }
    }.build);
    defer w.deinit();
    try w.press("x");
    try expectEqual(@as(usize, 0), (try w.view()).current.len);
    var dir = try w.tmp.dir.openDir(io, "trash/info", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    const e = (try it.next(io)).?;
    try expect(e.name.len <= 255);
    const info = try dir.readFileAlloc(io, e.name, gpa, .limited(4096));
    defer gpa.free(info);
    try expect(std.mem.indexOf(u8, info, comptime rep("L", 250)) != null);
}

/// `s` repeated `n` times, at compile time.
fn rep(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}
