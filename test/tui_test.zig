//! UI integration through public functions: key decoding, size format, name sanitizing, and painting views
//! into an in-memory screen. Assertions are invariants, never golden snapshots.
const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core");
const tui = @import("tui");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

fn key(k: vaxis.Key) ?core.Key {
    return tui.coreKey(k);
}

fn sameAsNotation(k: vaxis.Key, notation: []const u8) !void {
    const want = core.keymap.Seq.parse(notation).?.keys[0];
    const got = key(k).?;
    try expect(want.eql(got));
}

test "coreKey: decoded keys equal the keymap notation for the same key" {
    try sameAsNotation(.{ .codepoint = 'j', .text = "j" }, "j");
    try sameAsNotation(.{ .codepoint = 'g', .shifted_codepoint = 'G', .mods = .{ .shift = true }, .text = "G" }, "G");
    try sameAsNotation(.{ .codepoint = 'g', .shifted_codepoint = 'G', .mods = .{ .shift = true } }, "G");
    try sameAsNotation(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }, "<C-d>");
    try sameAsNotation(.{ .codepoint = 'D', .mods = .{ .ctrl = true } }, "<C-d>");
    try sameAsNotation(.{ .codepoint = vaxis.Key.up }, "<up>");
    try sameAsNotation(.{ .codepoint = vaxis.Key.down }, "<down>");
    try sameAsNotation(.{ .codepoint = vaxis.Key.left }, "<left>");
    try sameAsNotation(.{ .codepoint = vaxis.Key.right }, "<right>");
    try sameAsNotation(.{ .codepoint = vaxis.Key.escape }, "<esc>");
    try sameAsNotation(.{ .codepoint = vaxis.Key.enter }, "<cr>");
    try sameAsNotation(.{ .codepoint = 0xE9, .text = "é" }, "é");
}

test "coreKey: hostile or unsupported input never panics" {
    try expect(key(.{ .codepoint = 'x', .text = "" }) != null);
    try expect(key(.{ .codepoint = 'x', .text = "\xff" }) == null);
    try expect(key(.{ .codepoint = 'x', .text = "\xe2\x82" }) == null);
    try expect(key(.{ .codepoint = 57399 }) == null); // kitty private-use (keypad)
    // A typed private-use character must never alias the core's arrow keys.
    const pua = key(.{ .codepoint = 0xE000, .text = "\u{E000}" });
    if (pua) |k| try expect(k.code != core.Key.UP);
    var prng: std.Random.DefaultPrng = .init(99);
    const rnd = prng.random();
    for (0..5000) |_| {
        var text: [4]u8 = undefined;
        rnd.bytes(&text);
        const k: vaxis.Key = .{
            .codepoint = rnd.uintLessThan(u21, 0x110000),
            .mods = @bitCast(rnd.int(u8)),
            .text = if (rnd.boolean()) text[0..rnd.uintAtMost(usize, 4)] else null,
            .shifted_codepoint = if (rnd.boolean()) rnd.uintLessThan(u21, 0x110000) else null,
        };
        _ = key(k);
    }
}

test "fmtSize: du -h style boundaries" {
    var buf: [16]u8 = undefined;
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0B" },         .{ 1023, "1023B" },       .{ 1024, "1.0K" },    .{ 1536, "1.5K" },
        .{ 10 * 1024, "10K" }, .{ 1048575, "1.0M" },     .{ 1 << 20, "1.0M" }, .{ 5 << 30, "5.0G" },
        .{ 300 << 30, "300G" }, .{ std.math.maxInt(u64), "16384P" },
    };
    for (cases) |c| try expectEqualStrings(c[1], tui.fmtSize(&buf, c[0]));
    var prng: std.Random.DefaultPrng = .init(5);
    for (0..10_000) |_| {
        const s = tui.fmtSize(&buf, prng.random().int(u64) >> prng.random().int(u6));
        try expect(s.len <= 7);
        try expect(std.mem.indexOfAny(u8, s[s.len - 1 ..], "BKMGTP") != null);
    }
}

fn expectSafe(s: []const u8) !void {
    try expect(std.unicode.utf8ValidateSlice(s));
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepoint()) |cp| {
        try expect(cp >= 0x20 and cp != 0x7f and !(cp >= 0x80 and cp < 0xa0) and cp != 0x2028 and cp != 0x2029);
    }
}

test "clean: every 1- and 2-byte input becomes safe, printable UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buf: [2]u8 = undefined;
    for (0..256) |a| {
        buf[0] = @intCast(a);
        try expectSafe(try tui.clean(arena.allocator(), buf[0..1]));
        for (0..256) |b| {
            buf[1] = @intCast(b);
            try expectSafe(try tui.clean(arena.allocator(), &buf));
        }
        _ = arena.reset(.retain_capacity);
    }
    try expectEqualStrings("a?[31mb", try tui.clean(arena.allocator(), "a\x1b[31mb"));
    try expectEqualStrings("café 日本 😀", try tui.clean(arena.allocator(), "café 日本 😀"));
}

// ---- paint into an in-memory screen ----

const Canvas = struct {
    screen: vaxis.Screen,

    fn init(cols: u16, rows: u16) !Canvas {
        return .{ .screen = try .init(gpa, .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 }) };
    }

    fn deinit(c: *Canvas) void {
        c.screen.deinit(gpa);
    }

    fn window(c: *Canvas) vaxis.Window {
        return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = c.screen.width, .height = c.screen.height, .screen = &c.screen };
    }

    /// No cell may hold a control character, whatever the names were.
    fn expectNoControls(c: *Canvas) !void {
        for (c.screen.buf) |cell| try expectSafe(cell.char.grapheme);
    }

    fn rowText(c: *Canvas, arena: std.mem.Allocator, y: u16) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..c.screen.width) |x| try out.appendSlice(arena, c.screen.buf[y * c.screen.width + x].char.grapheme);
        return out.items;
    }
};

const hostile = [_][]const u8{
    "\x1b[2J\x1b]0;pwned\x07", "line\nbreak", "tab\there", "\xff\xfe invalid", "bell\x07", "\xc2\x9b csi",
    rep("a", 300),                rep("é", 100),     "wide 日本語日本語", "\u{2028}sep",
};

fn hostileApp() !core.App {
    var app = try core.App.init(gpa, "/root\x1b[31m");
    var entries: [hostile.len]core.Entry = undefined;
    for (&entries, hostile, 0..) |*e, n, i| e.* = .{ .name = n, .kind = if (i % 2 == 0) .dir else .file, .size = (i + 1) * 4096 };
    const dirs = try app.addDir(app.root, &entries);
    _ = try app.addDir(dirs[0], &.{.{ .name = "\x1b[5minner", .kind = .file, .size = 1 }});
    try app.setOuter(&.{.{ .name = "\x1bouter", .kind = .dir, .size = 0 }});
    try app.logError("bad\x1b[2Jlog\nline");
    return app;
}

test "paint: hostile names never put control characters on screen, in every mode and size" {
    var app = try hostileApp();
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const sizes = [_][2]u16{ .{ 0, 0 }, .{ 1, 1 }, .{ 9, 4 }, .{ 10, 5 }, .{ 11, 6 }, .{ 40, 10 }, .{ 80, 24 }, .{ 200, 3 }, .{ 3, 200 }, .{ 300, 60 } };
    for (sizes) |sz| {
        for ([_][]const u8{ "", "X", "!" }) |keys| {
            var a = try hostileApp();
            defer a.deinit();
            for (keys) |k| _ = try a.handleKey(core.Key.char(k));
            var c = try Canvas.init(sz[0], sz[1]);
            defer c.deinit();
            var scroll: tui.Scroll = .{};
            _ = arena.reset(.retain_capacity);
            try tui.paint(arena.allocator(), c.window(), try a.view(arena.allocator()), &scroll);
            try c.expectNoControls();
        }
    }
}

test "paint: the selected row is always visible while moving through a long list" {
    var app = try core.App.init(gpa, "/r");
    defer app.deinit();
    var names: [300][8]u8 = undefined;
    var entries: [300]core.Entry = undefined;
    for (&entries, &names, 0..) |*e, *nb, i| {
        const n = try std.fmt.bufPrint(nb, "f{d:0>4}", .{i});
        e.* = .{ .name = n, .kind = .file, .size = 300 - i };
    }
    _ = try app.addDir(app.root, &entries);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(11);
    const rnd = prng.random();
    for ([_]u16{ 6, 10, 24, 40 }) |h| {
        var c = try Canvas.init(80, h);
        defer c.deinit();
        var scroll: tui.Scroll = .{};
        for (0..400) |_| {
            try app.moveCursor(rnd.intRangeAtMost(i64, -40, 40));
            _ = arena.reset(.retain_capacity);
            const v = try app.view(arena.allocator());
            try tui.paint(arena.allocator(), c.window(), v, &scroll);
            const sel = v.current[v.cursor].name;
            var seen = false;
            for (2..h - 2) |y| {
                if (std.mem.indexOf(u8, try c.rowText(arena.allocator(), @intCast(y)), sel) != null) seen = true;
            }
            try expect(seen);
        }
    }
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

test "coreKey: Alt/Super/Meta combos and Ctrl with non-letters are ignored" {
    try expect(key(.{ .codepoint = 'x', .text = "x", .mods = .{ .alt = true } }) == null);
    try expect(key(.{ .codepoint = 'X', .text = "X", .mods = .{ .meta = true } }) == null);
    try expect(key(.{ .codepoint = 'q', .mods = .{ .super = true } }) == null);
    try expect(key(.{ .codepoint = 0xE9, .mods = .{ .ctrl = true } }) == null);
    try expect(key(.{ .codepoint = '[', .mods = .{ .ctrl = true } }) == null);
    try expect(key(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }).?.eql(core.Key.QUIT));
}

test "clean: bidi and zero-width characters are shown as ?, so names can't disguise themselves" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try expectEqualStrings("photos?gpj.exe", try tui.clean(arena.allocator(), "photos\u{202E}gpj.exe"));
    try expectEqualStrings("a?b?c?d", try tui.clean(arena.allocator(), "a\u{200B}b\u{FEFF}c\u{2066}d"));
}

test "paint: the delete prompt shows the target's size (text outlives the paint call)" {
    var app = try core.App.init(gpa, "/r");
    defer app.deinit();
    _ = try app.addDir(app.root, &.{.{ .name = "big", .kind = .dir, .size = 9 << 30 }});
    _ = try app.handleKey(core.Key.char('X'));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try Canvas.init(80, 24);
    defer c.deinit();
    var scroll: tui.Scroll = .{};
    try tui.paint(arena.allocator(), c.window(), try app.view(arena.allocator()), &scroll);
    // Reuse the stack below this frame (where paint's locals lived), then read the screen.
    smashStack();
    // The size is the line right under the prompt's path ("9.0G" also appears in the list and status bar).
    var path_row: ?u16 = null;
    for (0..24) |y| {
        if (std.mem.indexOf(u8, try c.rowText(arena.allocator(), @intCast(y)), "/r/big") != null) path_row = @intCast(y);
    }
    const size_line = try c.rowText(arena.allocator(), path_row.? + 1);
    try expect(std.mem.indexOf(u8, size_line, "9.0G") != null);
}

noinline fn smashStack() void {
    var junk: [64 * 1024]u8 = undefined;
    @memset(&junk, '@');
    std.mem.doNotOptimizeAway(&junk);
}
