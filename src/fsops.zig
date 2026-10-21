//! Filesystem side effects shared by the platform mains: running core commands (trash, rm -r, rescan,
//! re-root), loading the keymap, parsing args. The core never calls this; the platforms do.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const scan = @import("scan_pool");
const c = std.c;
const Allocator = std.mem.Allocator;

/// Paths derived from the environment once at startup.
pub const Env = struct {
    home: []const u8,
    /// macOS: ~/.Trash. Linux: $XDG_DATA_HOME/Trash (default ~/.local/share/Trash).
    trash_root: []const u8,
    keymap_path: []const u8,

    /// Empty or relative XDG values are ignored, as the XDG spec says.
    pub fn init(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error!Env {
        const home = env.get("HOME") orelse "/";
        const data_home = absOrNull(env.get("XDG_DATA_HOME"));
        const config_home = absOrNull(env.get("XDG_CONFIG_HOME"));
        return .{
            .home = home,
            .trash_root = switch (builtin.os.tag) {
                .macos => try std.fmt.allocPrint(arena, "{s}/.Trash", .{home}),
                else => if (data_home) |d|
                    try std.fmt.allocPrint(arena, "{s}/Trash", .{d})
                else
                    try std.fmt.allocPrint(arena, "{s}/.local/share/Trash", .{home}),
            },
            .keymap_path = if (config_home) |d|
                try std.fmt.allocPrint(arena, "{s}/space-hog/keymap.zon", .{d})
            else
                try std.fmt.allocPrint(arena, "{s}/.config/space-hog/keymap.zon", .{home}),
        };
    }

    fn absOrNull(v: ?[]const u8) ?[]const u8 {
        const s = v orelse return null;
        return if (std.fs.path.isAbsolute(s)) s else null;
    }
};

pub const Args = struct { path: ?[]const u8 = null, jobs: usize = 0, dry_run: bool = false };

/// `space-hog [-n|--dry-run] [-j N] [path]`. `argv[0]` is the program name.
pub fn parseArgs(argv: []const []const u8) error{InvalidJobs}!Args {
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

/// Reads the keymap file if present; problems go to the app's log, never fail startup.
pub fn loadKeymap(gpa: Allocator, io: std.Io, env: Env, app: *core.App) Allocator.Error!void {
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, env.keymap_path, gpa, .limited(1 << 20), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => return,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const msg = try std.fmt.allocPrint(gpa, "keymap: cannot read {s}: {s}", .{ env.keymap_path, @errorName(e) });
            defer gpa.free(msg);
            return app.logError(msg);
        },
    };
    defer gpa.free(src);
    try app.loadKeymap(src);
}

/// Runs a command from the core. Caller holds the scanner lock. Returns true to quit.
/// `page_rows` turns a half-page scroll into a row count.
pub fn execute(gpa: Allocator, io: std.Io, env: Env, app: *core.App, scanner: *scan.Scanner, listing: *scan.Listing, page_rows: usize, cmd: core.Command) !bool {
    switch (cmd) {
        .none => {},
        .quit => return true,
        .trash => |id| {
            const path = try gpa.dupe(u8, try app.path(id));
            defer gpa.free(path);
            if (trash(gpa, env.trash_root, path)) |_| app.markDeleted(id) else |e| try logFailure(gpa, app, "trash", path, e);
        },
        .delete => |id| {
            const path = try gpa.dupe(u8, try app.path(id));
            defer gpa.free(path);
            if (std.Io.Dir.cwd().deleteTree(io, path)) |_| app.markDeleted(id) else |e| {
                try logFailure(gpa, app, "rm -r", path, e);
                // Part of it may be gone: rescan so the tree matches the disk.
                const again = try app.rescan(id);
                if (again != .nil) try scanner.pushLocked(&.{again});
            }
        },
        .rescan => |id| try scanner.pushLocked(&.{id}),
        .scroll => |s| {
            const n: i64 = @intCast(if (s.amount == .half_page) @max(page_rows / 2, 1) else s.lines);
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
pub fn listOuter(gpa: Allocator, app: *core.App, listing: *scan.Listing) !void {
    const root = try app.path(app.root);
    const parent = std.fs.path.dirname(root) orelse return app.setOuter(&.{});
    const z = try gpa.dupeSentinel(u8, parent, 0);
    defer gpa.free(z);
    try app.setOuter(try listing.read(gpa, z));
}

fn logFailure(gpa: Allocator, app: *core.App, what: []const u8, path: []const u8, e: anyerror) !void {
    const msg = try std.fmt.allocPrint(gpa, "{s} failed for {s}: {s}", .{ what, path, @errorName(e) });
    defer gpa.free(msg);
    try app.logError(msg);
}

const trash = switch (builtin.os.tag) {
    .macos => trashMacos,
    else => trashFreedesktop,
};

/// Moves `path` into `trash_root` (~/.Trash), adding " 2", " 3"... on name collisions.
fn trashMacos(gpa: Allocator, trash_root: []const u8, path: []const u8) !void {
    const base = std.fs.path.basename(path);
    const src = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(src);
    const root_z = try gpa.dupeSentinel(u8, trash_root, 0);
    defer gpa.free(root_z);
    if (c.mkdir(root_z, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return error.TrashDirFailed;
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const dst = if (n == 1)
            try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ trash_root, base }, 0)
        else
            try std.fmt.allocPrintSentinel(gpa, "{s}/{s} {d}", .{ trash_root, base, n }, 0);
        defer gpa.free(dst);
        var st: scan.Stat = undefined;
        if (scan.lstatAt(c.AT.FDCWD, dst, &st) == 0) continue;
        // RENAME_EXCL: never replace something that appeared at `dst` since the check above.
        if (renamex_np(src, dst, RENAME_EXCL) == 0) return;
        return switch (std.posix.errno(@as(c_int, -1))) {
            .EXIST => continue,
            .XDEV => error.TrashOnOtherVolume,
            .ACCES, .PERM => error.AccessDenied,
            .NOENT => error.NotFound,
            else => error.Unexpected,
        };
    }
    return error.TooManyNameCollisions;
}

const RENAME_EXCL: c_uint = 0x4;
extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;

/// Moves `path` to the FreeDesktop trash at `trash_root` ($XDG_DATA_HOME/Trash): writes
/// info/<name>.trashinfo first, then renames into files/<name>. Names collide → "<name>.2", "<name>.3"...
fn trashFreedesktop(gpa: Allocator, trash_root: []const u8, path: []const u8) !void {
    const files_dir = try std.fmt.allocPrintSentinel(gpa, "{s}/files", .{trash_root}, 0);
    defer gpa.free(files_dir);
    const info_dir = try std.fmt.allocPrintSentinel(gpa, "{s}/info", .{trash_root}, 0);
    defer gpa.free(info_dir);
    try mkdirP(gpa, files_dir);
    try mkdirP(gpa, info_dir);

    const base = std.fs.path.basename(path);
    const src = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(src);
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const name = if (n == 1) try gpa.dupe(u8, base) else try std.fmt.allocPrint(gpa, "{s}.{d}", .{ base, n });
        defer gpa.free(name);
        const info_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}.trashinfo", .{ info_dir, name }, 0);
        defer gpa.free(info_path);
        const dst = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ files_dir, name }, 0);
        defer gpa.free(dst);

        var st: scan.Stat = undefined;
        if (scan.lstatAt(c.AT.FDCWD, dst, &st) == 0) continue;
        const fd = c.open(info_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) {
            if (std.posix.errno(@as(c_int, -1)) == .EXIST) continue;
            return error.TrashInfoFailed;
        }
        const info = try trashInfo(gpa, path);
        defer gpa.free(info);
        const written = c.write(fd, info.ptr, info.len);
        _ = c.close(fd);
        if (written != @as(isize, @intCast(info.len))) {
            _ = c.unlink(info_path);
            return error.TrashInfoFailed;
        }
        if (c.rename(src, dst) == 0) return;
        const err = std.posix.errno(@as(c_int, -1));
        _ = c.unlink(info_path);
        return switch (err) {
            .XDEV => error.TrashOnOtherVolume,
            .ACCES, .PERM => error.AccessDenied,
            .NOENT => error.NotFound,
            else => error.Unexpected,
        };
    }
    return error.TooManyNameCollisions;
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c.time_t, out: *Tm) ?*Tm;
extern "c" fn time(t: ?*c.time_t) c.time_t;

/// `[Trash Info]` file body: percent-encoded absolute path and local deletion time.
fn trashInfo(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "[Trash Info]\nPath=");
    for (path) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "/-_.~", b) != null) {
            try out.append(gpa, b);
        } else {
            try out.print(gpa, "%{X:0>2}", .{b});
        }
    }
    const now = time(null);
    var tm: Tm = std.mem.zeroes(Tm);
    if (localtime_r(&now, &tm) == null) return error.NoLocalTime;
    try out.print(gpa, "\nDeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),        @as(u32, @intCast(tm.min)),     @as(u32, @intCast(tm.sec)),
    });
    return out.toOwnedSlice(gpa);
}

fn mkdirP(gpa: Allocator, path: [:0]const u8) !void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        const part = try gpa.dupeSentinel(u8, path[0..i], 0);
        defer gpa.free(part);
        if (c.mkdir(part, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return error.TrashDirFailed;
    }
}
