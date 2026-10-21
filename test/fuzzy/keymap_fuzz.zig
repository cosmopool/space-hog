//! Fuzz (hostile input): keymap.zon contents. Must never crash or leak, and always leave a usable keymap.
const std = @import("std");
const core = @import("core");
const gpa = std.testing.allocator;

const corpus = [_][]const u8{
    "",                                      ".{}",                                   ".{ .quit = \"q\" }",
    ".{ .top = .{\"gg\",\"G\",\"<C-g>\",\"x\",\"y\"} }", ".{ .trash = .{ \"d\" }, .nope = .{ \"z\" }, .quit = .{ \"<bogus>\" } }",
    ".{ .trash = }",                         ".{ .quit = \"a\", .quit = \"b\" }",       ".{ .quit = 5 }",
    ".{ .quit = .{ .a = 1 } }",              ".{ .quit = \"\\x00\" }",                  ".{ .quit = \"<\" }",
    ".{ .quit = \"<>\" }",                   ".{ .quit = \"<C-\" }",                    ".{ .down = \"gg\", .trash = \"g\" }",
    rep(".{", 200),
};

fn parse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048:0]u8 = undefined;
    const len = smith.slice(buf[0..2047]);
    buf[len] = 0;
    const src: [:0]const u8 = buf[0..len :0];

    var errs: std.ArrayList([]u8) = .empty;
    defer {
        for (errs.items) |e| gpa.free(e);
        errs.deinit(gpa);
    }
    const km = try core.keymap.Keymap.parse(gpa, src, &errs);
    // Usable: every stored sequence is well formed and bound to exactly one action.
    for (std.enums.values(core.keymap.Action)) |a| {
        try std.testing.expect(km.counts.get(a) <= core.keymap.SEQS_PER_ACTION);
        for (km.seqs.getPtrConst(a)[0..km.counts.get(a)]) |s| {
            try std.testing.expect(s.len >= 1 and s.len <= core.keymap.SEQ_CAP);
            for (std.enums.values(core.keymap.Action)) |b| {
                if (a == b) continue;
                for (km.seqs.getPtrConst(b)[0..km.counts.get(b)]) |t| try std.testing.expect(!s.eql(t));
            }
        }
    }
    // And the app still runs with it.
    var app = try core.App.init(gpa, "/k");
    defer app.deinit();
    try app.loadKeymap(src);
    _ = try app.addDir(app.root, &.{.{ .name = "a", .kind = .dir, .size = 1 }});
    for ("jkhlgGqx!") |k| _ = try app.handleKey(core.Key.char(k));
}

test "fuzz: keymap.zon parsing" {
    try std.testing.fuzz({}, parse, .{ .corpus = &corpus });
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
