//! macOS entry point: owns the main loop, the scan threads and the filesystem side effects.
const std = @import("std");
const core = @import("core");
const tui_mod = @import("tui");
const scan = @import("scan_pool");
const c = std.c;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    const home = env.get("HOME") orelse "/";

    const args = try parseArgs(init.arena.allocator(), init.minimal.args);
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(io, args.path orelse home, init.arena.allocator());

    var app = try core.App.init(gpa, root_path);
    defer app.deinit();
    app.dry_run = args.dry_run;
    try loadKeymap(gpa, io, env, home, &app);

    var tui: tui_mod.Tui = undefined;
    try tui.init(gpa, io, env);
    defer tui.deinit();

    var scanner = scan.Scanner.init(gpa, io, &app, .{ .ctx = &tui, .func = tui_mod.Tui.wake });
    defer scanner.deinit();
    var listing: scan.Listing = .{};
    defer listing.deinit(gpa);

    scanner.lock();
    try listOuter(gpa, &app, &listing);
    try scanner.pushLocked(&.{app.root});
    scanner.unlock();
    try scanner.start(args.jobs);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        scanner.lock();
        const v = app.view(arena.allocator());
        scanner.unlock();
        try tui.draw(arena.allocator(), try v);

        const ev = try tui.next();
        const key = switch (ev) {
            .key_press => |k| tui_mod.coreKey(k) orelse continue,
            else => continue,
        };
        scanner.lock();
        const cmd = app.handleKey(key) catch |e| {
            scanner.unlock();
            return e;
        };
        const quit = try execute(gpa, io, home, &app, &scanner, &tui, &listing, cmd);
        scanner.unlock();
        if (quit) break;
    }
}

/// Runs a command from the core. Called with the scanner lock held.
fn execute(gpa: Allocator, io: std.Io, home: []const u8, app: *core.App, scanner: *scan.Scanner, tui: *tui_mod.Tui, listing: *scan.Listing, cmd: core.Command) !bool {
    switch (cmd) {
        .none => {},
        .quit => return true,
        .trash => |id| {
            const path = try gpa.dupe(u8, try app.path(id));
            defer gpa.free(path);
            if (trash(gpa, home, path)) |_| app.markDeleted(id) else |e| try logFailure(gpa, app, "trash", path, e);
        },
        .delete => |id| {
            const path = try gpa.dupe(u8, try app.path(id));
            defer gpa.free(path);
            if (std.Io.Dir.cwd().deleteTree(io, path)) |_| app.markDeleted(id) else |e| try logFailure(gpa, app, "rm -r", path, e);
        },
        .rescan => |id| try scanner.pushLocked(&.{id}),
        .scroll => |s| {
            const n: i64 = @intCast(if (s.amount == .half_page) @max(tui.pageRows() / 2, 1) else s.lines);
            try app.moveCursor(if (s.down) n else -n);
        },
        .rerooted => |ids| {
            try scanner.pushLocked(ids);
            try listOuter(gpa, app, listing);
        },
    }
    return false;
}

/// Feeds the core the unscanned listing of the scan root's real parent.
fn listOuter(gpa: Allocator, app: *core.App, listing: *scan.Listing) !void {
    const root = try app.path(app.root);
    const parent = std.fs.path.dirname(root) orelse return app.setOuter(&.{});
    const z = try gpa.dupeSentinel(u8, parent, 0);
    defer gpa.free(z);
    try app.setOuter(try listing.read(gpa, z));
}

/// Moves `path` into ~/.Trash, adding " 2", " 3"... on name collisions.
fn trash(gpa: Allocator, home: []const u8, path: []const u8) !void {
    const base = std.fs.path.basename(path);
    const src = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(src);
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const dst = if (n == 1)
            try std.fmt.allocPrintSentinel(gpa, "{s}/.Trash/{s}", .{ home, base }, 0)
        else
            try std.fmt.allocPrintSentinel(gpa, "{s}/.Trash/{s} {d}", .{ home, base, n }, 0);
        defer gpa.free(dst);
        var st: scan.Stat = undefined;
        if (scan.lstatAt(c.AT.FDCWD, dst, &st) == 0) continue;
        if (c.rename(src, dst) == 0) return;
        return switch (std.posix.errno(@as(c_int, -1))) {
            .XDEV => error.TrashOnOtherVolume,
            .ACCES, .PERM => error.AccessDenied,
            .NOENT => error.NotFound,
            else => error.Unexpected,
        };
    }
    return error.TooManyNameCollisions;
}

fn logFailure(gpa: Allocator, app: *core.App, what: []const u8, path: []const u8, e: anyerror) !void {
    const msg = try std.fmt.allocPrint(gpa, "{s} failed for {s}: {s}", .{ what, path, @errorName(e) });
    defer gpa.free(msg);
    try app.logError(msg);
}

fn loadKeymap(gpa: Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8, app: *core.App) !void {
    const path = if (env.get("XDG_CONFIG_HOME")) |x|
        try std.fmt.allocPrint(gpa, "{s}/space-hog/keymap.zon", .{x})
    else
        try std.fmt.allocPrint(gpa, "{s}/.config/space-hog/keymap.zon", .{home});
    defer gpa.free(path);
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(1 << 20), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => return,
        else => {
            const msg = try std.fmt.allocPrint(gpa, "keymap: cannot read {s}: {s}", .{ path, @errorName(e) });
            defer gpa.free(msg);
            return app.logError(msg);
        },
    };
    defer gpa.free(src);
    try app.loadKeymap(src);
}

const Args = struct { path: ?[]const u8 = null, jobs: usize = 0, dry_run: bool = false };

/// `space-hog [-n|--dry-run] [-j N] [path]`
fn parseArgs(arena: Allocator, raw: std.process.Args) !Args {
    const argv = try raw.toSlice(arena);
    var out: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--dry-run")) {
            out.dry_run = true;
        } else if (std.mem.eql(u8, a, "-j") and i + 1 < argv.len) {
            i += 1;
            out.jobs = std.fmt.parseInt(usize, argv[i], 10) catch return error.InvalidJobs;
        } else if (std.mem.startsWith(u8, a, "-j")) {
            out.jobs = std.fmt.parseInt(usize, a[2..], 10) catch return error.InvalidJobs;
        } else {
            out.path = a;
        }
    }
    return out;
}
