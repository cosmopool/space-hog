//! Fuzz (hostile input): arbitrary filename bytes through the core and the sanitizer.
//! `zig build test` replays the corpus deterministically; `zig build test --fuzz` explores further.
const std = @import("std");
const core = @import("core");
const tui = @import("tui");
const gpa = std.testing.allocator;

const corpus = [_][]const u8{
    "",                       "\x1b[2J",                    "\x1b]0;title\x07",      "\x1b]8;;http://x\x1b\\",
    "\xc0\x80",               "\xed\xa0\x80",               "\xe2\x80\xa8",          "\xf4\x90\x80\x80",
    "\x9b31m",                "a/b\x00c",                   rep("\xff", 64),            rep("\x1b", 64),
};

fn expectSafe(s: []const u8) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepoint()) |cp| {
        try std.testing.expect(cp >= 0x20 and cp != 0x7f and !(cp >= 0x80 and cp < 0xa0));
    }
}

fn names(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const once = try tui.clean(arena.allocator(), input);
    try expectSafe(once);
    try std.testing.expectEqualStrings(once, try tui.clean(arena.allocator(), once));

    // Split into names on '/' and NUL, feed them as one directory, press a few keys, view.
    var app = try core.App.init(gpa, "/fuzz");
    defer app.deinit();
    var entries: std.ArrayList(core.Entry) = .empty;
    defer entries.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, input, "/\x00");
    var i: u64 = 0;
    while (it.next()) |n| : (i += 1) {
        if (entries.items.len == 64) break;
        try entries.append(gpa, .{ .name = n, .kind = if (i % 3 == 0) .dir else .file, .size = i * 4096 });
    }
    _ = try app.addDir(app.root, entries.items);
    for ("jlhxXjG") |k| _ = try app.handleKey(core.Key.char(k));
    const v = try app.view(arena.allocator());
    try std.testing.expect(v.current.len <= entries.items.len);
    for (v.current) |r| try expectSafe(try tui.clean(arena.allocator(), r.name));
    try expectSafe(try tui.clean(arena.allocator(), v.path));
}

test "fuzz: filenames through core and clean" {
    try std.testing.fuzz({}, names, .{ .corpus = &corpus });
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
