//! Shared scan helper the platforms call: a thread pool reading directories with portable libc calls
//! (openat + readdir + fstatat) and feeding `core.App.addDir`, one batch per directory.
//! `du` semantics: symlinks not followed, filesystems crossed, hardlinks counted once, size = st_blocks * 512.
const std = @import("std");
const core = @import("core");
const c = std.c;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Notify = struct {
    ctx: *anyopaque,
    /// Called from worker threads after progress and when the scan finishes. Must not block.
    func: *const fn (ctx: *anyopaque) void,
};

pub const Scanner = struct {
    gpa: Allocator,
    io: Io,
    app: *core.App,
    notify: Notify,
    /// Guards `app`, `stack`, `links`, `active`, `shutdown`. The UI thread takes it too.
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    stack: std.ArrayList(core.NodeId) = .empty,
    /// (dev, ino) of multi-link files already counted.
    links: std.AutoHashMapUnmanaged([2]u64, void) = .empty,
    active: usize = 0,
    shutdown: bool = false,
    idle_reported: bool = true,
    threads: []std.Thread = &.{},

    pub fn init(gpa: Allocator, io: Io, app: *core.App, notify: Notify) Scanner {
        return .{ .gpa = gpa, .io = io, .app = app, .notify = notify };
    }

    /// Starts `n` worker threads (0 = CPU count).
    pub fn start(s: *Scanner, n: usize) !void {
        const count = if (n == 0) std.Thread.getCpuCount() catch 4 else n;
        s.threads = try s.gpa.alloc(std.Thread, count);
        for (s.threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{s});
    }

    pub fn deinit(s: *Scanner) void {
        s.lock();
        s.shutdown = true;
        s.cond.broadcast(s.io);
        s.unlock();
        for (s.threads) |t| t.join();
        s.gpa.free(s.threads);
        s.stack.deinit(s.gpa);
        s.links.deinit(s.gpa);
    }

    pub fn lock(s: *Scanner) void {
        s.mutex.lockUncancelable(s.io);
    }

    pub fn unlock(s: *Scanner) void {
        s.mutex.unlock(s.io);
    }

    /// Queues directories to scan. Caller must hold the lock.
    pub fn pushLocked(s: *Scanner, ids: []const core.NodeId) Allocator.Error!void {
        if (ids.len == 0) return;
        try s.stack.appendSlice(s.gpa, ids);
        s.idle_reported = false;
        s.cond.broadcast(s.io);
    }

    fn worker(s: *Scanner) void {
        var batch: Batch = .{};
        defer batch.deinit(s.gpa);
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(s.gpa);
        var since_notify: usize = 0;

        s.lock();
        while (true) {
            while (s.stack.items.len == 0 and !s.shutdown) {
                if (s.active == 0 and !s.idle_reported) {
                    s.idle_reported = true;
                    s.app.scanDone();
                    s.notify.func(s.notify.ctx);
                }
                s.cond.wait(s.io, &s.mutex) catch {};
            }
            if (s.shutdown) break;
            const dir = s.stack.pop().?;
            s.active += 1;
            const p = s.app.path(dir) catch "";
            path.clearRetainingCapacity();
            path.appendSlice(s.gpa, p) catch {};
            path.append(s.gpa, 0) catch {};
            s.unlock();

            batch.reset();
            const err = readDir(s.gpa, path.items[0 .. path.items.len - 1 :0], &batch);

            s.lock();
            s.feed(dir, &batch, err, path.items[0 .. path.items.len - 1]) catch {};
            s.active -= 1;
            since_notify += 1;
            if (since_notify >= 64) {
                since_notify = 0;
                s.notify.func(s.notify.ctx);
            }
        }
        s.unlock();
    }

    /// Caller holds the lock.
    fn feed(s: *Scanner, dir: core.NodeId, batch: *Batch, err: ?ReadError, dir_path: []const u8) Allocator.Error!void {
        batch.entries.clearRetainingCapacity();
        for (batch.records.items) |r| {
            var size = r.size;
            if (r.link) |key| {
                const gop = try s.links.getOrPut(s.gpa, key);
                if (gop.found_existing) size = 0;
            }
            try batch.entries.append(s.gpa, .{ .name = batch.names.items[r.off..][0..r.len], .kind = r.kind, .size = size });
        }
        const ids = try s.app.addDir(dir, batch.entries.items);
        try s.pushLocked(ids);
        if (err) |e| {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ dir_path, @errorName(e) }) catch dir_path;
            try s.app.dirError(dir, msg);
        }
        for (batch.skipped.items) |name_range| {
            var buf: [4096]u8 = undefined;
            const name = batch.names.items[name_range[0]..][0..name_range[1]];
            const msg = std.fmt.bufPrint(&buf, "{s}/{s}: vanished or unreadable", .{ dir_path, name }) catch dir_path;
            try s.app.logError(msg);
        }
    }
};

/// One directory's entries. Names are offsets into `names`, which grows while reading.
const Record = struct { off: usize, len: usize, kind: core.Kind, size: u64, link: ?[2]u64 };

const Batch = struct {
    records: std.ArrayList(Record) = .empty,
    entries: std.ArrayList(core.Entry) = .empty,
    names: std.ArrayList(u8) = .empty,
    skipped: std.ArrayList([2]usize) = .empty,

    fn reset(b: *Batch) void {
        b.records.clearRetainingCapacity();
        b.names.clearRetainingCapacity();
        b.skipped.clearRetainingCapacity();
    }

    fn deinit(b: *Batch, gpa: Allocator) void {
        b.records.deinit(gpa);
        b.entries.deinit(gpa);
        b.names.deinit(gpa);
        b.skipped.deinit(gpa);
    }
};

const ReadError = error{ AccessDenied, NotFound, NotDir, OutOfMemory, Unexpected };

/// Reads one directory into `batch`. On error the batch holds whatever was read before it.
fn readDir(gpa: Allocator, path: [:0]const u8, batch: *Batch) ?ReadError {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return errnoError();
    const dirp = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return errnoError();
    };
    defer _ = c.closedir(dirp);

    while (c.readdir(dirp)) |ent| {
        const name = direntName(ent);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const off = batch.names.items.len;
        batch.names.appendSlice(gpa, name) catch return error.OutOfMemory;
        batch.names.append(gpa, 0) catch return error.OutOfMemory;
        const name_z = batch.names.items[off .. off + name.len :0];

        var st: Stat = undefined;
        if (lstatAt(fd, name_z, &st) != 0) {
            batch.skipped.append(gpa, .{ off, name.len }) catch return error.OutOfMemory;
            continue;
        }
        const kind: core.Kind = switch (st.mode & c.S.IFMT) {
            c.S.IFDIR => .dir,
            c.S.IFREG => .file,
            c.S.IFLNK => .symlink,
            else => .other,
        };
        const link: ?[2]u64 = if (kind != .dir and st.nlink > 1) .{ st.dev, st.ino } else null;
        batch.records.append(gpa, .{
            .off = off,
            .len = name.len,
            .kind = kind,
            .size = st.blocks * 512,
            .link = link,
        }) catch return error.OutOfMemory;
    }
    return null;
}

fn direntName(ent: *const c.dirent) []const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
}

fn errnoError() ReadError {
    return switch (std.posix.errno(@as(c_int, -1))) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.NotFound,
        .NOTDIR, .LOOP => error.NotDir,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// A single directory listing outside the scan (e.g. the root's real parent). Hardlinks are not deduplicated.
pub const Listing = struct {
    batch: Batch = .{},

    pub fn deinit(l: *Listing, gpa: Allocator) void {
        l.batch.deinit(gpa);
    }

    /// Reads `path`; the entries stay valid until the next `read` or `deinit`.
    pub fn read(l: *Listing, gpa: Allocator, path: [:0]const u8) Allocator.Error![]const core.Entry {
        l.batch.reset();
        _ = readDir(gpa, path, &l.batch);
        l.batch.entries.clearRetainingCapacity();
        for (l.batch.records.items) |r| {
            try l.batch.entries.append(gpa, .{ .name = l.batch.names.items[r.off..][0..r.len], .kind = r.kind, .size = r.size });
        }
        return l.batch.entries.items;
    }
};

/// fstatat(..., AT_SYMLINK_NOFOLLOW). std.c leaves fstatat undefined on Linux, so declare libc's directly.
/// The stat fields the scan needs, filled by `lstatAt`.
pub const Stat = struct { mode: u32, nlink: u64, dev: u64, ino: u64, blocks: u64 };

/// lstat relative to `dirfd`: fstatat(AT_SYMLINK_NOFOLLOW) on macOS, statx on Linux. Returns 0 on success.
pub fn lstatAt(dirfd: c.fd_t, path: [*:0]const u8, out: *Stat) c_int {
    if (@import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(dirfd, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .NLINK = true, .INO = true, .BLOCKS = true }, &stx);
        if (linux.errno(rc) != .SUCCESS) return -1;
        out.* = .{
            .mode = stx.mode,
            .nlink = stx.nlink,
            .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
            .ino = stx.ino,
            .blocks = stx.blocks,
        };
        return 0;
    }
    var st: c.Stat = undefined;
    if (c.fstatat(dirfd, path, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return -1;
    out.* = .{
        .mode = st.mode,
        .nlink = st.nlink,
        .dev = @bitCast(@as(i64, st.dev)),
        .ino = @intCast(st.ino),
        .blocks = @intCast(@max(st.blocks, 0)),
    };
    return 0;
}
