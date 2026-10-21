const std = @import("std");
const Allocator = std.mem.Allocator;

/// Index into `Tree.nodes`. Slot 0 is the read-only nil node, so a zero-initialized id means "no node".
pub const NodeId = enum(u32) {
    nil = 0,
    _,

    pub fn index(id: NodeId) u32 {
        return @backingInt(id);
    }
};

pub const Kind = enum(u2) { dir, file, symlink, other };

pub const Flags = packed struct(u8) {
    /// Removed from the tree (trashed, deleted, or dropped by a rescan). Never listed again.
    deleted: bool = false,
    /// This directory could not be fully read.
    unreadable: bool = false,
    /// Size is partial: this node or a descendant was unreadable.
    incomplete: bool = false,
    /// This node or a descendant is a file with other hardlinks: deleting it may free less than its size.
    shared: bool = false,
    /// Another path to a directory already in the tree (same dev+inode, e.g. a macOS firmlink). Not scanned,
    /// counted as 0 bytes; `App.aliases` holds the path that is counted.
    alias: bool = false,
    _pad: u3 = 0,
};

pub const Node = struct {
    name_off: u32 = 0,
    name_len: u32 = 0,
    parent: NodeId = .nil,
    first_child: NodeId = .nil,
    next_sibling: NodeId = .nil,
    /// Bytes on disk (st_blocks * 512). For directories, includes all descendants.
    size: u64 = 0,
    kind: Kind = .dir,
    flags: Flags = .{},
};

/// One entry of a directory read, as reported by the platform scan.
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// Bytes on disk. 0 for a hardlink already counted elsewhere.
    size: u64,
    /// A file with more than one hardlink.
    shared: bool = false,
};

pub const Tree = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Allocator.Error!Tree {
        var t: Tree = .{};
        try t.nodes.append(gpa, .{}); // nil
        return t;
    }

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.names.deinit(gpa);
    }

    pub fn get(t: *const Tree, id: NodeId) Node {
        return t.nodes.get(id.index());
    }

    pub fn name(t: *const Tree, id: NodeId) []const u8 {
        const n = t.nodes.get(id.index());
        return t.names.items[n.name_off..][0..n.name_len];
    }

    pub fn add(t: *Tree, gpa: Allocator, node_name: []const u8, node: Node) Allocator.Error!NodeId {
        var n = node;
        n.name_off = @intCast(t.names.items.len);
        n.name_len = @intCast(node_name.len);
        try t.names.appendSlice(gpa, node_name);
        const id: NodeId = @fromBackingInt(@as(u32, @intCast(t.nodes.len)));
        try t.nodes.append(gpa, n);
        return id;
    }

    /// Links `child` as the first child of `parent`.
    pub fn link(t: *Tree, parent: NodeId, child: NodeId) void {
        const parents = t.nodes.items(.parent);
        const firsts = t.nodes.items(.first_child);
        const nexts = t.nodes.items(.next_sibling);
        parents[child.index()] = parent;
        nexts[child.index()] = firsts[parent.index()];
        firsts[parent.index()] = child;
    }

    /// Removes `child` from its parent's sibling list.
    pub fn unlink(t: *Tree, child: NodeId) void {
        const parent = t.nodes.items(.parent)[child.index()];
        const firsts = t.nodes.items(.first_child);
        const nexts = t.nodes.items(.next_sibling);
        if (firsts[parent.index()] == child) {
            firsts[parent.index()] = nexts[child.index()];
        } else {
            var it = firsts[parent.index()];
            while (it != .nil) : (it = nexts[it.index()]) {
                if (nexts[it.index()] == child) {
                    nexts[it.index()] = nexts[child.index()];
                    break;
                }
            }
        }
        nexts[child.index()] = .nil;
    }

    /// Adds `delta` bytes to `id` and every ancestor (saturating).
    pub fn addSize(t: *Tree, id: NodeId, delta: u64) void {
        const sizes = t.nodes.items(.size);
        const parents = t.nodes.items(.parent);
        var it = id;
        while (it != .nil) : (it = parents[it.index()]) sizes[it.index()] +|= delta;
    }

    /// Subtracts `delta` bytes from `id` and every ancestor (saturating).
    pub fn subSize(t: *Tree, id: NodeId, delta: u64) void {
        const sizes = t.nodes.items(.size);
        const parents = t.nodes.items(.parent);
        var it = id;
        while (it != .nil) : (it = parents[it.index()]) sizes[it.index()] -|= delta;
    }

    /// True if `id` or any ancestor is deleted.
    pub fn isDetached(t: *const Tree, id: NodeId) bool {
        const flags = t.nodes.items(.flags);
        const parents = t.nodes.items(.parent);
        var it = id;
        while (it != .nil) : (it = parents[it.index()]) {
            if (flags[it.index()].deleted) return true;
        }
        return false;
    }

    /// Writes the full path of `id` (its root's name is an absolute path).
    pub fn fullPath(t: *const Tree, id: NodeId, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        // Measure first, then fill back to front: no depth limit, one allocation.
        const parents = t.nodes.items(.parent);
        var len: usize = 0;
        var it = id;
        while (it != .nil) : (it = parents[it.index()]) {
            len += t.name(it).len;
            if (parents[it.index()] != .nil and !std.mem.endsWith(u8, t.name(parents[it.index()]), "/")) len += 1;
        }
        try out.resize(gpa, len);
        var end = len;
        it = id;
        while (it != .nil) : (it = parents[it.index()]) {
            const part = t.name(it);
            end -= part.len;
            @memcpy(out.items[end..][0..part.len], part);
            if (parents[it.index()] != .nil and !std.mem.endsWith(u8, t.name(parents[it.index()]), "/")) {
                end -= 1;
                out.items[end] = '/';
            }
        }
    }

    /// Children of `dir` that are not deleted, sorted: size desc, dirs first, ASCII case-insensitive name.
    pub fn sortedChildren(t: *const Tree, dir: NodeId, out: *std.ArrayList(NodeId), gpa: Allocator) Allocator.Error!void {
        out.clearRetainingCapacity();
        const nexts = t.nodes.items(.next_sibling);
        const flags = t.nodes.items(.flags);
        var it = t.nodes.items(.first_child)[dir.index()];
        while (it != .nil) : (it = nexts[it.index()]) {
            if (!flags[it.index()].deleted) try out.append(gpa, it);
        }
        std.mem.sort(NodeId, out.items, t, lessThan);
    }

    fn lessThan(t: *const Tree, a: NodeId, b: NodeId) bool {
        const sizes = t.nodes.items(.size);
        if (sizes[a.index()] != sizes[b.index()]) return sizes[a.index()] > sizes[b.index()];
        const kinds = t.nodes.items(.kind);
        const a_dir = kinds[a.index()] == .dir;
        const b_dir = kinds[b.index()] == .dir;
        if (a_dir != b_dir) return a_dir;
        switch (std.ascii.orderIgnoreCase(t.name(a), t.name(b))) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, t.name(a), t.name(b))) {
            .lt => return true,
            .gt => return false,
            .eq => return a.index() < b.index(),
        }
    }
};
