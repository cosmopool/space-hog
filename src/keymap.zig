const std = @import("std");
const Allocator = std.mem.Allocator;

/// A key press. Shifted letters arrive as their uppercase codepoint.
pub const Key = struct {
    code: u21,
    ctrl: bool = false,

    pub const ESC: u21 = 0x1b;
    pub const ENTER: u21 = '\r';
    pub const TAB: u21 = '\t';
    // Above the Unicode range, so no typed character can collide with them.
    pub const UP: u21 = 0x110000;
    pub const DOWN: u21 = 0x110001;
    pub const LEFT: u21 = 0x110002;
    pub const RIGHT: u21 = 0x110003;

    /// Ctrl-C: always quits, reserved from the keymap.
    pub const QUIT: Key = .{ .code = 'c', .ctrl = true };

    pub fn char(c: u21) Key {
        return .{ .code = c };
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.code == b.code and a.ctrl == b.ctrl;
    }
};

pub const Action = enum {
    down,
    up,
    parent,
    enter,
    top,
    bottom,
    half_down,
    half_up,
    trash,
    delete,
    rescan,
    log,
    quit,
};

pub const SEQ_CAP = 4;
pub const SEQS_PER_ACTION = 4;

pub const Seq = struct {
    keys: [SEQ_CAP]Key = undefined,
    len: u8 = 0,

    pub fn slice(s: *const Seq) []const Key {
        return s.keys[0..s.len];
    }

    pub fn eql(a: Seq, b: Seq) bool {
        if (a.len != b.len) return false;
        for (a.keys[0..a.len], b.keys[0..b.len]) |x, y| if (!x.eql(y)) return false;
        return true;
    }

    /// Vim-style text for messages, e.g. "g", "<C-d>".
    pub fn format(s: *const Seq, buf: *[32]u8) []const u8 {
        var n: usize = 0;
        for (s.slice()) |k| {
            const piece_buf = buf[n..];
            const piece = if (k.ctrl)
                std.fmt.bufPrint(piece_buf, "<C-{u}>", .{k.code}) catch break
            else if (k.code > 0x10ffff)
                std.fmt.bufPrint(piece_buf, "<{s}>", .{switch (k.code) {
                    Key.UP => "up",
                    Key.DOWN => "down",
                    Key.LEFT => "left",
                    else => "right",
                }}) catch break
            else
                std.fmt.bufPrint(piece_buf, "{u}", .{k.code}) catch break;
            n += piece.len;
        }
        return buf[0..n];
    }

    /// True if `a` is a strict prefix of `b`.
    pub fn isPrefixOf(a: Seq, b: Seq) bool {
        if (a.len >= b.len) return false;
        for (a.keys[0..a.len], b.keys[0..a.len]) |x, y| if (!x.eql(y)) return false;
        return true;
    }

    /// Parses vim-style notation: "j", "gg", "<C-d>", "<esc>", "<cr>", "<tab>", "<space>", "<up>".
    pub fn parse(text: []const u8) ?Seq {
        var s: Seq = .{};
        var i: usize = 0;
        while (i < text.len) {
            if (s.len == SEQ_CAP) return null;
            var key: Key = undefined;
            if (text[i] == '<' and text.len - i > 1) {
                const end = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return null;
                key = parseNamed(text[i + 1 .. end]) orelse return null;
                i = end + 1;
            } else {
                const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
                if (i + n > text.len) return null;
                key = .{ .code = std.unicode.utf8Decode(text[i .. i + n]) catch return null };
                i += n;
            }
            s.keys[s.len] = key;
            s.len += 1;
        }
        if (s.len == 0) return null;
        return s;
    }

    fn parseNamed(name: []const u8) ?Key {
        const named = [_]struct { []const u8, u21 }{
            .{ "esc", Key.ESC },   .{ "cr", Key.ENTER },     .{ "enter", Key.ENTER }, .{ "tab", Key.TAB },
            .{ "space", ' ' },     .{ "lt", '<' },           .{ "up", Key.UP },       .{ "down", Key.DOWN },
            .{ "left", Key.LEFT }, .{ "right", Key.RIGHT },
        };
        for (named) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return .{ .code = n[1] };
        if (name.len == 3 and (name[0] == 'C' or name[0] == 'c') and name[1] == '-' and std.ascii.isAlphabetic(name[2])) {
            return .{ .code = std.ascii.toLower(name[2]), .ctrl = true };
        }
        return null;
    }
};

pub const Keymap = struct {
    seqs: std.EnumArray(Action, [SEQS_PER_ACTION]Seq) = .initFill(undefined),
    counts: std.EnumArray(Action, u8) = .initFill(0),

    pub fn defaults() Keymap {
        var km: Keymap = .{};
        const table = [_]struct { Action, []const []const u8 }{
            .{ .down, &.{ "j", "<down>" } },
            .{ .up, &.{ "k", "<up>" } },
            .{ .parent, &.{ "h", "<left>" } },
            .{ .enter, &.{ "l", "<right>" } },
            .{ .top, &.{"gg"} },
            .{ .bottom, &.{"G"} },
            .{ .half_down, &.{"<C-d>"} },
            .{ .half_up, &.{"<C-u>"} },
            .{ .trash, &.{"x"} },
            .{ .delete, &.{"X"} },
            .{ .rescan, &.{"r"} },
            .{ .log, &.{"!"} },
            .{ .quit, &.{"q"} },
        };
        for (table) |row| {
            for (row[1]) |text| km.add(row[0], Seq.parse(text).?);
        }
        return km;
    }

    fn add(km: *Keymap, action: Action, seq: Seq) void {
        const n = km.counts.getPtr(action);
        if (n.* == SEQS_PER_ACTION) return;
        km.seqs.getPtr(action)[n.*] = seq;
        n.* += 1;
    }

    /// Removes `seq` from every action other than `keep`. Returns true if something was removed.
    fn unbindOthers(km: *Keymap, keep: Action, seq: Seq) bool {
        var removed = false;
        for (std.enums.values(Action)) |a| {
            if (a == keep) continue;
            const list = km.seqs.getPtr(a);
            const n = km.counts.getPtr(a);
            var i: usize = 0;
            while (i < n.*) {
                if (list[i].eql(seq)) {
                    list[i] = list[n.* - 1];
                    n.* -= 1;
                    removed = true;
                } else i += 1;
            }
        }
        return removed;
    }

    pub const Match = struct { action: ?Action = null, is_prefix: bool = false };

    pub fn match(km: *const Keymap, seq: Seq) Match {
        var m: Match = .{};
        for (std.enums.values(Action)) |a| {
            for (km.seqs.getPtrConst(a)[0..km.counts.get(a)]) |s| {
                if (s.eql(seq)) m.action = a;
                if (seq.isPrefixOf(s)) m.is_prefix = true;
            }
        }
        return m;
    }

    /// Parses keymap.zon over the defaults. Bad entries are skipped and reported in `errs`; never fails except on OOM.
    /// Format: `.{ .trash = .{ "d" }, .top = .{ "gg", "<C-g>" } }` (a single string is also accepted).
    pub fn parse(gpa: Allocator, source: [:0]const u8, errs: *std.ArrayList([]u8)) Allocator.Error!Keymap {
        var km = defaults();
        var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
        defer ast.deinit(gpa);
        if (ast.errors.len > 0) {
            try logErr(gpa, errs, "keymap: syntax error, using defaults", .{});
            return km;
        }
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        defer zoir.deinit(gpa);
        if (zoir.hasCompileErrors()) {
            try logErr(gpa, errs, "keymap: invalid ZON, using defaults", .{});
            return km;
        }
        const root = std.zig.Zoir.Node.Index.root.get(&zoir);
        const fields = switch (root) {
            .struct_literal => |s| s,
            .empty_literal => return km,
            else => {
                try logErr(gpa, errs, "keymap: expected a struct literal, using defaults", .{});
                return km;
            },
        };
        for (fields.names, 0..) |name_nts, i| {
            const name = name_nts.get(&zoir);
            const action = std.meta.stringToEnum(Action, name) orelse {
                try logErr(gpa, errs, "keymap: unknown action '{s}', skipped", .{name});
                continue;
            };
            var parsed: [SEQS_PER_ACTION]Seq = undefined;
            var count: usize = 0;
            const val = fields.vals.at(@intCast(i)).get(&zoir);
            switch (val) {
                .string_literal => |text| {
                    const parsed_one = Seq.parse(text);
                    if (parsed_one == null) {
                        try logErr(gpa, errs, "keymap: bad key '{s}' for '{s}', skipped", .{ text, name });
                    } else if (parsed_one.?.keys[0].eql(Key.QUIT)) {
                        try logErr(gpa, errs, "keymap: <C-c> is reserved for quit, skipped for '{s}'", .{name});
                    } else {
                        parsed[0] = parsed_one.?;
                        count = 1;
                    }
                },
                .array_literal => |range| {
                    for (0..range.len) |j| {
                        const elem = range.at(@intCast(j)).get(&zoir);
                        const text = switch (elem) {
                            .string_literal => |t| t,
                            else => {
                                try logErr(gpa, errs, "keymap: '{s}' entries must be strings, skipped one", .{name});
                                continue;
                            },
                        };
                        const s = Seq.parse(text) orelse {
                            try logErr(gpa, errs, "keymap: bad key '{s}' for '{s}', skipped", .{ text, name });
                            continue;
                        };
                        if (s.keys[0].eql(Key.QUIT)) {
                            try logErr(gpa, errs, "keymap: <C-c> is reserved for quit, skipped for '{s}'", .{name});
                            continue;
                        }
                        if (count == SEQS_PER_ACTION) {
                            try logErr(gpa, errs, "keymap: too many keys for '{s}', extra skipped", .{name});
                            break;
                        }
                        parsed[count] = s;
                        count += 1;
                    }
                },
                .empty_literal => {
                    // `.action = .{}` unbinds the action.
                    km.counts.set(action, 0);
                    continue;
                },
                else => try logErr(gpa, errs, "keymap: '{s}' must be a string or list of strings, skipped", .{name}),
            }
            if (count == 0) continue;
            km.counts.set(action, 0);
            for (parsed[0..count]) |s| {
                if (km.unbindOthers(action, s)) {
                    try logErr(gpa, errs, "keymap: a key for '{s}' was bound to another action; '{s}' wins", .{ name, name });
                }
                km.add(action, s);
            }
        }
        try km.logShadowed(gpa, errs);
        return km;
    }

    /// A binding that is a strict prefix of another (`g` vs `gg`) waits for the next key forever and never fires.
    fn logShadowed(km: *const Keymap, gpa: Allocator, errs: *std.ArrayList([]u8)) Allocator.Error!void {
        for (std.enums.values(Action)) |a| {
            for (km.seqs.getPtrConst(a)[0..km.counts.get(a)]) |short| {
                outer: for (std.enums.values(Action)) |b| {
                    for (km.seqs.getPtrConst(b)[0..km.counts.get(b)]) |long| {
                        if (!short.isPrefixOf(long)) continue;
                        var sb: [32]u8 = undefined;
                        var lb: [32]u8 = undefined;
                        try logErr(gpa, errs, "keymap: '{s}' for '{s}' never fires: '{s}' for '{s}' starts with it", .{
                            short.format(&sb), @tagName(a), long.format(&lb), @tagName(b),
                        });
                        break :outer;
                    }
                }
            }
        }
    }
};

fn logErr(gpa: Allocator, errs: *std.ArrayList([]u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    try errs.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}
