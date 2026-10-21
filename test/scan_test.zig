//! Filesystem integration: scan a real temp tree with the shared scanner and compare against `du`.
const std = @import("std");
const core = @import("core");
const scan = @import("scan_pool");
const io = std.testing.io;
const gpa = std.testing.allocator;

const Done = struct {
    fn noop(_: *anyopaque) void {}
};

/// Scans `root` with `jobs` threads and returns the finished app (caller deinits).
fn scanTree(root: []const u8, jobs: usize) !core.App {
    var app = try core.App.init(gpa, root);
    errdefer app.deinit();
    var dummy: u8 = 0;
    var s = scan.Scanner.init(gpa, io, &app, .{ .ctx = &dummy, .func = Done.noop });
    defer s.deinit();
    s.lock();
    try s.pushLocked(&.{app.root});
    s.unlock();
    try s.start(jobs);
    while (true) {
        s.lock();
        const done = app.scan_done;
        s.unlock();
        if (done) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    return app;
}

/// `du -sk path` in bytes.
fn duBytes(path: []const u8) !u64 {
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "du", "-sk", path } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const end = std.mem.indexOfAny(u8, r.stdout, " \t") orelse return error.BadDuOutput;
    return 1024 * try std.fmt.parseInt(u64, r.stdout[0..end], 10);
}

fn absTmp(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

fn makeTree(dir: std.Io.Dir, cross_link: bool) !void {
    try dir.createDirPath(io, "a/deep/er");
    try dir.createDirPath(io, "b");
    try dir.createDirPath(io, "empty");
    const big = try gpa.alloc(u8, 300 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try dir.writeFile(io, .{ .sub_path = "a/deep/er/big.bin", .data = big });
    try dir.writeFile(io, .{ .sub_path = "a/small.txt", .data = "hello" });
    try dir.writeFile(io, .{ .sub_path = "b/mid.bin", .data = big[0 .. 100 * 1024] });
    // A hardlink counts once; a symlink loop is not followed.
    if (cross_link) {
        try std.Io.Dir.hardLink(dir, "a/deep/er/big.bin", dir, "b/big-link.bin", io, .{});
    } else {
        try std.Io.Dir.hardLink(dir, "a/deep/er/big.bin", dir, "a/deep/big-link.bin", io, .{});
    }
    try dir.symLink(io, "..", "b/loop", .{});
}

test "scan sizes match du -sk per directory; hardlink inside one subtree counted once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir, false);
    var buf: [4096]u8 = undefined;
    const root = try absTmp(&tmp, &buf);

    var app = try scanTree(root, 4);
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try app.view(arena.allocator());

    // du counts the root directory's own blocks, which the scan of its contents does not see.
    const du_total = try duBytes(root);
    const own = try duOwnBlocks(root);
    try std.testing.expectEqual(du_total - own, v.size);
    for (v.current) |r| {
        if (r.kind != .dir) continue;
        const p = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ root, r.name });
        try std.testing.expectEqual(try duBytes(p), r.size);
    }
    try std.testing.expectEqual(@as(usize, 0), v.status.errors);
}

test "hardlink across subtrees: total matches du (which directory is charged depends on scan order)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir, true);
    var buf: [4096]u8 = undefined;
    const root = try absTmp(&tmp, &buf);
    var app = try scanTree(root, 4);
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try app.view(arena.allocator());
    try std.testing.expectEqual(try duBytes(root) - try duOwnBlocks(root), v.size);
}

test "one thread and many threads produce the same view" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir, false);
    var buf: [4096]u8 = undefined;
    const root = try absTmp(&tmp, &buf);

    var one = try scanTree(root, 1);
    defer one.deinit();
    var many = try scanTree(root, 8);
    defer many.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = try one.view(arena.allocator());
    const b = try many.view(arena.allocator());
    try std.testing.expectEqual(a.size, b.size);
    try std.testing.expectEqual(a.current.len, b.current.len);
    for (a.current, b.current) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(x.size, y.size);
    }
}

test "unreadable directory is reported and its size is marked partial" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "locked/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "locked/inner/f", .data = "data" });
    var buf: [4096]u8 = undefined;
    const root = try absTmp(&tmp, &buf);
    const locked = try std.fmt.allocPrintSentinel(gpa, "{s}/locked", .{root}, 0);
    defer gpa.free(locked);
    _ = std.c.chmod(locked, 0);
    defer _ = std.c.chmod(locked, 0o755);
    if (std.c.getuid() == 0) return error.SkipZigTest; // root ignores permissions

    var app = try scanTree(root, 2);
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try app.view(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), v.status.errors);
    try std.testing.expect(v.current[0].incomplete);
}

/// Bytes used by the directory inode itself.
fn duOwnBlocks(root: []const u8) !u64 {
    const z = try gpa.dupeSentinel(u8, root, 0);
    defer gpa.free(z);
    var st: scan.Stat = undefined;
    if (scan.lstatAt(std.c.AT.FDCWD, z, &st) != 0) return error.StatFailed;
    return st.blocks * 512;
}

test "files with several hardlinks are flagged shared by the scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir, true);
    var buf: [4096]u8 = undefined;
    const root = try absTmp(&tmp, &buf);
    var app = try scanTree(root, 2);
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try app.view(arena.allocator());
    for (v.current) |r| {
        const want = std.mem.eql(u8, r.name, "a") or std.mem.eql(u8, r.name, "b");
        try std.testing.expectEqual(want, r.shared);
    }
}

test "macOS firmlink: the same directory reached via /Users and /System/Volumes/Data is counted once" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blob", .data = &@as([200 * 1024]u8, @splat('b')) });
    var buf: [4096]u8 = undefined;
    const real = try absTmp(&tmp, &buf);
    const twin = try std.fmt.allocPrint(gpa, "/System/Volumes/Data{s}", .{real});
    defer gpa.free(twin);
    // Only meaningful when the temp dir lives on the data volume behind a firmlink.
    if (try duBytes(twin) != try duBytes(real) or !std.mem.startsWith(u8, real, "/Users/")) return error.SkipZigTest;

    // Build "/" with both chains down to the temp dir, then scan both leaves.
    var app = try core.App.init(gpa, "/");
    defer app.deinit();
    var leaves: [2]core.NodeId = undefined;
    for ([_][]const u8{ real, twin }, &leaves) |p, *leaf| {
        var node = app.root;
        var it = std.mem.tokenizeScalar(u8, p, '/');
        while (it.next()) |part| {
            var found: core.NodeId = .nil;
            var ch = app.tree.get(node).first_child;
            while (ch != .nil) : (ch = app.tree.get(ch).next_sibling) {
                if (std.mem.eql(u8, app.tree.name(ch), part)) found = ch;
            }
            node = if (found != .nil) found else (try app.addDir(node, &.{.{ .name = part, .kind = .dir, .size = 0 }}))[0];
        }
        leaf.* = node;
    }
    var dummy: u8 = 0;
    var s = scan.Scanner.init(gpa, io, &app, .{ .ctx = &dummy, .func = Done.noop });
    defer s.deinit();
    s.lock();
    try s.pushLocked(&leaves);
    s.unlock();
    try s.start(2);
    while (true) {
        s.lock();
        const done = app.scan_done;
        s.unlock();
        if (done) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    const a = app.tree.get(leaves[0]);
    const b = app.tree.get(leaves[1]);
    try std.testing.expect(a.flags.alias != b.flags.alias);
    const counted = if (a.flags.alias) b else a;
    try std.testing.expect(counted.size >= 200 * 1024);
    try std.testing.expectEqual(counted.size, app.tree.get(app.root).size);
}
