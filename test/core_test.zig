//! Smoke tests for core.App through its public API (feed entries, press keys, read the View / Commands).
const std = @import("std");
const core = @import("core");
const App = core.App;
const Key = core.Key;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Fixture = struct {
    app: App,
    arena: std.heap.ArenaAllocator,

    fn init(root_path: []const u8) !Fixture {
        return .{ .app = try App.init(std.testing.allocator, root_path), .arena = .init(std.testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        f.arena.deinit();
    }

    fn view(f: *Fixture) !core.View {
        return f.app.view(f.arena.allocator());
    }

    fn keys(f: *Fixture, text: []const u8) !core.Command {
        var cmd: core.Command = .none;
        for (text) |c| cmd = try f.app.handleKey(Key.char(c));
        return cmd;
    }

    /// Adds `entries` under the directory reached by following `names` from the root (dirs must exist).
    fn add(f: *Fixture, path: []const []const u8, entries: []const core.Entry) !void {
        var d = f.app.root;
        for (path) |n| d = f.child(d, n);
        _ = try f.app.addDir(d, entries);
    }

    fn child(f: *Fixture, parent: core.NodeId, name: []const u8) core.NodeId {
        var it = f.app.tree.get(parent).first_child;
        while (it != .nil) : (it = f.app.tree.get(it).next_sibling) {
            if (std.mem.eql(u8, f.app.tree.name(it), name)) return it;
        }
        unreachable;
    }
};

fn dir(name: []const u8, size: u64) core.Entry {
    return .{ .name = name, .kind = .dir, .size = size };
}

fn file(name: []const u8, size: u64) core.Entry {
    return .{ .name = name, .kind = .file, .size = size };
}

fn names(rows: []const core.Row, buf: *[16][]const u8) []const []const u8 {
    for (rows, 0..) |r, i| buf[i] = r.name;
    return buf[0..rows.len];
}

fn expectNames(rows: []const core.Row, want: []const []const u8) !void {
    var buf: [16][]const u8 = undefined;
    const got = names(rows, &buf);
    try expectEqual(want.len, got.len);
    for (want, got) |w, g| try expectEqualStrings(w, g);
}

test "first view lists children largest first with the first one selected" {
    var f = try Fixture.init("/home/u");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("b", 60), file("c", 40), dir("a", 900) });
    try f.add(&.{"a"}, &.{ file("a1", 10), file("a2", 20) });

    const v = try f.view();
    try expectNames(v.current, &.{ "a", "b", "c" });
    try expectEqual(@as(u64, 930), v.current[0].size);
    try expect(v.current[0].selected);
    try expectNames(v.preview, &.{ "a2", "a1" });
    try expectEqual(@as(u64, 1030), v.size);
}

test "j/k move the selection and the preview follows" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 90), dir("b", 60), dir("c", 40) });
    try f.add(&.{"b"}, &.{file("inside-b", 5)});

    _ = try f.keys("jjjj");
    try expectEqual(@as(usize, 2), (try f.view()).cursor);
    _ = try f.keys("k");
    const v = try f.view();
    try expectEqual(@as(usize, 1), v.cursor);
    try expectNames(v.preview, &.{"inside-b"});
    _ = try f.keys("kkk");
    try expectEqual(@as(usize, 0), (try f.view()).cursor);
}

test "l enters a directory, h returns with the same selection" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 90), dir("b", 60) });
    try f.add(&.{"b"}, &.{ file("b1", 3), file("b2", 2) });

    _ = try f.keys("jlj");
    var v = try f.view();
    try expectEqualStrings("/r/b", v.path);
    try expectNames(v.current, &.{ "b1", "b2" });
    try expectNames(v.parent, &.{ "a", "b" });
    try expect(v.parent[1].selected);
    try expectEqual(@as(usize, 1), v.cursor);

    _ = try f.keys("h");
    v = try f.view();
    try expectEqualStrings("/r", v.path);
    try expectEqual(@as(usize, 1), v.cursor);
    _ = try f.keys("l");
    try expectEqual(@as(usize, 1), (try f.view()).cursor);
}

test "x returns trash for the selected node without a prompt" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 90), dir("b", 60) });

    const cmd = try f.keys("jx");
    try expectEqualStrings("/r/b", try f.app.path(cmd.trash));
    try expect((try f.view()).prompt == null);
}

test "X asks, y confirms delete, any other key cancels" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 90), dir("b", 60) });

    try expectEqual(core.Command.none, try f.keys("X"));
    const p = (try f.view()).prompt.?;
    try expectEqualStrings("/r/a", p.path);
    try expectEqual(@as(u64, 90), p.size);
    try expectEqual(core.Command.none, try f.keys("j"));
    try expect((try f.view()).prompt == null);
    try expectEqual(@as(usize, 0), (try f.view()).cursor);

    const cmd = try f.keys("Xy");
    try expectEqualStrings("/r/a", try f.app.path(cmd.delete));
}

test "markDeleted drops the node, subtracts its size up the tree, selects the next row" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 10), dir("b", 5) });
    try f.add(&.{"a"}, &.{ dir("big", 100), dir("mid", 50), dir("small", 1) });
    try f.add(&.{ "a", "big" }, &.{file("blob", 1000)});

    _ = try f.keys("l");
    const cmd = try f.keys("x");
    f.app.markDeleted(cmd.trash);
    f.app.markDeleted(cmd.trash); // idempotent

    const v = try f.view();
    try expectNames(v.current, &.{ "mid", "small" });
    try expect(v.current[0].selected);
    try expectEqual(@as(u64, 61), v.size);
    try expectEqual(@as(u64, 61), v.parent[0].size);
}

test "q quits, r clears the current directory and asks for a rescan" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{dir("a", 10)});
    try f.add(&.{"a"}, &.{file("f", 100)});
    try expectEqual(core.Command.quit, try f.keys("q"));

    _ = try f.keys("l");
    const cmd = try f.keys("r");
    const a = cmd.rescan;
    try expectEqual(@as(usize, 0), (try f.view()).current.len);
    try expectEqual(@as(u64, 10), (try f.view()).size);
    _ = try f.app.addDir(a, &.{file("g", 7)});
    try expectEqual(@as(u64, 17), (try f.view()).size);
}

test "highlight: largest children reaching 80% of the parent; dim: the rest under 15%" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 50), file("b", 30), file("c", 10), file("d", 6), file("e", 4) });

    const v = try f.view();
    const want = [_]core.view.Style{ .highlight, .highlight, .dim, .dim, .dim };
    for (v.current, want) |r, s| try expectEqual(s, r.style);
}

test "gg and G jump to the ends; a non-matching key after g is handled on its own" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 5), file("b", 4), file("c", 3), file("d", 2) });

    _ = try f.keys("G");
    try expectEqual(@as(usize, 3), (try f.view()).cursor);
    _ = try f.keys("g");
    try expectEqualStrings("g", (try f.view()).status.pending);
    _ = try f.keys("g");
    try expectEqual(@as(usize, 0), (try f.view()).cursor);
    _ = try f.keys("gj");
    try expectEqual(@as(usize, 1), (try f.view()).cursor);
}

test "edges and empty directories never panic" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try expectEqual(core.Command.none, try f.keys("jkhlxXgG"));
    try f.add(&.{}, &.{ dir("empty", 1), file("f", 0) });
    _ = try f.keys("l");
    try expectEqualStrings("/r/empty", (try f.view()).path);
    try expectEqual(core.Command.none, try f.keys("jkxXl"));
    _ = try f.keys("h");
    try expectEqualStrings("/r", (try f.view()).path);
}

test "keymap overrides replace the default key and bad entries are logged" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{dir("a", 1)});
    try f.app.loadKeymap(
        \\.{ .trash = .{ "d" }, .nope = .{ "z" }, .quit = .{ "<bogus>" } }
    );
    try expect(try f.keys("d") == .trash);
    try expectEqual(core.Command.none, try f.keys("x"));
    try expectEqual(core.Command.quit, try f.keys("q"));
    try expectEqual(@as(usize, 2), (try f.view()).status.errors);
}

test "unreadable directory: partial size marked incomplete, error counted, log view toggles" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{dir("locked", 4)});
    try f.app.dirError(f.child(f.app.root, "locked"), "permission denied: /r/locked");

    var v = try f.view();
    try expect(v.current[0].incomplete);
    try expectEqual(@as(usize, 1), v.status.errors);
    _ = try f.keys("!");
    v = try f.view();
    try expectEqual(core.view.Mode.log, v.mode);
    try expectEqualStrings("permission denied: /r/locked", v.log[0]);
    try expectEqual(core.Command.none, try f.keys("q"));
    try expectEqual(core.view.Mode.normal, (try f.view()).mode);
}

test "h at the root re-roots onto the real parent and asks to scan the siblings" {
    var f = try Fixture.init("/home/u");
    defer f.deinit();
    try f.add(&.{}, &.{file("f", 100)});
    try f.app.setOuter(&.{ dir("u", 4), dir("other", 4), file("note", 8) });

    var v = try f.view();
    try expectNames(v.parent, &.{ "other", "u", "note" });
    try expect(v.parent[0].unscanned);
    try expect(v.parent[1].selected);

    const cmd = try f.keys("h");
    try expectEqual(@as(usize, 1), cmd.rerooted.len);
    const other = cmd.rerooted[0];
    _ = try f.app.addDir(other, &.{file("x", 50)});
    v = try f.view();
    try expectEqualStrings("/home", v.path);
    try expectNames(v.current, &.{ "u", "other", "note" });
    try expect(v.current[0].selected);
    try expectEqual(@as(u64, 104 + 54 + 8), v.size);
}
