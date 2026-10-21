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

// ---- highlight / dim rules ----

fn styles(f: *Fixture) ![]core.view.Style {
    const v = try f.view();
    const out = try f.arena.allocator().alloc(core.view.Style, v.current.len);
    for (v.current, out) |r, *s| s.* = r.style;
    return out;
}

fn expectStyles(f: *Fixture, want: []const core.view.Style) !void {
    const got = try styles(f);
    try expectEqual(want.len, got.len);
    for (want, got) |w, g| try expectEqual(w, g);
}

test "highlight boundary: reaching exactly 80% stops the prefix; exactly 15% is not dimmed" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 50), file("b", 30), file("c", 15), file("d", 5) });
    try expectStyles(&f, &.{ .highlight, .highlight, .normal, .dim });
}

test "highlight: one row short of 80% pulls in the next row" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 50), file("b", 29), file("c", 21) });
    try expectStyles(&f, &.{ .highlight, .highlight, .highlight });
}

test "highlight wins over dim when many small children are needed to reach 80%" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    var entries: [10]core.Entry = undefined;
    const names_ = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    for (&entries, names_) |*e, n| e.* = file(n, 10);
    try f.add(&.{}, &entries);
    try expectStyles(&f, &.{ .highlight, .highlight, .highlight, .highlight, .highlight, .highlight, .highlight, .highlight, .dim, .dim });
}

test "a single child is highlighted; a zero-size directory styles nothing" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("only", 100), dir("zero", 0) });
    try f.add(&.{"zero"}, &.{ file("z1", 0), file("z2", 0) });
    try expectStyles(&f, &.{ .highlight, .dim });
    _ = try f.keys("jl");
    try expectStyles(&f, &.{ .normal, .normal });
}

test "rules are computed per directory, and the selected row keeps its style" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("big", 0), file("small", 10) });
    try f.add(&.{"big"}, &.{ file("x", 45), file("y", 45) });
    var v = try f.view();
    try expectEqual(core.view.Style.highlight, v.current[0].style);
    try expectEqual(core.view.Style.dim, v.current[1].style);
    try expectEqual(core.view.Style.highlight, v.preview[0].style);
    try expectEqual(core.view.Style.highlight, v.preview[1].style);
    _ = try f.keys("j");
    v = try f.view();
    try expect(v.current[1].selected);
    try expectEqual(core.view.Style.dim, v.current[1].style);
}

// ---- sorting ----

test "order is independent of arrival order: size desc, dirs first, case-insensitive name" {
    const set = [_]core.Entry{ file("b", 5), dir("B2", 5), file("A", 5), dir("a2", 5), file("big", 9), file("Z", 1) };
    const want = [_][]const u8{ "big", "a2", "B2", "A", "b", "Z" };
    var orders = [_][6]usize{ .{ 0, 1, 2, 3, 4, 5 }, .{ 5, 4, 3, 2, 1, 0 }, .{ 2, 5, 0, 4, 1, 3 } };
    for (&orders) |order| {
        var f = try Fixture.init("/r");
        defer f.deinit();
        var entries: [6]core.Entry = undefined;
        for (order, &entries) |i, *e| e.* = set[i];
        try f.add(&.{}, &entries);
        try expectNames((try f.view()).current, &want);
    }
}

test "the cursor follows its node when a late scan re-sorts the list" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 10), dir("b", 5), dir("c", 1) });
    _ = try f.keys("jj");
    try expectEqualStrings("c", (try f.view()).current[(try f.view()).cursor].name);
    try f.add(&.{"c"}, &.{file("huge", 1000)});
    const v = try f.view();
    try expectEqual(@as(usize, 0), v.cursor);
    try expectEqualStrings("c", v.current[0].name);
}

// ---- navigation ----

test "C-d and C-u ask for a half-page scroll; moveCursor clamps at both ends" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 5), file("b", 4), file("c", 3) });
    const down = try f.app.handleKey(.{ .code = 'd', .ctrl = true });
    try expect(down.scroll.down and down.scroll.amount == .half_page);
    const up = try f.app.handleKey(.{ .code = 'u', .ctrl = true });
    try expect(!up.scroll.down);
    try f.app.moveCursor(100);
    try expectEqual(@as(usize, 2), (try f.view()).cursor);
    try f.app.moveCursor(-100);
    try expectEqual(@as(usize, 0), (try f.view()).cursor);
}

test "arrow keys navigate like h/j/k/l" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 5), dir("b", 4) });
    try f.add(&.{"b"}, &.{file("in", 1)});
    _ = try f.app.handleKey(.{ .code = Key.DOWN });
    _ = try f.app.handleKey(.{ .code = Key.RIGHT });
    try expectEqualStrings("/r/b", (try f.view()).path);
    _ = try f.app.handleKey(.{ .code = Key.LEFT });
    _ = try f.app.handleKey(.{ .code = Key.UP });
    const v = try f.view();
    try expectEqualStrings("/r", v.path);
    try expectEqual(@as(usize, 0), v.cursor);
}

// ---- delete flow ----

test "deleting the last row selects the previous one; deleting the only child leaves an empty dir" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 5), dir("b", 4) });
    try f.add(&.{"a"}, &.{file("only", 1)});
    _ = try f.keys("j");
    f.app.markDeleted((try f.keys("x")).trash);
    var v = try f.view();
    try expectNames(v.current, &.{"a"});
    try expect(v.current[0].selected);
    _ = try f.keys("l");
    f.app.markDeleted((try f.keys("x")).trash);
    v = try f.view();
    try expectEqual(@as(usize, 0), v.current.len);
    try expectEqual(@as(u64, 5), v.size);
    try expectEqual(core.Command.none, try f.keys("xX"));
}

test "the prompt keeps its target even if the list re-sorts while it is open" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 10), dir("b", 5) });
    _ = try f.keys("X");
    try f.add(&.{"b"}, &.{file("grow", 100)});
    try expectEqualStrings("/r/a", (try f.view()).prompt.?.path);
    const cmd = try f.keys("y");
    try expectEqualStrings("/r/a", try f.app.path(cmd.delete));
}

test "deleting a deep node updates every ancestor and the styles computed from them" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("l1", 0), dir("other", 30) });
    try f.add(&.{"l1"}, &.{dir("l2", 0)});
    try f.add(&.{ "l1", "l2" }, &.{dir("l3", 0)});
    try f.add(&.{ "l1", "l2", "l3" }, &.{ file("victim", 60), file("keep", 10) });
    try expectStyles(&f, &.{ .highlight, .highlight });

    _ = try f.keys("llll");
    try expectEqualStrings("/r/l1/l2/l3", (try f.view()).path);
    f.app.markDeleted((try f.keys("x")).trash);
    try expectEqual(@as(u64, 10), (try f.view()).size);
    _ = try f.keys("hhh");
    const v = try f.view();
    try expectEqual(@as(u64, 40), v.size);
    try expectNames(v.current, &.{ "other", "l1" });
    try expectEqual(@as(u64, 10), v.current[1].size);
}

test "deleting the directory you are in moves you to its parent" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 5), dir("b", 4) });
    try f.add(&.{"a"}, &.{file("in", 1)});
    _ = try f.keys("l");
    f.app.markDeleted(f.child(f.app.root, "a"));
    const v = try f.view();
    try expectEqualStrings("/r", v.path);
    try expectNames(v.current, &.{"b"});
}

test "scan results arriving for a deleted or rescanned subtree are ignored" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 5), dir("b", 4) });
    const a = f.child(f.app.root, "a");
    const inner = (try f.app.addDir(a, &.{dir("inner", 1)}))[0];
    f.app.markDeleted(a);
    try expectEqual(@as(usize, 0), (try f.app.addDir(inner, &.{file("late", 1000)})).len);
    try expectEqual(@as(u64, 4), (try f.view()).size);

    _ = try f.keys("l");
    const b = f.child(f.app.root, "b");
    const deep = (try f.app.addDir(b, &.{dir("deep", 1)}))[0];
    _ = try f.keys("r");
    _ = try f.app.addDir(deep, &.{file("stale", 500)});
    try expectEqual(@as(u64, 4), (try f.view()).size);
}

test "a failed trash is logged and leaves the tree unchanged" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{dir("a", 5)});
    _ = try f.keys("x");
    try f.app.logError("trash failed for /r/a: AccessDenied");
    const v = try f.view();
    try expectNames(v.current, &.{"a"});
    try expectEqual(@as(usize, 1), v.status.errors);
}

// ---- keymap ----

test "keymap: partial override keeps the other defaults; syntax error keeps all defaults" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 2), file("b", 1) });
    try f.app.loadKeymap(".{ .quit = \"Q\" }");
    try expectEqual(core.Command.none, try f.keys("q"));
    try expectEqual(core.Command.quit, try f.keys("Q"));
    _ = try f.keys("j");
    try expectEqual(@as(usize, 1), (try f.view()).cursor);

    try f.app.loadKeymap(".{ .quit = ");
    try expectEqual(core.Command.quit, try f.keys("q"));
    try expectEqual(@as(usize, 1), (try f.view()).status.errors);
}

test "keymap: a key moved to another action stops doing its old one" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 2), file("b", 1) });
    try f.app.loadKeymap(".{ .trash = .{ \"j\" } }");
    try expect(try f.keys("j") == .trash);
    try expectEqual(@as(usize, 0), (try f.view()).cursor);
    try expectEqual(@as(usize, 1), (try f.view()).status.errors);
}

test "keymap: multi-key and ctrl bindings from the file work" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ file("a", 2), file("b", 1) });
    try f.app.loadKeymap(".{ .bottom = .{ \"<C-e>\", \"ge\" } }");
    _ = try f.app.handleKey(.{ .code = 'e', .ctrl = true });
    try expectEqual(@as(usize, 1), (try f.view()).cursor);
    _ = try f.keys("gg");
    _ = try f.keys("ge");
    try expectEqual(@as(usize, 1), (try f.view()).cursor);
    try expectEqual(core.Command.none, try f.keys("G"));
}

// ---- status and error log ----

test "status counts files and bytes and reports when the scan is done" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{ dir("a", 4), file("b", 6) });
    try f.add(&.{"a"}, &.{file("c", 10)});
    var v = try f.view();
    try expectEqual(@as(u64, 3), v.status.files);
    try expectEqual(@as(u64, 20), v.status.bytes);
    try expect(!v.status.scan_done);
    f.app.scanDone();
    v = try f.view();
    try expect(v.status.scan_done);
}

test "log view: navigation keys scroll it, x/r do nothing, ! closes it" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    try f.add(&.{}, &.{dir("a", 1)});
    for ([_][]const u8{ "e1", "e2", "e3" }) |m| try f.app.logError(m);
    _ = try f.keys("!jj");
    try expectEqual(@as(usize, 2), (try f.view()).log_cursor);
    _ = try f.keys("gg");
    try expectEqual(@as(usize, 0), (try f.view()).log_cursor);
    _ = try f.keys("G");
    try expectEqual(@as(usize, 2), (try f.view()).log_cursor);
    try expectEqual(core.Command.none, try f.keys("xr"));
    _ = try f.keys("!");
    try expectEqual(core.view.Mode.normal, (try f.view()).mode);
    try expectNames((try f.view()).current, &.{"a"});
}

// ---- randomized invariants (fixed seeds, bounded) ----

const SEEDS = [_]u64{ 1, 42, 0xdead_beef, 20261021 };

test "random trees and key sequences keep the view consistent" {
    for (SEEDS) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rnd = prng.random();
        var f = try Fixture.init("/r");
        defer f.deinit();

        // Random tree, fed breadth-first like the scanner does.
        var queue: std.ArrayList(core.NodeId) = .empty;
        defer queue.deinit(std.testing.allocator);
        try queue.append(std.testing.allocator, f.app.root);
        var name_buf: [32]u8 = undefined;
        var made: usize = 0;
        while (queue.items.len > 0 and made < 400) {
            const d = queue.orderedRemove(0);
            var entries: [12]core.Entry = undefined;
            var names_store: [12][8]u8 = undefined;
            const n = rnd.uintLessThan(usize, 13);
            for (entries[0..n], 0..) |*e, i| {
                const nm = try std.fmt.bufPrint(&name_buf, "n{d}", .{rnd.uintLessThan(u32, 50)});
                @memcpy(names_store[i][0..nm.len], nm);
                const sz = switch (rnd.uintLessThan(u8, 4)) {
                    0 => 0,
                    1 => rnd.uintLessThan(u64, 10),
                    2 => rnd.uintLessThan(u64, 1 << 20),
                    else => rnd.uintLessThan(u64, 1 << 40),
                };
                e.* = .{ .name = names_store[i][0..nm.len], .kind = if (rnd.boolean()) .dir else .file, .size = sz };
            }
            for (try f.app.addDir(d, entries[0..n])) |id| try queue.append(std.testing.allocator, id);
            made += n;
        }

        const key_pool = "jkhlgGxXyrq!nj";
        for (0..300) |_| {
            const c = key_pool[rnd.uintLessThan(usize, key_pool.len)];
            const cmd = try f.app.handleKey(Key.char(c));
            switch (cmd) {
                .trash, .delete => |id| if (rnd.boolean()) f.app.markDeleted(id),
                .scroll => |s| try f.app.moveCursor(if (s.down) 5 else -5),
                else => {},
            }
            try checkInvariants(&f);
        }
    }
}

fn checkInvariants(f: *Fixture) !void {
    _ = f.arena.reset(.retain_capacity);
    const v = try f.view();
    // I3 sorted, I4 highlight prefix, I5 exactly one selected row within bounds.
    var selected: usize = 0;
    var sum: u128 = 0;
    var reached = v.size == 0;
    for (v.current, 0..) |r, i| {
        if (i > 0) try expect(v.current[i - 1].size >= r.size);
        if (r.selected) selected += 1;
        if (!reached) {
            try expectEqual(core.view.Style.highlight, r.style);
            sum += r.size;
            reached = sum * 100 >= @as(u128, v.size) * 80;
        } else {
            try expect(r.style != .highlight);
            try expectEqual(@as(u128, r.size) * 100 < @as(u128, v.size) * 15, r.style == .dim);
        }
    }
    if (v.current.len > 0) {
        try expectEqual(@as(usize, 1), selected);
        try expect(v.cursor < v.current.len);
        try expect(v.current[v.cursor].selected);
    } else try expectEqual(@as(usize, 0), selected);
    // I1 size consistency: a directory is at least the sum of its listed children.
    var children: u128 = 0;
    for (v.current) |r| children += r.size;
    try expect(children <= v.size);
}

// ---- dry run ----

test "dry run: x and X+y never return trash/delete, they log what would happen" {
    var f = try Fixture.init("/r");
    defer f.deinit();
    f.app.dry_run = true;
    try f.add(&.{}, &.{ dir("a", 90), dir("b", 60) });

    try expectEqual(core.Command.none, try f.keys("x"));
    try expectEqual(core.Command.none, try f.keys("jXy"));
    const v = try f.view();
    try expect(v.status.dry_run);
    try expectEqual(@as(usize, 0), v.status.errors);
    try expectNames(v.current, &.{ "a", "b" });
    try expectEqual(@as(u64, 150), v.size);
    _ = try f.keys("!");
    const log = (try f.view()).log;
    try expectEqual(@as(usize, 2), log.len);
    try expectEqualStrings("dry run: would trash /r/a (90 bytes)", log[0]);
    try expectEqualStrings("dry run: would rm -r /r/b (60 bytes)", log[1]);
}

test "dry run: random key sequences never produce a destructive command" {
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    var f = try Fixture.init("/r");
    defer f.deinit();
    f.app.dry_run = true;
    try f.add(&.{}, &.{ dir("a", 9), dir("b", 8), file("c", 7) });
    try f.add(&.{"a"}, &.{ file("a1", 3), dir("a2", 2) });
    for (0..2000) |_| {
        const cmd = try f.app.handleKey(Key.char("jkhlxXygG"[rnd.uintLessThan(usize, 9)]));
        try expect(cmd != .trash and cmd != .delete);
    }
}
