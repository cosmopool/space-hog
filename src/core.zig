//! Sans-IO core: owns the tree, navigation and keymap; never touches the filesystem or the terminal.
//! The platform feeds it scan results and keys, executes the commands it returns, and reports back.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const tree = @import("tree.zig");
pub const rules = @import("rules.zig");
pub const keymap = @import("keymap.zig");
pub const view = @import("view.zig");

pub const NodeId = tree.NodeId;
pub const Entry = tree.Entry;
pub const Kind = tree.Kind;
pub const Key = keymap.Key;
pub const View = view.View;
pub const Row = view.Row;

pub const Scroll = struct {
    amount: enum { half_page, lines } = .half_page,
    lines: u32 = 0,
    down: bool,
};

pub const Command = union(enum) {
    none,
    quit,
    /// Move this node to the trash, then call `markDeleted` (or `logError` on failure).
    trash: NodeId,
    /// `rm -r` this node (already confirmed), then call `markDeleted` (or `logError` on failure).
    delete: NodeId,
    /// The directory's old contents were dropped; scan it again with `addDir`.
    rescan: NodeId,
    /// Convert to a row count with the terminal height and call `moveCursor`.
    scroll: Scroll,
    /// The scan root moved up one level. Scan these new directories with `addDir`, and call `setOuter` with the
    /// listing of the new root's parent. Slice valid until the next call into the App.
    rerooted: []const NodeId,
};

const Mode = enum { normal, prompt, log };

const OuterEntry = struct { name_off: u32, name_len: u32, kind: Kind, size: u64 };

pub const App = struct {
    gpa: Allocator,
    tree: tree.Tree,
    root: NodeId,
    cwd: NodeId,
    /// Selected node in `cwd`. May be stale (nil or deleted); resolved by `selected()`.
    cursor: NodeId = .nil,
    /// Last selection per directory, restored when coming back.
    cursors: std.AutoHashMapUnmanaged(NodeId, NodeId) = .empty,
    keys: keymap.Keymap,
    pending: keymap.Seq = .{},
    mode: Mode = .normal,
    prompt_target: NodeId = .nil,
    log: std.ArrayList([]u8) = .empty,
    log_cursor: usize = 0,
    /// Unscanned listing of the root's real parent directory.
    outer: std.ArrayList(OuterEntry) = .empty,
    outer_names: std.ArrayList(u8) = .empty,
    files: u64 = 0,
    bytes: u64 = 0,
    scan_done: bool = false,
    scratch: std.ArrayList(NodeId) = .empty,
    sorted: std.ArrayList(NodeId) = .empty,
    path_buf: std.ArrayList(u8) = .empty,

    /// `root_path` must be absolute. The platform then calls `addDir(app.root, ...)`.
    pub fn init(gpa: Allocator, root_path: []const u8) Allocator.Error!App {
        var t = try tree.Tree.init(gpa);
        errdefer t.deinit(gpa);
        const root = try t.add(gpa, root_path, .{ .kind = .dir });
        return .{ .gpa = gpa, .tree = t, .root = root, .cwd = root, .keys = keymap.Keymap.defaults() };
    }

    pub fn deinit(app: *App) void {
        const gpa = app.gpa;
        app.tree.deinit(gpa);
        app.cursors.deinit(gpa);
        for (app.log.items) |msg| gpa.free(msg);
        app.log.deinit(gpa);
        app.outer.deinit(gpa);
        app.outer_names.deinit(gpa);
        app.scratch.deinit(gpa);
        app.sorted.deinit(gpa);
        app.path_buf.deinit(gpa);
    }

    // ---- inputs from the platform ----

    /// Parses keymap.zon over the defaults; bad entries go to the error log.
    pub fn loadKeymap(app: *App, source: [:0]const u8) Allocator.Error!void {
        app.keys = try keymap.Keymap.parse(app.gpa, source, &app.log);
    }

    /// Adds the entries of one directory read. Returns the ids of the new subdirectories to scan
    /// (valid until the next call into the App). Ignored if `dir` was deleted or rescanned meanwhile.
    pub fn addDir(app: *App, dir: NodeId, entries: []const Entry) Allocator.Error![]const NodeId {
        app.scratch.clearRetainingCapacity();
        if (dir == .nil or app.tree.isDetached(dir)) return app.scratch.items;
        var sum: u64 = 0;
        for (entries) |e| {
            const id = try app.tree.add(app.gpa, e.name, .{ .kind = e.kind, .size = e.size });
            app.tree.link(dir, id);
            if (e.kind == .dir) try app.scratch.append(app.gpa, id);
            sum += e.size;
        }
        app.tree.addSize(dir, @intCast(sum));
        app.files += entries.len;
        app.bytes += sum;
        return app.scratch.items;
    }

    /// `dir` could not be (fully) read: its size is partial and `msg` goes to the error log.
    pub fn dirError(app: *App, dir: NodeId, msg: []const u8) Allocator.Error!void {
        if (dir != .nil) {
            const flags = app.tree.nodes.items(.flags);
            const parents = app.tree.nodes.items(.parent);
            flags[dir.index()].unreadable = true;
            var it = dir;
            while (it != .nil) : (it = parents[it.index()]) flags[it.index()].incomplete = true;
        }
        try app.logError(msg);
    }

    pub fn logError(app: *App, msg: []const u8) Allocator.Error!void {
        try app.log.append(app.gpa, try app.gpa.dupe(u8, msg));
    }

    pub fn scanDone(app: *App) void {
        app.scan_done = true;
    }

    /// The node was trashed or deleted: drop it and subtract its size from every ancestor.
    pub fn markDeleted(app: *App, id: NodeId) void {
        if (id == .nil or id == app.root or app.tree.isDetached(id)) return;
        const parent = app.tree.get(id).parent;
        if (app.cursor == id or (app.cursor == .nil and parent == app.cwd)) {
            app.cursor = app.neighbour(id) catch .nil;
        }
        // Leaving a deleted directory: land on its parent with the neighbour selected.
        if (app.isUnder(app.cwd, id)) {
            app.cwd = parent;
            app.cursor = app.neighbour(id) catch .nil;
        }
        app.tree.addSize(parent, -@as(i64, @intCast(app.tree.get(id).size)));
        app.tree.unlink(id);
        app.tree.nodes.items(.flags)[id.index()].deleted = true;
    }

    /// Unscanned listing of the scan root's real parent (shown in the parent column at the root).
    pub fn setOuter(app: *App, entries: []const Entry) Allocator.Error!void {
        app.outer.clearRetainingCapacity();
        app.outer_names.clearRetainingCapacity();
        for (entries) |e| {
            try app.outer.append(app.gpa, .{
                .name_off = @intCast(app.outer_names.items.len),
                .name_len = @intCast(e.name.len),
                .kind = e.kind,
                .size = e.size,
            });
            try app.outer_names.appendSlice(app.gpa, e.name);
        }
    }

    /// Moves the cursor by `delta` rows (clamped). Used for `Command.scroll`.
    pub fn moveCursor(app: *App, delta: i64) Allocator.Error!void {
        if (app.mode == .log) {
            const last: i64 = @as(i64, @intCast(app.log.items.len)) - 1;
            app.log_cursor = @intCast(std.math.clamp(@as(i64, @intCast(app.log_cursor)) + delta, 0, @max(last, 0)));
            return;
        }
        try app.tree.sortedChildren(app.cwd, &app.sorted, app.gpa);
        if (app.sorted.items.len == 0) return;
        const sel = app.selectedIn(app.sorted.items);
        const idx = std.mem.indexOfScalar(NodeId, app.sorted.items, sel) orelse 0;
        const last: i64 = @intCast(app.sorted.items.len - 1);
        const next = std.math.clamp(@as(i64, @intCast(idx)) + delta, 0, last);
        app.cursor = app.sorted.items[@intCast(next)];
    }

    pub fn handleKey(app: *App, key: Key) Allocator.Error!Command {
        if (app.mode == .prompt) {
            app.mode = .normal;
            const target = app.prompt_target;
            app.prompt_target = .nil;
            if (key.code == 'y' and !key.ctrl and !app.tree.isDetached(target)) return .{ .delete = target };
            return .none;
        }
        var seq = app.pending;
        seq.keys[seq.len] = key;
        seq.len += 1;
        const m = app.keys.match(seq);
        if (m.is_prefix and seq.len < keymap.SEQ_CAP) {
            app.pending = seq;
            return .none;
        }
        app.pending = .{};
        if (m.action) |action| return app.act(action);
        // An unfinished sequence followed by a non-matching key: drop the prefix, handle the key alone.
        if (seq.len > 1) return app.handleKey(key);
        return .none;
    }

    // ---- queries ----

    /// Full path of `id`; valid until the next call into the App.
    pub fn path(app: *App, id: NodeId) Allocator.Error![]const u8 {
        try app.tree.fullPath(id, &app.path_buf, app.gpa);
        return app.path_buf.items;
    }

    /// Builds the view model. Everything is allocated in `arena`.
    pub fn view(app: *App, arena: Allocator) Allocator.Error!View {
        var v: View = .{};
        var p: std.ArrayList(u8) = .empty;
        try app.tree.fullPath(app.cwd, &p, arena);
        v.path = p.items;
        v.size = app.tree.get(app.cwd).size;
        v.status = .{
            .files = app.files,
            .bytes = app.bytes,
            .scan_done = app.scan_done,
            .errors = app.log.items.len,
            .pending = try pendingText(arena, app.pending),
        };

        var kids: std.ArrayList(NodeId) = .empty;
        try app.tree.sortedChildren(app.cwd, &kids, arena);
        const sel = app.selectedIn(kids.items);
        v.current = try app.rows(arena, app.cwd, kids.items, sel);
        v.cursor = std.mem.indexOfScalar(NodeId, kids.items, sel) orelse 0;

        if (app.cwd != app.root) {
            const parent = app.tree.get(app.cwd).parent;
            var sibs: std.ArrayList(NodeId) = .empty;
            try app.tree.sortedChildren(parent, &sibs, arena);
            v.parent = try app.rows(arena, parent, sibs.items, app.cwd);
            v.parent_cursor = std.mem.indexOfScalar(NodeId, sibs.items, app.cwd) orelse 0;
        } else {
            const r = try app.outerRows(arena);
            v.parent = r.rows;
            v.parent_cursor = r.cursor;
        }

        if (sel != .nil and app.tree.get(sel).kind == .dir) {
            var grand: std.ArrayList(NodeId) = .empty;
            try app.tree.sortedChildren(sel, &grand, arena);
            v.preview = try app.rows(arena, sel, grand.items, .nil);
        }

        switch (app.mode) {
            .normal => {},
            .prompt => {
                var tp: std.ArrayList(u8) = .empty;
                try app.tree.fullPath(app.prompt_target, &tp, arena);
                v.prompt = .{ .path = tp.items, .size = app.tree.get(app.prompt_target).size };
            },
            .log => {
                v.mode = .log;
                v.log = app.log.items;
                v.log_cursor = app.log_cursor;
            },
        }
        return v;
    }

    // ---- internals ----

    fn act(app: *App, action: keymap.Action) Allocator.Error!Command {
        if (app.mode == .log) {
            switch (action) {
                .down => try app.moveCursor(1),
                .up => try app.moveCursor(-1),
                .top => app.log_cursor = 0,
                .bottom => app.log_cursor = app.log.items.len -| 1,
                .half_down => return .{ .scroll = .{ .down = true } },
                .half_up => return .{ .scroll = .{ .down = false } },
                .log, .quit => app.mode = .normal,
                else => {},
            }
            return .none;
        }
        switch (action) {
            .down => try app.moveCursor(1),
            .up => try app.moveCursor(-1),
            .top => try app.moveCursor(std.math.minInt(i32)),
            .bottom => try app.moveCursor(std.math.maxInt(i32)),
            .half_down => return .{ .scroll = .{ .down = true } },
            .half_up => return .{ .scroll = .{ .down = false } },
            .enter => {
                const sel = try app.selected();
                if (sel == .nil or app.tree.get(sel).kind != .dir) return .none;
                try app.cursors.put(app.gpa, app.cwd, sel);
                app.cwd = sel;
                app.cursor = app.cursors.get(sel) orelse .nil;
            },
            .parent => {
                if (app.cwd != app.root) {
                    try app.cursors.put(app.gpa, app.cwd, try app.selected());
                    app.cursor = app.cwd;
                    app.cwd = app.tree.get(app.cwd).parent;
                    return .none;
                }
                return app.reroot();
            },
            .trash => {
                const sel = try app.selected();
                if (sel == .nil) return .none;
                return .{ .trash = sel };
            },
            .delete => {
                const sel = try app.selected();
                if (sel == .nil) return .none;
                app.mode = .prompt;
                app.prompt_target = sel;
            },
            .rescan => {
                app.clearDir(app.cwd);
                app.scan_done = false;
                return .{ .rescan = app.cwd };
            },
            .log => {
                app.mode = .log;
                app.log_cursor = 0;
            },
            .quit => return .quit,
        }
        return .none;
    }

    /// The scan root's parent becomes the new root; the old root becomes one of its children (not rescanned).
    fn reroot(app: *App) Allocator.Error!Command {
        const old = app.root;
        const old_path = app.tree.name(old);
        const parent_path = std.fs.path.dirname(old_path) orelse return .none;
        if (app.outer.items.len == 0) return .none;

        const new = try app.tree.add(app.gpa, parent_path, .{ .kind = .dir });
        // The old root's name becomes its basename (a suffix of its full path).
        const base = std.fs.path.basename(app.tree.name(old));
        const n = &app.tree.nodes.items(.name_off)[old.index()];
        n.* += app.tree.nodes.items(.name_len)[old.index()] - @as(u32, @intCast(base.len));
        app.tree.nodes.items(.name_len)[old.index()] = @intCast(base.len);
        app.tree.link(new, old);
        app.tree.nodes.items(.size)[new.index()] = app.tree.get(old).size;
        if (app.tree.get(old).flags.incomplete) app.tree.nodes.items(.flags)[new.index()].incomplete = true;
        app.root = new;
        app.cwd = new;
        app.cursor = old;
        app.scan_done = false;

        var siblings: std.ArrayList(Entry) = .empty;
        defer siblings.deinit(app.gpa);
        for (app.outer.items) |o| {
            const name = app.outer_names.items[o.name_off..][0..o.name_len];
            if (std.mem.eql(u8, name, base)) {
                // The listing knows the old root's own blocks, which its scan never counted.
                app.tree.addSize(old, @intCast(o.size));
                continue;
            }
            try siblings.append(app.gpa, .{ .name = name, .kind = o.kind, .size = o.size });
        }
        const ids = try app.addDir(new, siblings.items);
        app.outer.clearRetainingCapacity();
        return .{ .rerooted = ids };
    }

    /// Drops the contents of `dir` (for a rescan).
    fn clearDir(app: *App, dir: NodeId) void {
        const nodes = &app.tree.nodes;
        var sum: u64 = 0;
        var it = nodes.items(.first_child)[dir.index()];
        while (it != .nil) : (it = nodes.items(.next_sibling)[it.index()]) {
            if (nodes.items(.flags)[it.index()].deleted) continue;
            sum += nodes.items(.size)[it.index()];
            nodes.items(.flags)[it.index()].deleted = true;
        }
        app.tree.addSize(dir, -@as(i64, @intCast(sum)));
        nodes.items(.first_child)[dir.index()] = .nil;
        nodes.items(.flags)[dir.index()].unreadable = false;
        nodes.items(.flags)[dir.index()].incomplete = false;
        app.cursor = .nil;
    }

    fn selected(app: *App) Allocator.Error!NodeId {
        try app.tree.sortedChildren(app.cwd, &app.sorted, app.gpa);
        return app.selectedIn(app.sorted.items);
    }

    /// The cursor if it is still a live child of `cwd`, else the first child, else nil.
    fn selectedIn(app: *const App, kids: []const NodeId) NodeId {
        if (std.mem.indexOfScalar(NodeId, kids, app.cursor) != null) return app.cursor;
        return if (kids.len > 0) kids[0] else .nil;
    }

    /// Row to select after `id` disappears: the next one in sorted order, else the previous one.
    fn neighbour(app: *App, id: NodeId) Allocator.Error!NodeId {
        try app.tree.sortedChildren(app.tree.get(id).parent, &app.sorted, app.gpa);
        const kids = app.sorted.items;
        const idx = std.mem.indexOfScalar(NodeId, kids, id) orelse return .nil;
        if (idx + 1 < kids.len) return kids[idx + 1];
        if (idx > 0) return kids[idx - 1];
        return .nil;
    }

    fn isUnder(app: *const App, id: NodeId, ancestor: NodeId) bool {
        const parents = app.tree.nodes.items(.parent);
        var it = id;
        while (it != .nil) : (it = parents[it.index()]) if (it == ancestor) return true;
        return false;
    }

    fn rows(app: *const App, arena: Allocator, parent: NodeId, kids: []const NodeId, sel: NodeId) Allocator.Error![]Row {
        const out = try arena.alloc(Row, kids.len);
        const sizes = try arena.alloc(u64, kids.len);
        const styles = try arena.alloc(rules.Style, kids.len);
        for (kids, sizes) |k, *s| s.* = app.tree.get(k).size;
        rules.classify(app.tree.get(parent).size, sizes, styles);
        for (kids, out, styles) |k, *r, style| {
            const n = app.tree.get(k);
            r.* = .{
                .name = app.tree.name(k),
                .size = n.size,
                .kind = n.kind,
                .style = style,
                .selected = k == sel,
                .incomplete = n.flags.incomplete,
            };
        }
        return out;
    }

    /// Parent column at the root: the real parent's listing, unscanned; the root itself shows its scanned size.
    fn outerRows(app: *const App, arena: Allocator) Allocator.Error!struct { rows: []Row, cursor: usize } {
        const base = std.fs.path.basename(app.tree.name(app.root));
        const out = try arena.alloc(Row, app.outer.items.len);
        for (app.outer.items, out) |o, *r| {
            const name = app.outer_names.items[o.name_off..][0..o.name_len];
            const is_root = std.mem.eql(u8, name, base);
            r.* = .{
                .name = name,
                .size = if (is_root) app.tree.get(app.root).size else 0,
                .kind = o.kind,
                .selected = is_root,
                .unscanned = !is_root,
                .incomplete = is_root and app.tree.get(app.root).flags.incomplete,
            };
        }
        std.mem.sort(Row, out, {}, struct {
            fn lt(_: void, a: Row, b: Row) bool {
                if ((a.kind == .dir) != (b.kind == .dir)) return a.kind == .dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt);
        var cursor: usize = 0;
        for (out, 0..) |r, i| if (r.selected) {
            cursor = i;
        };
        return .{ .rows = out, .cursor = cursor };
    }
};

fn pendingText(arena: Allocator, seq: keymap.Seq) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (seq.slice()) |k| {
        if (k.ctrl) try out.appendSlice(arena, "C-");
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(k.code, &buf) catch 0;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}
